// End-to-end: the simulated phones post through the real HTTP server; time is injected so 90 s run in a moment.
import test from 'node:test';
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { RoomStore } from '../state.mjs';
import { createHub } from '../server.mjs';
import { createScenario } from '../sim/room.mjs';

async function run(phones, seconds, each = () => {}) {
  let now = 0; const store = new RoomStore(() => now), { server } = createHub({ token: 'k', store });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`, headers = { Authorization: 'Bearer k', 'Content-Type': 'application/json' };
  const scenario = createScenario({ phones }), events = [], log = [];
  let seq = 0;
  try {
    for (let i = 0; i < seconds * 15; i++) {
      const t = i / 15; now = Math.round(t * 1000);
      for (let p = 0; p < scenario.phones.length; p++) {
        const { frame, seen } = scenario.frame(p, t);
        const r = await fetch(base + '/api/frames', { method: 'POST', headers, body: JSON.stringify(frame) });
        assert.equal(r.status, 200);
        const reply = await r.json(); scenario.reply(p, reply);
        if (p === 0) log.push({ t, advisories: reply.advisories, seen });
      }
      for (const s of store.spaces('DEMO')) for (const e of s.events) if (e.seq > seq) { seq = e.seq; events.push({ ...e, at: t }); }
      each(t, store, scenario);
    }
  } finally { await new Promise(r => { server.close(r); server.closeAllConnections(); }); }
  return { store, scenario, events, log };
}

test('three phones: the person who walks behind the open door stays known to the user\'s phone through the hallway phone', async () => {
  const errors = [];
  const { events, log, store, scenario } = await run(3, 60, (t, store, scenario) => {
    // Fused position of every object somebody sees must stay close to the simulated truth.
    const truth = scenario.truth(t).filter(o => o.label === 'person');
    for (const e of store.spaces('DEMO')[0].entities) if (e.label === 'person' && e.state === 'observed')
      errors.push(Math.min(...truth.map(p => Math.hypot(p.x - e.x, p.z - e.z))));
  });
  const handoff = events.filter(e => e.type === 'handoff' && e.label === 'person' && e.from === 'iPhone utente' && e.to === 'iPhone corridoio');
  assert.ok(handoff.length >= 1, 'handoff user -> hallway happened');
  assert.ok(['wall', 'door'].includes(handoff[0].occluder));
  const told = log.flatMap(l => l.advisories.map(a => ({ ...a, t: l.t }))).filter(a => a.label === 'person' && a.kind === 'seen' && a.localID != null && a.relation === 'occluded');
  assert.ok(told.length > 30, `the user's phone was told about its own lost person for a sustained time (${told.length} replies)`);
  assert.ok(told.some(a => a.occluder === 'door'), 'at some point she is behind the open door');
  // While the user's phone itself sees the person, the hub never reports her as hidden from it.
  for (const l of log) for (const a of l.advisories) assert.ok(a.localID == null || !l.seen.includes('anna') || a.label !== 'person' || a.relation !== 'visible');
  errors.sort((a, b) => a - b);
  const p95 = errors[Math.floor(errors.length * 0.95)];
  assert.ok(errors.length > 500 && p95 < 0.6, `fused people within 0.6 m of truth 95 % of the time (p95 ${p95?.toFixed(2)} m over ${errors.length} samples)`);
  assert.ok(store.spaces('DEMO')[0].entities.filter(e => e.label === 'person' && e.state !== 'lost').length <= 3, 'no pile-up of duplicate people');
  assert.equal(scenario.phones.length, 3);
});

test('one phone: nobody else can help, so hidden movers are predicted, flagged as estimates, and dropped when too uncertain', async () => {
  const { events, log, store } = await run(1, 60);
  assert.equal(store.spaces('DEMO')[0].key, 'local:demo-user', 'a single unaligned phone has its own space');
  // Constant velocity only (P02): a mover that turned is not followed around the corner, so the person may be lost
  // instead of hidden; what must hold is that hidden movers exist and are flagged, never invented.
  assert.ok(events.some(e => e.type === 'hidden' && ['person', 'dog'].includes(e.label) && e.reason === 'occluded'), 'a mover hidden by wall, door or object');
  assert.ok(events.every(e => e.type !== 'handoff'), 'no handoff without a second phone');
  const estimates = log.flatMap(l => l.advisories).filter(a => a.kind === 'estimated');
  assert.ok(estimates.length > 10 && estimates.every(a => a.sigma > 0.1 && a.seenBy === 0));
  assert.ok(log.flatMap(l => l.advisories).every(a => a.kind !== 'seen'), 'nothing can be "seen by another phone"');
  assert.ok(events.some(e => e.type === 'lost' && ['uncertainty', 'age', 'barrierConflict'].includes(e.reason)), 'estimates are abandoned, not kept forever');
  assert.ok(events.some(e => e.type === 'reacquired'), 'and picked up again when the object reappears');
});

test('latency budget: accepting a frame and building the push message stay far below one frame time', () => {
  let now = 0; const store = new RoomStore(() => now), scenario = createScenario({ phones: 3 });
  const frames = [];
  for (let i = 0; i < 900; i++) for (let p = 0; p < 3; p++) frames.push([Math.round(i / 15 * 1000), p, scenario.frame(p, i / 15).frame]);
  const samples = []; let bytes = 0, pushes = 0;
  for (const [t, p, f] of frames) {
    now = t; const a = performance.now(); const { code } = store.accept(f); samples.push(performance.now() - a); assert.equal(code, 200);
    if (f.deviceID === 'demo-user') { const s = performance.now(); bytes += JSON.stringify(store.stream('DEMO')).length; samples.push(performance.now() - s); pushes++; }
  }
  samples.sort((a, b) => a - b);
  const p99 = samples[Math.floor(samples.length * 0.99)], mean = samples.reduce((a, b) => a + b, 0) / samples.length;
  console.log(`      accept/push: mean ${mean.toFixed(3)} ms, p99 ${p99.toFixed(3)} ms; push message ${(bytes / pushes / 1024).toFixed(1)} KB`);
  assert.ok(p99 < 8, `p99 ${p99} ms`);
  assert.ok(bytes / pushes < 12000, 'push message stays small enough for 30 Hz');
});
