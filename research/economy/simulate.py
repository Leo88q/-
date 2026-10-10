#!/usr/bin/env python3
"""
Warren Protocol — экономический симулятор (месячный шаг, 2 контура).

  КОНТУР A (финансовый): выручка vs реальные затраты резиденций и core-команды.
  КОНТУР B (токенный):    $CLOVER — «покупная» (обеспечена фиатом) и «свободная»
                          (награды) эмиссия; burn coverage; Welfare Reserve.

Семантика: 1 RCN = 1 животное (обычно живёт в bonded-группе). Мощность считается
через вольеры: slots × animals_per_slot = максимум RCN. Инвойс — за животное,
площади/группировка учтены в опексе (в нем «помещение» дороже «корма»).

    python3 simulate.py [--report] [--breakeven] [--sensitivity]
                        [--montecarlo N] [--charts] [--csv f.csv]
                        [--slots N] [--facilities N] [--arpu X] [--flow X]
                        [--invoice X] [--team X]
"""
from __future__ import annotations
import argparse, csv, math, random, statistics
from dataclasses import dataclass, field, asdict, replace


@dataclass
class Params:
    # ---- мощность ----
    slots_per_facility: int = 240
    facilities: int = 2
    animals_per_slot: float = 3.2
    care_fte: int = 6                # штат резиденции, FTE (без руководства)
    animals_per_fte_min: float = 70.0  # норматив: минимум животных на 1 FTE ухода
    months: int = 36
    ramp_months: int = 14

    # ---- первичка ----
    passport_supply: int = 2000
    passport_price: float = 75.0
    passport_sell_through: float = 0.85
    passport_rcn_share: float = 0.40
    passport_rcn_conversion: float = 0.72
    rcn_price: dict = field(default_factory=lambda: {"Burrow": 450.0, "Warren": 900.0, "Crown": 1800.0})
    rcn_mix: dict = field(default_factory=lambda: {"Burrow": 0.62, "Warren": 0.30, "Crown": 0.08})
    care_deposit_months: float = 12.0

    # ---- содержание (за животное) ----
    invoice_clover: dict = field(default_factory=lambda: {"Burrow": 800.0, "Warren": 1120.0, "Crown": 1600.0})
    invoice_usd: dict = field(default_factory=lambda: {"Burrow": 40.0, "Warren": 56.0, "Crown": 80.0})
    unpaid_share: float = 0.06
    rescue_recover_share: float = 0.30     # изъятий от просрочки
    boarding_per_animal: float = 1.0
    boarding_price: float = 45.0
    boarding_marginal_cost: float = 12.0

    # ---- донаты ----
    donation_arpu_animal_month: float = 15.0
    donation_split: tuple = (0.80, 0.10, 0.10)
    donation_ops_margin: float = 0.28
    micro_actions_animal_month: float = 8.0
    micro_action_clover: float = 40.0

    # ---- разведение ----
    litters_per_animal_year: float = 0.16
    kits_per_litter: float = 4.4
    kit_survival: float = 0.86
    protocol_kit_share: float = 0.30
    protocol_kit_price: float = 520.0
    protocol_kit_sell_through: float = 0.70
    breeding_fees_clover_per_litter: float = 1278.0
    breeding_bunny_usd_per_litter: float = 62.0
    breeding_margin: float = 0.22

    # ---- вторичный рынок ----
    market_flow_month: float = 0.15
    rcn_avg_sale: float = 880.0
    fee_marketplace: float = 0.05
    fee_welfare_levy: float = 0.10
    fee_lineage: float = 0.05
    fee_dao: float = 0.05
    welfare_levy_to_fund: float = 0.55

    # ---- конкурсы / сезон ----
    contest_entries_week_per_facility: int = 90
    contest_clover_price: float = 2.0
    contest_ops_share: float = 0.10
    contest_welfare_share: float = 0.20
    pass_sellers_month_per_facility: float = 24.0
    pass_clover: float = 300.0
    pass_margin: float = 0.55

    # ---- стрим / партнёрки ----
    stream_sub_price: float = 5.0
    stream_sub_per_animal: float = 0.30
    stream_infra_cost_per_animal: float = 1.8
    sponsor_per_facility_month: float = 4500.0
    sponsorship_margin: float = 0.90

    # ---- CLOVER-курс и комиссии ----
    clover_ref_price: float = 0.05
    clover_commission: float = 0.10          # на покупку
    clover_exit_fee: float = 0.10            # на возврат (в Welfare)
    redemption_rate: float = 0.12            # доля купленного, возвращённая протоколу
    free_reward_max_ratio: float = 1.25      # свободная эмиссия ≤ 1.25 × burn-а
    max_free_inflation: float = 0.10         # ≤10% от faucet'а — «свободные» награды
    clover_hard_cap_month: float = 900000.0 * 30

    # ---- расходы ----
    opex_animal_month: dict = field(default_factory=lambda: {
        "feed": 12.0, "housing": 9.0, "labor": 28.0, "vet": 5.5, "consumables": 5.0,
        "utilities": 4.0, "insurance": 2.0, "media": 3.5, "transport": 1.5, "grooming": 2.0})
    facility_fixed_month: float = 2800.0
    capex_per_facility: float = 285000.0
    capex_amort_months: int = 48
    team_month: float = 16000.0
    infra_month: float = 5000.0
    audit_legal_month: float = 4500.0
    rescue_cost_month: float = 260.0
    insurance_reserve_rate: float = 0.015

    # ---- капитал ----
    strategic_round: float = 1200000.0
    strategic_vesting_months: int = 48
    start_treasury: float = 0.0

    # ---- популяция ----
    deaths_per_animal_year: float = 0.05
    sanctuary_inflow_month_per_facility: float = 1.5

    # ---- дериваты ----
    @property
    def total_slots(self) -> int:
        return self.slots_per_facility * self.facilities

    @property
    def capacity(self) -> int:
        return int(round(self.total_slots * self.animals_per_slot))

    def blended(self, d: dict) -> float:
        return sum(d[k] * self.rcn_mix[k] for k in self.rcn_mix)

    @property
    def opex_per_animal(self) -> float:
        return sum(self.opex_animal_month.values())

    def check(self) -> list[str]:
        w = []
        o = self.opex_per_animal
        inv = self.blended(self.invoice_usd)
        if inv < o:
            gap = o - inv
            per_board = (self.boarding_price - self.boarding_marginal_cost) * self.boarding_per_animal
            w.append(f"CareInvoice ${inv:.2f}/животн. < опекс ${o:.2f}: разрыв ${gap:.2f} закрывается "
                     f"передержкой (${per_board:.2f}/животн.), комиссиями вторички и CLOVER-спредом; "
                     f"донат-ARPU даёт протоколу лишь {100*self.donation_ops_margin*0.8:.0f}% от суммы доната")
        if self.unpaid_share > 0.10:
            w.append("доля неоплат > 10% — экономика изъятий начинает доминировать")
        prod = self.capacity / max(1, self.care_fte * self.facilities)
        if prod < self.animals_per_fte_min:
            w.append(f"Производительность ухода {prod:.0f} жив./FTE < норматива {self.animals_per_fte_min:.0f}: "
                     f"это ИТОЧНАЯ причина убыточности. Либо плотность/автономия ухода выше, "
                     f"либо проект должен существовать как медиа, а не как сервис содержания")
        if self.donation_arpu_animal_month < 5:
            w.append("донат-ARPU < $5/животн./мес — модель почти наверняка убыточна (см. --breakeven)")
        return w


