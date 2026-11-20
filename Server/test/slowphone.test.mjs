// A throttled phone (3 frames/s) that keeps seeing a person must keep her "observed" between its frames.
import test from 'node:test';
import assert from 'node:assert/strict';
import { RoomStore } from '../state.mjs';
import { createScenario } from '../sim/room.mjs';

test('a slow phone does not make what it sees blink to hidden between frames', () => {
  let now = 0; const store = new RoomStore(() => now), sc = createScenario({ phones: 1, seed: 3, noise: 0 });
  let blinks = 0, checks = 0, seen = [];
  for (let ms = 0; ms <= 6000; ms += 33) {
    now = ms;
    if (ms % 330 === 0) { const r = sc.frame(0, ms / 1000); seen = r.seen; sc.reply(0, store.accept(r.frame).reply); }
    store.tick();
    if (!seen.includes('anna')) continue;
    const person = store.spaces('DEMO')[0].entities.find(e => e.label === 'person' && e.state !== 'lost');
    if (!person) continue;
    checks++; if (person.state !== 'observed') blinks++;
  }
  assert.ok(checks > 20, `checked ${checks} ticks`);
  assert.ok(blinks / checks < 0.1, `observed while in view (${blinks} of ${checks} ticks were not)`);
});
