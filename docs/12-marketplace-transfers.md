# 12. Рынок, переводы, ликвидность фиджитал-актива

## 12.1. Что продаётся и по какой логике

| Объект | Рынок | Ценообразование | Комиссии |
|---|---|---|---|
| **RCN** (животное) | Внутренний маркетплейс + аукционы | Оценка-оракул + Dutch; floor по тирам и CareScore | 25% (5/10/5/5) |
| **HutchLease / EnrichmentItem** | P2P, «блошиный рынок» | свободная | 3% (в welfare) |
| **EventClip / BirthdaySponsor / DonorBadge** | P2P, вторичка | свободная | 5% |
| **GenotypeCard / Litter / KitShare** | P2P | свободная | 5% |
| **GoldenCarrot / LineageHouse** | P2P, «статусные» | свободная, с роялти-следом | 7% (из них 3% welfare) |
| **Genesis Passport** | P2P | свободная | 2.5% (фикс.) |
| **$BUNNY / $CLOVER** | BUNNY: DEX/CEX; CLOVER: только mint/burn у кура | — | 0.3% swap (BUNNY), CLOVER — spread |

## 12.2. Guard-гейты передачи (ERC-721 `TransferGuard`)

```solidity
function _beforeTokenTransfer(address from, address to, uint256 id) internal view {
  require(!paused, "PAUSED");
  Status s = state[id];
  require(s != Status.PREGNANT && s != Status.LACTATING, "REPRODUCTIVE_LOCK");
  require(s != Status.CARE_REQUIRED && s != Status.DISPUTED, "WELFARE_LOCK");
  require(s != Status.QUARANTINE, "HEALTH_LOCK");
  require(now - birthTs[id] >= 56 days, "MIN_AGE");          // 8 недель
  require(eligible(to), "RECIPIENT_NOT_ELIGIBLE");           // age/jurisdiction/acceptance/quiz
  if (msg.sender == address(marketplace)) {
     require(escrowActive(id), "ESCROW_REQUIRED");
     require(block.timestamp > rofrDeadline(id), "ROFR");
  }
  require(careDebt[id] == 0 || proceedsCoverDebt, "DEBT_FIRST");
}
```

Токен **нельзя** отправить «в никуда»: `to` обязан быть `MerchantGateway`-не совместим с RCN (нельзя отправить RCN на контракт), `to` обязан иметь `Eligibility`-регистр. Продажа на OpenSea возможна только через `ApprovalForAll` к нашему `Marketplace` (иначе `TransferGuard` блокирует) — это единственный способ держать welfare-гейты обязательными, а не рекомендацией. Мы открыто пишем об этом в описании коллекции: «ваш NFT не торгуется свободно, и это защита животного, а не ваше неудобство».

## 12.3. Процедура продажи (end-to-end)

```
1. Owner → ListForSale(price | dutch params)
   └─ Check: CareDebt = 0, welfare ≥ 55 (иначе только RescueAuction), не PREGNANT/LACTATING
   └─ Snapshot: CareScore история, WelfareScore, роялти-структура, "known quirks" (вет-флаги)
2. ROFR-окно 3 дня (для «обычных») / 30 дней (для второй стороны Bond)
   └─ уведомление в приложении + стрим-баннер «этот кролик уходит, есть право приоритета»
3. Escrow-режим: покупатель депонирует оплату; 14 дней «transition window»
   └─ в это время животное остаётся в резиденции, содержание оплачивает ПРОДАВЕЦ
      (чтобы «продать и бросить» не работало)
4. Покупатель может: «visit/observe» (расширенный доступ к кадрам), задать 10 вопросов владельцу/резиденции
5. Settlement: выплата продавцу (−25%), Welfare-Levy 10%, роялти-родителям 5% (40/40/20)
   └─ CareEndowment остаётся с животным (не переходит продавцу!) — это критично
6. Buyer: новый BreedingBond-статус, "ownership anniversary", стартовая серия streak = 0
7. Payout: продавец получает в USDC/BUNNY на выбор; если есть CareDebt — сначала погашение
```

## 12.4. Оценка и «пол» цены (oracle, а не «свободный рынок»)