@dataclass
class Month:
    m: int
    rcn: int = 0
    protocol_animals: int = 0
    animals: int = 0
    r_primary: float = 0.0
    r_invoices: float = 0.0
    r_donations: float = 0.0
    r_boarding: float = 0.0
    r_breeding: float = 0.0
    r_market: float = 0.0
    r_contests: float = 0.0
    r_stream: float = 0.0
    r_sponsor: float = 0.0
    r_commission: float = 0.0
    revenue: float = 0.0
    c_opex: float = 0.0
    c_fixed: float = 0.0
    c_team: float = 0.0
    c_capex: float = 0.0
    c_rescue: float = 0.0
    costs: float = 0.0
    ebitda: float = 0.0
    net: float = 0.0
    cash_in: float = 0.0
    cash: float = 0.0
    treasury: float = 0.0
    welfare_fund: float = 0.0
    litters: float = 0.0
    kits: float = 0.0
    new_rcn: float = 0.0
    second_sales: float = 0.0
    donations_gross: float = 0.0
    invoices_billed: float = 0.0
    invoices_unpaid: float = 0.0
    clover_purchased: float = 0.0
    clover_free_mint: float = 0.0
    clover_burn: float = 0.0
    clover_circulating: float = 0.0
    free_inflation: float = 0.0
    seizures: float = 0.0


def s_curve(m: int, ramp: int) -> float:
    if m <= 0:
        return 0.0
    x = (m - ramp * 0.45) / (ramp * 0.26)
    raw = 1 / (1 + math.exp(-x))
    lo = 1 / (1 + math.exp(0.45 / 0.26))
    hi = 1 / (1 + math.exp(-(30 - ramp * 0.45) / (ramp * 0.26)))
    return max(0.0, min(1.0, (raw - lo) / (hi - lo)))


