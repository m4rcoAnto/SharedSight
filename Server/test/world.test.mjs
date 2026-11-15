import test from 'node:test';
import assert from 'node:assert/strict';
import { WorldModel } from '../world.mjs';
import { poseFromYaw, cameraFromPose, sightRelation, wallFromPlane, visibilityFan, moveWithWalls, segmentHit } from '../geometry.mjs';
import { compatible, classInfo, CLASSES } from '../shared/classes.mjs';

const DEG = Math.PI / 180;
const wallPlane = (id, ax, az, bx, bz, kind = 'wall', y0 = 0, y1 = 2.7) => ({ id, vertical: true, kind,
  vertices: [{ x: ax, y: y0, z: az }, { x: bx, y: y0, z: bz }, { x: bx, y: y1, z: bz }, { x: ax, y: y1, z: az }], triangles: [0, 1, 2, 0, 2, 3] });
const phone = (name, x, z, yawDeg, y = 1.4) => ({ name, pose: poseFromYaw(x, y, z, yawDeg * DEG), fov: 60, tracking: true });
const obs = (id, label, x, z, extra = {}) => ({ id, label, confidence: 0.9, box: { x: 0.4, y: 0.2, w: 0.2, h: 0.6 }, position: { x, y: 0, z }, sigma: 0.15, ...extra });
const entity = (w, label = 'person') => w.snapshot().filter(e => e.label === label);

test('geometry: yaw convention, wall footprint, line of sight through wall / window / over low furniture', () => {
  const cam = cameraFromPose(poseFromYaw(0, 1.4, 0, 90 * DEG));
  assert.ok(Math.abs(cam.fx - 1) < 1e-9 && Math.abs(cam.fz) < 1e-9, 'yaw +90° looks along +X');
  const wall = wallFromPlane(wallPlane('w', 2, -1, 2, 1));
  assert.deepEqual([wall.ax, wall.bx, wall.y0, wall.y1], [2, 2, 0, 2.7]);
  assert.equal(wallFromPlane({ id: 'f', vertical: false, vertices: [], triangles: [] }), null);
  const person = { id: 'p', x: 4, z: 0, y: 0, h: 1.7, r: 0.25 };
  assert.equal(sightRelation(cam, 60, 10, person, []).relation, 'visible');
  assert.deepEqual(sightRelation(cam, 60, 10, person, [wall]).occluder, { kind: 'wall', id: 'w' });
  assert.equal(sightRelation(cam, 60, 10, person, [wallFromPlane(wallPlane('g', 2, -1, 2, 1, 'window'))]).relation, 'visible');
  assert.equal(sightRelation(cam, 60, 10, person, [wallFromPlane(wallPlane('d', 2, -1, 2, 1, 'door', 0, 2.05))]).occluder.kind, 'door');
  assert.equal(sightRelation(cam, 60, 10, { ...person, z: 4 }, []).relation, 'outOfView');
  assert.equal(sightRelation(cam, 60, 3, person, []).relation, 'outOfRange');
  // A couch hides a dog behind it but only the legs of a standing person.
  const couch = { id: 'c', label: 'couch', x: 2.5, z: 0, y: 0, h: 0.82, r: 0.8 };
  assert.equal(sightRelation(cam, 60, 10, { id: 'dog', x: 3.6, z: 0, y: 0, h: 0.55, r: 0.2 }, [], [couch]).relation, 'occluded');
  assert.notEqual(sightRelation(cam, 60, 10, person, [], [couch]).relation, 'occluded');
  // A phone pointing at the ceiling has no floor heading: nothing is claimed.
  const up = cameraFromPose([1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1.4, 0, 1]);
  assert.equal(sightRelation(up, 60, 10, person, []).relation, 'unknown');
});

test('geometry: coverage fan stops at walls; a walker cannot cross a wall but passes under a lintel', () => {
  const cam = cameraFromPose(poseFromYaw(0, 1.4, 0, 90 * DEG)), wall = wallFromPlane(wallPlane('w', 2, -5, 2, 5));
  const fan = visibilityFan(cam, 60, 9, [wall], [], 16);
  for (let i = 2; i < fan.length; i += 2) assert.ok(fan[i] <= 2.0001, 'no ray passes the wall');
  assert.ok(Math.max(...visibilityFan(cam, 60, 9, [], [], 16).filter((_, i) => i % 2 === 0)) > 8.5);
  assert.ok(moveWithWalls(1, 0, 2, 0, [wall]).x < 2);
  assert.equal(moveWithWalls(1, 0, 2, 0, [wallFromPlane(wallPlane('lintel', 2, -1, 2, 1, 'wall', 2.1, 2.7))]).x, 3);
  assert.equal(segmentHit(0, 0, 1, 0, 2, -1, 2, 1), null);
});

