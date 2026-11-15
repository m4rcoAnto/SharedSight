// Records what the simulated user's iPhone lives through, for the "listen only" test of the iOS decision and speech
// code (SharedSightCore/Tests/.../BlindWalkTests.swift): its own detections, the hub's replies, and the simulated
// truth to judge them against. SYNTHETIC data, produced by the same scenario as `npm run demo`.
//
//   node sim/record.mjs            writes walk-1.json and walk-3.json into the Swift test fixtures folder
import { writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { RoomStore } from '../state.mjs';
import { createScenario } from './room.mjs';
import { wallFromPlane } from '../geometry.mjs';

const r3 = n => Math.round(n * 1000) / 1000;

export function record({ phones, seconds = 75, rate = 10, seed = 7 }) {
  let now = 0;
  const store = new RoomStore(() => now), scenario = createScenario({ phones, seed });
  const walls = scenario.phones[0].planes.map(wallFromPlane).filter(Boolean)
    .map(w => ({ ax: r3(w.ax), az: r3(w.az), bx: r3(w.bx), bz: r3(w.bz), y0: r3(w.y0), y1: r3(w.y1), kind: w.kind }));
  const frames = [];
  for (let i = 0; i < seconds * rate; i++) {
    const t = i / rate; now = Math.round(t * 1000);
    const results = scenario.phones.map((_, p) => { const f = scenario.frame(p, t); const reply = store.accept(f.frame).reply; scenario.reply(p, reply); return { ...f, reply }; });
    const user = results[0], others = new Set(results.slice(1).flatMap(r => r.seen));
    frames.push({
      t: r3(t), m: user.frame.camera.m.map(r3), fov: user.frame.fov,
      objects: user.frame.objects.map(o => ({ id: o.id, label: o.label, c: o.confidence, box: [r3(o.box.x), r3(o.box.y), r3(o.box.w), r3(o.box.h)],
        ...(o.position ? { p: [r3(o.position.x), r3(o.position.y), r3(o.position.z)], s: r3(o.sigma) } : {}) })),
      advisories: user.reply.advisories.map(a => ({ id: a.id, kind: a.kind, label: a.label, position: a.position, sigma: a.sigma, relation: a.relation,
        occluder: a.occluder, seenBy: a.seenBy, localID: a.localID, moving: a.moving, ageMs: a.ageMs, ageUncertaintyMs: a.ageUncertaintyMs,
        velocity: a.velocity, velocitySigma: a.velocitySigma })),
      truth: scenario.truth(t).filter(o => o.moving !== undefined && (o.label === 'person' || o.label === 'dog'))
        .map(o => ({ key: o.key, label: o.label, x: r3(o.x), z: r3(o.z), user: user.seen.includes(o.key), other: others.has(o.key) })),
    });
  }
  return { synthetic: true, phones, rate, seed, walls, frames };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const dir = fileURLToPath(new URL('../../SharedSightCore/Tests/SharedSightCoreTests/Fixtures/', import.meta.url));
  await mkdir(dir, { recursive: true });
  for (const phones of [1, 3]) {
    const text = JSON.stringify(record({ phones }));
    await writeFile(`${dir}walk-${phones}.json`, text);
    console.log(`walk-${phones}.json  ${(text.length / 1024).toFixed(0)} KB`);
  }
}