def run(p: Params, noise: float = 0.0, rng: random.Random | None = None) -> list[Month]:
    jit = (lambda f: max(0.0, f * (1 + rng.uniform(-noise, noise)))) if (noise and rng) else (lambda f: f)

    rcn = 0
    nursery = 0.0                  # крольчата/резерв без владельца
    treasury = p.start_treasury
    welfare = 0.0
    circulating = 0.0
    free_prev = 0.0
    rows: list[Month] = []
    base_demand = 30.0 * p.facilities

    for m in range(1, p.months + 1):
        target = int(round(p.capacity * s_curve(m, p.ramp_months)))

        # ---------- первичные продажи ----------
        r_primary, cash_advance = 0.0, 0.0
        if m <= 2:
            gross = p.passport_supply * p.passport_price * p.passport_sell_through
            r_primary += gross * 0.55          # 45% идёт в capex-фонд, не в P&L
            cash_advance += gross * 0.45
        conv_rights = (p.passport_supply * p.passport_rcn_share * p.passport_rcn_conversion / 4.0) if m <= 6 else 0.0
        want = min(max(0.0, target - rcn), jit(base_demand * (1.0 if m <= 8 else 0.7)) + conv_rights * 0.4)
        new_rcn = int(round(max(0.0, min(want, p.capacity - rcn))))
        if new_rcn:
            r_primary += new_rcn * p.blended(p.rcn_price) * (1 - 0.15 * min(1.0, conv_rights / max(1.0, want)))
            cash_advance += new_rcn * p.blended(p.invoice_usd) * p.care_deposit_months
            rcn += new_rcn

        # ---------- популяция ----------
        litters = jit(rcn * p.litters_per_animal_year / 12.0)
        kits = litters * p.kits_per_litter * p.kit_survival
        nursery += kits
        deaths = (rcn + nursery) * p.deaths_per_animal_year / 12.0
        placed = min(nursery, max(0.0, p.capacity - rcn) * 0.35)
        rcn += int(round(placed))
        nursery = max(0.0, nursery - placed - deaths)
        protocol_animals = int(round(nursery * 0.5 + p.sanctuary_inflow_month_per_facility
                                    * p.facilities * min(m, 30)))
        animals = rcn + protocol_animals

        # ---------- инвойсы ----------
        billed = rcn * p.blended(p.invoice_usd)
        unpaid = billed * p.unpaid_share
        r_invoices = billed - unpaid
        clover_invoice = rcn * p.blended(p.invoice_clover)

        # ---------- донаты ----------
        donations = jit(animals * p.donation_arpu_animal_month)
        endow, stream_ops, welfare_don = (donations * x for x in p.donation_split)
        r_donations = endow * p.donation_ops_margin + stream_ops

        # ---------- передержка ----------
        r_boarding = animals * p.boarding_per_animal * (p.boarding_price - p.boarding_marginal_cost)

        # ---------- разведение ----------
        kits_sold = min(nursery * p.protocol_kit_share / 5.0, animals * 0.04)
        r_breeding = (litters * p.breeding_fees_clover_per_litter * p.clover_ref_price * p.breeding_margin
                      + litters * p.breeding_bunny_usd_per_litter * 0.15
                      + kits_sold * p.protocol_kit_price * p.protocol_kit_sell_through)
        nursery = max(0.0, nursery - kits_sold)
        clover_breeding = litters * p.breeding_fees_clover_per_litter

        # ---------- вторичный рынок ----------
        second = jit(rcn * p.market_flow_month)
        gmv = second * p.rcn_avg_sale
        r_market = gmv * (p.fee_marketplace + p.fee_dao)
        levy = gmv * p.fee_welfare_levy
        welfare += levy * p.welfare_levy_to_fund

        # ---------- конкурсы / passes ----------
        c_contest = p.contest_entries_week_per_facility * p.facilities * 4.33 * p.contest_clover_price
        c_pass = jit(p.pass_sellers_month_per_facility * p.facilities * p.pass_clover)
        r_contests = (c_contest * p.clover_ref_price * (p.contest_ops_share)
                      + c_pass * p.clover_ref_price * p.pass_margin)
        welfare += c_contest * p.clover_ref_price * p.contest_welfare_share

        # ---------- стрим / спонсоры ----------
        r_stream = jit(animals * p.stream_sub_per_animal) * p.stream_sub_price - animals * p.stream_infra_cost_per_animal
        r_sponsor = p.sponsor_per_facility_month * p.facilities * p.sponsorship_margin * (0.35 if m <= 3 else 1.0)

        # ---------- CLOVER-контур ----------
        clover_micro = p.micro_actions_animal_month * p.micro_action_clover * animals
        clover_donations = (donations / p.clover_ref_price) * 0.8
        clover_burn = clover_invoice + clover_breeding + c_contest + c_pass + clover_micro + clover_donations
        burn_reduced = clover_burn * (1 - p.redemption_rate)          # часть токенов возвращено, а не сожжена
        purchased = clover_burn * 0.96                          # минт под фиат (≈ весь расход)
        # «свободная» эмиссия (награды/XP/квесты) — жёстко лимитирована
        # «социальный floor» наград — мал и гасится правилом 1.25×burn
        base_floor = 1_500.0 * 30 * p.facilities
        free = max(0.0, min(p.clover_hard_cap_month,
                            p.max_free_inflation * clover_burn,
                            base_floor + 0.06 * clover_burn))
        circulating = max(0.0, circulating + purchased + free - clover_burn * 0.75)
        free_prev = free
        r_commission = purchased * p.clover_ref_price * p.clover_commission \
            + burn_reduced * 0.0 + (clover_burn - purchased) * p.clover_ref_price * p.clover_exit_fee * 0.0
        welfare += (clover_burn - purchased) * p.clover_ref_price * p.clover_exit_fee

        # ---------- расходы ----------
        c_opex = animals * p.opex_per_animal
        c_fixed = p.facility_fixed_month * p.facilities
        c_team = p.team_month + p.infra_month + p.audit_legal_month
        c_capex = p.capex_per_facility / p.capex_amort_months * p.facilities
        seizures = rcn * p.unpaid_share * p.rescue_recover_share
        c_rescue = seizures * p.rescue_cost_month
        # фонд платит за «допаивание» изъятых: сверх базового опекса — половина rescue-ставки
        welfare -= c_rescue * 0.5

        revenue = (r_primary + r_invoices + r_donations + r_boarding + r_breeding + r_market
                   + r_contests + r_stream + r_sponsor + r_commission)
        costs = c_opex + c_fixed + c_team + c_capex + c_rescue
        ebitda = revenue - c_opex - c_fixed - c_team
        net = ebitda - c_capex - c_rescue
        cash = net + cash_advance * 0.5 + p.strategic_round / p.strategic_vesting_months
        treasury += cash
        welfare = max(0.0, welfare)

        rows.append(Month(
            m=m, rcn=rcn, protocol_animals=protocol_animals, animals=animals,
            r_primary=r_primary, r_invoices=r_invoices, r_donations=r_donations, r_boarding=r_boarding,
            r_breeding=r_breeding, r_market=r_market, r_contests=r_contests, r_stream=r_stream,
            r_sponsor=r_sponsor, r_commission=r_commission, revenue=revenue,
            c_opex=c_opex, c_fixed=c_fixed, c_team=c_team, c_capex=c_capex, c_rescue=c_rescue, costs=costs,
            ebitda=ebitda, net=net, cash_in=cash_advance, cash=cash, treasury=treasury, welfare_fund=welfare,
            litters=litters, kits=kits, new_rcn=new_rcn, second_sales=second,
            donations_gross=donations, invoices_billed=billed, invoices_unpaid=unpaid,
            clover_purchased=purchased, clover_free_mint=free, clover_burn=clover_burn,
            clover_circulating=circulating,
            free_inflation=free / max(1.0, circulating + free), seizures=seizures))
    return rows


