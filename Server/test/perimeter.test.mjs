// Room perimeter from ARKit-like wall patches: partial, merging, renamed, interrupted. SYNTHETIC geometry.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Perimeter } from '../perimeter.mjs';
import { WorldModel } from '../world.mjs';
import { poseFromYaw, sightRelation, cameraFromPose } from '../geometry.mjs';

const DEG = Math.PI / 180;
// A room 5 m (along its own u axis) by 4 m, turned 20° in the phone's world frame, centred on (1, -2).
const ROT = 20 * DEG, CX = 1, CZ = -2;
const W = (u, v) => [CX + u * Math.cos(ROT) - v * Math.sin(ROT), CZ + u * Math.sin(ROT) + v * Math.cos(ROT)];
const vertical = (id, [ax, az], [bx, bz], kind = 'wall', y0 = 0, y1 = 2.5) => ({ id, vertical: true, kind,
  vertices: [{ x: ax, y: y0, z: az }, { x: bx, y: y0, z: bz }, { x: bx, y: y1, z: bz }, { x: ax, y: y1, z: az }], triangles: [0, 1, 2, 0, 2, 3] });
const floor = (id, pts) => ({ id, vertical: false, kind: 'floor', vertices: pts.map(([x, z]) => ({ x, y: 0, z })), triangles: [0, 1, 2, 0, 2, 3] });
// Patches of the four walls: north v=+2, south v=-2, east u=+2.5, west u=-2.5 (u along the room, v across).
const north = (id, u0, u1) => vertical(id, W(u0, 2), W(u1, 2));
const east = (id, v0, v1) => vertical(id, W(2.5, v0), W(2.5, v1));
const sideOf = (room, [u, v]) => room.sides.filter(p => { const [x, z] = W(u, v), mx = (p.ax + p.bx) / 2, mz = (p.az + p.bz) / 2; return Math.hypot(mx - x, mz - z) < 3; });
const toUV = (x, z) => { const dx = x - CX, dz = z - CZ; return [dx * Math.cos(ROT) + dz * Math.sin(ROT), -dx * Math.sin(ROT) + dz * Math.cos(ROT)]; };

test('two partial walls are enough for a closed, right-angled perimeter; unseen sides are marked inferred', () => {
  const p = new Perimeter();
  p.ingest('A', [north('n1', -0.5, 1.5), east('e1', -0.5, 1.0), floor('f', [W(-1, -1), W(1, -1), W(1, 1), W(-1, 1)])]);
  p.addPoint(...W(0, 0));
  const room = p.update();
  assert.ok(room, 'a perimeter is proposed');
  assert.equal(room.corners.length, 4);
  // Seen sides sit where the walls are (5 cm quantisation), at right angles.
  const seenNorth = room.sides.filter(s => s.kind === 'wall').map(s => toUV((s.ax + s.bx) / 2, (s.az + s.bz) / 2));
  assert.ok(seenNorth.some(([, v]) => Math.abs(v - 2) < 0.08), 'north wall in place');
  assert.ok(seenNorth.some(([u]) => Math.abs(u - 2.5) < 0.08), 'east wall in place');
  assert.ok(Math.abs(room.axisDeg % 90 - 20) < 0.5 || Math.abs(room.axisDeg % 90 + 70) < 0.5, `axes follow the room (${room.axisDeg}°)`);
  // Everything else on the outline is inferred, and the phone is inside.
  assert.ok(room.sides.some(s => s.kind === 'inferred'));
  assert.equal(room.seenSides, 2);
  const uv = room.corners.map(([x, z]) => toUV(x, z)), us = uv.map(a => a[0]), vs = uv.map(a => a[1]);
  assert.ok(Math.min(...us) < 0 && Math.max(...us) > 0 && Math.min(...vs) < 0 && Math.max(...vs) > 0, 'the phone is inside');
  // The seen parts plus the inferred parts cover the whole outline without gaps.
  const length = room.sides.reduce((t, s) => t + Math.hypot(s.bx - s.ax, s.bz - s.az), 0);
  const outline = room.corners.reduce((t, c, i) => { const d = room.corners[(i + 1) % 4]; return t + Math.hypot(d[0] - c[0], d[1] - c[1]); }, 0);
  assert.ok(Math.abs(length - outline) < 0.2, `closed outline (${length.toFixed(2)} of ${outline.toFixed(2)} m)`);
});

