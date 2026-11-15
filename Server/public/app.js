import { SceneView } from '/scene.js';
import { connect, fetchPreview } from '/net.js';
import { groupColor } from '/models.js';
import { classInfo } from '/shared/classes.mjs';
import qrcode from '/vendor/qrcode.mjs';

const $ = id => document.getElementById(id);
const IT = { person: 'persona', bicycle: 'bicicletta', car: 'auto', motorcycle: 'moto', airplane: 'aereo', bus: 'autobus', train: 'treno', truck: 'camion', boat: 'barca',
  'traffic light': 'semaforo', 'fire hydrant': 'idrante', 'stop sign': 'segnale di stop', 'parking meter': 'parchimetro', bench: 'panchina', bird: 'uccello', cat: 'gatto',
  dog: 'cane', horse: 'cavallo', sheep: 'pecora', cow: 'mucca', elephant: 'elefante', bear: 'orso', zebra: 'zebra', giraffe: 'giraffa', backpack: 'zaino', umbrella: 'ombrello',
  handbag: 'borsa', tie: 'cravatta', suitcase: 'valigia', frisbee: 'frisbee', skis: 'sci', snowboard: 'snowboard', 'sports ball': 'palla', kite: 'aquilone',
  'baseball bat': 'mazza da baseball', 'baseball glove': 'guantone', skateboard: 'skateboard', surfboard: 'tavola da surf', 'tennis racket': 'racchetta', bottle: 'bottiglia',
  'wine glass': 'calice', cup: 'tazza', fork: 'forchetta', knife: 'coltello', spoon: 'cucchiaio', bowl: 'ciotola', banana: 'banana', apple: 'mela', sandwich: 'panino',
  orange: 'arancia', broccoli: 'broccolo', carrot: 'carota', 'hot dog': 'hot dog', pizza: 'pizza', donut: 'ciambella', cake: 'torta', chair: 'sedia', couch: 'divano',
  'potted plant': 'pianta', bed: 'letto', 'dining table': 'tavolo', toilet: 'water', tv: 'televisore', laptop: 'portatile', mouse: 'mouse', remote: 'telecomando',
  keyboard: 'tastiera', 'cell phone': 'telefono', microwave: 'microonde', oven: 'forno', toaster: 'tostapane', sink: 'lavandino', refrigerator: 'frigorifero', book: 'libro',
  clock: 'orologio', vase: 'vaso', scissors: 'forbici', 'teddy bear': 'orsacchiotto', 'hair drier': 'asciugacapelli', toothbrush: 'spazzolino' };
const noun = label => IT[label] ?? label;
const Noun = label => { const n = noun(label); return n[0].toUpperCase() + n.slice(1); };
const OCCLUDER = { wall: 'dietro una parete', door: 'dietro una porta', object: 'dietro un oggetto' };

let present = false, wantPresent = new URLSearchParams(location.hash.slice(1)).get('present') === '1', plainFooter = null, plainSub = null;
let token = '', session = '1234', link = null, last = null, messages = 0, sceneStats = { fps: 0 }, lastEvent = 0;
const cards = new Map(), previews = new Map();
const scene = new SceneView($('viewport'), { labelFor: noun, onStats: s => { sceneStats = s; } });
if (scene.failed) { $('empty').querySelector('h2').textContent = 'WebGL non disponibile'; $('empty').querySelector('p').textContent = "L'elenco degli oggetti e le prospettive restano disponibili."; }

function setStatus(kind, detail) {
  const el = $('connection');
  el.className = 'status' + (kind === 'connected' ? ' connected' : kind === 'unauthorized' || kind === 'lost' ? ' error' : '');
  el.textContent = { connecting: 'Connessione…', connected: 'Connesso · dati in tempo reale', unauthorized: 'Chiave server errata', lost: 'Connessione persa · nuovo tentativo…' }[kind] ?? detail ?? '';
  if (kind === 'lost' || kind === 'unauthorized') { last = null; renderPanels(); }
  if (kind !== 'connected') { pairInfo = null; updatePair(); }
}

