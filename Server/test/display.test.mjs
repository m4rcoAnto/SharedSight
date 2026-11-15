// Dashboard-facing additions: confidence of estimates, frozen size, doorways opened by measured crossings, pairing.
// SYNTHETIC geometry and motion.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Perimeter } from '../perimeter.mjs';
import { WorldModel } from '../world.mjs';
import { createHub, lanAddresses } from '../server.mjs';
import { poseFromYaw } from '../geometry.mjs';

const DEG = Math.PI / 180;
const plane = (id, ax, az, bx, bz, kind = 'wall', y0 = 0, y1 = 2.6) => ({ id, vertical: true, kind,
  vertices: [{ x: ax, y: y0, z: az }, { x: bx, y: y0, z: bz }, { x: bx, y: y1, z: bz }, { x: ax, y: y1, z: az }], triangles: [0, 1, 2, 0, 2, 3] });
const phone = (name, x, z, yawDeg) => ({ name, pose: poseFromYaw(x, 1.4, z, yawDeg * DEG), fov: 60, tracking: true });
const obs = (id, x, z, extra = {}) => ({ id, label: 'person', confidence: 0.9, box: { x: 0.4, y: 0.2, w: 0.2, h: 0.6 }, position: { x, y: 0, z }, sigma: 0.15, ...extra });
const person = w => w.snapshot().find(e => e.label === 'person');
const parts = room => (room.rooms ?? [room]).flatMap(r => [...r.sides, ...r.interior]);

test('confidence is 1 while observed and strictly decreases once hidden; the drawn size does not shrink', () => {
  const w = new WorldModel();
  w.setPlanes('A', [plane('screen', 1.5, -1, 3.5, -1)]);
  const A = phone('A', 2.5, 3, 0);
  let t = 0, i = 0;
  // Walking at 1 m/s toward the wall; in the last second the detector measures her smaller and smaller (half covered).
  for (let x = -1.5; x < 1.2; x += 0.066, t += 66, i++) {
    const k = x < 0.2 ? 1 : 1 - (x - 0.2) * 0.45;
    w.observe('A', A, [obs(1, x, -2, { size: { w: 0.5 * k, h: 1.7 * k } })], t);
    assert.equal(person(w).conf, 1, 'observed: full confidence');
  }
  const seen = person(w), internal = [...w.entities.values()][0];
  assert.ok(internal.h < seen.h - 0.05, `the measured size shrank (${internal.h.toFixed(2)}) but the drawn one held (${seen.h})`);
  const confs = [], heights = [], widths = [];
  for (let n = 0; n < 60; n++, t += 66) {
    w.observe('A', A, [], t);
    const p = person(w);
    if (p?.state === 'observed' && !confs.length) continue;      // still within the short "seen now" hold
    if (!p || p.state !== 'hidden') break;
    confs.push(p.conf); heights.push(p.h); widths.push(p.w);
  }
  assert.ok(confs.length >= 15, `stayed hidden for a while (${confs.length} ticks)`);
  assert.ok(confs[0] < 1 && confs[0] > 0.8, `starts just below 1 (${confs[0]})`);
  for (let n = 1; n < confs.length; n++) assert.ok(confs[n] < confs[n - 1], `conf strictly decreases: ${confs[n - 1]} -> ${confs[n]} at ${n}`);
  assert.ok(confs.every(c => c >= 0 && c <= 1));
  assert.ok(heights.every(h => h === seen.h) && widths.every(v => v === seen.w), 'size frozen while hidden');
  // Left alone, the estimate ends at (about) zero confidence: lost, then removed.
  let last = null;
  for (let n = 0; n < 200 && person(w); n++, t += 66) { w.step(t); last = person(w) ?? last; }
  assert.ok(last == null || last.conf <= 0.05, `confidence near zero when dropped (${last?.conf})`);
});

test('a person measured walking across a wall line opens a doorway there; standing next to a wall does not', () => {
  // Perimeter alone: north wall z = -2 measured for x in [-2, 0], continued ('extended') to the east corner at x = 2.
  const p = new Perimeter();
  p.ingest('A', [plane('n', -2, -2, 0, -2), plane('e', 2, -1.5, 2, 1.5), plane('d', 2, 1.5, 2, 2.3, 'door', 0, 2.05)]);
  p.addPoint(0, 0); p.addPoint(0, 1.5); p.update();
  const kinds = () => parts(p.update()).filter(s => Math.abs(s.az + 2) < 0.1 && Math.abs(s.bz + 2) < 0.1);
  assert.ok(kinds().some(s => s.kind === 'extended') && !parts(p.room).some(s => s.kind === 'opening'));
  assert.equal(p.addCrossing(1, -1.9, 1, -2.1), false, 'noise next to the wall line is not a passage');
  assert.equal(p.addCrossing(-0.5, -1.8, -0.5, -2.2), false, 'nor is it across a measured wall');
  assert.equal(p.addCrossing(1, -1.5, 1.1, -2.5), true, 'clearly from one side to the other');
  const open = kinds().find(s => s.kind === 'opening');
  assert.ok(open && Math.abs((open.ax + open.bx) / 2 - 1.05) < 0.15, `opening at the crossing point (${JSON.stringify(open)})`);
  assert.ok(Math.abs(Math.hypot(open.bx - open.ax, open.bz - open.az) - 0.9) < 0.11, 'one doorway wide');
  // A measured wall and a door are obstacles until someone is measured going through them.
  assert.ok(p.measuredWalls().some(w => w.kind === 'door'));
  assert.equal(p.addCrossing(1.5, 1.9, 2.5, 1.9), true);
  p.update();
  assert.ok(parts(p.room).some(s => s.kind === 'opening' && Math.abs(s.ax - 2) < 0.1 && Math.abs(s.bx - 2) < 0.1), 'the door part became an opening');
  assert.equal(p.addCrossing(-0.5, -1.5, -0.5, -2.5), true);
  p.update();
  assert.ok(parts(p.room).some(s => s.kind === 'opening' && Math.abs(s.az + 2) < 0.1 && Math.abs((s.ax + s.bx) / 2 + 0.5) < 0.15), 'and so does a measured wall');
  assert.ok(!p.measuredWalls().some(w => w.kind === 'door'), 'an opening no longer blocks sight');
});

