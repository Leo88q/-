/* ══════════════════════════════════════════════════════════════
   Warren Protocol — landing runtime
   1) живой курс SOL (CoinGecko → Binance → KuCoin → fallback + localStorage)
   2) кошелёк-адаптер (Phantom / Solflare / Backpack) с честной деградацией
   3) калькулятор заботы, донат-цели, реестр кроликов, FAQ
   Никаких реальных списаний: все потоки — интерфейсная модель до деплоя программы.
   ══════════════════════════════════════════════════════════════ */
(() => {
'use strict';

/* ───────── конфигурация ───────── */
/* Решения владельца продукта 2026-10-10 (Q1–Q17) зафиксированы здесь, чтобы код и тексты не разъезжались:
   Q1 цепочка = Solana, переписываем стек   Q2 токен заботы = Token-2022 (transfer-fee, вывод энддаумента невозможен)
   Q3 карточка = Bubblegum cNFT + Metaplex attachment   Q4 RCN = внутриигровой предмет (не право требования)
   Q5 в цену входит только животное        Q6 500 $ = цена ВОЛНЫ 1, дальше +15% за волну, Crown = sealed-bid
   Q7 цена фиксируется quoting-окном + оракулом            Q8 газ платит ИГРОК   Q9 вход через swap-роут (Jupiter)
   Q10 юрлицо не указываем                  Q11 KYC пока не требуем              Q12 журнал заботы = гибрид
   Q13 стрим легален при нормальных условиях, риск не на нас Q14 просрочка → животное переходит разработчикам
   Q15 расчёт при продаже = $CLOVER по рынку Q16 риск сведения = риск игрока    Q17 один токен = одно животное */
const CFG = {
  RABBIT_USD: 500,           // ⚑ Q5/Q6: цена ВОЛНЫ 1, в цену входит только животное (без депозита)
  WAVES: { wl0: 0.75, wave1: 1.00, step: 0.15 },   // вайтлист −25 %, далее +15 % за волну
  CLOVER_USD: 0.02,          // 1 $CLOVER = 2 цента (внутренний референс; docs/05 — 0.05 $, Q3 по деньгам открыт)
  QUOTE_TTL_S: 90,           // ⚑ Q7: окно фиксации курса
  QUOTE_SLIP: 0.015,         // ⚑ Q7: допуск проскальзывания ±1.5 %
  GAS_PAYER: 'player',       // ⚑ Q8: газ платит игрок, протокол не субсидирует
  PRICE_SOURCES: [
    { name:'CoinGecko', url:'https://api.coingecko.com/api/v3/simple/price?ids=solana&vs_currencies=usd',
      pick: j => Number(j?.solana?.usd) },
    { name:'Binance',   url:'https://api.binance.com/api/v3/ticker/price?symbol=SOLUSDT',
      pick: j => Number(j?.price) },
    { name:'KuCoin',    url:'https://api.kucoin.com/api/v1/market/orderbook/level1?symbol=SOL-USDT',
      pick: j => Number(j?.data?.price) },
  ],
  FALLBACK_SOL: 108.50,      // ≈ курс на 2026-10-10 (OKX/CoinGecko); только чтобы страница не показывала «—»
                             // при недоступных API. В проде количество SOL считает оракул внутри quoting-окна (Q7)
  REFRESH_MS: 60_000,
  MINT_AT: (() => { const d = new Date(); d.setDate(d.getDate() + 10); d.setHours(18,0,0,0); return d; })(),
  OPS_COST_USD: 72.5,        // реальный опекс на животное/мес из модели docs/15
  DONATION_SPLIT: [0.80, 0.10, 0.10],   // энддаумент / эфир / welfare-reserve (docs/09)
};

/* ───────── утилиты ───────── */
const $  = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const nf = new Intl.NumberFormat('ru-RU');
const fmt = (n, d = 0) => Number(n).toLocaleString('ru-RU', { minimumFractionDigits:d, maximumFractionDigits:d });
const money = (n) => '$' + fmt(n, n < 10 ? 2 : (n < 1000 ? 0 : 0));
const C4 = n => Number(n).toLocaleString('ru-RU', { maximumFractionDigits:4 });
const usd2sol = usd => (usd / (SOL.usd || CFG.FALLBACK_SOL));
const el = (tag, cls, html) => { const n = document.createElement(tag); if (cls) n.className = cls; if (html != null) n.innerHTML = html; return n; };
const store = {
  get(k, d) { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
};

let toastTimer;
const wavePriceUsd = () => CFG.RABBIT_USD * CFG.WAVES.wave1;      // витрина: волна 1
const wlPriceUsd   = () => CFG.RABBIT_USD * CFG.WAVES.wl0;        // волна 0 для вайтлиста
function toast(msg) {
  const t = $('#toast'); t.textContent = msg; t.classList.add('is-on');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('is-on'), 3200);
}

/* ═══════════ 1. КУРС SOL ═══════════ */
const STALE_MS = 15 * 60_000;
const SOL = { usd: 0, src: 'init', ts: 0, stale: false };
(() => {                                  //hydration из кэша — мгновенно, без «—» на экране
  const c = store.get('solUsd', 0), ts = store.get('solTs', 0);
  if (c > 0 && ts && Date.now() - ts < 24 * 3600_000) Object.assign(SOL, { usd: c, src: 'cache', ts, stale: Date.now() - ts > STALE_MS });
  else Object.assign(SOL, { usd: CFG.FALLBACK_SOL, src: 'fallback', ts: 0, stale: true });
})();

async function loadSol() {
  for (const s of CFG.PRICE_SOURCES) {
    try {
      const ctl = new AbortController();
      const to = setTimeout(() => ctl.abort(), 6500);
      const r = await fetch(s.url, { signal: ctl.signal, headers: { accept: 'application/json' } });
      clearTimeout(to);
      if (!r.ok) throw new Error(r.status);
      const v = s.pick(await r.json());
      if (!v || !isFinite(v) || v <= 0) throw new Error('bad payload');
      SOL.usd = v; SOL.src = s.name; SOL.ts = Date.now(); SOL.stale = false;
      store.set('solUsd', v); store.set('solTs', SOL.ts);
      renderSol();
      return;
    } catch (e) { /* следующий источник */ }
  }
  SOL.stale = true;               // все источники недоступны → fallback, честно помечаем (в проде — оракул, ⚑ Q7)
  renderSol();
}

function renderSol() {
  const chip = $('#solChip'); if (!chip) return;
  chip.classList.toggle('is-old', SOL.stale);
  $('#solUsd').textContent = (SOL.stale ? '≈$' : '$') + fmt(SOL.usd, SOL.usd < 10 ? 4 : 2);
  chip.title = SOL.stale
    ? `Источник недоступен — показано значение из кэша (${new Date(SOL.ts).toLocaleString('ru-RU')}). Финальный курс транзакции может отличаться`
    : `Курс: ${SOL.src} · обновлён ${new Date(SOL.ts).toLocaleTimeString('ru-RU')}`;

  const priceSol = usd2sol(wavePriceUsd());
  $('#priceSol').textContent = C4(priceSol);
  const mb = $('#mintBtnSol'); if (mb) mb.textContent = C4(priceSol);
  $('#priceNote').textContent = `${fmt(wavePriceUsd())} $ (волна 1) ÷ ${fmt(SOL.usd, 2)} $/SOL · ${SOL.src}${SOL.stale ? ' · приблизительный курс' : ''}`;
  $$('.sol-in').forEach(n => {
    const usd = Number(n.dataset.usd || 0);
    n.textContent = usd ? C4(usd2sol(usd)) + ' SOL' : C4(priceSol) + ' SOL';
  });
  renderQuote();
}

/* ⚑ Q7: quote-око. Финальную цену считает оракул в момент подписи; здесь — та же семантика на витрине */
const QUOTE = { sol: 0, usd: 0, at: 0, lock: () => ({ sol: usd2sol(wavePriceUsd()), usd: wavePriceUsd(), at: Date.now() }) };
function newQuote(loud = true) {
  const q = QUOTE.lock();
  QUOTE.sol = q.sol; QUOTE.usd = q.usd; QUOTE.at = q.at;
  renderQuote();
  if (loud) toast('Курс зафиксирован на ' + CFG.QUOTE_TTL_S + ' с · проскальзывание ±' + (CFG.QUOTE_SLIP * 100).toFixed(1) + ' %');
}
function renderQuote() {
  const box = $('#quote'); if (!box) return;
  const left = Math.max(0, CFG.QUOTE_TTL_S - Math.round((Date.now() - QUOTE.at) / 1000));
  if (!QUOTE.at || left === 0) {
    box.classList.add('is-old');
    $('#qSol').textContent = '—'; $('#qLeft').textContent = 'нужен новый расчёт';
    $('#qBar').style.width = '0%';
    if (QUOTE.at) newQuote(false);          // истекло → тихий авто-пересчёт
    return;
  }
  box.classList.remove('is-old');
  $('#qSol').textContent = C4(QUOTE.sol);
  $('#qLeft').textContent = left + ' с · ' + fmt(QUOTE.usd / QUOTE.sol, 2) + ' $/SOL';
  $('#qBar').style.width = (left / CFG.QUOTE_TTL_S * 100).toFixed(1) + '%';
}
setInterval(renderQuote, 1000);
$('#qRefresh')?.addEventListener('click', () => newQuote());
renderSol();                       //hydration-рендер до первого ответа API
newQuote(false);                   //стартовое quote-око (⚑ Q7), без тоста
newQuote();                        //стартовое quote-око (⚑ Q7)
setInterval(loadSol, CFG.REFRESH_MS);
loadSol();

/* ═══════════ 2. КОШЕЛЁК ═══════════ */
const provider = () => window.phantom?.solana || window.solflare || window.backpack?.solana || window.solana;
let wallet = null;

async function connectWallet() {
  const p = provider();
  if (!p || p.isPhantom !== true && !p.isSolflare && !p.isBackpack && !p.isPhantom) {
    openModal({
      title: 'Кошелёк Solana не найден',
      html: `<p class="lead small">Нужно любое расширение с поддержкой <code>window.solana</code> и цепочки <b>Mainnet-beta / Devnet</b>.</p>
      <div class="mlist">
        <li><span>Phantom</span><code>phantom.app</code></li>
        <li><span>Solflare</span><code>solflare.com</code></li>
        <li><span>Backpack</span><code>backpack.app</code></li>
      </div>
      <div class="mbox">Можно продолжить без кошелька: вайтлист по email даёт приоритет и −25% к цене Genesis.</div>`,
      actions: [{ label: 'Понятно', kind: 'line' }],
    });
    return null;
  }
  try {
    const res = await p.connect({ onlyIfTrusted: false });
    wallet = { address: res.publicKey.toString(), kind: p.isPhantom ? 'Phantom' : p.isSolflare ? 'Solflare' : 'Backpack' };
    store.set('wallet', wallet);
    paintWallet();
    toast('Кошелёк подключён · ' + short(wallet.address));
    return p;
  } catch (e) {
    toast('Подключение отменено в кошельке');
    return null;
  }
}
const short = a => a ? `${a.slice(0, 4)}…${a.slice(-4)}` : '';

function paintWallet() {
  const b = $('#walletBtn');
  if (wallet) { b.textContent = short(wallet.address); b.dataset.intent = 'account'; b.style.fontFamily = 'ui-monospace,Menlo,monospace'; }
  else { b.textContent = 'Кошелёк'; b.dataset.intent = 'connect'; b.style.fontFamily = ''; }
}
const restored = store.get('wallet', null);
if (restored?.address) { wallet = restored; }   // показываем адрес; подпись всё равно требует connect
paintWallet();

$('#walletBtn').addEventListener('click', () => {
  if (!wallet) return connectWallet();
  openAccount();
});
$('#connectWallet2')?.addEventListener('click', () => wallet ? openAccount() : connectWallet());

function openAccount() {
  openModal({
    title: 'Аккаунт',
    html: `<div class="mrow"><span>Адрес</span><b>${short(wallet.address)}</b></div>
      <div class="mrow"><span>Провайдер</span><b>${wallet.kind}</b></div>
      <div class="mrow"><span>Целевой баланс заботы (12 мес. · Warren)</span><b>${C4(usd2sol(42 * 12))} SOL</b></div>
      <div class="mrow"><span>Газ</span><b>платите вы · ≈0.000005 SOL за подпись</b></div>
      <code class="addr">${wallet.address}</code>
      <div class="mbox">Средства не списываются: платёжный маршрут откроется вместе с деплоем программы
      <code>warren-care</code> и офертой резиденции. Сейчас страница — витрина продукта.</div>`,
    actions: [
      { label: 'Скопировать адрес', kind: 'primary', fn: () => navigator.clipboard?.writeText(wallet.address).then(() => toast('Адрес скопирован')) },
      { label: 'Отключить', kind: 'line', fn: () => { wallet = null; store.set('wallet', null); paintWallet(); toast('Кошелёк отключён'); closeModal(); } },
    ],
  });
}

/* ═══════════ 3. КАРОЧКИ КРОЛИКОВ ═══════════ */
const RARITY = {
  Common:    { c1:'#8FA79A', c2:'#5C7468', w:150, pct:45 },
  Uncommon:  { c1:'#7FB7C9', c2:'#46707E', w:150, pct:30 },
  Rare:      { c1:'#89A6E8', c2:'#4A5FA0', w:150, pct:17 },
  Epic:      { c1:'#C08BE6', c2:'#6E4597', w:150, pct:6.5 },
  Legendary: { c1:'#F0C36A', c2:'#A6761F', w:150, pct:1.4 },
  Mythic:    { c1:'#F49BB0', c2:'#8E3A63', w:150, pct:0.1 },
};
const RABBITS = [
  { n:'Nimbus',   id:'042', r:'Legendary', breed:'English Angora',      tier:'Warren',   coat:'Золотистый палевый', eyes:'Тёмный обсидиан', w:88, days:6, view:'Binky',  sex:'♀ самка',  litters:'1 / 4', inb:'2.1 %', owner:'free' },
  { n:'Luna',     id:'007', r:'Mythic',    breed:'Netherland Dwarf',    tier:'Crown',      coat:'Лунно-серебристый', eyes:'Рубин',            w:94, days:11,view:'Chin',   sex:'♀ самка',  litters:'0 / 4', inb:'0.8 %', owner:'0x…7fa2' },
  { n:'Pepper',   id:'118', r:'Rare',      breed:'Mini Rex',            tier:'Burrow',     coat:'Чёрный',            eyes:'Карий',            w:81, days:4, view:'Floppy', sex:'♂ самец',  litters:'—',     inb:'3.4 %', owner:'free' },
  { n:'Mochi',    id:'233', r:'Epic',      breed:'Holland Lop',         tier:'Warren',     coat:'Рыже-белый пёстрый',eyes:'Карий',            w:90, days:9, view:'Zoomies',sex:'♀ самка',  litters:'2 / 4', inb:'1.2 %', owner:'0x…c1d9' },
  { n:'Bagel',    id:'305', r:'Uncommon',  breed:'Lionhead',            tier:'Burrow',     coat:'Палевая грива',     eyes:'Карий',            w:77, days:2, view:'Digging',sex:'♂ самец',  litters:'—',     inb:'4.1 %', owner:'free' },
  { n:'Ash',      id:'311', r:'Common',    breed:'Mini Rex',            tier:'Burrow',     coat:'Голубой',           eyes:'Серо-голубой',     w:73, days:5, view:'Sploot', sex:'♂ самец',  litters:'—',     inb:'2.9 %', owner:'free' },
  { n:'Clover',   id:'128', r:'Rare',      breed:'Dutch',               tier:'Warren',     coat:'Классический пёстрый',eyes:'Карий',         w:86, days:8, view:'Binky',  sex:'♀ самка',  litters:'1 / 4', inb:'1.9 %', owner:'0x…90ba' },
  { n:'Ginger',   id:'019', r:'Uncommon',  breed:'English Angora',      tier:'Burrow',     coat:'Имбирный',          eyes:'Карий',            w:69, days:1, view:'Napping',sex:'♀ самка',  litters:'0 / 4', inb:'5.2 %', owner:'free' },
  { n:'Snow',     id:'244', r:'Common',    breed:'Hotot',               tier:'Burrow',     coat:'Белый, тёмная обводка',eyes:'Рубин',        w:75, days:3, view:'Chin',   sex:'♂ самец',  litters:'—',     inb:'3.7 %', owner:'free' },
  { n:'Toffee',   id:'066', r:'Epic',      breed:'Mini Lop',            tier:'Warren',     coat:'Карамельный shade', eyes:'Янтарь',           w:92, days:12,view:'Zoomies',sex:'♂ самец',  litters:'—',     inb:'1.1 %', owner:'0x…447e' },
  { n:'Biscuit',  id:'177', r:'Uncommon',  breed:'Netherland Dwarf',    tier:'Burrow',     coat:'Агути',             eyes:'Карий',            w:80, days:7, view:'Floppy', sex:'♀ самка',  litters:'1 / 4', inb:'2.4 %', owner:'free' },
  { n:'Truffle',  id:'201', r:'Common',    breed:'Rex',                 tier:'Burrow',     coat:'Шоколадный',        eyes:'Серый',            w:71, days:4, view:'Digging',sex:'♂ самец',  litters:'—',     inb:'4.8 %', owner:'free' },
];

function cardNode(r, i) {
  const R = RARITY[r.r];
  const c = el('article', 'rc');
  c.dataset.rar = r.r;
  c.style.setProperty('--c1', R.c1); c.style.setProperty('--c2', R.c2);
  c.innerHTML = `
    <div class="rc-scene">
      <div class="rc-bg"></div>
      <div class="rc-emoji">${['🐇','🐰','🐇','🐇'][i % 4]}</div>
      <span class="rc-live"><span class="dot live"></span> LIVE</span>
      <span class="rc-rank">#${r.id}</span>
    </div>
    <div class="rc-body">
      <div class="rc-name">${r.n}</div>
      <div class="rc-sub">${r.breed} · ${r.tier} · <span class="rarity-dot" style="background:${R.c1}"></span> ${r.r}</div>
      <div class="rc-traits"><i>${r.coat}</i><i>${r.eyes}</i><i>✨ ${r.view}</i></div>
      <div class="rc-meter">
        <div class="ml"><span>WelfareScore</span><span>${r.w}</span></div>
        <div class="bar"><i style="width:0%" data-w="${r.w}"></i></div>
      </div>
      <div class="rc-foot">
        <span class="rc-owner">${r.owner === 'free' ? '🟢 свободен' : '🔒 ' + r.owner}</span>
        <button class="rc-act">${r.owner === 'free' ? 'Забрать' : 'Открыть'}</button>
      </div>
    </div>`;
  c.querySelector('.rc-act').addEventListener('click', () => openRabbit(r));
  return c;
}

function renderCards(filter = 'all') {
  const box = $('#cards'); box.innerHTML = '';
  RABBITS.forEach((r, i) => {
    if (filter !== 'all' && r.r !== filter) return;
    box.appendChild(cardNode(r, i));
  });
  const left = 888 - (filter === 'all' ? RABBITS.length : RABBITS.filter(r => r.r === filter).length);
  const more = el('button', 'rc-new', `<b>${fmt(left)}</b><span>ещё в очереди на вольер<br>открываем волнами</span>`);
  more.style.gridColumn = '1/-1';
  more.addEventListener('click', () => scrollToMint());
  box.appendChild(more);
  requestAnimationFrame(() => $$('.bar > i[data-w]', box).forEach(b => b.style.width = b.dataset.w + '%'));
}
$$('.chip[data-rar]').forEach(ch => ch.addEventListener('click', () => {
  $$('.chip[data-rar]').forEach(c => c.classList.toggle('is-on', c === ch));
  renderCards(ch.dataset.rar);
}));
renderCards();

function openRabbit(r) {
  const R = RARITY[r.r];
  const free = r.owner === 'free';
  openModal({
    title: `${r.n} · #${r.id}`,
    html: `
      <p class="lead small">${r.breed} · уровень <b>${r.tier}</b> · <span style="color:${R.c1}">${r.r}</span></p>
      <div class="mrow"><span>WelfareScore</span><b>${r.w} / 100</b></div>
      <div class="mrow"><span>Корм оплачен на</span><b>${r.days} дн.</b></div>
      <div class="mrow"><span>Фирменное поведение</span><b>${r.view}</b></div>
      <div class="mrow"><span>Пол / выводки</span><b>${r.sex} · ${r.litters}</b></div>
      <div class="mrow"><span>Коэффициент инбридинга</span><b>${r.inb}${parseFloat(r.inb) > 6.25 ? ' ⚠️' : ''}</b></div>
      <div class="mrow"><span>Ежемесячное содержание</span><b>${money(invoiceFor(r.tier))} ≈ ${C4(usd2sol(invoiceFor(r.tier)))} SOL</b></div>
      ${free
        ? `<div class="mbox ok">Свободен: <b>${C4(usd2sol(wavePriceUsd()))} SOL</b> (волна 1, ⚑ Q6). В цену входит только животное
        + его карточка-cNFT и 12-месячное обязательство по содержанию — его вы оплачиваете отдельным инвойсом
        (⚑ Q5: депозит в цену не включён).</div>`
        : `<div class="mbox">Животное уже в частных руках. Можно оставить передержку (Resident Pass) или поставить оферту — право первого отказа у второй стороны разведения 30 дней.</div>`}
      <div class="mlist">
        <li><span>Роялти линии при перепродаже</span><code>25 % (5/10/5/5)</code></li>
        <li><span>Разведение</span><code>≤ 2 окрола/год</code></li>
        <li><span>Передача</span><code>≥ 56 дней, гейт</code></li>
      </div>`,
    actions: free
      ? [{ label: `Забронировать · ${C4(usd2sol(CFG.RABBIT_USD))} SOL`, kind:'primary', fn: buyFlow },
         { label: 'Донатить на заботу', kind:'line', fn: () => { closeModal(); donateFlow(40, r.n); } }]
      : [{ label: 'Оставить передержку · 45 $/мес', kind:'primary', fn: boardingFlow },
         { label: 'Донатить на заботу', kind:'line', fn: () => { closeModal(); donateFlow(40, r.n); } }],
  });
}
const invoiceFor = tier => ({ Burrow: 30, Warren: 42, Crown: 60 })[tier] ?? 30;

/* ═══════════ 4. ЦЕЛИ / ДОНАТЫ ═══════════ */
const GOALS = [
  { kind:'HutchRefresh', name:'Реновация A-07 «Библиотека»', r:'Nimbus',
    desc:'Полки-лесенки, укрытие с двумя входами, защита проводов, тёплый настил.',
    target: 12000, raised: 8400, donors: 43, left:'6 дн.',
    quote:'Timothy 3.6 кг — 1 200 C · фанера/укрытие — 6 400 C · монтаж — 2 800 C · освещение 5000K — 1 600 C' },
  { kind:'VetRoute', name:'Стоматология + анализы (Toffee)', r:'Toffee',
    desc:'Седация, рентген, шлифовка, биохимия. Публичный отчёт-хеш.',
    target: 20000, raised: 15100, donors: 88, left:'11 дн.',
    quote:'осмотр 2 000 · седация + стоматоскопия 9 600 · рентген 3 400 · лаборатория 5 000' },
  { kind:'NestBox', name:'Гнездо и уход за выводком', r:'Mochi',
    desc:'Материалы, весы, 24/7 наблюдение первые 14 дней после окрола.',
    target: 900, raised: 900, donors: 27, left:'готово', done:true,
    quote:'800 C собрано · исполнено 2026-10-04 · фото-отчёт и аттестация опубликованы' },
  { kind:'SanctuaryFoster', name:'Recovery-план для rescue «Truffle»', r:'Truffle',
    desc:'3 месяца премиум-содержания после изъятия: отдельный зал, ежедневный видео-отчёт.',
    target: 6000, raised: 2200, donors: 14, left:'19 дн.',
    quote:'премиум-содержание 4 500 · вет-контроль 900 · обогащение 600' },
];
const QUICK = [
  { e:'🌿', t:'Горсть зелени', c:30,  d:'Welfare +1.0 · 15 секунд «Treat Cam»' },
  { e:'🥕', t:'Любимое лакомство', c:40, d:'Welfare +1.5 · клип с именем донатера' },
  { e:'💧', t:'Свежая вода + фильтр', c:20, d:'Welfare +0.5 · отметка в журнале заботы' },
  { e:'🚶', t:'Прогулка 30 минут', c:120, d:'Welfare +2.0 · EventClip #n · ≤1 в сутки' },
  { e:'🔨', t:'Мелкий ремонт вольера', c:150, d:'Welfare +3.0 · durability предмета' },
  { e:'🎂', t:'День рождения (слот)', c:500, d:'Ивент 20 мин · 1 из 12 слотов в год' },
];

function renderGoals() {
  const box = $('#goals'); box.innerHTML = '';
  GOALS.forEach((g, i) => {
    const pct = Math.min(100, Math.round(g.raised / g.target * 100));
    const n = el('article', 'goal');
    n.innerHTML = `
      <div class="g-top"><span class="g-kind">${g.kind}</span><span style="font-size:12px;color:var(--tx-mut)">${g.left}</span></div>
      <h4 class="g-name">${g.name}</h4>
      <p class="g-desc">${g.desc}</p>
      <div class="g-meta">
        <span>собрано <b>${fmt(g.raised)}</b> / ${fmt(g.target)} C</span>
        <span>≈ <b>${money(g.raised * CFG.CLOVER_USD)}</b></span>
        <span>донатеров <b>${g.donors}</b></span>
      </div>
      <div class="bar g-bar"><i style="width:0%" data-w="${pct}"></i></div>
      <p class="g-quote">Смета резиденции: ${g.quote}</p>
      <div class="g-actions"></div>`;
    const acts = $('.g-actions', n);
    if (g.done) {
      acts.appendChild(el('span','tag','✅ исполнено · излишек 4 % ушёл в welfare-фонд'));
    } else {
      const b1 = el('button', 'btn btn-primary', 'Донат 2 $');
      b1.addEventListener('click', () => donateFlow(100, g.name, i));
      const b2 = el('button', 'btn btn-line', 'Донат 10 $');
      b2.addEventListener('click', () => donateFlow(500, g.name, i));
      const b3 = el('button', 'btn btn-line', 'Как работает refund?');
      b3.addEventListener('click', () => explainRefund(g));
      acts.append(b1, b2, b3);
    }
    box.appendChild(n);
  });
  requestAnimationFrame(() => $$('.g-bar > i', box).forEach(b => b.style.width = b.dataset.w + '%'));
}
renderGoals();

function donateFlow(clover, target) {
  const usd = clover * CFG.CLOVER_USD;
  openModal({
    title: 'Заявка на заботу',
    html: `
      <p class="lead small">Сумма <b>${fmt(clover)} C</b> ≈ ${money(usd)} · ${C4(usd2sol(usd))} SOL</p>
      <div class="mlist">
        <li><span>В энддаумент (${CFG.DONATION_SPLIT[0] * 100}%)</span><code>${fmt(Math.round(clover * CFG.DONATION_SPLIT[0]))} C</code></li>
        <li><span>Эфир и сообщество (${CFG.DONATION_SPLIT[1] * 100}%)</span><code>${fmt(clover * CFG.DONATION_SPLIT[1])} C</code></li>
        <li><span>Welfare Reserve (${CFG.DONATION_SPLIT[2] * 100}%)</span><code>${fmt(clover * CFG.DONATION_SPLIT[2])} C</code></li>
      </div>
      <div class="mrow"><span>Назначение</span><b>${target}</b></div>
      <div class="mrow"><span>SLA исполнения</span><b>24 часа · иначе авто-возврат</b></div>
      <div class="mbox">В демо-режиме средства не списываются: заявка сохраняется локально, чтобы показать
      прогресс цели. Боевой маршрут: <code>USDC/SOL → DonationRouter → MerchantGateway</code>, оплата — только
      whitelisted-вендору, вывод владельцу невозможен на уровне контракта.</div>`,
    actions: [{ label:'Отправить заявку (демо)', kind:'primary', fn: () => {
      const g = GOALS.find(x => x.name === target);
      if (g && !g.done) { g.raised = Math.min(g.target, g.raised + clover); g.donors += 1; renderGoals(); }
      closeModal();
      toast('Заявка принята · цель продвинулась');
    }}, { label:'Отмена', kind:'line' }],
  });
}

function explainRefund(g) {
  openModal({
    title: 'Почему донат безопасен',
    html: `<div class="mlist">
        <li><span>Не собрано к дедлайну</span><code>возврат 100 %</code></li>
        <li><span>Собрано, но не исполнено в срок</span><code>возврат + штраф резиденции 2 %</code></li>
        <li><span>Излишек свыше сметы</span><code>50 % улучшение / 50 % welfare</code></li>
        <li><span>Вывод владельцу</span><code>невозможен (нет функции)</code></li>
      </div>
      <div class="mbox ok">Смета зафиксирована: ${g.quote}. Любое изменение сметы — новая версия цели,
      а не «тихое» расходование уже собранных средств.</div>`,
    actions: [{ label:'Понятно', kind:'line' }],
  });
}

const quickBox = $('#quick');
QUICK.forEach(q => {
  const b = el('button', 'q', `<i>${q.e}</i><div><b>${q.t}</b><span>${fmt(q.c)} C · ${money(q.c * CFG.CLOVER_USD)}</span></div>`);
  b.title = q.d;
  b.addEventListener('click', () => donateFlow(q.c, 'nimbus_042'));
  quickBox.appendChild(b);
});

/* мини-эфир: живые метрики (имитация потока оракула) */
(() => {
  const w = $('#msW'), d = $('#msD'), v = $('#msV'); let W = 88, V = 412;
  setInterval(() => {
    V += Math.round((Math.random() - .35) * 9); V = Math.max(120, V);
    W = Math.max(80, Math.min(97, W + (Math.random() < .55 ? 1 : -1)));
    v.textContent = fmt(V); w.textContent = W;
    if (Math.random() < .12) { const cur = Number(d.textContent); d.textContent = Math.max(0, cur - 1) || 9; }
  }, 3400);
})();

/* ═══════════ 5. КАЛЬКУЛЯТОР ЗАБОТЫ ═══════════ */
const TIERS = [
  { n:'Burrow', c:1500, u:30 }, { n:'Warren', c:2100, u:42 }, { n:'Crown', c:3000, u:60 },
];
const WALK_C = 120, ITEM_C = 400, VET_C = 600;
const WALK_W = 2.0, ITEM_W = 3.0, VET_W = 5.0;

function calc() {
  const t = TIERS[+$('#cLevel').value];
  const walks = +$('#cWalks').value, items = +$('#cItems').value, vets = +$('#cVet').value;
  $('#oLevel').textContent = t.n;
  $('#oWalks').textContent = walks; $('#oItems').textContent = items; $('#oVet').textContent = vets;

  const extraC = walks * WALK_C + items * ITEM_C + vets * VET_C;
  const fullC  = t.c + extraC;                        // месяц «как есть»
  const mineC  = t.c + Math.round(extraC * 0.25);    // 25% «хвоста» — на владельце, остальное добирают донатеры
  const mineUsd = mineC * CFG.CLOVER_USD;
  const fullUsd = fullC * CFG.CLOVER_USD;
  const cover  = Math.round(t.u / CFG.OPS_COST_USD * 100);           // ядро (еда/подстилка/вет-план) vs опекс
  const gapUsd = Math.max(0, fullUsd - mineUsd);
  const welfare = Math.round((t.n === 'Crown' ? 6 : t.n === 'Warren' ? 4 : 2) + walks * WALK_W + items * ITEM_W + vets * VET_W);

  $('#tMine').textContent = fmt(mineC);
  $('#tMineUsd').textContent = fmt(mineUsd, 0);
  $('#tCover').textContent = cover;
  $('#tFull').textContent = fmt(fullC);
  $('#tWel').textContent = welfare;
  $('#barFill').style.width = Math.max(4, Math.min(100, cover)) + '%';

  const solIn = $('.calc-total .sol-in');
  if (solIn) { solIn.dataset.usd = mineUsd.toFixed(0); solIn.textContent = C4(usd2sol(mineUsd)) + ' SOL'; }
  const gb = $('#gapBuy');
  if (gb) {
    gb.textContent = gapUsd > 0 ? 'закрыть разницу · ' + money(gapUsd) + ' ≈ ' + C4(usd2sol(gapUsd)) + ' SOL'
                               : 'хвост = 0, всё на вашей стороне';
    gb.dataset.usd = gapUsd.toFixed(0);
  }

  const hints = cover >= 75
    ? 'Ядро содержания оплачено полностью. ' + money(gapUsd) + ' «хвоста» (прогулки, предметы, чекапы сверх плана) закрывают микро-донаты — их не нужно платить вам.'
    : cover >= 50
      ? 'Ядро закрыто частично: не хватает ' + money(CFG.OPS_COST_USD - t.u) + '/мес. До 100 % доводит передержка (45 $) или серия заботы — разведение и конкурсы при <60 % заблокированы.'
      : 'Ниже 50 % ядра: животное в «жёлтой зоне» — только базовое кормление, без разведения и конкурсов. Это защита животного, а не наказание владельца.';
  $('#ccHint').textContent = hints;
}
['cLevel','cWalks','cItems','cVet'].forEach(id => $('#' + id).addEventListener('input', calc));
$('#gapBuy').addEventListener('click', (e) => {
  const usd = Number(e.currentTarget.dataset.usd || 0);
  donateFlow(Math.max(1, Math.round(usd / CFG.CLOVER_USD)), t_now() + ' · хвост месяца');
});
const t_now = () => TIERS[+$('#cLevel').value].n;
calc();

/* ═══════════ 6. БРИДИНГ-ВИЗУАЛ ═══════════ */
function renderTree() {
  const t = $('#tree'); if (!t) return;
  const node = (txt, cls = '') => `<span class="tr-node ${cls}">${txt}</span>`;
  t.innerHTML = `
    <div class="tr-row">${node('House of Cirrus','lead')}${node('3 титула предков')}</div>
    <div class="tr-link"></div>
    <div class="tr-row">${node('Nimbus · Rare 642')}${node('Toffee · Epic 711')}</div>
    <div class="tr-link"></div>
    <div class="tr-row">${node('Snow · Common 311')}${node('Ash · Common 288')}${node('Bagel · Unc. 405')}${node('поиск 5–6 колен…','void')}</div>
    <div class="tr-row">${node('PedigreeScore 58 / 100')}${node('Inbreeding 2.1 %','lead')}</div>`;
}
renderTree();

(() => {
  const box = $('#rar'); if (!box) return;
  Object.entries(RARITY).forEach(([k, R]) => {
    const row = el('div', 'rar-row', `
      <span>${k}</span>
      <span class="rar-bar"><i style="width:${Math.max(2, R.pct)}%;background:linear-gradient(90deg,${R.c1},${R.c2})"></i></span>
      <b>${R.pct}%</b>`);
    box.appendChild(row);
  });
})();

/* ═══════════ 7. MINT ═══════════ */
const WAVES = [
  { n:'Волна 0 · вайтлист', s:'120 животных', p:'375 $ · −25 %', st:'is-now', e:'🎟' },
  { n:'Волна 1 · общая', s:'320 животных', p:'500 $ в SOL', st:'', e:'🐇' },
  { n:'Волна 2 · Crown', s:'48 животных', p:'sealed-bid, старт 575 $', st:'', e:'👑' },
  { n:'Волна 3 · kit-аукционы', s:'крольчата', p:'Dutch −6 %/12 ч', st:'is-done', e:'🐣' },
  { n:'Rescue-аукционы', s:'изъятые', p:'1 SOL старт', st:'is-now', e:'🛟' },
  { n:'Очередь вольеров', s:'360 в листе', p:'открыто 888', st:'', e:'⏳' },
];
(() => {
  const box = $('#waves'); if (!box) return;
  WAVES.forEach(w => box.appendChild(el('div', 'wave ' + w.st,
    `<b>${w.n}</b><span>${w.s} · ${w.p}</span><i>${w.e}</i>`)));
})();

function scrollToMint() { $('#mint')?.scrollIntoView({ behavior:'smooth', block:'start' }); }
$('#mintBtn').addEventListener('click', async () => {
  if (!wallet) { const p = await connectWallet(); if (!p) return; }
  buyFlow();
});
function buyFlow() {
  const sol = QUOTE.sol || usd2sol(wavePriceUsd());
  openModal({
    title: 'Кассовое окно · волна 1',
    html: `
      <div class="mrow"><span>Цена животного (волна 1)</span><b>${fmt(wavePriceUsd())} $</b></div>
      <div class="mrow"><span>Зафиксировано в SOL</span><b>${C4(sol)} SOL</b></div>
      <div class="mrow"><span>Окно курса</span><b>${CFG.QUOTE_TTL_S} с · проскальзывание ±${(CFG.QUOTE_SLIP * 100).toFixed(1)} %</b></div>
      <div class="mrow"><span>Маршрут оплаты (⚑ Q9)</span><code>SOL → Jupiter → USDC → DonationRouter</code></div>
      <div class="mrow"><span>Содержание (⚑ Q5, отдельно)</span><b>30–60 $/мес. инвойсом</b></div>
      <div class="mrow"><span>Газ (⚑ Q8)</span><b>за счёт игрока · ≈0.000005 SOL</b></div>
      <div class="mbox">⚠️ Маршрут ещё не опубликован: программа <code>warren-care</code> на Solana в разработке,
      карточка — <code>Bubblegum cNFT</code>, токен заботы — <code>Token-2022</code>. Сейчас это запись в лист
      ожидания без подписи; финальное количество SOL считает оракул внутри окна, а не значение на экране.</div>`,
    actions: [
      { label:'Записать в лист ожидания', kind:'primary', fn: () => { closeModal(); toast('Вы в листе · приоритет на волну 0 (−25 %)'); wlPush(); } },
      { label:'Позже', kind:'line' },
    ],
  });
}
function boardingFlow() {
  openModal({
    title: 'Передержка · Resident Pass',
    html: `<div class="mrow"><span>Ставка</span><b>45 $/мес. ≈ ${C4(usd2sol(45))} SOL</b></div>
      <div class="mlist">
        <li><span>55 %</span><code>прямое содержание животного</code></li>
        <li><span>28 %</span><code>фонд изъятий и приюта</code></li>
        <li><span>17 %</span><code>инфраструктура и медиа</code></li>
      </div>
      <div class="mbox ok">Не требует владения и 12-летнего обязательства: имя на табличке вольера, 4 голоса
      по декору в год, −15 % на донаты, приоритет покупки RCN при освобождении слота, 2 клипа-коллекционки в месяц.</div>`,
    actions: [{ label:'В лист на передержку', kind:'primary', fn: () => { closeModal(); toast('Заявка на передержку принята'); } }, { label:'Отмена', kind:'line' }],
  });
}
$('#boardingBtn').addEventListener('click', boardingFlow);

/* вайтлист */
function wlPush() {
  const n = $('#wlCount'); const v = Number(String(n.textContent).replace(/\D/g, '')) || 1412;
  n.textContent = fmt(v + 1);
}
$('#wlBtn').addEventListener('click', () => {
  const input = $('#wlEmail'); const v = input.value.trim();
  if (!/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(v)) { toast('Проверьте email — он нужен только для письма о старте'); input.focus(); return; }
  const list = store.get('waitlist', []);
  if (!list.includes(v)) list.push(v);
  store.set('waitlist', list);
  input.value = ''; $('#wlNote').textContent = 'Готово: ' + v + ' в списке. Волна 0 · 375 $ (−25 % от волны 1) · приоритет 48 ч.';
  wlPush(); toast('Вы в вайтлисте');
});

/* обратный отсчёт */
(() => {
  const out = $('#countdown');
  const tick = () => {
    const ms = CFG.MINT_AT - Date.now();
    if (ms <= 0) { out.textContent = 'идёт'; return; }
    const d = Math.floor(ms / 864e5), h = Math.floor(ms % 864e5 / 36e5), m = Math.floor(ms % 36e5 / 6e4), s = Math.floor(ms % 6e4 / 1e3);
    out.textContent = `${d}д ${String(h).padStart(2,'0')}ч ${String(m).padStart(2,'0')}м ${String(s).padStart(2,'0')}с`;
  };
  tick(); setInterval(tick, 1000);
})();

/* ═══════════ 8. FAQ ═══════════ */
const FAQ = [
  ['Что именно я покупаю за 500 $?',
   'RCN — <b>внутриигровой предмет</b> (так решил продукт, ⚑ Q4), а не долговое требование и не ценная бумага: он даёт права участия за конкретным живым животным в резиденции — смотреть 24/7, задавать расписание, обогащение, разведение, голосовать по декору, продавать предмет, получать роялти линии. Он не даёт права забрать кролика домой и не обещает доход. В 500 $ (волна 1) входит <b>только животное и его карточка</b>; содержание — отдельный месячный инвойс 30–60 $ (⚑ Q5).'],
  ['Почему кроликов ровно 888?',
   'Потому что столько <b>реальных вольеров</b>: 160 слотов на резиденцию × 5 резиденций к концу roadmap. Слот закрывается только когда построено помещение, подписан вет-партнёр и опубликован <code>CapacityProof</code>. «Добить минт под спрос» невозможно контрактом — это и есть настоящий дефицит.'],
  ['Почему цена в SOL, а не в долларах?',
   'Цена задаётся в USD (500 $), а списание идёт в SOL по курсу оракула в момент подписания транзакции. Курс на странице — живой (CoinGecko/Binance/KuCoin с локальным кэшем и пометкой «кэш», если источники недоступны).'],
  ['Что если я перестану платить содержание?',
   'Инвойс гасится из энддаумента животного, затем на вас фиксируется <code>CareDebt</code>. Через 7 дней — запрет разведения и конкурсов, 30 дней — статус «требуется забота» и публичный отчёт, 60 дней — изъятие с rescue-аукционом. <b>Животное при этом не голодает и не меняет вольер</b>: смена bonded-группы — самостоятельный стресс-фактор.'],
  ['Куда делятся 30 % от выводка?',
   'Два режима в договоре <code>BreedingBond</code>: «натуральный» (протокол получает ⌊0.30 × выводок⌋ крольчонка и продаёт его Dutch-аукционом, 100 % выручки — в фонд содержания) или «роялти» (крольчата достаются сторонам, а линия несёт надбавку на первые 4 инвойса). Выбор виден второй стороне до подписи.'],
  ['Можно ли вывести донаты, которые мне оставили?',
   'Нет, и это не ограничение «для галочки»: у энддаумента животного <b>нет функции вывода</b>. Расход возможен только через <code>MerchantGateway</code> whitelisted-вендорами (корма, вет, оборудование, услуги резиденции). Владелец зарабатывает на правах — продажа RCN, роялти, титулы, призы, — а не на содержании.'],
  ['Что если кролик умрёт?',
   'Статус <code>Legacy</code>: cNFT остаётся в реестре с мемориальными метаданными, остаток энддаумента уходит в welfare-фонд на выбранного сообществом подопечного, а потомки получают ауру предка (+2..+6 к редкости). Если смерть наступила при низком WelfareScore по вине резиденции — выплату покрывает страховка (до $600 или 3 месяца содержания).'],
  ['Где гарантия, что кролика реально кормят?',
   'Нигде в смысле «обещания». Есть проверяемые данные: автовесы, RFID-кормушки, счётчик кормлений, ИИ-детекция поведения, журнал оператора и 3 подписи оракула из 5 (персонал, ветеринар, внешний аудитор, ИИ-сервис, менеджер). Расхождение ончейн/факт дольше 48 часов → статус <code>Disputed</code> и независимая проверка за счёт фонда.'],
  ['Какие комиссии и кто их платит?',
   'При продаже RCN — 25 % совокупно: 5 % маркетплейс, 10 % welfare-сбор, 5 % родителю-линии (40/40/20 между отцом, матерью и фондом), 5 % DAO. Все 25 % видны в калькуляторе до листинга; «скрытых» комиссий нет, и уменьшить welfare-сбор голосованием нельзя — он зашит в неизменяемые константы.'],
  ['Что будет, если я перестану платить и не найду покупателя?',
   'Животное <b>не продают и не «изымают в никуда»</b>: права по карточке переходят разработчикам (⚑ Q14), а само животное остаётся в том же вольере с тем же bonded-кругом — смена группы для кролика стресс опаснее, чем смена владельца. Дальше оно живёт на funds из welfare-резерва и донатах, ваша карточка получает статус <code>Custody: Warren Labs</code>. Вернуть права можно, закрыв долг и оплатив месяц вперёд.'],
  ['Риск «сведения» не сработал — кто платит?',
   'Игрок (⚑ Q16). <code>BreedingBond</code> — двусторонний опцион: если окрола не случилось, депозит bond не возвращается, а уходит в фонд содержания; 30 % протоколу начисляются <b>только на живых зарегистрированных крольчат</b>, «за несостоявшуюся вязку» роялти нет. Вет-расходы на подтверждение бесплодия — тоже сторона игроков.'],
  ['Это инвестиция?',
   'Нет. Токены дают права участия и заботы, а не право на доход; цена актива — следствие спроса, а не обещание. Любые формулировки о «доходности» запрещены политикой проекта, а buyback и сжигание — механика эмиссии, не дивиденд.'],
];
(() => {
  const box = $('#faq-list'); if (!box) return;
  FAQ.forEach(([q, a], i) => {
    const d = el('details', 'qa');
    if (i === 0) d.open = true;
    d.innerHTML = `<summary>${q}</summary><div>${a}</div>`;
    box.appendChild(d);
  });
})();

/* ═══════════ 9. МОДАЛКА ═══════════ */
function openModal({ title, html = '', actions = [] }) {
  const m = $('#modal'), body = $('#modalBody');
  body.innerHTML = `<h3>${title}</h3>${html}`;
  if (actions.length) {
    const row = el('div', 'card-actions'); row.style.marginTop = '18px';
    actions.forEach(a => {
      const b = el('button', 'btn ' + (a.kind === 'line' ? 'btn-line' : 'btn-primary'), a.label);
      b.addEventListener('click', () => a.fn ? a.fn() : closeModal());
      row.appendChild(b);
    });
    body.appendChild(row);
  }
  m.classList.add('is-open'); m.setAttribute('aria-hidden', 'false');
  document.body.style.overflow = 'hidden';
}
function closeModal() {
  const m = $('#modal'); m.classList.remove('is-open'); m.setAttribute('aria-hidden', 'true');
  document.body.style.overflow = '';
}
$$('#modal [data-close]').forEach(n => n.addEventListener('click', closeModal));
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeModal(); });

/* прочее */
$('#year').textContent = new Date().getFullYear();
$('#wlCount').textContent = fmt(1412 + store.get('waitlist', []).length);
})();