// "Collega iPhone": a QR code with the hub's address on the local network (told by the hub: this page is usually
// open on localhost, which a phone cannot reach), the key and the session. Available only while connected.
let pairInfo = null;
function pairPayload(address) {
  const url = `http://${address}:${pairInfo.port}`;
  return { url, payload: `sharedsight://hub?url=${encodeURIComponent(url)}&token=${encodeURIComponent(token)}&session=${encodeURIComponent(session)}` };
}
function drawPair() {
  const addresses = pairInfo?.addresses ?? [], select = $('pairAddress'), canvas = $('pairCode');
  if (select.dataset.sig !== addresses.join()) { select.dataset.sig = addresses.join(); select.replaceChildren(...addresses.map(a => new Option(a, a))); }
  $('pairAddressRow').hidden = addresses.length < 2;
  const address = addresses.includes(select.value) ? select.value : addresses[0];
  canvas.hidden = !address; $('pairNone').hidden = !!address;
  if (!address) { $('pairUrl').textContent = ''; $('pairSession').textContent = ''; return; }
  const { url, payload } = pairPayload(address), qr = qrcode(0, 'M');
  qr.addData(payload); qr.make();
  const n = qr.getModuleCount(), quiet = 4, scale = Math.max(2, Math.floor(260 / (n + 2 * quiet))), size = (n + 2 * quiet) * scale, g = canvas.getContext('2d');
  canvas.width = canvas.height = size; g.fillStyle = '#fff'; g.fillRect(0, 0, size, size); g.fillStyle = '#000';
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) g.fillRect((c + quiet) * scale, (r + quiet) * scale, scale, scale);
  canvas.setAttribute('aria-label', `Codice QR per collegare un iPhone a ${url}, sessione ${session}`);
  $('pairUrl').textContent = url; $('pairSession').textContent = `Sessione ${session}`;
}
function updatePair() {
  $('pair').disabled = !pairInfo;
  if (!pairInfo) { $('pairPanel').hidden = true; $('pair').setAttribute('aria-expanded', 'false'); } else if (!$('pairPanel').hidden) drawPair();
}
$('pair').onclick = () => { const open = $('pairPanel').hidden; $('pairPanel').hidden = !open; $('pair').setAttribute('aria-expanded', open); if (open) drawPair(); };
$('pairClose').onclick = () => { $('pairPanel').hidden = true; $('pair').setAttribute('aria-expanded', 'false'); $('pair').focus(); };
$('pairAddress').onchange = drawPair;

function start() {
  present = session === 'DEMO' || wantPresent;
  applyPresent();
  link?.close(); last = null; lastEvent = 0; previews.clear();
  $('events').replaceChildren(quiet('Quando un oggetto esce dalla vista di un iPhone ed entra in quella di un altro, compare qui.'));
  link = connect({ token, session, onStatus: setStatus, onMessage(msg) {
    if (msg.type === 'planes') scene.setSurfaces(msg.device, msg.space, msg.planes);
    else if (msg.type === 'room') scene.setRoom(msg.space, msg.room);
    // A hub started before its code was last changed still runs the old code: say so instead of looking broken.
    else if (msg.type === 'hello') { $('stale').hidden = !(msg.stale || !msg.features); pairInfo = msg.pair?.port ? msg.pair : null; updatePair(); }
    else if (msg.type === 'world') { last = msg; messages++; chooseSpace(msg); scene.update(msg); }
  } });
  $('connectButton').textContent = 'Riconnetti';
}
$('connect').onsubmit = e => { e.preventDefault(); token = $('token').value.trim(); session = $('session').value.trim(); if (token && session) start(); };

// The space shown: the shared (marker-aligned) one when it exists, otherwise the first phone's own space.
let chosen = '', manual = false;
function chooseSpace(msg) {
  const keys = msg.spaces.map(s => s.key);
  if (!manual || !keys.includes(chosen)) { chosen = keys.find(k => k.startsWith('shared:')) ?? keys[0] ?? ''; manual = false; }
  scene.setSpace(chosen || null);
}
function spaceTitle(key, msg) {
  if (key.startsWith('shared:')) return `Spazio condiviso · ${msg.devices.filter(d => d.space === key && d.live).length} iPhone`;
  const d = msg.devices.find(x => x.space === key); return `${d?.name ?? 'iPhone'} · non allineato`;
}
$('space').onchange = () => { chosen = $('space').value; manual = true; scene.setSpace(chosen || null); };
$('reset').onclick = () => scene.resetView();
$('top').onclick = () => scene.topView();
for (const [id, option] of [['zones', 'zones'], ['labels', 'labels']]) $(id).onclick = () => {
  const on = $(id).getAttribute('aria-pressed') !== 'true'; $(id).setAttribute('aria-pressed', on); scene.setOptions({ [option]: on });
};