test('world model: successive measurements of a walker crossing a continued wall produce an opening at the crossing point', () => {
  const w = new WorldModel();
  w.setPlanes('A', [plane('n', -2, -2, 0, -2), plane('e', 2, -1.5, 2, 1.5)]);
  // The phone stands outside the mapped room's reach of sight() (not aligned with the wall), looking at the walker.
  const A = phone('A', 0, 1, 20);
  w.observe('A', A, [], 0);
  assert.ok(parts(w.perimeter.room).some(s => s.kind === 'extended'));
  let t = 66;
  for (let z = -1.2; z > -1.95; z -= 0.066, t += 66) w.observe('A', A, [obs(1, 1, z)], t);
  assert.ok(!parts(w.perimeter.room).some(s => s.kind === 'opening'), 'no opening before she reaches the wall line');
  w.perimeter.passes.length = 0;
  for (let z = -1.95; z > -2.24; z -= 0.066, t += 66) w.observe('A', A, [obs(1, 1, z)], t);
  const open = parts(w.perimeter.room).find(s => s.kind === 'opening');
  assert.ok(open, 'opening recorded while she is still within 0.3 m of the line (before the see-through rule applies)');
  assert.ok(Math.abs((open.ax + open.bx) / 2 - 1) < 0.15 && Math.abs(open.az + 2) < 0.1, JSON.stringify(open));
  for (let z = -2.24; z > -3.2; z -= 0.066, t += 66) w.observe('A', A, [obs(1, 1, z)], t);
  const p = person(w);
  assert.equal(p.state, 'observed'); assert.ok(Math.abs(p.z + 3.2) < 0.3);
  // Whatever the room became once she was seen beyond it, nothing solid is left across the path she walked.
  const crosses = s => (s.az + 2) * (s.bz + 2) <= 0.01 && Math.min(s.ax, s.bx) < 1 && Math.max(s.ax, s.bx) > 1 && Math.abs(s.az - s.bz) < 0.1;
  assert.ok(!parts(w.perimeter.room).some(s => ['wall', 'door', 'extended'].includes(s.kind) && crosses(s)), JSON.stringify(parts(w.perimeter.room)));
  assert.ok(w.perimeter.passes.length <= 2, 'one doorway, not a row of them');
});

test('pairing: hello and GET /api/pair carry the LAN addresses and port; the QR library is served; no key, no data', async t => {
  const { server } = createHub({ token: 'test-secret' }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise(r => { server.close(r); server.closeAllConnections(); }));
  const port = server.address().port, base = `http://127.0.0.1:${port}`, headers = { Authorization: 'Bearer test-secret' };
  assert.equal((await fetch(base + '/api/pair')).status, 401);
  const pair = await (await fetch(base + '/api/pair?session=abc', { headers })).json();
  assert.deepEqual(pair, { addresses: lanAddresses(), port, session: 'abc' });
  assert.ok(pair.addresses.every(a => /^\d+\.\d+\.\d+\.\d+$/.test(a)));
  const controller = new AbortController(), stream = await fetch(base + '/api/stream?session=abc', { headers, signal: controller.signal });
  const reader = stream.body.getReader(), decoder = new TextDecoder(); let text = '';
  while (!text.includes('\n')) text += decoder.decode((await reader.read()).value, { stream: true });
  controller.abort();
  const hello = JSON.parse(text.split('\n')[0]);
  assert.equal(hello.type, 'hello'); assert.deepEqual(hello.pair, { addresses: lanAddresses(), port }); assert.ok(hello.features.includes('pair'));
  const lib = await fetch(base + '/vendor/qrcode.mjs');
  assert.equal(lib.status, 200); assert.equal(lib.headers.get('content-type'), 'text/javascript');
  // The payload the dashboard encodes (same construction as public/app.js) fits a QR code and round-trips.
  const { default: qrcode } = await import('qrcode-generator');
  const payload = `sharedsight://hub?url=${encodeURIComponent(`http://192.168.1.23:${port}`)}&token=${encodeURIComponent('0123456789abcdef0123456789abcdef')}&session=${encodeURIComponent('1234')}`;
  const qr = qrcode(0, 'M'); qr.addData(payload); qr.make();
  assert.ok(qr.getModuleCount() >= 21);
  const u = new URL(payload);
  assert.equal(u.searchParams.get('url'), `http://192.168.1.23:${port}`); assert.equal(u.searchParams.get('token').length, 32);
});