test('ARKit merging and renaming anchors, or losing tracking, never shrinks or moves what was seen', () => {
  const p = new Perimeter();
  p.ingest('A', [north('a', -2, -0.5), north('b', 0, 1.5), east('c', -1.5, 1.5)]); p.addPoint(...W(0, 0));
  const first = p.update(), rev = p.rev;
  // ARKit merges a and b into a new anchor d (a and b disappear from the list), then tracking hiccups (empty list).
  p.ingest('A', [vertical('d', W(-2, 2.01), W(1.6, 1.99)), east('c', -1.5, 1.5)]); p.update();
  p.ingest('A', []); const after = p.update();
  const seen = r => r.sides.filter(s => s.kind === 'wall').reduce((t, s) => t + Math.hypot(s.bx - s.ax, s.bz - s.az), 0);
  assert.ok(seen(after) >= seen(first) - 0.05, 'nothing seen is forgotten');
  for (let i = 0; i < 4; i++) for (let k = 0; k < 2; k++) assert.ok(Math.abs(after.corners[i][k] - first.corners[i][k]) < 0.15, 'corners stay put');
  // The same information sent again does not change the published room.
  const r2 = p.rev; p.ingest('A', [vertical('d', W(-2, 2.01), W(1.6, 1.99)), east('c', -1.5, 1.5)]); p.update();
  assert.equal(p.rev, r2, 'no new revision for repeated input');
  assert.ok(p.rev - rev <= 2);
});

test('one wall gives a plausible room at once; a couch back is not a wall; outdoors there is no perimeter', () => {
  const one = new Perimeter();
  one.ingest('A', [north('n', -1, 1)]); one.addPoint(...W(0, 0));
  const room = one.update();
  assert.ok(room && room.seenSides === 1 && room.corners.length === 4);
  const uv = room.corners.map(([x, z]) => toUV(x, z)), vs = uv.map(a => a[1]);
  assert.ok(Math.max(...vs) - Math.min(...vs) >= 1.2, 'at least the minimum depth, marked inferred');

  const couch = new Perimeter();
  couch.ingest('A', [vertical('couch', W(-1, 0.5), W(1, 0.5), 'wall', 0, 0.8)]); couch.addPoint(0, 0);
  assert.equal(couch.update(), null, 'an 80 cm high vertical surface is furniture');

  const outside = new Perimeter();
  outside.ingest('A', [floor('f', [[0, 0], [5, 0], [5, 5], [0, 5]])]); outside.addPoint(1, 1);
  assert.equal(outside.update(), null);
});

test('a door seen in a wall stays a door in the perimeter', () => {
  const p = new Perimeter();
  p.ingest('A', [north('n1', -2.5, -0.5), vertical('door', W(-0.5, 2), W(0.4, 2), 'door', 0, 2.1), north('n2', 0.4, 2.5)]);
  p.addPoint(...W(0, 0));
  const room = p.update();
  assert.ok(room.sides.some(s => s.kind === 'door'), 'door part');
  assert.ok(room.sides.filter(s => s.kind === 'wall').length >= 2);
});

test('a phone whose own frame restarted forgets its walls; the world keeps blocking sight with remembered walls', () => {
  const w = new WorldModel();
  const [cx, cz] = W(0, 0), [tx, tz] = W(0, 3);
  const cam = { name: 'A', pose: poseFromYaw(cx, 1.4, cz, Math.atan2(tx - cx, -(tz - cz))), fov: 60, tracking: true };
  w.setPlanes('A', [north('n', -2.5, 2.5)]);
  w.observe('A', cam, [], 0);
  w.setPlanes('A', []);                                   // tracking hiccup: the phone reports nothing
  const c = cameraFromPose(cam.pose);
  const rel = sightRelation(c, 60, 20, { x: tx, z: tz, y: 0, h: 1.7, r: 0.3 }, w.walls);
  assert.equal(rel.relation, 'occluded', 'the person 1 m behind the wall is hidden by the remembered wall');
  assert.equal(sightRelation(c, 60, 20, { x: tx, z: tz, y: 0, h: 1.7, r: 0.3 }, []).relation, 'visible', 'and would be visible without it');
  assert.ok(w.walls.length > 0);
  w.invalidateDevice('A');
  assert.equal(w.perimeter.patches.size, 0, 'a new unaligned AR session forgets the old frame');
});