const quiet = text => Object.assign(document.createElement('li'), { className: 'quiet', textContent: text });
function stateText(e, names) {
  const who = (e.seenBy ?? []).map(id => names.get(id) ?? 'iPhone');
  // The hub's confidence in an estimate (a display heuristic): it falls while nobody sees the object.
  const pct = e.conf == null ? '' : ` ${Math.round(e.conf * 100)}%`;
  if (e.state === 'observed') return who.length > 1 ? `in vista · ${who.length} iPhone` : `in vista · ${who[0] ?? 'un iPhone'}`;
  if (e.state === 'remembered') return (e.reason === 'occluded' ? 'ricordato · coperto alla vista' : 'ricordato · fuori campo') + (e.conf != null && e.conf < 0.995 ? ` · affidabilità${pct}` : '');
  if (e.state === 'lost') return 'stima abbandonata';
  if (e.reason === 'unconfirmed') return 'in attesa di conferma';
  return `fuori vista per tutti (${e.reason === 'occluded' ? OCCLUDER[e.occluder] ?? 'coperto' : 'fuori campo'}) · posizione stimata${pct} · ±${e.sigma.toFixed(1).replace('.', ',')} m`;
}
function eventText(ev) {
  const n = Noun(ev.label), why = ev.relation === 'outOfView' || ev.reason === 'outOfView' ? 'fuori campo' : OCCLUDER[ev.occluder] ?? 'coperta alla vista';
  if (ev.type === 'handoff') return [`${n} ${why} per «${ev.from}»`, `resta in vista di «${ev.to}»: «${ev.from}» viene avvisato`];
  if (ev.type === 'hidden') return [`${n} fuori vista per tutti (${why})`, 'traiettoria stimata, incertezza crescente'];
  if (ev.type === 'reacquired') return [`${n} di nuovo in vista`, `rilevamento di «${ev.by}»`];
  if (ev.reason === 'missedExit') return [`${n}: non è riapparsa dove previsto`, 'si è fermata o ha cambiato direzione: posizione non più nota'];
  return [`${n}: stima abbandonata`, ev.reason === 'unconfirmed' ? 'non è dove era prevista' : ev.reason === 'barrierConflict' ? 'la traiettoria incontra una parete' : 'troppo incerta per essere utile'];
}

function renderPanels() {
  const msg = last, live = msg?.devices.filter(d => d.live) ?? [], space = msg?.spaces.find(s => s.key === chosen);
  const entities = space?.entities ?? [], names = new Map((msg?.devices ?? []).map(d => [d.id, d.name]));
  $('deviceCount').textContent = live.length; $('objectCount').textContent = entities.filter(e => e.state !== 'lost').length;
  const delays = live.map(d => d.latencyMs).filter(v => v != null);
  $('latency').textContent = delays.length ? `${Math.max(...delays)} ms` : '—';
  $('empty').hidden = !!(msg && msg.devices.length);

  // Space selector (only rebuilt when the set changes).
  const keys = (msg?.spaces ?? []).map(s => s.key), signature = keys.map(k => spaceTitle(k, msg)).join('|');
  if ($('space').dataset.sig !== signature) {
    $('space').dataset.sig = signature;
    $('space').replaceChildren(...(keys.length ? keys.map(k => new Option(spaceTitle(k, msg), k)) : [new Option('Spazio condiviso', '')]));
  }
  if (keys.includes(chosen)) $('space').value = chosen;

  // Objects: what moves first, then by state.
  const order = e => (classInfo(e.label).dyn ? 0 : 2) + (e.state === 'observed' ? 0 : 1);
  const rows = entities.filter(e => e.state !== 'lost').sort((a, b) => order(a) - order(b) || a.id.localeCompare(b.id, undefined, { numeric: true }));
  $('trackCount').textContent = rows.length;
  const list = $('tracks');
  if (!rows.length) list.replaceChildren(quiet(msg ? 'Nessun oggetto con posizione misurata in questo spazio.' : 'Nessun oggetto.'));
  else {
    while (list.children.length > rows.length) list.lastChild.remove();
    if (list.firstChild?.classList.contains('quiet')) list.replaceChildren();
    rows.forEach((e, i) => {
      let li = list.children[i];
      if (!li) { li = document.createElement('li'); li.innerHTML = '<span class="dot"></span><div><b></b><small></small></div><span class="who"></span>'; list.append(li); }
      const estimate = e.state === 'hidden' && e.reason !== 'unconfirmed';
      li.className = estimate ? 'estimate' : ''; li.querySelector('.dot').style.background = groupColor(e.label);
      const title = Noun(e.label), detail = stateText(e, names);
      if (li.querySelector('b').textContent !== title) li.querySelector('b').textContent = title;
      if (li.querySelector('small').textContent !== detail) li.querySelector('small').textContent = detail;
      const who = (e.seenBy ?? []).map(id => scene.colorOf(id)).join();
      if (li.dataset.who !== who) { li.dataset.who = who; li.querySelector('.who').replaceChildren(...(e.seenBy ?? []).map(id => Object.assign(document.createElement('i'), { style: `background:${scene.colorOf(id)}`, title: names.get(id) ?? '' }))); }
    });
  }

  // Events: handoffs between phones and estimates, newest first.
  for (const ev of space?.events ?? []) {
    if (ev.seq <= lastEvent || (ev.type !== 'handoff' && !classInfo(ev.label).dyn)) continue;
    lastEvent = ev.seq;
    const [head, tail] = eventText(ev), li = document.createElement('li');
    li.className = ev.type; li.append(Object.assign(document.createElement('b'), { textContent: head }), Object.assign(document.createElement('small'), { textContent: tail }));
    $('events').querySelector('.quiet')?.remove(); $('events').prepend(li);
    while ($('events').children.length > 12) $('events').lastChild.remove();
  }

  renderDemoMotion(msg);
  renderCameras(msg);
}

