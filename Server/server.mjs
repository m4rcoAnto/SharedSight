import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { readFileSync, writeFileSync, statSync, readdirSync, mkdirSync, unlinkSync, createWriteStream } from 'node:fs';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { networkInterfaces } from 'node:os';
import { fileURLToPath } from 'node:url';
import { resolve, extname } from 'node:path';
import { RoomStore } from './state.mjs';

const root = fileURLToPath(new URL('.', import.meta.url));
const STATIC = {
  '/': 'public/index.html', '/app.js': 'public/app.js', '/scene.js': 'public/scene.js', '/models.js': 'public/models.js',
  '/net.js': 'public/net.js', '/style.css': 'public/style.css',
  '/shared/classes.mjs': 'shared/classes.mjs', '/shared/geometry.mjs': 'geometry.mjs',
  '/vendor/three.module.js': 'node_modules/three/build/three.module.js',
  '/vendor/three.core.js': 'node_modules/three/build/three.core.js',
  '/vendor/OrbitControls.js': 'node_modules/three/examples/jsm/controls/OrbitControls.js',
  '/vendor/RoundedBoxGeometry.js': 'node_modules/three/examples/jsm/geometries/RoundedBoxGeometry.js',
};
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css' };

const STARTED = Date.now();
/** True when a code file of the hub is newer than this process: the hub must be restarted to run it. */
function codeIsNewer() {
  try {
    const dirs = [root, resolve(root, 'shared')];
    return dirs.some(d => readdirSync(d).some(f => f.endsWith('.mjs') && statSync(resolve(d, f)).mtimeMs > STARTED + 1000));
  } catch { return false; }
}

/**
 * pushHz: how often connected dashboards receive the fused world (motion is predicted between phone frames).
 * record: a writable stream; every accepted frame is appended as one JSON line (camera pictures left out), so a real
 *         session can be replayed later (`npm run replay -- <file>`) for debugging or for a demo without phones.
 */
export function createHub({ token = randomBytes(16).toString('hex'), store = new RoomStore(), pushHz = 30, record = null, recordLimit = 60e6 } = {}) {
  const subscribers = new Set();
  let timer = null, recorded = 0;

  function push() {
    const cache = new Map();
    for (const sub of subscribers) {
      // Latest-state-wins: a slow client skips ticks instead of queueing stale ones (no lag build-up).
      if (sub.res.writableLength > 262144) continue;
      let msg = cache.get(sub.session);
      if (!msg) { const data = store.stream(sub.session); msg = { data, text: JSON.stringify(data) + '\n', live: data.devices.some(d => d.live) }; cache.set(sub.session, msg); }
      const idle = !msg.live && store.revision === sub.revision;
      if (idle && ++sub.idleTicks < pushHz) continue;                       // nothing live: 1 Hz heartbeat
      sub.idleTicks = 0; sub.revision = store.revision;
      for (const s of store.surfaces(sub.session)) {
        if (sub.planes.get(s.device) === s.rev) continue;
        sub.planes.set(s.device, s.rev);
        sub.res.write(JSON.stringify({ type: 'planes', ...s }) + '\n');
      }
      // The room perimeter travels only when it changes (5 cm resolution), never at 30 Hz.
      for (const r of store.rooms(sub.session)) {
        if (sub.rooms.get(r.space) === r.rev) continue;
        sub.rooms.set(r.space, r.rev);
        sub.res.write(JSON.stringify({ type: 'room', ...r }) + '\n');
      }
      sub.res.write(msg.text);
    }
  }
  function subscribe(res, session) {
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'X-Accel-Buffering': 'no' });
    res.socket?.setNoDelay(true);
    const sub = { res, session, planes: new Map(), rooms: new Map(), revision: -1, idleTicks: 0 };
    subscribers.add(sub);
    res.write(JSON.stringify({ type: 'hello', now: store.clock(), pushHz, stale: codeIsNewer(), features: ['room', 'scan'] }) + '\n');
    res.on('close', () => { subscribers.delete(sub); if (!subscribers.size && timer) { clearInterval(timer); timer = null; } });
    if (!timer) { timer = setInterval(push, Math.round(1000 / pushHz)); timer.unref?.(); }
    push();
  }

  const server = http.createServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'none'");
    const send = (code, data) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(data == null ? undefined : JSON.stringify(data)); };
    try {
      const url = new URL(req.url, 'http://localhost');
      if (url.pathname.startsWith('/api/')) {
        const supplied = Buffer.from(req.headers.authorization ?? '');
        const expected = Buffer.from(`Bearer ${token}`);
        if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return send(401, { error: 'Chiave server errata' });
        // Browser writes are same-origin only. Native clients do not send Origin.
        if (req.headers.origin && new URL(req.headers.origin).host !== req.headers.host) return send(403, { error: 'Origin denied' });
        const session = url.searchParams.get('session') ?? '1234';
        if (req.method === 'GET' && url.pathname === '/api/state') return send(200, store.snapshot(session));
        if (req.method === 'GET' && url.pathname === '/api/stream') return subscribe(res, session);
        if (req.method === 'GET' && url.pathname === '/api/preview') {
          const image = store.preview(session, url.searchParams.get('device') ?? '');
          if (!image) return send(404, { error: 'No preview' });
          res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Content-Length': image.length });
          return res.end(image);
        }
        if (req.method === 'POST' && url.pathname === '/api/frames') {
          let size = 0; const chunks = [];
          for await (const chunk of req) {
            size += chunk.length;
            if (size > 2_000_000) { send(413, { error: 'Frame too large' }); req.resume(); return; }
            chunks.push(chunk);
          }
          let frame;
          try { frame = JSON.parse(Buffer.concat(chunks).toString()); } catch { return send(400, { error: 'Invalid JSON' }); }
          const { code, reply } = store.accept(frame);
          if (record && (code === 200 || code === 204) && recorded < recordLimit) {
            const { jpeg, ...light } = frame, line = JSON.stringify({ at: Math.round(store.clock()), frame: light }) + '\n';
            recorded += line.length; record.write(line);
          }
          if (code === 200) return send(200, reply);
          return send(code, code === 204 ? null : { error: 'Invalid, stale frame or capacity exceeded' });
        }
        return send(404, { error: 'Not found' });
      }
      if (req.method !== 'GET') return send(405, { error: 'Method not allowed' });
      const file = STATIC[url.pathname];
      if (!file) return send(404, { error: 'Not found' });
      const body = await readFile(resolve(root, file));
      res.writeHead(200, { 'Content-Type': TYPES[extname(file)] });
      res.end(body);
    } catch (error) {
      if (!res.headersSent) send(500, { error: 'Server error' }); else res.end();
      console.error(error.message);
    }
  });
  server.requestTimeout = 10000; server.headersTimeout = 10000; server.keepAliveTimeout = 30000;
  server.on('connection', socket => socket.setNoDelay(true));
  server.on('close', () => { if (timer) clearInterval(timer); timer = null; });
  return { server, token, store };
}