test('classes: every COCO label has metadata; confusable sets are symmetric and conservative', () => {
  assert.equal(Object.keys(CLASSES).length, 80);
  assert.ok(classInfo('person').dyn && !classInfo('couch').dyn && classInfo('unknown thing').g === 'prop');
  assert.ok(compatible('couch', 'chair') && compatible('chair', 'couch') && !compatible('person', 'dog') && !compatible('person', 'couch'));
});

test('fusion: two phones measuring one person give one object, attributed to both', () => {
  const w = new WorldModel();
  for (let i = 0; i < 30; i++) {
    const t = i * 66, x = 1 + i * 0.066;                    // walking 1 m/s along +X
    w.observe('A', phone('A', -3, 0, 90), [obs(1, 'person', x + 0.05, 0.04)], t);
    w.observe('B', phone('B', 3, 4, 200), [obs(7, 'person', x - 0.06, -0.05)], t + 10);
  }
  const people = entity(w);
  assert.equal(people.length, 1);
  assert.deepEqual(people[0].seenBy.sort(), ['A', 'B']);
  assert.ok(Math.abs(people[0].x - 2.92) < 0.25, `fused x ${people[0].x}`);
  assert.ok(Math.abs(people[0].vx - 1) < 0.3, `velocity ${people[0].vx}`);
  assert.equal(people[0].state, 'observed');
  assert.ok(people[0].path?.length >= 2, 'a moving object carries a short forecast');
});

test('two people one metre apart stay two objects; one phone seeing both prevents a merge', () => {
  const w = new WorldModel();
  for (let i = 0; i < 20; i++) w.observe('A', phone('A', -3, 0, 90), [obs(1, 'person', 1, 0.5), obs(2, 'person', 1, -0.5)], i * 66);
  assert.equal(entity(w).length, 2);
});

test("one phone's shadow is another phone's light: hidden behind a wall for A, seen by B, A is told", () => {
  const w = new WorldModel();
  w.setPlanes('A', [wallPlane('partition', 2, -3, 2, 0.3), wallPlane('leaf', 2.02, 0.3, 2.9, 0.3, 'door', 0, 2.05)]);
  const A = phone('A', -2, 1, 90), B = phone('B', 3.6, -3, 180);          // B is in the far room, looking toward +Z
  // The person walks through the doorway (x = 2, z > 0.3) and turns behind the open door.
  const route = t => t < 2 ? { x: 0.6 + t, z: 0.8 } : t < 3 ? { x: 2.6 + (t - 2) * 0.8, z: 0.8 - (t - 2) * 0.2 } : { x: 3.4, z: Math.max(0.6 - (t - 3) * 0.8, -0.6) };
  let t = 0, sawNothingToTell = true;
  for (; t < 6000; t += 66) {
    const p = route(t / 1000);
    const forA = sightRelation(cameraFromPose(A.pose), 60, 10, { id: 'p', x: p.x, z: p.z, y: 0, h: 1.7, r: 0.25 }, w.walls).relation;
    const forB = sightRelation(cameraFromPose(B.pose), 60, 10, { id: 'p', x: p.x, z: p.z, y: 0, h: 1.7, r: 0.25 }, w.walls).relation;
    w.observe('A', A, forA === 'visible' ? [obs(4, 'person', p.x, p.z)] : [], t);
    w.observe('B', B, forB === 'visible' ? [obs(9, 'person', p.x, p.z)] : [], t + 5);
    if (forA === 'visible' && w.advisoriesFor('A').length) sawNothingToTell = false;
  }
  assert.ok(sawNothingToTell, 'nothing to tell while A sees the person itself');
  const person = entity(w);
  assert.equal(person.length, 1, 'still one person: B continued the object A lost');
  assert.equal(person[0].state, 'observed'); assert.deepEqual(person[0].seenBy, ['B']);
  const [a] = w.advisoriesFor('A');
  assert.equal(a.kind, 'seen'); assert.equal(a.relation, 'occluded'); assert.ok(['wall', 'door'].includes(a.occluder), a.occluder);
  assert.equal(a.localID, 4, 'A is told this is the person it was following');
  assert.equal(a.seenBy, 1); assert.ok(Math.hypot(a.position.x - 3.4, a.position.z + 0.6) < 0.35);
  assert.ok(w.events.some(e => e.type === 'handoff' && e.from === 'A' && e.to === 'B'), 'handoff is logged');
  assert.equal(w.advisoriesFor('B').length, 0);
});

