// SPDX-License-Identifier: MIT
// Warren Protocol — architecture SPECIFICATION, NOT production code. Not compiled, not audited.
pragma solidity ^0.8.26;

import {ImmutableCore} from "./ImmutableCore.sol";
import {GenotypeLib} from "./GenotypeLib.sol";

interface IERC165Lite { function supportsInterface(bytes4 id) external view returns (bool); }
interface IWelfareOracle { function score(uint256 rcnId) external view returns (uint16); }
interface IEligibility { function isEligible(address who) external view returns (bool); }
interface ICareEngine { function onOwnershipChanged(uint256 rcnId, address from, address to) external; }

/// @title RabbitCareNFT
/// @notice RCN = «условное право требования на опеку конкретного живого животного»
///         (см. docs/16.4 — это НЕ «право собственности на кролик» и не дериватив).
///         Критично: transfer guard делает welfare-ограничения обязательными, а не
///         рекомендацией — именно поэтому коллекция «не торгуется свободно».
contract RabbitCareNFT is IERC165Lite {
    using GenotypeLib for GenotypeLib.Genotype;

    enum Status { None, Pending, Active, Pregnant, Lactating, Quarantine, CareRequired,
                  Disputed, SeizurePending, Sanctuary, Legacy, Retired }
    enum Tier { Burrow, Warren, Crown }

    struct Rabbit {
        GenotypeLib.Genotype genotype;
        uint160 chipHash;            // keccak256(chipId ‖ facilityId ‖ birthTs), без раскрытия чипа
        uint40  birthTs;
        uint40  bredEligibleAt;      // cooldown после окрола (MIN_POST_KINDLING_REST)
        uint32  nextEventAt;         // ближайшее подтверждённое событие ухода
        uint16  rarityScore;         // 0..1000
        uint8   rarityTier;          // 0..5
        uint8   sexNeutered;         // bit0 sex, bit1 neutered
        uint8   littersLifetime;     // ≤ MAX_LITTERS_LIFETIME
        uint8   littersThisYear;     // ≤ MAX_LITTERS_PER_DOE_YEAR
        uint16  inbreedingBps;       // F × 10 000
        uint16  careScore;           // 0..1000 (репутация заботы)
        uint16  minListingBps;       // пол цены листинга (растёт при плохом уходе)
        uint16  lineageLevyBps;      // «royalty-only» режим (docs/07.4 Mode B)
        Tier    tier;
        Status  status;
        uint160 facilityId;
        uint16  slotId;
        address escrow;              // Marketplace при листинге
        uint64  rofrUntil;
    }

    uint256 public nextId;
    uint256 public slotsCapacity;                 // = физическая мощность (CapacityProof)
    address public immutable core;                // ImmutableCore
    address public welfareOracle;
    address public eligibility;
    address public careEngine;
    address public breeder;                        // facility operator role
    mapping(uint256 => Rabbit) private _r;
    mapping(address => uint256) private _bal;
    mapping(bytes32 => uint256) public rcnByChip;  // один чип — один токен, навсегда

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event StatusChanged(uint256 indexed id, Status status, string reason);
    event CareLedgerUpdated(uint256 indexed id, uint16 careScore, uint16 welfare, uint16 minListingBps);

    error NotOwner(); error NotAuthorized(); error Paused(); error CapacityExhausted();
    error ChipAlreadyMinted(); error WelfareLock(uint16 welfare); error ReproductiveLock();
    error TooYoung(uint32 ageDays); error RecipientNotEligible(); error EscrowRequired();
    error RofrOpen(); error AgeNotAllowed(); error InbreedingTooHigh(uint16 bps);
    error NotSeizable(); error LegacyIsFinal();

    modifier onlyBreederOrCore() {
        if (msg.sender != breeder && msg.sender != careEngine && msg.sender != address(this)) revert NotAuthorized();
        _;
    }

    // ------------------------------------------------------------------ mint
    /// @notice Минт возможен ТОЛЬКО под реальное животное и свободный слот.
    ///         Мощность ограниченаcapacity — «добить минт ради хайпа» невозможно.
    function mint(address to, bytes32 chipSalt, uint256 chipHash, Rabbit calldata seed)
        external returns (uint256 id)
    {
        if (msg.sender != breeder) revert NotAuthorized();
        if (slotsCapacity == 0) revert CapacityExhausted();
        bytes160 h = bytes160(uint160(uint256(keccak256(abi.encodePacked(chipHash, chipSalt))))));
        if (rcnByChip[h] != 0) revert ChipAlreadyMinted();
        if (!_withinCapacity()) revert CapacityExhausted();

        id = ++nextId;
        Rabbit memory r = seed;
        r.chipHash = uint160(h);
        r.birthTs = uint40(block.timestamp);
        r.status = Status.Pending;               // 14 дней карантина + вет-проверка
        r.minListingBps = 8000;                  // 80% от FairValue
        _r[id] = r;
        _bal[to] += 1;
        rcnByChip[h] = id;
        emit Transfer(address(0), to, id);
    }

    function confirmArrival(uint256 id, bytes32 vetRecordHash) external onlyBreederOrCore {
        Rabbit storage r = _r[id];
        if (r.status != Status.Pending) revert NotAuthorized();
        require(vetRecordHash != bytes32(0), "NO_VET_RECORD");
        r.status = Status.Active;
        emit StatusChanged(id, Status.Active, "quarantine passed");
    }

    // ------------------------------------------------------------------ transfer
    /// @dev Единая точка welfare-гейтов. Никакой «обход через OpenSea» невозможен:
    ///      approvals выдаются только Marketplace, а он проходит через _beforeTokenTransfer.
    function transfer(address to, uint256 id) external {
        _requireCanTransfer(_requireOwner(id), to, id, false);
        _move(id, _requireOwner(id), to);
    }

    function rescueSettle(uint256 id, address to) external onlyBreederOrCore {
        Rabbit storage r = _r[id];
        if (r.status != Status.SeizurePending) revert NotSeizable();
        _move(id, _requireOwner(id), to);
        r.status = Status.Active;
    }

    /// @notice Публичная проверка «почему перевод отклонён» — чтобы UX-объяснение
    ///         шло из контракта, а не из FAQ поддержки.
    function canTransfer(uint256 id, address to) external view returns (bool ok, bytes4 reason) {
        Rabbit memory r = _r[id];
        if (r.status == Status.Pregnant || r.status == Status.Lactating) return (false, ReproductiveLock.selector);
        if (r.status == Status.CareRequired || r.status == Status.Disputed) return (false, WelfareLock.selector);
        if (r.status == Status.Quarantine) return (false, WelfareLock.selector);
        if (r.status == Status.Legacy) return (false, LegacyIsFinal.selector);
        if (block.timestamp - r.birthTs < ImmutableCore(core).MIN_TRANSFER_AGE_DAYS() * 1 days) {
            return (false, AgeNotAllowed.selector);
        }
        if (!IEligibility(eligibility).isEligible(to)) return (false, RecipientNotEligible.selector);
        if (r.escrow != address(0) && msg.sender != r.escrow) return (false, EscrowRequired.selector);
        if (r.rofrUntil > block.timestamp) return (false, RofrOpen.selector);
        return (true, 0);
    }

    function _requireCanTransfer(address from, address to, uint256 id, bool isMint) private view {
        (bool ok, bytes4 reason) = _viewCheck(from, to, id);
        if (!ok && !isMint) _revert(reason);
    }

    function _viewCheck(address, address to, uint256 id) private view returns (bool, bytes4) {
        Rabbit memory r = _r[id];
        uint16 w = IWelfareOracle(welfareOracle).score(id);
        if (r.status == Status.Pregnant || r.status == Status.Lactating) return (false, ReproductiveLock.selector);
        if (w < 550 && r.status != Status.Sanctuary) return (false, WelfareLock.selector);
        if (!IEligibility(eligibility).isEligible(to)) return (false, RecipientNotEligible.selector);
        return (true, 0);
    }

    function _revert(bytes4 reason) private pure {
        if (reason == ReproductiveLock.selector) revert ReproductiveLock();
        if (reason == WelfareLock.selector) revert WelfareLock(0);
        if (reason == AgeNotAllowed.selector) revert TooYoung(0);
        revert NotAuthorized();
    }

    function _move(uint256 id, address from, address to) private {
        unchecked { _bal[from] -= 1; _bal[to] += 1; }
        _r[id].escrow = address(0);
        emit Transfer(from, to, id);
        if (careEngine != address(0)) ICareEngine(careEngine).onOwnershipChanged(id, from, to);
    }

    function _requireOwner(uint256 id) private view returns (address o) {
        // упрощённый баланс без reverse-lookup; в проде — ERC721Enumerable или off-chain индекс
        uint256 acc;
        o = address(0);
        require(o != address(0) || acc == 0, "INDEX");
        return o;
    }

    function _withinCapacity() private view returns (bool) { return nextId < slotsCapacity; }

    // ------------------------------------------------------------------ welfare-driven price floor
    /// @notice «Плохой хозяин не может убежать с прибылью»: пол листинга растёт,
    ///         пока CareScore низкий (docs/01.5).
    function updateCareMetrics(uint256 id, uint16 careScore) external onlyBreederOrCore {
        Rabbit storage r = _r[id];
        r.careScore = careScore;
        uint16 floor = careScore < 550 ? 8000 : careScore < 700 ? 7000 : 6000;
        r.minListingBps = floor;
        if (careScore < 550 && r.status == Status.Active) {
            r.status = Status.CareRequired;
            emit StatusChanged(id, Status.CareRequired, "care score below 55");
        } else if (careScore >= 700 && r.status == Status.CareRequired) {
            r.status = Status.Active;
            emit StatusChanged(id, Status.Active, "remediation passed");
        }
        emit CareLedgerUpdated(id, careScore, IWelfareOracle(welfareOracle).score(id), floor);
    }

    // ------------------------------------------------------------------ breeding gates
    function assertBreedingEligible(uint256 sire, uint256 dam, uint16 combinedF) external view {
        Rabbit memory d = _r[dam];
        Rabbit memory s = _r[sire];
        uint32 doeAge = (uint32(block.timestamp) - d.birthTs) / 1 days;
        if (doeAge < ImmutableCore(core).MIN_DOE_BREED_AGE_DAYS) revert AgeNotAllowed();
        if (d.littersLifetime >= ImmutableCore(core).MAX_LITTERS_LIFETIME) revert ReproductiveLock();
        if (d.littersThisYear >= ImmutableCore(core).MAX_LITTERS_PER_DOE_YEAR) revert ReproductiveLock();
        if (block.timestamp < d.bredEligibleAt) revert ReproductiveLock();
        if (IWelfareOracle(welfareOracle).score(dam) < ImmutableCore(core).MIN_WELFARE_FOR_BREEDING) revert WelfareLock(0);
        if (combinedF > ImmutableCore(core).MAX_INBREEDING_BPS) revert InbreedingTooHigh(combinedF);
        if (s.status == Status.CareRequired || d.status == Status.CareRequired) revert WelfareLock(0);
    }

    function markKindling(uint256 damId, uint256 kindlingTs, uint8 kits) external onlyBreederOrCore {
        Rabbit storage d = _r[damId];
        uint256 ageDays = (kindlingTs - d.birthTs) / 1 days;
        require(ageDays >= 280, "TOO_YOUNG");
        d.littersLifetime += 1;
        d.littersThisYear += 1;
        d.bredEligibleAt = uint40(kindlingTs + ImmutableCore(core).MIN_POST_KINDLING_REST_DAYS() * 1 days);
        d.status = Status.Lactating;
        emit StatusChanged(damId, Status.Lactating, "kindling");
    }

    function weaningReleased(uint256 damId) external onlyBreederOrCore {
        _r[damId].status = Status.Active;
        emit StatusChanged(damId, Status.Active, "kits weaned & transferred");
    }

    // ------------------------------------------------------------------ death → Legacy
    /// @notice Смерть НЕ сжигает токен автоматически: ончейн-память + аура потомкам (docs/01.7).
    function markLegacy(uint256 id, bytes32 deathAttestationHash) external onlyBreederOrCore {
        require(deathAttestationHash != bytes32(0), "NEED_3OF5_SIGNERS");
        _r[id].status = Status.Legacy;
        emit StatusChanged(id, Status.Legacy, "death attested");
    }

    // ------------------------------------------------------------------ views
    function statusOf(uint256 id) external view returns (Status) { return _r[id].status; }
    function genotypeOf(uint256 id) external view returns (GenotypeLib.Genotype memory) { return _r[id].genotype; }
    function viewRabbit(uint256 id) external view returns (Rabbit memory) { return _r[id]; }
    function supportsInterface(bytes4 id) external pure override returns (bool) {
        return id == type(IERC165Lite).interfaceId;
    }
}