function renderCameras(msg) {
  const devices = msg?.devices ?? [];
  $('cameraTotal').textContent = devices.length;
  for (const [id, card] of cards) if (!devices.some(d => d.id === id)) { card.el.remove(); cards.delete(id); }
  if (devices.length) $('cameras').querySelector('.quiet')?.remove();
  for (const d of devices) {
    let card = cards.get(d.id);
    if (!card) {
      const el = document.createElement('article'); el.className = 'camera-card';
      el.innerHTML = '<div class="camera-view"><canvas width="360" height="480"></canvas></div><div class="camera-meta"><i></i><b></b><small></small></div>';
      card = { el, canvas: el.querySelector('canvas'), image: null, rev: -1 }; cards.set(d.id, card); $('cameras').append(el);
    }
    card.el.classList.toggle('offline', !d.live);
    card.el.querySelector('i').style.background = scene.colorOf(d.id); card.el.querySelector('b').textContent = d.name;
    card.el.querySelector('small').textContent = !d.live ? 'segnale scaduto' : `${!d.tracking ? 'AR in attesa' : d.aligned ? 'allineato' : 'non allineato'} · ${d.fps.toFixed(0)} agg/s${d.latencyMs != null ? ` · ${d.latencyMs} ms` : ''}`;
    if (d.previewRev !== card.rev && !card.loading) {
      card.loading = true; const rev = d.previewRev;
      (rev ? fetchPreview(token, session, d.id) : Promise.resolve(null)).then(image => { card.image?.close?.(); card.image = image; card.rev = rev; }).catch(() => {}).finally(() => { card.loading = false; });
    }
    drawCard(card, d);
  }
}

function drawCard(card, d) {
  const c = card.canvas, g = c.getContext('2d'), img = d.live ? card.image : null;
  const w = img?.width || 360, h = img?.height || 480;
  if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
  if (img) g.drawImage(img, 0, 0); else {
    g.fillStyle = '#ece5d6'; g.fillRect(0, 0, w, h); g.fillStyle = '#dcd3c0'; g.fillRect(0, h * 0.5, w, h * 0.5);
    g.fillStyle = '#8b8275'; g.font = '13px -apple-system, sans-serif'; g.textAlign = 'center';
    g.fillText(d.live ? 'Anteprima non inviata · solo rilevamenti' : 'Segnale scaduto', w / 2, 22); g.textAlign = 'left';
  }
  if (!d.live) return;
  g.font = '600 12px -apple-system, sans-serif'; g.lineWidth = 2;
  for (const o of d.objects) {
    const X = o.box.x * w, Y = o.box.y * h, color = o.p ? '#2f9d6a' : '#c8644a';
    g.strokeStyle = color; g.strokeRect(X, Y, o.box.w * w, o.box.h * h);
    const text = `${noun(o.label)} ${Math.round(o.c * 100)}%${o.p ? '' : ' · solo 2D'}`, tw = g.measureText(text).width + 8;
    const lx = Math.min(X, w - tw), ly = Math.max(0, Y - 18);
    g.fillStyle = color; g.fillRect(lx, ly, tw, 17); g.fillStyle = '#fff'; g.fillText(text, lx + 4, ly + 12);
  }
}