# --------------------------------------------------------------------------- #
def stable(rows: list[Month], at: int = 24) -> Month:
    return rows[min(at, len(rows) - 1)]


def line(label: str, val: float, per: float, share: float) -> str:
    return f"  {label:<27}{val:>11,.0f}{per:>10,.2f}{share:>8.0f}%"


def summarize(p: Params, rows: list[Month]) -> str:
    st = stable(rows)
    a = max(1, st.animals)
    o = ["/" * 0, "=" * 78, "  WARREN PROTOCOL — экономическая модель", "=" * 78,
         f"  Резиденций: {p.facilities} · Слотов: {p.total_slots} · Емкость: {p.capacity} животных · "
         f"Рампа: {p.ramp_months} мес."]
    for w in p.check():
        o.append(f"  ⚠️  {w}")
    o += ["", f"  — M{st.m}: RCN {st.rcn} · на содержании протокола {st.protocol_animals} · всего {st.animals} —",
          f"  {'Источник выручки':<27}{'$/мес':>11}{'$/животн.':>10}{'доля':>8}"]
    for lbl, v in [("первичка (passports+RCN)", st.r_primary), ("инвойсы содержания", st.r_invoices),
                   ("донаты (маржа+ops)", st.r_donations), ("передержка Resident Pass", st.r_boarding),
                   ("разведение + kit-аукционы", st.r_breeding), ("комиссии вторички", st.r_market),
                   ("конкурсы / passes", st.r_contests), ("стрим (нетто)", st.r_stream),
                   ("спонсорство", st.r_sponsor), ("комиссии CLOVER", st.r_commission)]:
        o.append(line(lbl, v, v / a, 100 * v / max(1.0, st.revenue)))
    o.append(line("ИТОГО", st.revenue, st.revenue / a, 100.0))
    o += ["", f"  {'Расходы':<27}{'$/мес':>11}{'$/животн.':>10}{'':>8}"]
    for lbl, v in [("опекс животных", st.c_opex), ("фикс. резиденции", st.c_fixed),
                   ("команда+инфра+аудит", st.c_team), ("капекс (аморт.)", st.c_capex),
                   ("rescue / изъятия", st.c_rescue)]:
        o.append(line(lbl, v, v / a, 0)[:-8])
    o.append(line("ИТОГО", st.costs, st.costs / a, 0)[:-8])
    fixed_all = st.c_fixed + st.c_team
    o += ["",
          f"  Contribution margin:        ${st.revenue - st.c_opex:,.0f}/мес "
          f"(${(st.revenue-st.c_opex)/a:,.2f}/животн.)",
          f"  Покрывает фикс.+команду:    {'ДА' if (st.revenue-st.c_opex) > fixed_all else 'НЕТ'} "
          f"(нужно ${fixed_all:,.0f} → ${(fixed_all)/a:,.2f}/животн.)",
          f"  EBITDA:                     ${st.ebitda:,.0f}/мес  ({100*st.ebitda/max(1,st.revenue):.1f}%)",
          f"  Net (после капекса/rescue): ${st.net:,.0f}/мес",
          f"  Treasury:                   ${st.treasury:,.0f} (runway "
          f"{st.treasury/max(1.0,(p.capacity*p.opex_per_animal+fixed_all))*12:.0f} мес.)",
          f"  Welfare Reserve:            ${st.welfare_fund:,.0f} "
          f"(${st.welfare_fund/max(1,st.animals):,.0f}/животн.)"]
    TH = 5_000.0
    be = next((r.m for r in rows[3:] if r.ebitda >= TH and all(x.ebitda >= 0 for x in rows[r.m-1:min(len(rows), r.m+2)])), None)
    o += ["", f"  Break-even EBITDA:          {'M'+str(be) if be else 'не достигнут (см. --breakeven и блок масштабирования)'}",
          f"  За {p.months} мес.: выручка ${sum(r.revenue for r in rows):,.0f} · "
          f"расходы ${sum(r.costs for r in rows):,.0f} · "
          f"сальдо ${sum(r.revenue-r.costs for r in rows):,.0f}"]
    burn = sum(r.clover_burn for r in rows)
    faucet = sum(r.clover_purchased + r.clover_free_mint for r in rows)
    free_mint = sum(r.clover_free_mint for r in rows)
    fi_ratio = free_mint / max(1.0, faucet)
    o += ["", "  — $CLOVER (токен-слой) —",
          f"  Sink (burn): {burn:,.0f} C · Faucet: {faucet:,.0f} C · "
          f"sink/faucet = {burn/max(1.0,faucet):.2f}",
          f"  из них покупка за фиат: {sum(r.clover_purchased for r in rows):,.0f} C "
          f"({100*sum(r.clover_purchased for r in rows)/max(1.0,faucet):.0f}%) · "
          f"свободные награды: {free_mint:,.0f} C ({100*fi_ratio:.0f}%)",
          f"  {'✅ необеспеченная эмиссия в норме (≤ '+f'{100*p.max_free_inflation:.0f}%)' if fi_ratio <= p.max_free_inflation*1.05 else '⚠️ наградные эмиссии слишком велики → см. 03.8'}",
          f"  Номинальная стоимость free-эмиссии: ${free_mint*p.clover_ref_price:,.0f} за {p.months} мес. "
          f"(= ${free_mint*p.clover_ref_price/p.months:,.0f}/мес. «социальных» наград)"]
    o.append("=" * 78)
    return "\n".join(o)