test('single phone: an object that walks behind a wall follows a predicted path with growing uncertainty, then is declared lost', () => {
  const w = new WorldModel();
  w.setPlanes('A', [wallPlane('screen', 1.5, -1, 3.5, -1)]);             // a wall parallel to the walking direction, between phone and path
  const A = phone('A', 2.5, 3, 0);                                        // looks along -Z toward the wall
  let t = 0;
  for (let x = -1.5; x < 1.2; x += 0.066, t += 66) w.observe('A', A, [obs(1, 'person', x, -2)], t);   // visible left of the wall, 1 m/s
  const before = entity(w)[0];
  assert.equal(before.state, 'observed'); assert.ok(before.vx > 0.7);
  const sigmas = [];
  for (let i = 0; i < 20; i++, t += 66) { w.observe('A', A, [], t); sigmas.push(entity(w)[0]?.sigma); }
  const hidden = entity(w)[0];
  assert.equal(hidden.state, 'hidden'); assert.equal(hidden.reason, 'occluded'); assert.equal(hidden.occluder, 'wall');
  assert.ok(hidden.x > before.x + 0.6, `kept moving behind the wall: ${before.x} -> ${hidden.x}`);
  assert.ok(sigmas.at(-1) > sigmas[3] && sigmas[3] > before.sigma, 'uncertainty grows while unobserved');
  const [a] = w.advisoriesFor('A');
  assert.equal(a.kind, 'estimated'); assert.equal(a.localID, 1); assert.ok(a.sigma > 0.3);
  // Reappears past the end of the wall, where the phone can actually see it again (x 3.9: the line of sight clears the
  // wall end at 3.5): same object. Reappearing still behind the wall would be a reflection and is rejected.
  const id = hidden.id;
  w.observe('A', A, [obs(2, 'person', 3.9, -2)], t);
  assert.equal(entity(w)[0].id, id); assert.equal(entity(w)[0].state, 'observed');
  // Hidden for too long: no position is claimed any more.
  for (let i = 0; i < 160 && entity(w).some(e => e.state !== 'lost'); i++, t += 66) w.observe('A', A, [], t);
  assert.ok(entity(w).every(e => e.state === 'lost') || entity(w).length === 0);
  assert.ok(w.events.some(e => e.type === 'lost'));
  assert.equal(w.advisoriesFor('A').length, 0, 'a lost estimate is never advertised');
});

test('evidence of absence: a prediction in plain view that is not detected is dropped, not shown', () => {
  const w = new WorldModel();
  const A = phone('A', 0, 4, 0);
  let t = 0;
  for (let i = 0; i < 15; i++, t += 66) w.observe('A', A, [obs(1, 'person', 0.2, 0)], t);   // standing in the middle of the view
  for (let i = 0; i < 8; i++, t += 66) w.observe('A', A, [], t);        // short detector dropout: tolerated
  assert.equal(entity(w)[0].state, 'hidden'); assert.equal(entity(w)[0].reason, 'unconfirmed');
  assert.equal(w.advisoriesFor('A').length, 0);
  for (let i = 0; i < 16; i++, t += 66) w.observe('A', A, [], t);
  assert.ok(entity(w).every(e => e.state === 'lost'), 'gone after the grace period');
});

test('absence never invents a turn behind a corner', () => {
  const w = new WorldModel();
  w.setPlanes('A', [wallPlane('corner', 1, -3, 1, 0)]);                 // wall along Z ending at z = 0; A looks along +X past its end
  const A = phone('A', -3, 1.2, 90);
  let t = 0;
  for (let x = -1; x < 1.5; x += 0.066, t += 66) w.observe('A', A, [obs(1, 'person', x, 0.5)], t);   // walks past the corner...
  for (let i = 0; i < 12; i++, t += 66) w.observe('A', A, [], t);        // ...and turns behind the wall, unseen
  const p = entity(w)[0];
  assert.equal(p.state, 'hidden'); assert.equal(p.reason, 'unconfirmed');
  assert.ok(Math.abs(p.z - 0.5) < 0.2, 'the centre of its cloud stays on its line');
  assert.deepEqual(w.advisoriesFor('A'), []);
  const rel = sightRelation(cameraFromPose(A.pose), 60, 10, { id: 'x', x: p.x, z: p.z, y: 0, h: 1.7, r: 0.25 }, w.walls).relation;
  assert.equal(rel, 'visible', 'the model keeps its trajectory; it does not move it into a hiding place');
});