setInterval(renderPanels, 200);
setInterval(() => { $('rates').textContent = last ? `${messages} agg/s · ${sceneStats.fps} fps` : '—'; messages = 0; }, 1000);

// "#token=…&session=…" (printed by the server and by the demo) connects without typing.
const params = new URLSearchParams(location.hash.slice(1));
if (params.get('token')) { $('token').value = token = params.get('token'); $('session').value = session = params.get('session') ?? '1234'; start(); }
window.sharedSight = { scene, get last() { return last; } };

// Presentation layout. Always on for the synthetic DEMO session; for a live session it is a choice ("Presentazione"
// button, or "&present=1" in the address) and every label then says the data are live measurements, not a simulation.
function applyPresent() {
  const demo = session === 'DEMO';
  scene.setOptions({ demo, forecast: present, zones: !present });
  setupPitch(present, demo);
  $('present').setAttribute('aria-pressed', present); $('present').disabled = demo;
  $('zones').setAttribute('aria-pressed', !present);
}
$('present').onclick = () => { wantPresent = present = !present; applyPresent(); renderDemoMotion(last); };

function setupPitch(enabled, demo = true) {
  document.body.classList.toggle('pitch', enabled); document.body.classList.toggle('live', enabled && !demo);
  plainFooter ??= document.querySelector('footer').textContent; plainSub ??= document.querySelector('.brand .sub').textContent;
  let hero = $('pitch-intro');
  if (!hero) {
    hero = document.createElement('section'); hero.id = 'pitch-intro';
    hero.innerHTML = '<div><p class="eyebrow">FIELDVISION / SHARED SIGHT</p><h1>Più occhi.<br>Meno punti ciechi.</h1><p class="intro-copy">Un iPhone vede una parte della stanza. <br>Insieme, condividono ciò che resta fuori vista.</p></div><div class="pitch-caption"><span class="simulation-badge">DEMO SIMULATA</span><p>3 iPhone virtuali · un unico spazio condiviso</p></div>';
    document.querySelector('main').before(hero);
    const panel = document.createElement('section'); panel.id = 'demo-motion';
    panel.innerHTML = '<p class="eyebrow">COSA STA SUCCEDENDO</p><h2 id="pitch-state">Osservare. Condividere. Prevedere.</h2><p id="pitch-explain"></p><div class="pitch-metrics"><div><b id="pitch-seen">—</b><span>in vista</span></div><div><b id="pitch-shared">—</b><span>condivisi</span></div><div><b id="pitch-estimated">—</b><span>stimati</span></div></div><h3>Previsione del movimento <span>3 s</span></h3><ul class="pitch-alerts"></ul><p class="pitch-limit">Stima da posizione e velocità rilevate. Ingombri approssimati; non è una garanzia di percorso libero.</p>';
    document.querySelector('aside').prepend(panel);
    const guide = document.createElement('div'); guide.id = 'pitch-guide';
    guide.innerHTML = '<div><b>01 <span>Rileva</span></b><p>Ogni telefono osserva il proprio campo visivo.</p></div><div><b>02 <span>Condivide</span></b><p>Un altro iPhone può vedere oltre un punto cieco.</p></div><div><b>03 <span>Prevede</span></b><p>Traiettorie stimate e possibili ostacoli, prima del contatto.</p></div>';
    document.querySelector('main').after(guide);
    const legend = document.createElement('div'); legend.className = 'pitch-legend';
    legend.innerHTML = '<span><i style="background:#236fc2"></i>Traiettoria prevista</span><span><i style="background:#d64032"></i>Possibile ostacolo</span><span><i style="background:#9da6b8"></i>Sagoma trasparente: stima</span>';
    $('viewport').append(legend);
  }
  hero.hidden = !enabled; $('pitch-guide').hidden = !enabled; $('demo-motion').hidden = !enabled;
  hero.querySelector('.simulation-badge').textContent = demo ? 'DEMO SIMULATA' : 'DAL VIVO';
  document.querySelector('.brand .sub').textContent = enabled ? 'Many eyes. Fewer blind spots.' : plainSub;
  document.querySelector('footer').textContent = !enabled ? plainFooter
    : `Prototipo sperimentale · ${demo ? 'Dati sintetici, non misure dal vivo' : 'Posizioni misurate dagli iPhone collegati; le previsioni sono stime'} · Le sagome rappresentano categorie di oggetti · Supporto alla consapevolezza, non dispositivo di navigazione.`;
}