test('a wall seen on a side continues to both corners; a parallel offset patch joins it instead of floating inside', () => {
  const p = new Perimeter();
  // North wall seen only in the middle; a second patch of the same wall measured 45 cm off (ARKit noise, a wardrobe).
  p.ingest('A', [north('n', -0.5, 0.5), vertical('w2', W(1.2, 1.55), W(2.2, 1.55)), east('e', -1, 1)]);
  p.addPoint(...W(0, 0));
  const room = p.update();
  const northParts = room.sides.filter(s => { const [, v] = toUV((s.ax + s.bx) / 2, (s.az + s.bz) / 2); return Math.abs(v - 2) < 0.1; });
  assert.ok(northParts.length && northParts.every(s => s.kind === 'wall' || s.kind === 'extended'), 'the whole north side is wall');
  const len = northParts.reduce((t, s) => t + Math.hypot(s.bx - s.ax, s.bz - s.az), 0);
  const [a, b] = [room.corners[2], room.corners[3]];
  assert.ok(Math.abs(len - Math.hypot(a[0] - b[0], a[1] - b[1])) < 0.15, 'corner to corner');
  assert.equal(room.interior.length, 0, 'no floating block inside the room');
});

test('something seen behind a measured wall is a reflection; behind a continued wall it opens a doorway', () => {
  const p = new Perimeter();
  p.ingest('A', [north('n', -2.5, -0.5), east('e', -2, 2)]); p.addPoint(...W(0, 0)); p.update();
  const [cx, cz] = W(0, 0);
  assert.equal(p.sight(cx, cz, ...W(-1.5, 3.5)), 'reflection', 'behind the measured part of the north wall (a mirror)');
  assert.equal(p.sight(cx, cz, ...W(-1.5, 1.5)), 'ok', 'in front of it');
  assert.equal(p.sight(cx, cz, ...W(1.5, 3.5)), 'passThrough', 'behind the continued part: an unmeasured opening');
  const room = p.update();
  assert.ok(room.sides.some(s => s.kind === 'opening'), 'the opening is now part of the perimeter');
  assert.equal(p.sight(cx, cz, ...W(1.5, 3.5)), 'ok', 'and is seen through from then on');
});

test('the world model rejects a person seen in a mirror and keeps the real one', () => {
  const w = new WorldModel();
  const [cx, cz] = W(0, 0), cam = { name: 'A', pose: poseFromYaw(cx, 1.4, cz, Math.atan2(...(() => { const [x, z] = W(0, 2); return [x - cx, -(z - cz)]; })())), fov: 60, tracking: true };
  w.setPlanes('A', [north('n', -2.5, 2.5), east('e', -2, 2)]);
  w.observe('A', cam, [], 0);
  const real = W(0, 1), mirrored = W(0, 3);
  for (let i = 1; i <= 5; i++) w.observe('A', cam, [
    { id: 1, label: 'person', confidence: .9, position: { x: real[0], y: 0, z: real[1] }, sigma: .2 },
    { id: 2, label: 'person', confidence: .9, position: { x: mirrored[0], y: 0, z: mirrored[1] }, sigma: .2 }], i * 100);
  const people = [...w.entities.values()].filter(e => e.label === 'person');
  assert.equal(people.length, 1, 'one person, not two');
  assert.equal(w.invalidations.get('A|2'), 'reflection');
});

