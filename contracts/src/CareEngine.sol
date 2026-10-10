// SPDX-License-Identifier: MIT
// Warren Protocol — architecture SPECIFICATION, NOT production code. Not compiled, not audited.
pragma solidity ^0.8.26;

import {ImmutableCore} from "./ImmutableCore.sol";

interface IClover {
    function burnFrom(address from, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
    function balanceOf(address who) external view returns (uint256);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
}

interface IRabbit {
    function updateCareMetrics(uint256 id, uint16 careScore) external;
    function rescueSettle(uint256 id, address to) external;
    function statusOf(uint256 id) external view returns (uint8);
}

/// @title CareEngine
/// @notice Месячный инвойс содержания, авто-погашение из энддаумента кролика, CareDebt,
///         эскалация до изъятия. Ключевой «стик» экономики: его нельзя отключить,
///         отложить навсегда или «оплатить будущим минтом» (docs/04, docs/01.6).
contract CareEngine {
    enum InvoiceState { Open, Paid, AutoPaidFromEndowment, Overdue, Escalated, SeizurePending }

    struct Invoice {
        uint64  period;          // 202603
        uint96  baseClover;      // tier-ставка
        uint96  servicesClover;  // вет/груминг/ремонт по факту
        uint16  discountBps;     // streak/titles/партнёрки
        uint40  dueTs;
        InvoiceState state;
    }

    struct CareLedger {
        uint32  unpaid;          // просроченные инвойсы
        uint32  streakPaid;      // серия оплаченного содержания (месяцы)
        uint64  debtClover;      // CareDebt в единицах содержания
        uint40  lastInvoicePaidTs;
        uint32  remediationDeadline;
        bool    restorationOffered;
    }

    /// @notice grace → endowment → restriction → boarding → CARE_REQUIRED → изъятие
    uint32 public constant GRACE_DAYS = 7;
    uint32 public constant RESTRICT_AFTER_DAYS = 7;
    uint32 public constant BOARDING_AFTER_DAYS = 14;
    uint32 public constant CARE_REQUIRED_AFTER_DAYS = 30;
    uint32 public constant SEIZURE_AFTER_DAYS = 60;
    uint16 public constant DEBT_GROWTH_BPS_MONTH = 200;   // +2%/мес. за отложенную заботу
    uint16 public constant RESTATE_BONUS_BPS = 11000;      // тело долга ×110% для прощения
    uint16 public constant STREAK_CASHBACK_BPS = 500;      // 5% кэшбэк за оплату
    uint256 public constant STREAK_CASHBACK_CAP = 90e6;
    uint32 public constant STREAK_12_DISCOUNT_BPS = 1000;  // 12 мес. подряд → −10%

    address public immutable core;
    address public clover;
    address public rabbitNFT;
    address public facility;                    // резиденция: получает «compensation» не деньгами, а исполнением
    address public welfareReserve;
    mapping(uint256 => mapping(uint64 => Invoice)) private _inv;
    mapping(uint256 => CareLedger) public ledger;
    mapping(uint256 => uint64) public openPeriods;          // bitmap периодов (упрощённо)

    event InvoiceIssued(uint256 indexed rcnId, uint64 period, uint96 amount);
    event InvoicePaid(uint256 indexed rcnId, uint64 period, bool fromEndowment, uint256 cashback);
    event Escalated(uint256 indexed rcnId, uint32 daysLate, InvoiceState state);
    event DebtRestated(uint256 indexed rcnId, uint64 paid, uint64 remaining);
    event SeizureTriggered(uint256 indexed rcnId, address to);

    error NotFacility(); error NoInvoice(); error AlreadyPaid(); error DebtOutstanding();

    modifier onlyFacility() { if (msg.sender != facility) revert NotFacility(); _; }

    // ------------------------------------------------------------------ issue
    /// @notice Инвойс выставляется автоматически по мощности, а не «по решению оператора»:
    ///         база = f(tier), услуги — по факту исполненных процедур.
    function issue(uint256 rcnId, uint64 period, uint96 base, uint96 services, uint16 discountBps)
        external onlyFacility
    {
        require(_inv[rcnId][period].dueTs == 0, "DUP");
        _inv[rcnId][period] = Invoice({
            period: period,
            baseClover: base,
            servicesClover: services,
            discountBps: discountBps > 2500 ? 2500 : discountBps,   // суммарный потолок скидки 25%
            dueTs: uint40(block.timestamp + GRACE_DAYS * 1 days),
            state: InvoiceState.Open
        });
        openPeriods[rcnId] |= 1 << (period % 64);
        emit InvoiceIssued(rcnId, period, base + services);
    }

    // ------------------------------------------------------------------ pay
    /// @notice Оплата: сжигание $CLOVER (100% base) + часть услуг идёт вендору через
    ///         MerchantGateway. Кэшбэк за своевременность — единственный «faucet» владельца.
    function pay(uint256 rcnId, uint64 period) external returns (uint256 burned) {
        Invoice storage i = _inv[rcnId][period];
        if (i.dueTs == 0) revert NoInvoice();
        if (i.state == InvoiceState.Paid || i.state == InvoiceState.AutoPaidFromEndowment) revert AlreadyPaid();

        uint256 amount = uint256(i.baseClover) + i.servicesClover;
        amount = amount * (1e4 - i.discountBps) / 1e4;
        amount += ledger[rcnId].debtClover > 0 ? 0 : 0;

        CareLedger storage l = ledger[rcnId];
        address payer = msg.sender;
        uint256 avail = IClover(clover).balanceOf(payer);
        if (avail < amount && payer == tx.origin) {
            // не хватает у владельца → авто-покрытие из энддаумента животного (T+3)
            _payFromEndowment(rcnId, amount);
            l.unpaid += 1;                      // фиксируем «не сам заплатил» — это дефолт по обязательствам
            i.state = InvoiceState.AutoPaidFromEndowment;
        } else {
            require(IClover(clover).transferFrom(payer, address(this), amount), "XFER");
            IClover(clover).burnFrom(address(this), (amount * i.baseClover) / (i.baseClover + i.servicesClover));
            i.state = InvoiceState.Paid;
        }
        burned = amount;

        // кэшбэк и серия
        uint256 cashback = amount * STREAK_CASHBACK_BPS / 1e4;
        if (cashback > STREAK_CASHBACK_CAP) cashback = STREAK_CASHBACK_CAP;
        if (block.timestamp <= i.dueTs) {
            l.streakPaid += 1;
            IClover(clover).mint(payer, uint96(cashback));
        } else {
            l.streakPaid = 0;
            // «восстановление серии» 1×/квартал — за XP, а не за деньги (docs/08.4)
        }
        l.lastInvoicePaidTs = uint40(block.timestamp);
        openPeriods[rcnId] &= ~(1 << (period % 64));
        emit InvoicePaid(rcnId, period, i.state == InvoiceState.AutoPaidFromEndowment, cashback);
    }

    function _payFromEndowment(uint256 rcnId, uint256 amount) private {
        // энддаумент лежит в TBA животного; у нас право списать — только на содержание
        (bool ok, ) = _tbaOf(rcnId).call(abi.encodeWithSignature("spendForCare(uint256)", amount));
        require(ok, "ENDOWMENT_SHORT");
    }

    function _tbaOf(uint256 rcnId) private view returns (address) {
        // ERC-6551 registry deterministic address (упрощённо)
        return address(uint160(uint256(keccak256(abi.encode("TBA", rcnId)))));
    }

    // ------------------------------------------------------------------ escalation
    /// @notice Кто угодно может вызвать проверку просрочки (в т.ч. DAO/донатер) —
    ///         это не «донос владельца на себя», а публичный контроль.
    function escalate(uint256 rcnId) external {
        CareLedger storage l = ledger[rcnId];
        if (l.lastInvoicePaidTs == 0) return;
        uint32 late = uint32((block.timestamp - l.lastInvoicePaidTs) / 1 days);
        if (late < 30) return;

        InvoiceState s = late >= SEIZURE_AFTER_DAYS ? InvoiceState.SeizurePending
                     : late >= CARE_REQUIRED_AFTER_DAYS ? InvoiceState.Escalated
                     : InvoiceState.Overdue;
        IRabbit(rabbitNFT).updateCareMetrics(rcnId, late >= CARE_REQUIRED_AFTER_DAYS ? 400 : 700);
        if (s == InvoiceState.Escalated) {
            l.remediationDeadline = uint32(block.timestamp + 30 days);
            emit Escalated(rcnId, late, s);
        }
        if (s == InvoiceState.SeizurePending && !l.restorationOffered) {
            l.restorationOffered = true;          // шанс на «board-патронаж» (docs/01.6 T+14)
            emit Escalated(rcnId, late, s);
        }
        l.unpaid += 1;
    }

    /// @notice Погашение долга: 110% тела. До погашения — запрет на вывод выручки от продажи
    ///         (она идёт на долг приоритетно), breeding и конкурсы.
    function restateDebt(uint256 rcnId) external {
        CareLedger storage l = ledger[rcnId];
        if (l.debtClover == 0) revert DebtOutstanding();
        uint256 need = l.debtClover * RESTATE_BONUS_BPS / 1e4;
        require(IClover(clover).transferFrom(msg.sender, welfareReserve, need), "XFER");
        emit DebtRestated(rcnId, need, 0);
        l.debtClover = 0;
        l.unpaid = 0;
        IRabbit(rabbitNFT).updateCareMetrics(rcnId, 720);   // «чистый лист с историей»
    }

    function accrueDebt(uint256 rcnId) external onlyFacility {
        CareLedger storage l = ledger[rcnId];
        if (l.unpaid > 0) l.debtClover += l.debtClover * DEBT_GROWTH_BPS_MONTH / 1e4;
    }

    /// @notice Финальная стадия: токен переходит попечителю/фонду, животное НЕ покидает
    ///         резиденцию (разлука bonded-группы — самостоятельный стресс-фактор).
    function seize(uint256 rcnId, address guardian) external onlyFacility {
        CareLedger storage l = ledger[rcnId];
        require(l.unpaid >= 2, "NOT_ENOUGH");
        IRabbit(rabbitNFT).rescueSettle(rcnId, guardian);
        emit SeizureTriggered(rcnId, guardian);
    }

    // ------------------------------------------------------------------ views
    function invoiceOf(uint256 rcnId, uint64 p) external view returns (Invoice memory) { return _inv[rcnId][p]; }
    function discountFor(uint256 rcnId) public view returns (uint16) {
        CareLedger memory l = ledger[rcnId];
        return l.streakPaid >= 12 ? STREAK_12_DISCOUNT_BPS : uint16(min(l.streakPaid, 6) * 100);
    }
    function min(uint32 a, uint32 b) private pure returns (uint32) { return a < b ? a : b; }
}