test('a hidden estimate never passes through a measured wall', () => {
  const w = new WorldModel();
  w.setPlanes('A', [wallPlane('end', 3, -4, 3, 4), wallPlane('screen', 0.5, 1, 6, 1)]);
  const A = phone('A', 1, 3, 0);
  let t = 0;
  for (let x = -1; x < 0.4; x += 0.1, t += 66) w.observe('A', A, [obs(1, 'person', x, -1)], t);   // 1.5 m/s toward the end wall
  for (let i = 0; i < 60; i++, t += 66) w.observe('A', A, [], t);
  for (const e of entity(w)) assert.ok(e.x < 3, `estimate stayed on this side of the wall (${e.x})`);
});

test('furniture out of view is remembered where it was; furniture that is gone from plain view is removed', () => {
  const w = new WorldModel();
  let t = 0;
  for (let i = 0; i < 10; i++, t += 66) w.observe('A', phone('A', 0, 4, 0), [obs(1, 'couch', 0, 0)], t);
  for (let i = 0; i < 100; i++, t += 66) w.observe('A', phone('A', 0, 4, 180), [], t);      // turned away
  const couch = entity(w, 'couch')[0];
  assert.equal(couch.state, 'remembered'); assert.equal(couch.reason, 'outOfView'); assert.ok(Math.abs(couch.x) < 0.05 && Math.abs(couch.vx) < 1e-6);
  for (let i = 0; i < 80; i++, t += 66) w.observe('A', phone('A', 0, 4, 0), [], t);         // looks again: it is not there
  assert.equal(entity(w, 'couch').length, 0);
});

test('bearing-only detections do not renew the last metric measurement', () => {
  const w = new WorldModel();
  const A = phone('A', 0, 3, 0);
  let t = 0;
  for (let i = 0; i < 10; i++, t += 66) w.observe('A', A, [obs(1, 'person', 0.3, 0.5)], t);
  const lastMeasurement = [...w.entities.values()][0].lastObs;
  const flat = { id: 1, label: 'person', confidence: 0.9, box: { x: 0.52, y: 0.05, w: 0.3, h: 0.95 } };       // no position
  for (let i = 0; i < 40; i++, t += 66) w.observe('A', A, [flat], t);
  const p = entity(w)[0];
  assert.notEqual(p?.state, 'observed');
  for (const e of w.entities.values()) assert.equal(e.lastObs, lastMeasurement);
});

test('stale phone: its objects stop being "observed", and an unaligned restart forgets old bindings', () => {
  const w = new WorldModel();
  w.observe('A', phone('A', 0, 4, 0), [obs(1, 'person', 0, 0)], 0);
  w.step(5000);
  assert.notEqual(entity(w)[0]?.state, 'observed');
  assert.deepEqual(w.advisoriesFor('A', 5000), []);
  w.resetBindings('A'); assert.equal(w.bindings.size, 0);
});

// The car under the bridge. SYNTHETIC: a wall 1.5 m wide between the phone and the road hides 3 m of it.
function bridge() {
  const w = new WorldModel();
  w.setPlanes('A', [wallPlane('pier', -0.75, -3, 0.75, -3)]);
  const A = { ...phone('A', 0, 0, 0), fov: 100 };
  let t = 0, x = -7;
  for (; x < -2.6; x += 6 / 15, t += 1000 / 15) w.observe('A', A, [obs(1, 'car', x, -6)], t);     // 6 m/s along +X, in view
  return { w, A, t, x };
}

test('bridge: a mover that goes behind something gets the place and time where it should come out, and keeps its identity', () => {
  let { w, A, t } = bridge();
  const id = entity(w, 'car')[0].id;
  let exit = null;
  for (let i = 0; i < 9; i++, t += 1000 / 15) { w.observe("A", A, [], t); exit = entity(w, "car")[0].exit ?? exit; }
  const hidden = entity(w, 'car')[0];
  assert.equal(hidden.state, 'hidden'); assert.equal(hidden.reason, 'occluded'); assert.equal(hidden.occluder, 'wall');
  assert.ok(exit, 'an exit is expected');
  assert.ok(exit.x > 1.5 && exit.x < 3.2 && Math.abs(exit.z + 6) < 0.3, `on the far side of the pier (x ${exit.x})`);
  assert.ok(exit.inMs > 0 && exit.inMs < 1200 && exit.halfMs >= 300, `soon, with a window (${exit.inMs} ± ${exit.halfMs} ms)`);
  const [told] = w.advisoriesFor('A');
  assert.equal(told.kind, 'estimated'); assert.ok(told.exit, 'the phone is told where to expect it');
  // It comes out where expected: same object, measured again, no exit pending.
  for (let x = 2.6; x < 4.5; x += 6 / 15, t += 1000 / 15) w.observe('A', A, [obs(2, 'car', x, -6)], t);
  const again = entity(w, 'car');
  assert.equal(again.length, 1); assert.equal(again[0].id, id); assert.equal(again[0].state, 'observed'); assert.equal(again[0].exit, undefined);
});