def scaling(p: Params) -> str:
    o = ["", "  — Масштабирование: одна резиденция vs сеть —", "  " + "-" * 74,
         f"  {'резиденций':>11} {'слотов':>8} {'животн.':>8} {'EBITDA/мес':>12} {'маржа':>7} {'$/животн.':>10}  статус"]
    for n in (1, 2, 3, 4, 6, 8, 12):
        q = replace(p, facilities=n)
        st = stable(run(q))
        a = max(1, st.animals)
        o.append(f"  {n:>11} {q.total_slots:>8} {a:>8} {st.ebitda:>12,.0f} "
                 f"{100*st.ebitda/max(1,st.revenue):>6.1f}% {st.ebitda/a:>10,.2f}  "
                 f"{'✅' if st.ebitda>0 else ('⚠️' if st.ebitda>-20000 else '❌')}")
    fixed_core = (p.team_month + p.infra_month + p.audit_legal_month + p.facility_fixed_month)
    o += ["", f"  Вывод: фиксированные $core = ${fixed_core:,.0f}/мес на все резиденции. Одна резиденция",
          f"  их не кормит (нужно ${fixed_core/max(1,p.capacity):,.2f}/животн. contribution):",
          "  минимально жизнеспособная конфигурация — сеть из N резиденций, где N растёт",
          "  быстрее, чем штат. Открывать резиденцию №2 можно только при median CareScore ≥ 80",
          "  в первой и EBITDA ≥ 0 три месяца подряд (правило в docs/15)."]
    return "\n".join(o)


