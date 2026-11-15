// SIMULATED demo. Starts a hub (unless SERVER_URL points at a running one) and feeds it with virtual iPhones
// that post exactly what the app posts. Nothing here is a real measurement; the session is always "DEMO".
//
//   npm run demo              three phones: one object's shadow is another phone's light
//   npm run demo -- --phones=1   one phone: hidden objects continue on a predicted, increasingly uncertain path
//   SERVER_URL=http://192.168.1.7:8080 SHAREDSIGHT_TOKEN=… npm run demo     feed an already running hub
import { performance } from 'node:perf_hooks';
import { createHub, lanAddresses } from './server.mjs';
import { createScenario } from './sim/room.mjs';

const arg = name => process.argv.find(a => a.startsWith(`--${name}=`))?.split('=')[1];
const phones = Number(arg('phones') ?? process.env.PHONES ?? 3), rate = Number(arg('rate') ?? 20), port = Number(arg('port') ?? process.env.PORT ?? 8080);
let url = process.env.SERVER_URL, token = process.env.SHAREDSIGHT_TOKEN, hub = null;

if (!url) {
  hub = createHub({ token: token || 'demo' }); token = hub.token;
  await new Promise((resolve, reject) => { hub.server.once('error', reject); hub.server.listen(port, process.env.HOST ?? '0.0.0.0', resolve); })
    .catch(error => { console.error(error.code === 'EADDRINUSE' ? `La porta ${port} è occupata: chiudi l'altro server o usa --port=8081.` : error.message); process.exit(1); });
  url = `http://127.0.0.1:${port}`;
} else if (!token) { console.error('Imposta SHAREDSIGHT_TOKEN alla chiave mostrata dal server.'); process.exit(1); }

const scenario = createScenario({ phones });
const open = `${hub ? `http://localhost:${port}` : url}/#token=${token}&session=DEMO`;
console.log(`\nDEMO SIMULATA · ${scenario.phones.length} iPhone virtual${scenario.phones.length === 1 ? 'e' : 'i'} · sessione DEMO · ${rate} invii/s ciascuno`);
console.log(`Apri: ${open}`);
if (hub) for (const a of lanAddresses()) console.log(`Da un altro dispositivo: http://${a}:${port}/#token=${token}&session=DEMO`);
console.log('Ctrl+C per terminare.\n');

const IT = { person: 'Persona', dog: 'Cane', couch: 'Divano', chair: 'Sedia', 'dining table': 'Tavolo', 'potted plant': 'Pianta', vase: 'Vaso' };
const where = a => a.relation === 'outOfView' ? 'fuori dal campo visivo' : a.occluder === 'door' ? 'dietro la porta' : a.occluder === 'wall' ? 'dietro la parete' : 'dietro un oggetto';
let stopped = false, told = new Map(), delays = [], sent = 0, failed = 0;
process.on('SIGINT', () => { stopped = true; });

async function post(index, t) {
  const { frame } = scenario.frame(index, t), started = performance.now();
  try {
    const r = await fetch(`${url}/api/frames`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(frame), signal: AbortSignal.timeout(3000) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const reply = await r.json(); scenario.reply(index, reply); delays.push(performance.now() - started); sent++;
    if (index === 0) narrate(reply.advisories ?? [], t);
  } catch (error) { if (++failed === 1 || failed % 50 === 0) console.error(`Invio non riuscito (${error.message}).`); if (failed > 200) stopped = true; }
}

/** What the user's phone learns from the hub, printed when it changes. The app turns the same data into speech. */
function narrate(advisories, t) {
  const moving = advisories.filter(a => IT[a.label] && (a.label === 'person' || a.label === 'dog'));
  const now = new Map(moving.map(a => [a.id, `${a.kind}|${where(a)}`]));
  for (const a of moving) if (told.get(a.id) !== now.get(a.id))
    console.log(`${t.toFixed(1).padStart(6)} s  → iPhone utente: ${IT[a.label]} ${where(a)}, ${a.kind === 'seen' ? `vista da ${a.seenBy} altro iPhone` : `non la vede nessuno: posizione stimata ±${a.sigma.toFixed(1)} m`} (a ${a.distance.toFixed(1)} m${a.localID != null ? ', la stava seguendo' : ''})`);
  told = now;
}

const started = performance.now(); let tick = 0, lastReport = started;
while (!stopped) {
  const t = (performance.now() - started) / 1000;
  await Promise.all(scenario.phones.map((_, i) => post(i, t)));
  if (performance.now() - lastReport > 10000 && delays.length) {
    delays.sort((a, b) => a - b);
    console.log(`        [rete] ${sent} invii · risposta del server: mediana ${delays[delays.length >> 1].toFixed(1)} ms, p95 ${delays[Math.floor(delays.length * 0.95)].toFixed(1)} ms`);
    delays = []; lastReport = performance.now();
  }
  const next = started + ++tick * 1000 / rate, wait = next - performance.now();
  if (wait > 0) await new Promise(r => setTimeout(r, wait)); else tick = Math.ceil((performance.now() - started) * rate / 1000);
}
hub?.server.close(); hub?.server.closeAllConnections?.();
console.log('\nDemo terminata.');