test('bridge: if it does not come out where expected, the estimate is abandoned as "missed exit", never as "all clear"', () => {
  let { w, A, t } = bridge();
  for (let i = 0; i < 60 && entity(w, 'car').some(e => e.state !== 'lost'); i++, t += 1000 / 15) w.observe('A', A, [], t);
  const lost = w.events.filter(e => e.type === 'lost' && e.label === 'car');
  assert.equal(lost.length, 1); assert.equal(lost[0].reason, 'missedExit');
  assert.equal(w.advisoriesFor('A').length, 0, 'no position is claimed any more');
});

// A person walks behind a wall 2 m wide while the phone keeps looking. SYNTHETIC.
function behindWall() {
  const w = new WorldModel();
  w.setPlanes('A', [wallPlane('screen', -1, -2, 1, -2)]);                 // the obstacle, 2 m wide, between phone and path
  const A = { ...phone('A', 0, 2, 0), fov: 90 };                          // looks along -Z
  let t = 0;
  for (let x = -3; x < -1.2; x += 1 / 15, t += 1000 / 15) w.observe('A', A, [obs(1, 'person', x, -3.5)], t);   // 1 m/s along +X
  return { w, A, t };
}
const behind = (w, p) => sightRelation(cameraFromPose(phone('A', 0, 2, 0).pose), 90, 10, { id: 'q', x: p.x, z: p.z, y: 0, h: 1.7, r: 0.15 }, w.walls).relation !== 'visible';

test('person behind an obstacle: a cloud of possible positions stays behind it and spreads with time', () => {
  let { w, A, t } = behindWall();
  const id = entity(w)[0].id;
  let s1 = null;
  for (let i = 0; i < 30; i++, t += 1000 / 15) { w.observe('A', A, [], t); if (i === 10) s1 = entity(w)[0].sigma; }   // 2 s hidden
  const p = entity(w)[0];
  assert.equal(p.state, 'hidden');
  assert.ok(p.cloud && p.cloud.length > 10, 'a cloud of possible positions is published');
  assert.ok(behind(w, p), `its centre is behind the obstacle (${p.x}, ${p.z})`);
  const visibleShare = p.cloud.filter(([x, z]) => !behind(w, { x, z })).length / p.cloud.length;
  assert.ok(visibleShare < 0.2, `places in plain view were ruled out (${(visibleShare * 100).toFixed(0)}% left)`);
  assert.ok(p.sigma > s1, 'the spread grows with time');
  assert.ok(p.x > -1.2 && p.x < 1.2, `moved on at about its speed (x ${p.x})`);
  // It comes out on the other side: same person.
  for (let x = 1.3; x < 2; x += 1 / 15, t += 1000 / 15) w.observe('A', A, [obs(2, 'person', x, -3.5)], t);
  const again = entity(w);
  assert.equal(again.length, 1); assert.equal(again[0].id, id); assert.equal(again[0].state, 'observed');
});

test('person who stops behind the obstacle stays estimated there; seen nowhere at all, the estimate ends as "not there"', () => {
  let { w, A, t } = behindWall();
  for (let x = -1.2; x < 0; x += 1 / 15, t += 1000 / 15) w.observe('A', A, [], t);   // walks behind it (unseen)...
  for (let i = 0; i < 45; i++, t += 1000 / 15) w.observe('A', A, [], t);               // ...3 more seconds
  const p = entity(w)[0];
  assert.equal(p.state, 'hidden', 'still estimated behind the obstacle');
  assert.ok(behind(w, p));
  // A second phone now looks behind the obstacle and sees nobody: the cloud is ruled out.
  const B = { ...phone('B', 0, -6, 180), fov: 120 };
  for (let i = 0; i < 25; i++, t += 1000 / 15) { w.observe('A', A, [], t); w.observe('B', B, [], t); }
  const lost = w.events.filter(e => e.type === 'lost' && e.label === 'person');
  assert.ok(lost.length === 1 && ['notThere', 'missedExit'].includes(lost[0].reason), `ended as ${lost[0]?.reason}`);
});