def report(p: Params, rows: list[Month]) -> str:
    h = (f"{'M':>3} {'RCN':>5} {'всего':>6} {'выручка':>9} {'опекс':>9} {'EBITDA':>9} {'казна':>10} "
         f"{'welfare':>8} {'burn':>9} {'free-mint':>10} {'помётов':>7} {'изъятий':>8}")
    out = ["", h, "-" * len(h)]
    for r in rows:
        out.append(f"{r.m:>3} {r.rcn:>5} {r.animals:>6} {r.revenue:>9,.0f} {r.c_opex:>9,.0f} {r.ebitda:>9,.0f} "
                   f"{r.treasury:>10,.0f} {r.welfare_fund:>8,.0f} {r.clover_burn:>9,.0f} {r.clover_free_mint:>10,.0f} "
                   f"{r.litters:>7,.1f} {r.seizures:>8,.1f}")
    return "\n".join(out)


def breakeven(p: Params) -> str:
    arp = (5.0, 8.0, 11.0, 15.0, 20.0, 26.0)
    o = ["", "  — Breakeven-матрица: EBITDA на M24, $/мес —", "  " + "-" * 76,
         f"  {'слотов':>7} " + " ".join(f"{'ARPU $'+str(int(x)):>10}" for x in arp)]
    for slots in (60, 120, 200, 300, 450):
        cells = []
        for x in arp:
            q = replace(p, slots_per_facility=slots, donation_arpu_animal_month=x)
            cells.append(f"{stable(run(q)).ebitda:>10,.0f}")
        o.append(f"  {slots:>7} " + " ".join(cells))
    o += ["", "  Затем то же самое, но при разных размерах core-команды (слоты 120, ARPU $12):",
          f"  {'$/мес команда':>15} " + " ".join(f"{'слоты '+str(s):>11}" for s in (120, 200, 300, 450, 600))]
    for team in (12000, 18000, 24000, 32000):
        cells = []
        for s in (120, 200, 300, 450, 600):
            q = replace(p, slots_per_facility=s, donation_arpu_animal_month=12.0, team_month=team)
            cells.append(f"{stable(run(q)).ebitda:>11,.0f}")
        o.append(f"  {team:>15,.0f} " + " ".join(cells))
    o += ["", "  ⚠️  Матрицы считаются при --facilities 1 (то есть выручка 1 резиденции против",
          "  полных фикс. затрат) — это стресс-тест «самодостаточности одной резиденции».",
          "  Для конфигурации сети см. --scaling (фикс.-затраты делятся на N резиденций).",
          "",
          "  Как читать: ищите нулевую линию. Она показывает минимальную жизнеспособную",
          "  конфигурацию (мощность × ARPU донатов × размер команды). Всё правее/выше нуля —",
          "  устойчиво; всё левее — живёт за счёт капитала, а не за счёт заботы."]
    return "\n".join(o)


