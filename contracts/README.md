# Warren Protocol — контракты: эскизы архитектуры (NE PRODUCTION)

> **⚠️ 2026-10-10.** Выбрана **Solana** → эти Solidity-эскизи остаются **спецификацией механик** (гейты, доли, состояние),
> но не кодом для деплоя. Порт на Anchor/Rust — после ответов на **Q1–Q3** (`landing/QUESTIONS.md`): там решается
> Token-2022 vs SPL + учётная программа, Metaplex Core vs Bubblegum cNFT, и где живёт журнал заботы (ончейн/Merkle-пруф/офчейн).

> ⚠️ **Важно.** Это не продакшен-код и не аудированный код. Это **спецификация в Solidity**: она нужна, чтобы проверить, что механики вообще выражаются в контрактах, где проходят welfare-гейты и где проходит разделение «деньги животного / деньги владельца». Перед любым деплоем: переписать, покрыть тестами, 2 аудита, bug bounty.
>
> Компилятор в песочнице недоступен (нет доступа к binaries.soliditylang.org), поэтому файлы **не скомпилированы** — трактуйте их как псевдокод с точной сигнатурной схемой.

| Файл | Что задаёт |
|---|---|
| `ImmutableCore.sol` | Неизменяемые welfare- и эмиссион-константы (docs/03.9, 06.4, 13.2) |
| `GenotypeLib.sol` | Пак-структура генотипа, детерминированное наследование, RarityScore, инбридинг |
| `RabbitCareNFT.sol` | RCN: ERC-721 + CareLedger + TransferGuard (welfare-гейты, эскроу, ROFR, мин. возраст) |
| `CareEngine.sol` | CareInvoice, авто-погашение из энддаумента, CareDebt, эскалация до изъятия |
| `DonationRouter.sol` | Цели с авто-возвратом, сплит 80/10/10, MerchantGateway (деньги животного нельзя вывести) |

Порядок зависимостей:

```
ImmutableCore ──┬── RabbitCareNFT ──┬── CareEngine
                │                   └── DonationRouter ── MerchantGateway
                ├── GenotypeLib (used by breeding contracts)
                └── WelfareGates (in every state-changing path)
```

Главная архитектурная идея, которую видно из кода: **`Endowment` не имеет функции вывода**. Ни `withdraw`, ни `transferOwner`, ни «компенсация владельцу». Единственный путь средств животного — `MerchantGateway.pay(vendor, item)`. Всё остальное в системе — про права, а не про деньги кролика.
