// SPDX-License-Identifier: MIT
// Warren Protocol — architecture SPECIFICATION, NOT production code. Not compiled, not audited.
pragma solidity ^0.8.26;

/// @title ImmutableCore
/// @notice Welfare- и эмиссион-константы, которые НЕЛЬЗЯ изменить голосованием.
///         Вынесены в отдельный контракт без апгрейда, чтобы «DAO урезал бюджет на
///         животных ради токена» было структурно невозможно, а не морально запрещено.
/// @dev См. docs/03.9, docs/06.4, docs/13.2
contract ImmutableCore {
    // ------------------------------------------------------------------ biology
    /// @notice Минимальный возраст самки для первого спаривания (дни). Консервативно.
    uint16 public constant MIN_DOE_BREED_AGE_DAYS = 280;
    /// @notice Минимальный возраст самца (дни).
    uint16 public constant MIN_BUCK_AGE_DAYS = 240;
    /// @notice Максимум окролов на самку в год (этичная low-intensity модель).
    uint16 public constant MAX_LITTERS_PER_DOE_YEAR = 2;
    /// @notice Максимум окролов за жизнь.
    uint16 public constant MAX_LITTERS_LIFETIME = 4;
    /// @notice Минимальный отдых после окрола (дни).
    uint32 public constant MIN_POST_KINDLING_REST_DAYS = 120;
    /// @notice Беременность: окно в днях (28–35, типично ~31 для карликов).
    uint32 public constant GESTATION_MIN_DAYS = 28;
    uint32 public constant GESTATION_MAX_DAYS = 35;
    /// @notice Крольчата остаются с самкой (дни) — жёсткий лок на продажу/переезд.
    uint32 public constant MIN_WITH_DAM_DAYS = 49;
    /// @notice Минимальный возраст передачи/продажи животного (дни) = 8 недель.
    uint32 public constant MIN_TRANSFER_AGE_DAYS = 56;
    /// @notice Потолок «производительности»: всего крольчат за жизнь у одного животного.
    uint16 public constant MAX_KITS_LIFETIME = 18;
    /// @notice Максимально допустимый коэффициент инбридинга (bps, 12.50%). Выше — revert.
    uint16 public constant MAX_INBREEDING_BPS = 1250;
    /// @notice Порог, ниже которого breeding недоступен по welfare.
    uint16 public constant MIN_WELFARE_FOR_BREEDING = 700; // 70.0% of 1000

    // ------------------------------------------------------------------ housing
    /// @notice Минимальная площадь на совместимую пару, см² (3×2 м). Проверка приCapacityProof.
    uint32 public constant MIN_AREA_CM2_PER_PAIR = 60_000;
    /// @notice Минимальная высота, см (100) — «3 прыжка + вертикальная стойка».
    uint16 public constant MIN_ENCLOSURE_HEIGHT_CM = 100;
    /// @notice Животное никогда не содержится одно (кроме медицинского карантина ≤ 14 дней).
    uint16 public constant MIN_GROUP_SIZE = 2;
    uint16 public constant MAX_QUARANTINE_DAYS = 14;

    // ------------------------------------------------------------------ money
    /// @notice Минимальная доля доната, идущая в фонд содержания. Нельзя уменьшить.
    uint16 public constant DONATION_WELFARE_SHARE_BPS = 1000; // 10%
    /// @notice Минимальный welfare-сбор при продаже RCN. Нельзя уменьшить.
    uint16 public constant WELFARE_LEVY_MIN_BPS = 1000;       // 10%
    /// @notice Комиссия продавца суммарно (5 маркет + 10 welfare + 5 род + 5 DAO).
    uint16 public constant SELLER_FEE_MAX_BPS = 2500;
    /// @notice Спред возврата $CLOVER — зачисляется целиком в Welfare Reserve.
    uint16 public constant CLOVER_EXIT_FEE_MIN_BPS = 1000;
    /// @notice Доля «свободной» (необеспеченной фиатом) эмиссии $CLOVER от faucet'а.
    uint16 public constant FREE_REWARD_MAX_BPS = 1000;       // ≤10%

    // ------------------------------------------------------------------ emission
    /// @notice Жёсткий дневной потолок эмиссии $CLOVER.
    uint256 public constant MAX_CLOVER_MINT_PER_DAY = 900_000e6;
    /// @notice Антифарм: максимум наград на адрес в сутки.
    uint256 public constant MAX_REWARD_PER_ADDR_DAY = 250e6;
    /// @notice Правило «анти-SLP»: эмиссия наград ≤ 1.25 × подтверждённое сжигание за 7 дней.
    uint16 public constant REWARD_OVER_BURN_BPS = 12_500;
    /// @notice Максимум свободных трансферов $CLOVER на адрес в сутки (вне protocol routes).
    uint256 public constant MAX_DAILY_TRANSFER = 5_000e6;
    /// @notice Запрет плеча в CareBondPool (bps = 0).
    uint16 public constant MAX_BOND_LEVERAGE_BPS = 0;
    /// @notice Потолок размещения оборотного капитала в DeFi (25%).
    uint16 public constant MAX_OPS_ALLOCATION_BPS = 2500;

    // ------------------------------------------------------------------ UX safety
    /// @notice Максимум донатов на одно животное в час (защита животного от «донат-шторма»).
    uint16 public constant MAX_DONATIONS_PER_RABBIT_HOUR = 12;
    /// @notice Лимит само-доната в энддаумент собственного RCN (анти-само-накрутка), $CLOVER/нед.
    uint256 public constant SELF_DONATION_WEEKLY_CAP = 10_000e6;
    /// @notice Эскроу «transition window» при продаже (дни).
    uint32 public constant SALE_ESCROW_DAYS = 14;
    /// @notice Право первого отказа второй стороны BreedingBond (дни).
    uint32 public constant ROFR_DAYS = 30;

    error Immutable();
    /// @dev Все попытки «отредактировать» эти значения должны приводить сюда.
    modifier immutable() {
        revert Immutable();
        _;
    }
}