```
FairValue(rcn) = TierBase × RarityMult × CareMult × WelfareMult × MarketMult
  TierBase    = $450 / $900 / $1 800 (Burrow/Warren/Crown)
  RarityMult  = 1.0 + (RarityScore − 500)/500 × 0.9          → 0.1..1.9
  CareMult    = 0.85 + CareScore/1000 × 0.45                 → 0.85..1.30
  WelfareMult = 0.90 + WelfareScore/1000 × 0.20              → 0.90..1.10
  MarketMult  = 0.75..1.45 (скользящая 90-дневная, ограничена)
MinListing  = FairValue × 0.60  (или × 0.80 при CareScore < 55)
```

Эффект: **кролик, за которым хорошо ухаживают, стоит дороже — и это единственная «доходность», которую мы обещаем**, и она не гарантирована, а является следствием спроса.

## 12.5. Аукционы

| Тип | Механика | Когда |
|---|---|---|
| **Dutch** | старт 1.2× FairValue, шаг −6% / 12 ч, пол 0.8× | обычные листинги |
| **English** | шаг +5%, 3 дня, soft close 5 мин | Legendary/Mythic, Crown-слоты |
| **Sealed-bid** (только welfare-approved) | 1 заявка/адрес, победитель = высшая при равенстве — больший CareStreak | редкие «Genesis-only» крольчата |
| **Rescue** | старт 1 B, шаг +10%/24 ч, без пола; 100% на долг/welfare | изъятия (01.6) |
| **Protocol-kit** | Dutch-волна 1×/нед., старт = FairValue × 1.1 | 30% выводков (07.4) |
| **Sanctuary auction** | нет продажи, только «Sponsor-for-life» | старые/больные животные |

## 12.6. Eligibility Gate (кто может купить живое существо)

```
обязательное: 18+ · юрисдикция-allowlist (16.2) · принятие FacilityTerms (EIP-712) ·
              CareQuiz ≥8/10 · подтверждение CareDeposit (12 мес.) · отсутствие CareDebt > 0
для RCN:       1 адрес ≤ 5 RCN (снятие лимита: 36 мес. «Zero Unpaid» или уровень ≥10)
для Crown:     +видео-интервью с резиденцией 15 мин (реальная проверка «не для перепродажи на следующий день»)
блок:          «мгновенная перепродажа» < 90 дней → листинг возможен, но welfare-Levy ×1.5 (40% против 10%)
               и −200 XP. Это анти-флиппинг для живых существ.
```

## 12.7. Ликвидность без «бегства»

- **CareBondPool** — единственный «pool с доходностью»: стейкинг в USDC/CLOVER/BUNNY, доход от комиссий, а не от «выкупа NFT».
- **Никакого «buyback guarantee» за RCN.** Проект не обязуется выкупать животных. Вместо этого — гарантированная **процедура** (Rescue Auction + Sanctuary), которая всегда находит решение для животного, независимо от рыночной цены токена.
- **Marketplace-ликвидность BUNNY** — узкий VAMM с ограничением 4% от предложения в одном LP и защитой от sandwich (private mempool через приоритетный контракт-роутер).
- **Трансфер-фрикции:** эскроу 14 дней и ROFR — это осознанная «плохая ликвидность» для спекулянта и хорошая защита для животного. Мы публично считаем это фичей, а не недостатком.

## 12.8. Наследование, опекунство, «смена куратора»

| Ситуация | Механика |
|---|---|
| Смерть владельца (физическая) | `Inheritance`-квест: 30 дней, получатель проходит Eligibility Gate, 0% комиссий, «CareDebt» переходит с токеном (иначе наследник не получает актив) |
| Владелец не может платить (документированно) | «Temporary Foster Transfer» — `Resident Pass`-холдеры могут закрыть долг за 30-дневные права (04.5, 01.6 T+14) |
| Владелец хочет «передать в заботу» другу | Gift-transfer через тот же гейт, без цены → роялти 0, `minListingBps` у получателя +20% на 6 мес. |
| Потеря доступа к кошельку | Social recovery (ERC-4337, 3 из 5 «хранителей»), либо Custody-мандат с 30-дневным карантином |
| Владелец несовершеннолетний (наследник) | Передача опекуну + «Care Mentor»-куратор; breeding-права замораживаются до 18 лет |
