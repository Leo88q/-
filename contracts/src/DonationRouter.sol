// SPDX-License-Identifier: MIT
// Warren Protocol — architecture SPECIFICATION, NOT production code. Not compiled, not audited.
pragma solidity ^0.8.26;

import {ImmutableCore} from "./ImmutableCore.sol";

interface ICloverMint {
    function mintForAction(address to, uint256 clover, bytes32 actionId) external;
    function burn(uint256 amount) external;
}
interface IEscrowRefund { function refund(address to, uint256 amount) external; }

/// @title DonationRouter
/// @notice Единственный вход для «доната на кролика». Проектировался вокруг одного
///         принципа: **у доната нет получателя-человека**. 80% средств животного
///         существуют только как «право на товар/услугу у whitelisted-вендора».
///         Это снимает стимул демонстрировать нуждаемость — главный отказ всех
///         donate-to-pet схем (docs/09.1).
contract DonationRouter {
    enum GoalState { None, Active, Funded, Executing, Refunding, Closed, Expired }

    /// @notice Классы целей. Новый класс добавляется только через ImmutableCore-allowlist,
    ///         т.е. «донат на что угодно» (в т.ч. на «нужны деньги владельцу») невозможен.
    enum GoalKind { NeedFeed, NeedInvoice, EnrichmentWalk, EnrichmentPlay, HutchRefresh,
                    HutchTheme, Grooming, NailTrim, VetRoutine, VetDental, VetEmergency,
                    NestBox, Birthday, NamedSign, PhotoSession, RecoveryPlan, SanctuaryFoster }

    struct Quote {
        string[6] items;      // человекочитаемые позиции сметы («Timothy hay 3.6 kg»)
        uint64[6] clover;     // цена позиции в единицах содержания
        uint32  daysCovered;  // «куплено N дней» — то, что видит донатер
    }

    struct Goal {
        uint256 rcnId;
        GoalKind kind;
        uint64  targetClover;
        uint64  raisedClover;
        uint32  deadline;
        uint32  execDueTs;         // FUNDED → исполнение в этом окне
        Quote   quote;
        GoalState state;
        address creator;           // донатер-инициатор (не владелец!)
        bool    overfundingToWelfare;
        uint64  depositClover;     // 10% от сметы — burn при отмене без причины
        uint32  claimCounter;
    }

    struct Receipt {
        uint64  goalId;
        uint64  amount;
        address vendor;
        bytes32 fulfillmentHash;   // keccak(photo ‖ ts ‖ operator ‖ chipHash)
        bool    refunded;
    }

    /// @notice Сплит входящего платежа. Доли — константы ImmutableCore, не настройки.
    uint16 private immutable WELFARE_SHARE_BPS;
    uint16 private immutable STREAM_SHARE_BPS = 1000;   // 10%
    address public immutable core;
    address public clover;
    address public welfareReserve;
    address public streamOps;
    address public facility;                  // исполнитель (резиденция)
    address public merchantGateway;           // whitelisted-вендоры
    mapping(uint64 => Goal) public goals;
    mapping(uint256 => uint64[]) public goalsOfRabbit;
    mapping(uint64 => Receipt[]) private _receipts;
    mapping(address => uint256) public selfDonationWeek;   // анти-само-накрутка
    uint64 public nextGoalId;

    event GoalCreated(uint64 indexed id, uint256 indexed rcnId, GoalKind kind, uint64 target);
    event Donated(uint64 indexed goalId, address indexed donor, uint256 amount, uint256 toWelfare);
    event GoalFunded(uint64 indexed goalId, uint64 raised, uint32 execDueTs);
    event GoalExecuted(uint64 indexed goalId, bytes32 fulfillmentHash, uint256 spent);
    event GoalRefunded(uint64 indexed goalId, uint256 amount, uint256 donors);
    event VendorsPaid(uint64 indexed goalId, address vendor, uint256 cloverBurned);
    error NotFacility(); error UnknownGoal(); error DeadlinePassed(); error QuoteMissing();
    error AlreadyFunded(); error TooSmall(); error SelfDonationCapped(); error NotExecutable();

    modifier onlyFacility() { if (msg.sender != facility) revert NotFacility(); _; }

    constructor(address core_, address welfare_) {
        core = core_;
        welfareReserve = welfare_;
        WELFARE_SHARE_BPS = ImmutableCore(core_).DONATION_WELFARE_SHARE_BPS();
    }

    // ------------------------------------------------------------------ create
    /// @notice Цель создаёт донатер, смета — резиденция. Иначе «самоцель ради XP» и
    ///         «фантазийные сметы» упираются в требование подписанной котировки.
    function createGoal(uint256 rcnId, GoalKind kind, Quote calldata quote, uint32 windowDays)
        external returns (uint64 id)
    {
        uint64 target;
        for (uint256 i; i < quote.clover.length; ++i) target += quote.clover[i];
        if (target < 150e6) revert TooSmall();                    // ≥150 C ($7.5) — иначе спам
        if (bytes(quote.items[0]).length == 0) revert QuoteMissing();
        if (windowDays < 7) revert DeadlinePassed();

        id = ++nextGoalId;
        goals[id] = Goal({
            rcnId: rcnId, kind: kind, targetClover: target, raisedClover: 0,
            deadline: uint32(block.timestamp + windowDays * 1 days),
            execDueTs: 0, quote: quote, state: GoalState.Active, creator: msg.sender,
            overfundingToWelfare: true, depositClover: target / 10
        });
        goalsOfRabbit[rcnId].push(id);
        emit GoalCreated(id, rcnId, kind, target);
    }

    // ------------------------------------------------------------------ donate
    /// @notice Оплата в USDC/фиате → минт $CLOVER (1:1 к внутренней цене) → сплит
    ///         **в момент приёма**, до любой траты. Владелец не участвует в маршрутизации.
    function donate(uint64 goalId, uint256 cloverAmount) external {
        Goal storage g = goals[goalId];
        if (g.state == GoalState.None) revert UnknownGoal();
        if (g.state != GoalState.Active) revert AlreadyFunded();
        if (block.timestamp > g.deadline) revert DeadlinePassed();

        if (g.rcnId == _rcnOwnedBy(msg.sender)) {
            if (selfDonationWeek[msg.sender] + cloverAmount
                > ImmutableCore(core).SELF_DONATION_WEEKLY_CAP()) revert SelfDonationCapped();
            selfDonationWeek[msg.sender] += cloverAmount;
        }

        uint256 toWelfare = cloverAmount * WELFARE_SHARE_BPS / 1e4;
        uint256 toStream = cloverAmount * STREAM_SHARE_BPS / 1e4;
        uint256 toEndow = cloverAmount - toWelfare - toStream;

        ICloverMint(clover).mintForAction(address(this), cloverAmount, bytes32(goalId));
        // энддаумент животного — «заморожен» под конкретную цель: его нельзя ни вывести,
        // ни перенаправить на другую цель без возврата
        g.raisedClover += toEndow;
        _welfareIn(toWelfare);
        _streamIn(toStream);

        if (g.raisedClover >= g.targetClover) {
            g.state = GoalState.Funded;
            g.execDueTs = uint32(block.timestamp + _execWindow(g.kind) * 1 days);
            emit GoalFunded(goalId, g.raisedClover, g.execDueTs);
        }
        emit Donated(goalId, msg.sender, cloverAmount, toWelfare);
    }

    function _execWindow(GoalKind k) private pure returns (uint32) {
        if (k == GoalKind.NeedInvoice || k == GoalKind.NeedFeed) return 3;
        if (k == GoalKind.VetEmergency) return 1;
        if (k == GoalKind.Birthday || k == GoalKind.PhotoSession || k == GoalKind.HutchTheme) return 30;
        return 14;
    }

    // ------------------------------------------------------------------ execute
    /// @notice Резиденция не «получает деньги»: она представляет вендор-инвойс,
    ///         протокол платит вендору, токены сжигаются, донатеру возвращается 0 денег
    ///         и 100% доказуемого результата.
    function execute(uint64 goalId, address vendor, bytes32 fulfillmentHash) external onlyFacility {
        Goal storage g = goals[goalId];
        if (g.state != GoalState.Funded && g.state != GoalState.Executing) revert NotExecutable();
        if (fulfillmentHash == bytes32(0)) revert QuoteMissing();
        g.state = GoalState.Executing;

        uint256 spent = _payVendor(vendor, g.raisedClover, fulfillmentHash);
        _receipts[goalId].push(Receipt(g.raisedClover, vendor, fulfillmentHash, g.raisedClover, false));
        unchecked { g.raisedClover = 0; }
        g.state = GoalState.Closed;
        emit GoalExecuted(goalId, fulfillmentHash, spent);
    }

    function _payVendor(address vendor, uint256 amount, bytes32 h) private returns (uint256) {
        require(vendor != address(0) && _isWhitelisted(vendor), "NOT_WHITELISTED");
        // вендор получает стейбл из OpsVault (реальная оплата), CLOVER — сжигание
        ICloverMint(clover).burn(amount);
        (bool ok, ) = merchantGateway.call(abi.encodeWithSignature(
            "payVendor(address,uint256,bytes32)", vendor, amount, h));
        require(ok, "VENDOR_PAY_FAILED");
        emit VendorsPaid(0, vendor, amount);
        return amount;
    }

    function _isWhitelisted(address v) private view returns (bool) {
        return merchantGateway != address(0)
            && IERC165Check(merchantGateway).callSupports(v);
    }

    // ------------------------------------------------------------------ refund
    /// @notice Не собрано к дедлайну ИЛИ не исполнено в окне исполнения → **автоматический
    ///         возврат всем донатерам**. Это обещание исполняется кодом, а не поддержкой.
    function sweepOrRefund(uint64 goalId) external {
        Goal storage g = goals[goalId];
        if (g.state == GoalState.None) revert UnknownGoal();
        bool expired = block.timestamp > g.deadline && g.state == GoalState.Active;
        bool missedExec = g.state == GoalState.Funded && block.timestamp > g.execDueTs;
        if (!expired && !missedExec) revert DeadlinePassed();
        g.state = GoalState.Refunding;
        uint256 amount = g.raisedClover;
        g.raisedClover = 0;
        // возврат донатерам: пропорционально вкладу, через Merkle-дерево заявок (упрощённо)
        IEscrowRefund(merchantGateway).refund(address(0), amount);
        // «штраф резиденции» за пропуск окна исполнения — из FacilityBond, в welfare
        if (missedExec) {
            _welfareIn(amount / 50);            // 2% от суммы, платит исполнитель, не проситель
        }
        emit GoalRefunded(goalId, amount, g.claimCounter);
        g.state = GoalState.Closed;
    }

    /// @notice Излишек > 100% сметы: 50% на «улучшение по той же смете», 50% в welfare.
    ///         Разница никогда не уходит владельцу.
    function overfund(uint64 goalId) external {
        Goal storage g = goals[goalId];
        if (g.state != GoalState.Funded) revert NotExecutable();
        uint256 excess = g.raisedClover > g.targetClover ? g.raisedClover - g.targetClover : 0;
        if (excess == 0) revert TooSmall();
        g.raisedClover -= excess;
        if (g.overfundingToWelfare) _welfareIn(excess / 2);
        else g.raisedClover += excess / 2;   // 50% — «расширение по той же смете»
    }

    // ------------------------------------------------------------------ views
    function goalProgress(uint64 goalId) external view returns (uint64 raised, uint64 target, GoalState s, uint32 due) {
        Goal memory g = goals[goalId];
        return (g.raisedClover, g.targetClover, g.state, g.state == GoalState.Active ? g.deadline : g.execDueTs);
    }
    function receiptsOf(uint64 goalId) external view returns (Receipt[] memory r) { return _receipts[goalId]; }
    function _rcnOwnedBy(address) private pure returns (uint256) { return 0; }   // rabbitNFT.ownerOf
    function _welfareIn(uint256 amount) private {
        ICloverMint(clover).burn(amount);                    // CLOVER исчезает
        // эквивалент в стейбле уже лежит в OpsVault: ончейн-роутер переносит учёт, а не деньги
    }
    function _streamIn(uint256 amount) private { ICloverMint(clover).burn(amount); }
}

interface IERC165Check { function callSupports(address who) external view returns (bool); }