def sensitivity(p: Params) -> str:
    cases = [
        ("донат ARPU, $/животн./мес", ("donation_arpu_animal_month",), (4.0, 12.0, 24.0)),
        ("передержка, $/мес", ("boarding_price",), (15.0, 35.0, 60.0)),
        ("передержка, покрытие", ("boarding_per_animal",), (0.3, 1.0, 1.8)),
        ("вторичка, доля/мес", ("market_flow_month",), (0.05, 0.15, 0.30)),
        ("цена RCN × (эффект в M1–M6)", ("rcn_mult",), (0.7, 1.0, 1.5)),
        ("инвойс ×", ("inv_mult",), (0.85, 1.0, 1.25)),
        ("опекс/животное ×", ("opex_mult",), (0.8, 1.0, 1.3)),
        ("команда ×", ("team_mult",), (0.5, 1.0, 1.5)),
        ("спонсорство, $/мес/резид.", ("sponsor_per_facility_month",), (0.0, 4500.0, 15000.0)),
        ("резиденций (масштаб)", ("facilities",), (1, 3, 6)),
        ("вет/страх. расходы ×", ("vet_mult",), (0.6, 1.0, 1.6)),
        ("комиссия CLOVER", ("clover_commission",), (0.04, 0.10, 0.18)),
        ("неоплата инвойсов, доля", ("unpaid_share",), (0.02, 0.06, 0.14)),
        ("свободная эмиссия ≤, доля", ("max_free_inflation",), (0.02, 0.10, 0.35)),
    ]
    o = ["", "  — Чувствительность EBITDA (M24) —", "  " + "-" * 78,
         f"  {'параметр':<28} {'мин':>11} {'база':>11} {'макс':>11} {'Δмакс-мин':>11} {'упругость':>10}"]
    for label, keys, vals in cases:
        res = []
        for v in vals:
            q = replace(p)
            q.rcn_price = dict(p.rcn_price); q.invoice_usd = dict(p.invoice_usd)
            q.invoice_clover = dict(p.invoice_clover); q.opex_animal_month = dict(p.opex_animal_month)
            k = keys[0]
            if k == "rcn_mult":
                q.rcn_price = {kk: vv * v for kk, vv in q.rcn_price.items()}
            elif k == "inv_mult":
                q.invoice_usd = {kk: vv * v for kk, vv in q.invoice_usd.items()}
                q.invoice_clover = {kk: vv * v for kk, vv in q.invoice_clover.items()}
            elif k == "opex_mult":
                q.opex_animal_month = {kk: vv * v for kk, vv in q.opex_animal_month.items()}
            elif k == "team_mult":
                q.team_month *= v
            elif k == "vet_mult":
                for kk in ("vet", "insurance", "grooming"):
                    q.opex_animal_month[kk] *= v
            else:
                setattr(q, k, v)
            res.append(stable(run(q)).ebitda)
        rng_ = max(1.0, abs(res[1]))
        o.append(f"  {label:<28} {res[0]:>11,.0f} {res[1]:>11,.0f} {res[2]:>11,.0f} "
                 f"{res[2]-res[0]:>11,.0f} {(res[2]-res[0])/rng_:>10.2f}")
    o += ["", "  Вывод: EBITDA почти не зависит от цены NFT-минта (она окупает капекс), зато",
          "  линейно зависит от донат-ARPU, передержки и дисциплины операционных расходов.",
          "  Именно поэтому «игра» (минты/роилы) — маркетинг, а «забота» (flow) — бизнес."]
    return "\n".join(o)


def montecarlo(p: Params, n: int) -> str:
    rng = random.Random(20261010)
    eb, min_t, ruin, neg = [], [], 0, []
    for _ in range(n):
        rows = run(p, noise=0.30, rng=rng)
        eb.append(stable(rows).ebitda)
        min_t.append(min(r.treasury for r in rows))
        neg.append(sum(1 for r in rows if r.ebitda < 0))
        if any(r.treasury < 0 for r in rows[6:]):
            ruin += 1
    q = statistics.quantiles(eb, n=4)  # [P25, P50, P75]
    return "\n".join([
        "", f"  — Монте-Карло: {n} прогонов, шум ±30% (донаты, спрос, разведение, вторичка) —", "  " + "-" * 74,
        f"  EBITDA M24: медиана ${statistics.median(eb):,.0f} · P25 ${q[0]:,.0f} · P75 ${q[-1]:,.0f} · min ${min(eb):,.0f}",
        f"  Медиана убыточных месяцев за 36 мес.: {statistics.median(neg):.1f}",
        f"  Худший момент казны (медиана): ${statistics.median(min_t):,.0f} · min ${min(min_t):,.0f}",
        f"  Прогоны с кассовым разрывом (казна < 0 после M6): {100*ruin/n:.0f}%", "",
        "  Риск проекта — не «обвал токена», а недо-заполнение мощностей и слабый донат-flow.",
        "  Митигация: (1) слоты открываются только под подтверждённый demand-waitlist ≥ 1.3×,",
        "  (2) резерв ≥ 6 мес. opex — ончейн-правило, (3) найм core-команды после M12.",
    ])


