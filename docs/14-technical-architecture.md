# 14. Техническая архитектура

## 14.1. Принцип разделения: «цепочка — для обязательств, офчейн — для реальности»

| Слой | Что живёт здесь | Почему |
|---|---|---|
| **L2 (Base)** | права, балансировка средств, эмиссия/сжигание, роялти, аукционы, константы | необратимость, аудируемость, композабельность |
| **Commitment layer** | хеши фото/видео/актов, метаданные, Merkle-корни отчётов | доказательства без стоимости хранения |
| **Off-chain core** | расписания, очереди, ИИ-аналитика, стриминг, CRM, логистика | скорость, стоимость, ML |
| **IPFS/Arweave** | метаданные NFT, отчёты, клипы (долгосрочно) | устойчивость, отсутствие «мёртвых ссылок» |

## 14.2. Контрактный ландшафт

```
Core
 ├─ RabbitCareNFT.sol            ERC-721 + TransferGuard + CareLedger + EIP-2981 hooks
 ├─ RabbitTBAFactory.sol         ERC-6551 registry (кошелёк кролика)
 ├─ ChipRegistry.sol             chipId-hash ↔ tokenId, salted, «anti-spoof»
 ├─ GenotypeRegistry.sol         packing genotype, reveal, pedigree (Merkle)
 ├─ LitterRegistry.sol           Litter ERC-721 + KitShare ERC-1155
 ├─ BreedingBond.sol             предложения/подписи/фазы/лок-апы
 ├─ WelfareGates.sol             все welfare-гейты (единая точка правды)
 ├─ CareEngine.sol               инвойсы, авто-погашение, эскалация, CareDebt
 ├─ DonationRouter.sol           Goals, escrow, refund, splits 80/10/10
 ├─ MerchantGateway.sol          whitelisted-вендоры, оплата услуг из Endowment
 ├─ EndowmentLedger.sol           учёт «денег животного», receipts
 ├─ CloverToken.sol / BunnyToken.sol  ERC-20, MintController, BurnController
 ├─ PegEngine.sol                 ref price, corridor, exit fee
 ├─ HutchRegistry.sol             leases, items, durability
 ├─ Marketplace.sol               листинги, Dutch/English/Sealed, ROFR, эскроу
 ├─ RoyaltyEngine.sol             EIP-2981 + split 40/40/20 + lineage house
 ├─ ContestFactory.sol            конкурсы, commit-reveal судейства, payout
 ├─ StakingCareBond.sol           ERC-4626, тир-локи, slashing
 ├─ TreasuryVault.sol             6 корзин, timelocks
 ├─ MetricsOracle.sol             8 инвариантов (04.8) + алерты
 ├─ WelfareOracle.sol             5 подписантов, quorum 3/5, ротация ключей
 ├─ CommitmentStore.sol           хеши доказательств, archive integrity roots
 ├─ Governance (3 палаты) + Timelock + ImmutableCore
 └─ AccessManager / PauseGuardian / EmergencyCouncil (4/7)
Access & UX
 ├─ SessionKeyModule (ERC-4337)   сессионные ключи приложения, batch-ops
 ├─ Paymaster (CLOVER-funded)     газ за счёт 0.3% «infra-fee»
 └─ Verifier contracts              attestation (dApp) для «Witness»
```

## 14.3. Поток одного «быстрого доната» (2 $)

```
1. UI: кнопка «🌿 Зелень 1.5$» → onramp (карта) или CLOVER-кошелёк
2. Router: USDC → MintController.mint(30 CLOVER) → DonationRouter.declare(rcnId, GREENS)
3. Сплит: 24 C → Endowment(rcn) · 3 C → StreamOps · 3 C → WelfareReserve (в стейбле — 10% от $1.5)
4. ActionRouter: «GREENS_SERVED» → очередь резиденции (off-chain)
5. Исполнение ≤ 24 ч: оператор подтверждает (фото) → CareAttestation → hash в CommitmentStore
6. Effects: welfare +1.0 (через WelfareOracle, на след. пересчёт), XP +8, EventClip-mini mint
7. Refund path: не исполнено в SLA → авто-возврат 30 C + 5% «извинение» из OpsVault
```

Стоимость: ~0.00002 ETH эквивалент (gasless через paymaster ≈ $0.02 на Base), 1 блок. Для пользователя — «оплатил и забыл», вся криптография невидима.

## 14.4. Идентификация и KYC-уровни

| Уровень | Данные | Когда |
|---|---|---|
| L0 «зритель/донатер» | нет KYC, лимит $50/нед., $200/мес. | всегда |
| L1 «резидент/pass-holder» | email + гео + принятие правил | паспорт/boarding |
| L2 «владелец RCN» | KYC (Sumsub/Persona) + адрес-привязка + юрисдикционный скрининг | первая покупка RCN |
| L3 «Crown / крупная продажа >$5k» | расширенный KYC + происхождение средств | по порогу |

Данные **не** хранятся на цепочке — только `keccak256(kycId ‖ salt)` в `Eligibility`-регистре и сертифицированный «attestation from provider» (soulbound-креденшел).

## 14.5. Индексация и API

```
Chain events → Envio/Subsquid indexer → Postgres + clickhouse (метрики)
                                     → GraphQL для приложения
Off-chain DB (facility ops) → event bus → «reconciler» (сверяет with on-chain, 01.1)
Stream: MediaMTX (WebRTC/HLS) → CDN; запись: NVR 72ч → IPFS-пайплайн для клипов
AI: self-hosted (детекция: feeding, drink, binky, grooming, freeze, dig, litter-count,
    posture/BCS estimate) → события с confidence → «нужен 2-й источник» при conf < 0.85
```

## 14.6. Безопасность (минимально обязательный список)

- 2 аудита до TGE (ядро + рынок) + публичные отчёты; bug bounty от $25k; «audit-responsible» флаги в коде.
- Upgrades: только через Timelock + 4/7; `ImmutableCore` не апгрейдится.
- Мультиподпись с «emergency pause» (2/5) и «guardian veto» (welfare-палата может поставить контракт на паузу, а P1 — нет).
- Key management: HSM/YubiKey для оракулов; ротация 90 дней; «break-glass» в сейфе 3 человек.
- Rate limits и «daily caps» в контрактах (03.9), а не только в UI.
- Отказоустойчивость резиденции: N+1 питание, локальный буфер 8 ч видео, автономный режим «при потере сети — забота продолжается, аттестации догоняют».
- Privacy/security аудит камер: пентест, закрытие периметра-данных, отсутствие записей лиц.

## 14.7. Мобильное приложение (UX-принципы)

1. **Главный экран = живой кролик, а не портфель.** Запуск < 1.5 с, автовоспроизведение без звука.
2. **Одна кнопка заботы** (2 $) на первом экране; «расширенный каталог» — свайп вверх.
3. **Никогда не показывать «вы заработали»**; показывать «вы улучшили жизнь» (Δ welfare, дни сена, клип).
4. **Нотификации с пользой:** «у Нимбуса 4 дня сена», «вет-чекап через 3 дня», «окрол через 5 дней» — а не «цена упала».
5. **Виджет/lock-screen** со стрим-превью и streak — главный retention-ричуал.
6. **Инклюзия:** Web2-путь без кошелька (email + карта), «crypto» включается по желанию; мультиязык.