export function lanAddresses() {
  const out = [];
  for (const list of Object.values(networkInterfaces())) for (const i of list ?? []) if (i.family === 'IPv4' && !i.internal) out.push(i.address);
  return out;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT ?? 8080);
  // The key is kept in .hub-token next to this file, so the phones type it once and not after every restart.
  // SHAREDSIGHT_TOKEN overrides it; deleting the file makes a new one.
  const tokenFile = fileURLToPath(new URL('./.hub-token', import.meta.url));
  let saved = null;
  try { saved = readFileSync(tokenFile, 'utf8').trim(); } catch {}
  if (!/^[0-9a-f]{32}$/.test(saved ?? '')) {
    saved = randomBytes(16).toString('hex');
    try { writeFileSync(tokenFile, saved + '\n', { mode: 0o600 }); } catch (error) { console.warn(`Chiave non salvata (${error.message}): cambierà al prossimo avvio.`); }
  }
  // Every session is recorded (no pictures, 60 MB at most per run, the 8 most recent runs are kept).
  let record = null, recordPath = null;
  if (process.env.SHAREDSIGHT_RECORD !== '0') {
    try {
      const dir = fileURLToPath(new URL('./recordings/', import.meta.url));
      mkdirSync(dir, { recursive: true });
      const old = readdirSync(dir).filter(f => f.endsWith('.ndjson')).sort();
      for (const f of old.slice(0, Math.max(0, old.length - 7))) { try { unlinkSync(resolve(dir, f)); } catch {} }
      recordPath = resolve(dir, `sessione-${new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)}.ndjson`);
      record = createWriteStream(recordPath, { flags: 'a' });
      record.on('error', () => { record = null; });
    } catch (error) { console.warn(`Registrazione non attiva (${error.message}).`); }
  }
  const { server, token } = createHub({ token: process.env.SHAREDSIGHT_TOKEN || saved, record });
  server.listen(port, process.env.HOST ?? '0.0.0.0', () => {
    console.log(`Shared Sight Hub\nDashboard: http://localhost:${port}/#token=${token}&session=1234\nChiave server: ${token}\nSessione predefinita: 1234`);
    for (const address of lanAddresses()) console.log(`URL per iPhone: http://${address}:${port}`);
    if (recordPath) console.log(`Registrazione della sessione (senza immagini): ${recordPath}`);
    console.log('Ctrl+C per arrestare. HTTP: usare una rete locale fidata.');
  });
}
