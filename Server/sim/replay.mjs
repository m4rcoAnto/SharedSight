// Replays a recorded real session (Server/recordings/*.ndjson) through the hub's real code.
//
//   npm run replay -- recordings/<file>            prints what the hub understood: perimeter, objects, events
//   npm run replay -- recordings/<file> --serve    plays it in real time to the dashboard (no phones needed), in a loop
//   options: --port=8080  --speed=1
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { RoomStore } from '../state.mjs';
import { createHub, lanAddresses } from '../server.mjs';

export function load(path) {
  return readFileSync(path, 'utf8').split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(r => r?.frame);
}

/** Feeds the records to a store. The hub's receipt tokens are re-issued on replay, as a live phone would echo them. */
export function replay(records, store, setClock, { loop = 0, each = () => {} } = {}) {
  const tokens = new Map(), codes = {};
  for (const r of records) {
    setClock(r.at);
    const f = { ...r.frame, epoch: loop ? `${r.frame.epoch}#${loop}` : r.frame.epoch };
    const key = `${f.session}|${f.deviceID}|${f.epoch}`;
    if (f.version === 3) { if (tokens.has(key)) f.receiptToken = tokens.get(key); else delete f.receiptToken; }
    const out = store.accept(f);
    codes[out.code] = (codes[out.code] ?? 0) + 1;
    if (out.reply?.receiptToken) tokens.set(key, out.reply.receiptToken);
    each(r, out);
  }
  return codes;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const file = process.argv[2], arg = n => process.argv.find(a => a.startsWith(`--${n}=`))?.split('=')[1];
  if (!file) { console.error('Uso: npm run replay -- recordings/<file>.ndjson [--serve] [--port=8080] [--speed=1]'); process.exit(1); }
  const records = load(file);
  if (!records.length) { console.error('Registrazione vuota o non leggibile.'); process.exit(1); }
  const sessions = [...new Set(records.map(r => r.frame.session))], seconds = (records.at(-1).at - records[0].at) / 1000;
  console.log(`${records.length} fotogrammi, ${seconds.toFixed(0)} s, sessione ${sessions.join(', ')}, ${new Set(records.map(r => r.frame.deviceID)).size} telefono/i`);

  if (!process.argv.includes('--serve')) {
    let now = 0; const store = new RoomStore(() => now);
    const codes = replay(records, store, t => { now = t; });
    console.log('Esiti:', codes);
    for (const session of sessions) {
      for (const r of store.rooms(session)) {
        console.log(`\nSpazio ${r.space}: ` + (r.room ? `perimetro ${r.room.seenSides} lati visti su 4, assi ${r.room.axisDeg}°, altezza ${r.room.height} m` : 'nessun perimetro'));
        if (r.room) {
          const len = k => r.room.sides.filter(s => s.kind === k).reduce((t, s) => t + Math.hypot(s.bx - s.ax, s.bz - s.az), 0).toFixed(1);
          const c = r.room.corners, w = Math.hypot(c[1][0] - c[0][0], c[1][1] - c[0][1]), d = Math.hypot(c[2][0] - c[1][0], c[2][1] - c[1][1]);
          console.log(`  stanza ${w.toFixed(1)} x ${d.toFixed(1)} m · misurato ${len('wall')} m · prolungato ${len('extended')} m · stimato ${len('inferred')} m · varchi ${len('opening')} m · pareti interne ${r.room.interior.length}`);
        }
        const w = store.world(session, r.space, false);
        if (w) console.log(`  pezzi di parete ricordati ${w.perimeter.patches.size}, punti di scansione ${w.perimeter.scan?.size ?? 0}, riflessi scartati ${w.reflections ?? 0}`);
      }
      for (const s of store.spaces(session)) console.log(`  oggetti: ${s.entities.map(e => `${e.label}(${e.state})`).join(', ') || 'nessuno'}`);
    }
  } else {
    const port = Number(arg('port') ?? 8080), speed = Number(arg('speed') ?? 1);
    let now = 0; const store = new RoomStore(() => now), hub = createHub({ token: 'demo', store });
    await new Promise(r => hub.server.listen(port, '0.0.0.0', r));
    console.log(`REPLAY di una sessione registrata · apri http://localhost:${port}/#token=demo&session=${sessions[0]}`);
    for (const a of lanAddresses()) console.log(`Da un altro dispositivo: http://${a}:${port}/#token=demo&session=${sessions[0]}`);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    let offset = 0;
    for (let loop = 0; ; loop++) {
      const start = performance.now(), first = records[0].at;
      const tokens = new Map();
      for (const r of records) {
        const due = (r.at - first) / speed, wait = due - (performance.now() - start);
        if (wait > 1) await sleep(wait);
        now = offset + (r.at - first);
        const f = { ...r.frame, epoch: `${r.frame.epoch}#${loop}` }, key = `${f.session}|${f.deviceID}`;
        if (f.version === 3) { if (tokens.has(key)) f.receiptToken = tokens.get(key); else delete f.receiptToken; }
        const out = store.accept(f);
        if (out.reply?.receiptToken) tokens.set(key, out.reply.receiptToken);
      }
      offset = now + 2000; await sleep(2000);
    }
  }
}