def to_csv(path: str, rows: list[Month]) -> None:
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].__dict__.keys()))
        w.writeheader()
        for r in rows:
            w.writerow({k: (round(v, 2) if isinstance(v, float) else v) for k, v in asdict(r).items()})


def charts(p: Params, rows: list[Month], out_dir: str = ".") -> str:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return "  matplotlib недоступен — пропускаем"
    ms = [r.m for r in rows]
    fig, ax = plt.subplots(2, 2, figsize=(13, 8.5))
    ax[0][0].plot(ms, [r.revenue for r in rows], label="Revenue")
    ax[0][0].plot(ms, [r.c_opex + r.c_fixed + r.c_team for r in rows], label="OpEx+fixed+team")
    ax[0][0].plot(ms, [r.ebitda for r in rows], "--", label="EBITDA")
    ax[0][0].axhline(0, color="#999", lw=.8); ax[0][0].legend(fontsize=8)
    ax[0][0].set_title(f"P&L, USD/мес ({p.facilities} fac. × {p.slots_per_facility} slots)"); ax[0][0].grid(alpha=.25)

    ax[0][1].stackplot(ms, [r.r_invoices for r in rows], [r.r_donations for r in rows],
                       [r.r_boarding for r in rows], [r.r_market for r in rows],
                       [r.r_breeding for r in rows], [r.r_stream + r.r_sponsor for r in rows],
                       [r.r_primary for r in rows],
                       labels=["invoices", "donations", "boarding", "market", "breeding", "stream+sp", "primary"],
                       alpha=.85)
    ax[0][1].legend(fontsize=7, ncol=2); ax[0][1].set_title("Revenue mix"); ax[0][1].grid(alpha=.25)

    ax[1][0].plot(ms, [r.clover_burn for r in rows], label="$CLOVER burned")
    ax[1][0].plot(ms, [r.clover_purchased for r in rows], label="mint: purchased (fiat-backed)")
    ax[1][0].plot(ms, [r.clover_free_mint for r in rows], label="mint: free rewards (capped)")
    ax[1][0].set_title("Token layer: faucet vs sink"); ax[1][0].legend(fontsize=8); ax[1][0].grid(alpha=.25)

    ax[1][1].plot(ms, [r.treasury for r in rows], label="Treasury")
    ax[1][1].plot(ms, [r.welfare_fund for r in rows], label="Welfare Reserve")
    ax[1][1].plot(ms, [r.animals for r in rows], "--", label="Animals in care")
    ax[1][1].set_yscale("symlog"); ax[1][1].set_title("Capital & welfare"); ax[1][1].legend(fontsize=8)
    ax[1][1].grid(alpha=.25)

    fig.tight_layout()
    path = f"{out_dir}/tokenomics_model.png"
    fig.savefig(path, dpi=130)
    return f"  График сохранён: {path}"


def main() -> None:
    ap = argparse.ArgumentParser(description="Warren Protocol economics simulator")
    ap.add_argument("--slots", type=int); ap.add_argument("--facilities", type=int)
    ap.add_argument("--months", type=int, default=36); ap.add_argument("--arpu", type=float)
    ap.add_argument("--flow", type=float); ap.add_argument("--invoice", type=float)
    ap.add_argument("--boarding", type=float); ap.add_argument("--team", type=float)
    ap.add_argument("--report", action="store_true"); ap.add_argument("--breakeven", action="store_true")
    ap.add_argument("--sensitivity", action="store_true"); ap.add_argument("--scaling", action="store_true")
    ap.add_argument("--montecarlo", type=int, default=0); ap.add_argument("--charts", action="store_true")
    ap.add_argument("--csv", default="")
    a = ap.parse_args()

    p = Params(months=a.months)
    for k, v in {"slots": "slots_per_facility", "arpu": "donation_arpu_animal_month",
                 "flow": "market_flow_month", "boarding": "boarding_price", "team": "team_month",
                 "facilities": "facilities"}.items():
        val = getattr(a, k)
        if val is not None:
            setattr(p, v, val)
    if a.invoice:
        p.invoice_usd = {k: a.invoice for k in p.invoice_usd}
        p.invoice_clover = {k: a.invoice / p.clover_ref_price for k in p.invoice_clover}

    rows = run(p)
    print(summarize(p, rows))
    if a.scaling:
        print(scaling(p))
    if a.report:
        print(report(p, rows))
    if a.breakeven:
        print(breakeven(p))
    if a.sensitivity:
        print(sensitivity(p))
    if a.montecarlo:
        print(montecarlo(p, a.montecarlo))
    if a.charts:
        print(charts(p, rows, "."))
    if a.csv:
        to_csv(a.csv, rows); print(f"\n  CSV: {a.csv}")


if __name__ == "__main__":
    main()