function renderDemoMotion(msg) {
  if (!present) return;
  const panel = $('demo-motion'), demo = session === 'DEMO';
  const liveDevices = msg?.devices.filter(d => d.live) ?? [];
  // The phone taken as "the user's": the simulated one in the demo, otherwise the first phone that connected.
  const userPhone = demo ? 'demo-user' : liveDevices[0]?.id, phones = liveDevices.length;
  const caption = document.querySelector('.pitch-caption p');
  if (caption) caption.textContent = demo ? '3 iPhone virtuali · un unico spazio condiviso' : `${phones} iPhone ${phones === 1 ? 'collegato' : 'collegati'} · un unico spazio condiviso`;
  const entities = msg?.spaces.find(s => s.key === chosen)?.entities.filter(e => e.state !== 'lost') ?? [];
  const observed = entities.filter(e => e.state === 'observed');
  const shared = observed.filter(e => e.seenBy?.length && !e.seenBy.includes(userPhone));
  const hidden = entities.filter(e => e.state === 'hidden');
  $('pitch-seen').textContent = observed.length;
  $('pitch-shared').textContent = shared.length;
  $('pitch-estimated').textContent = hidden.length;
  const subject = shared.find(e => ['person','dog'].includes(e.label));
  $('pitch-state').textContent = !msg ? (demo ? 'Connessione alla demo…' : 'In attesa degli iPhone…') : subject ? 'Fuori vista. Ancora rilevato.' : hidden.length ? 'Non più visibile. Posizione stimata.' : demo ? 'Tre prospettive, una stanza.' : phones > 1 ? `${phones} prospettive, una stanza.` : phones === 1 ? 'Un iPhone collegato.' : 'Nessun iPhone collegato.';
  $('pitch-explain').textContent = !msg ? (demo ? 'In attesa dei dati della simulazione.' : 'In attesa dei dati dagli iPhone.') : subject ? `${Noun(subject.label)} fuori vista per ${demo ? 'l’iPhone utente' : `«${liveDevices[0]?.name ?? 'iPhone'}»`}, rilevato da un altro telefono. L’informazione resta disponibile nello spazio condiviso.` : hidden.length ? 'Quando nessuno vede un soggetto, la previsione resta esplicitamente una stima e viene abbandonata se troppo incerta.' : demo || phones > 1 ? `I rilevamenti ${demo ? 'dei tre' : 'degli'} iPhone vengono riuniti nello stesso modello spaziale, aggiornato durante il movimento.` : 'Con un solo iPhone non c’è ancora nulla da condividere: collegane un altro con «Collega iPhone».';
  const forecasts = msg ? scene.demoForecasts ?? [] : [];
  const ordered = [...forecasts].sort((a,b) => (a.hit?.t ?? 99) - (b.hit?.t ?? 99));
  const signature = ordered.map(f => `${f.label}:${f.estimated}:${f.hit?.label ?? ''}:${f.hit ? Math.ceil(f.hit.t * 2) / 2 : ''}`).join('|');
  if (panel.dataset.signature !== signature || !panel.querySelector('li')) {
    panel.dataset.signature = signature;
    const items = ordered.slice(0,2).map(f => {
      const li = document.createElement('li'); li.className = f.hit ? 'risk' : 'forecast';
      const title = document.createElement('b'), detail = document.createElement('span');
      title.textContent = f.hit ? `${Noun(f.label)} · possibile ostacolo` : `${Noun(f.label)} · traiettoria prevista`;
      detail.textContent = f.hit ? `${Noun(f.hit.label)} ${f.hit.t < 0.1 ? 'nelle immediate vicinanze' : 'tra circa ' + (Math.ceil(f.hit.t * 2) / 2).toFixed(1).replace('.', ',') + ' s'}${f.estimated ? ' · posizione stimata' : ''}` : `Proiezione a 3 secondi${f.estimated ? ' · posizione stimata' : ' dalla velocità rilevata'}`;
      li.append(title, detail); return li;
    });
    panel.querySelector('ul').replaceChildren(...(items.length ? items : [quiet(msg ? 'Nessun movimento confermato in questo istante.' : 'Previsioni in attesa di dati.')]));
  }
}