test('depth-scan hits build far walls before any plane exists; one-off hits and oblique noise are ignored', () => {
  const p = new Perimeter();
  p.addPoint(...W(0, 0));
  const hitsOn = (u0, u1, v, n = [0, -1]) => { const out = []; for (let u = u0; u <= u1; u += 0.4) { const [x, z] = W(u, v), [ox, oz] = W(0, 0), [qx, qz] = W(n[0], n[1]); out.push({ x, z, nx: qx - ox, nz: qz - oz }); } return out; };
  const north = hitsOn(-2, 2, 3.8), east = [];
  for (let v = -1; v <= 3; v += 0.4) { const [x, z] = W(3, v), [ox, oz] = W(0, 0), [qx, qz] = W(-1, 0); east.push({ x, z, nx: qx - ox, nz: qz - oz }); }
  const [cx, cz] = W(0, 0), cam = { x: cx, z: cz };      // the phone that cast the rays: free space up to each hit
  p.ingestScan('A', north, cam); p.ingestScan('A', east, cam);
  assert.equal(p.update(), null, 'a single scan proves nothing yet');
  p.ingestScan('A', north, cam); p.ingestScan('A', east, cam);
  p.ingestScan('A', [{ x: 9, z: 9, nx: 0.7, nz: 0.7 }]);                       // a passer-by, once, oblique
  const room = p.update();
  assert.ok(room, 'room from scans alone');
  const mids = room.sides.filter(s => s.kind === 'wall').map(s => toUV((s.ax + s.bx) / 2, (s.az + s.bz) / 2));
  assert.ok(mids.some(([, v]) => Math.abs(v - 3.8) < 0.15), 'north wall 3.8 m away');
  assert.ok(mids.some(([u]) => Math.abs(u - 3) < 0.15), 'east wall 3 m away');
  assert.equal(room.interior.length, 0);
  const far = room.corners.map(([x, z]) => Math.hypot(x - 9, z - 9));
  assert.ok(Math.min(...far) > 3, 'the stray hit did not stretch the room');
});

test('a wall seen far away through a doorway does not stretch the room the phone is in', () => {
  // Room u ∈ [-2.5, 2.5], v ∈ [-2, 2] with a doorway in the south wall; a wall of the NEXT room seen at v = -6.
  const p = new Perimeter(), cam = (() => { const [x, z] = W(0, 0.5); return { x, z }; })();
  p.ingest('A', [north('n', -2.5, 2.5), east('e', -2, 2), vertical('s1', W(-2.5, -2), W(-0.5, -2)), vertical('s2', W(0.5, -2), W(2.5, -2)),
                 vertical('far', W(-2, -6), W(2, -6))], cam);
  for (const [u, v] of [[0, 0.5], [-1, 1], [1, 0], [-1.5, -1], [1.5, 1.2]]) p.addPoint(...W(u, v));
  const room = p.update();
  const vs = room.corners.map(([x, z]) => toUV(x, z)[1]);
  assert.ok(Math.min(...vs) > -2.2, `south side at the room's own wall, not the far one (${Math.min(...vs).toFixed(2)})`);
  assert.ok(Math.max(...vs) - Math.min(...vs) < 4.5, 'about 4 m deep');
});

test('walking into another room makes a second room; neither becomes a giant rectangle', () => {
  // Living room u ∈ [-2.5, 2.5], v ∈ [-2, 2]; hallway u ∈ [2.5, 4.5], v ∈ [-2, 4], through a door in the shared wall.
  const p = new Perimeter(), at = (u, v) => { const [x, z] = W(u, v); return { x, z }; };
  p.ingest('A', [north('n', -2.5, 2.5), vertical('s', W(-2.5, -2), W(2.5, -2)), vertical('w', W(-2.5, -2), W(-2.5, 2)),
                 vertical('shared1', W(2.5, -2), W(2.5, -0.5)), vertical('shared2', W(2.5, 0.5), W(2.5, 2)),
                 vertical('hallE', W(4.5, -2), W(4.5, 4)), vertical('hallN', W(2.5, 4), W(4.5, 4)), vertical('hallS', W(2.5, -2), W(4.5, -2))], at(0, 0));
  for (const [u, v] of [[-1, 0], [0, 1], [1, -1], [-1.5, 1.5], [1.5, 0.5]]) p.addPoint(...W(u, v));     // in the living room
  for (const [u, v] of [[3.5, 0], [3.5, 1.2], [3.5, 2.4], [3.6, 3.3]]) p.addPoint(...W(u, v));             // then in the hallway
  const room = p.update();
  assert.ok(room.rooms.length >= 2, `${room.rooms.length} rooms`);
  for (const r of room.rooms) {
    const uv = r.corners.map(([x, z]) => toUV(x, z)), us = uv.map(a => a[0]), vs = uv.map(a => a[1]);
    const w = Math.max(...us) - Math.min(...us), d = Math.max(...vs) - Math.min(...vs);
    assert.ok(w < 5.6 && d < 6.6, `room ${w.toFixed(1)} x ${d.toFixed(1)} m is not a giant rectangle`);
  }
  const cur = room.corners.map(([x, z]) => toUV(x, z)), cu = cur.map(a => a[0]);
  assert.ok(Math.min(...cu) > 2.3 && Math.max(...cu) < 4.7, 'the current room is the hallway, where the phone is now');
});
