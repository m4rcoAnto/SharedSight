// SYNTHETIC scenario for the demo and for end-to-end tests. Nothing here is a measurement.
// A living room and a hallway joined by a doorway, furniture, two people and a dog on fixed routes, and up to
// three virtual iPhones. Each virtual phone "detects" only what its field of view and real line-of-sight geometry
// allow (walls, the open door, tall furniture and people hide things), adds measurement noise and dropouts, and
// emits exactly the frames the iOS app posts to the hub (protocol v2).
import { classInfo } from '../shared/classes.mjs';
import { poseFromYaw, cameraFromPose, sightRelation, wallFromPlane, segmentHit } from '../geometry.mjs';

const H = 2.7;                                   // wall height
const quad = (id, vertical, kind, pts) => ({ id, vertical, kind, vertices: pts.map(([x, y, z]) => ({ x, y, z })), triangles: [0, 1, 2, 0, 2, 3] });
const wall = (id, ax, az, bx, bz, kind = 'wall', y0 = 0, y1 = H) => quad(id, true, kind, [[ax, y0, az], [bx, y0, bz], [bx, y1, bz], [ax, y1, az]]);
const floor = (id, x0, z0, x1, z1) => quad(id, false, 'floor', [[x0, 0, z0], [x1, 0, z0], [x1, 0, z1], [x0, 0, z1]]);

const LIVING = [
  floor('living-floor', -3, -2.5, 3, 2.5),
  wall('living-back', -3, -2.5, 3, -2.5), wall('living-left', -3, -2.5, -3, 2.5), wall('living-front', -3, 2.5, 3, 2.5),
  wall('living-right-a', 3, -2.5, 3, 0.3), wall('living-right-b', 3, 1.3, 3, 2.5),
  wall('door-lintel', 3, 0.3, 3, 1.3, 'wall', 2.1, H),
  wall('window', -0.5, -2.49, 1.1, -2.49, 'window', 0.9, 2.2),
  quad('table-top', false, 'table', [[-0.6, 0.75, -0.8], [0.8, 0.75, -0.8], [0.8, 0.75, 0.0], [-0.6, 0.75, 0.0]]),   // ARKit 'table' surface
];
const HALL = [
  floor('hall-floor', 3, -2.5, 5, 2.5),
  wall('hall-right', 5, -2.5, 5, 2.5), wall('hall-back', 3, -2.5, 5, -2.5), wall('hall-front', 3, 2.5, 5, 2.5),
  wall('door-leaf', 3.02, 0.3, 3.64, 0.92, 'door', 0, 2.05),     // door half open into the hallway
];

const STATICS = [
  { key: 'couch-1', label: 'couch', x: 0, z: -1.9 }, { key: 'couch-2', label: 'couch', x: 1.9, z: -0.2 },
  { key: 'armchair', label: 'chair', x: -1.7, z: -0.7 }, { key: 'table', label: 'dining table', x: 0.1, z: -0.4 },
  { key: 'plant-1', label: 'potted plant', x: -2.6, z: -2.1 }, { key: 'plant-2', label: 'potted plant', x: 2.6, z: -2.1 },
  { key: 'plant-3', label: 'potted plant', x: -2.6, z: 2.0 }, { key: 'plant-4', label: 'potted plant', x: 3.4, z: -2.1 },
  { key: 'vase', label: 'vase', x: -2.2, z: -2.2 },
];

// Routes: [x, z, pauseSeconds]. Speeds in m/s. Anna walks out through the doorway and stops behind the open door;
// Luca paces the far end of the hallway; the dog trots around the room and behind the second couch.
const AGENTS = [
  { key: 'anna', label: 'person', speed: 1.0, route: [[-0.8, 1.5, 2], [1.6, 1.3, 0], [2.7, 1.1, 0], [3.5, 1.15, 0], [4.3, 0.95, 0], [4.3, 0.2, 5], [4.3, 0.95, 0], [3.5, 1.15, 0], [2.6, 1.1, 0], [0.6, 1.5, 0]] },
  { key: 'luca', label: 'person', speed: 0.8, route: [[4.4, -2.0, 3], [4.4, -1.0, 2], [3.6, -1.4, 2]] },
  { key: 'dog', label: 'dog', speed: 1.3, route: [[-2.0, 0.6, 1.5], [0.4, 0.9, 0], [2.0, 1.7, 0], [2.72, 1.25, 0], [2.72, -1.5, 1.5], [2.72, 1.25, 0], [1.0, 1.9, 0], [-1.6, 1.8, 0]] },
];

// Virtual iPhones. `path(t)` returns {x, y, z, yaw}; yaw 0 looks along -Z, +90 deg looks along +X.
const DEG = Math.PI / 180;
const PHONES = [
  { id: 'demo-user', name: 'iPhone utente', planes: LIVING, fov: 55, lidar: true,
    path: t => ({ x: -2.1 + 0.35 * Math.sin(t / 9), y: 1.35, z: 1.25 + 0.12 * Math.sin(t / 5), yaw: (82 + 11 * Math.sin(t / 6)) * DEG }) },
  { id: 'demo-hall', name: 'iPhone corridoio', planes: HALL, fov: 60,
    path: () => ({ x: 4.5, y: 1.3, z: 2.3, yaw: -6 * DEG }) },
  { id: 'demo-window', name: 'iPhone finestra', planes: [], fov: 60,
    path: t => ({ x: -2.7, y: 1.7, z: -2.2, yaw: (118 + 6 * Math.sin(t / 8)) * DEG }) },
];

function compile(agent) {
  const legs = []; let total = 0;
  for (let i = 0; i < agent.route.length; i++) {
    const a = agent.route[i], b = agent.route[(i + 1) % agent.route.length];
    if (a[2] > 0) { legs.push({ from: a, to: a, start: total, dur: a[2] }); total += a[2]; }
    const dur = Math.hypot(b[0] - a[0], b[1] - a[1]) / agent.speed;
    legs.push({ from: a, to: b, start: total, dur }); total += dur;
  }
  return { legs, total };
}

function mulberry(seed) { return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }

export function createScenario({ phones = 3, seed = 7, noise = 1, anchor = phones > 1 ? 'DEMO-MARKER' : null, reveal = true } = {}) {
  const random = mulberry(seed), gauss = () => { let s = 0; for (let i = 0; i < 6; i++) s += random(); return (s - 3) / Math.sqrt(0.5); };
  const agents = AGENTS.map(a => ({ ...a, ...compile(a), info: classInfo(a.label) }));
  const allPlanes = [...LIVING, ...HALL], walls = allPlanes.map(wallFromPlane).filter(Boolean);
  const active = PHONES.slice(0, Math.min(Math.max(phones, 1), PHONES.length)).map(p => ({ ...p, epoch: `demo-${p.id}-${seed}`, sequence: 0, ids: new Map(), nextID: 1, planesSent: false, revealed: new Map(), revealedSig: '', planesAt: -1 }));
  const verticals = allPlanes.filter(p => p.vertical).map(p => ({ plane: p, w: wallFromPlane(p) })).filter(v => v.w);

  /** Like ARKit: a wall appears as a patch where the camera looks at it, and grows as the phone keeps looking. */
  function revealWalls(p, cam, t) {
    if (cam.yaw == null) return;
    const rays = 24, half = p.fov * DEG / 2;
    for (let i = 0; i <= rays; i++) {
      const a = cam.yaw - half + (2 * half * i) / rays, qx = cam.x + Math.sin(a) * 7, qz = cam.z - Math.cos(a) * 7;
      let best = null;
      for (const v of verticals) {
        const k = segmentHit(cam.x, cam.z, qx, qz, v.w.ax, v.w.az, v.w.bx, v.w.bz);
        if (k != null && (!best || k < best.k)) best = { k, v };
      }
      if (!best) continue;
      const w = best.v.w, len = Math.hypot(w.bx - w.ax, w.bz - w.az);
      const hx = cam.x + (qx - cam.x) * best.k, hz = cam.z + (qz - cam.z) * best.k;
      const s = ((hx - w.ax) * (w.bx - w.ax) + (hz - w.az) * (w.bz - w.az)) / len;
      const cur = p.revealed.get(best.v.plane.id) ?? { s0: s, s1: s };
      cur.s0 = Math.max(0, Math.min(cur.s0, s - 0.35)); cur.s1 = Math.min(len, Math.max(cur.s1, s + 0.35));
      p.revealed.set(best.v.plane.id, cur);
    }
  }
  function revealedPlanes(p) {
    const out = allPlanes.filter(x => !x.vertical && p.planes.includes(x));          // the floor under the phone is found at once
    for (const [id, r] of p.revealed) {
      const v = verticals.find(x => x.plane.id === id), w = v.w, len = Math.hypot(w.bx - w.ax, w.bz - w.az);
      const ux = (w.bx - w.ax) / len, uz = (w.bz - w.az) / len;
      out.push(wall(id, w.ax + ux * r.s0, w.az + uz * r.s0, w.ax + ux * r.s1, w.az + uz * r.s1, v.plane.kind, w.y0, w.y1));
    }
    return out;
  }

  function agentAt(a, t) {
    const u = ((t % a.total) + a.total) % a.total;
    const leg = a.legs.find(l => u >= l.start && u < l.start + l.dur) ?? a.legs[a.legs.length - 1];
    const k = leg.dur > 0 ? (u - leg.start) / leg.dur : 0, moving = leg.from !== leg.to;
    return { key: a.key, label: a.label, x: leg.from[0] + (leg.to[0] - leg.from[0]) * k, z: leg.from[1] + (leg.to[1] - leg.from[1]) * k,
      y: 0, h: a.info.h, w: a.info.w, moving };
  }
  /** Ground truth at time t (seconds). */
  function truth(t) {
    return [...agents.map(a => agentAt(a, t)), ...STATICS.map(s => ({ ...s, y: 0, h: classInfo(s.label).h, w: classInfo(s.label).w, moving: false }))];
  }

  /** The frame phone `index` would post at time t (seconds), plus what it truly sees (for assertions). */
  function frame(index, t, { session = 'DEMO' } = {}) {
    const p = active[index], pose = p.path(t), m = poseFromYaw(pose.x, pose.y, pose.z, pose.yaw), cam = cameraFromPose(m);
    const things = truth(t);
    const blockers = things.map(o => ({ id: o.key, label: o.label, x: o.x, z: o.z, y: 0, h: o.h, r: Math.max(o.w, 0.2) * 0.45 }));
    const tanH = Math.tan(p.fov * DEG / 2), tanV = tanH / 0.75, objects = [], seen = [];
    for (const o of things) {
      const rel = sightRelation(cam, p.fov, 9, { id: o.key, x: o.x, z: o.z, y: 0, h: o.h, r: o.w / 2 }, walls, blockers);
      const known = p.ids.get(o.key);
      if (rel.relation !== 'visible' && rel.relation !== 'partial') { if (known && t - known.last > 1.5) p.ids.delete(o.key); continue; }
      seen.push(o.key);
      if (random() < 0.04 * noise) continue;                                           // detector dropout
      let entry = p.ids.get(o.key);
      if (!entry || t - entry.last > 1.5) { entry = { id: p.nextID++, last: t }; p.ids.set(o.key, entry); }
      entry.last = t;
      const sigma = 0.08 + 0.03 * rel.distance, forward = Math.max(rel.distance * Math.cos(rel.bearingDeg * DEG), 0.3);
      const cx = 0.5 + Math.tan(rel.bearingDeg * DEG) / (2 * tanH), bw = o.w / (forward * 2 * tanH), bh = o.h / (forward * 2 * tanV);
      const top = 0.5 - (o.h - pose.y) / (forward * 2 * tanV), clamp = v => Math.min(1, Math.max(0, v));
      const x0 = clamp(cx - bw / 2), y0 = clamp(top), x1 = clamp(cx + bw / 2), y1 = clamp(top + bh);
      // Feet outside the picture: no floor raycast. A LiDAR phone still measures depth up to about 5 m.
      const cut = top + bh > 0.97 && !(p.lidar && rel.distance < 5);
      objects.push({ id: entry.id, label: o.label, confidence: Math.round((0.93 - 0.02 * rel.distance - (rel.relation === 'partial' ? 0.2 : 0)) * 100) / 100,
        box: { x: x0, y: y0, w: Math.max(0.001, x1 - x0), h: Math.max(0.001, y1 - y0) },
        evidence: cut ? 'bearing' : 'measurement', ...(cut ? {} : { measuredAt: t }),
        ...(cut ? {} : { position: { x: o.x + gauss() * sigma * 0.6 * noise, y: 0, z: o.z + gauss() * sigma * 0.6 * noise }, sigma,
          size: { w: o.w * (1 + gauss() * 0.04 * noise), h: o.h * (1 + gauss() * 0.04 * noise) } }) });
    }
    // Same protocol as the app (v3): capture time per measurement, send time, and the hub's last receipt echoed back.
    const f = { version: 3, deviceID: p.id, name: p.name, session, epoch: p.epoch, sequence: ++p.sequence, tracking: true,
      anchorID: anchor, camera: { m }, fov: p.fov, t, sent: t + 0.045, objects, ...(p.receiptToken ? { receiptToken: p.receiptToken } : {}) };
    if (reveal) {
      revealWalls(p, cam, t);
      const sig = [...p.revealed].map(([id, r]) => `${id}:${r.s0.toFixed(1)}:${r.s1.toFixed(1)}`).join('|');
      if (!p.planesSent || (sig !== p.revealedSig && t - p.planesAt >= 0.5)) { f.planes = revealedPlanes(p); p.revealedSig = sig; p.planesAt = t; p.planesSent = true; }
    } else if (!p.planesSent) { f.planes = p.planes; p.planesSent = true; }
    return { frame: f, seen, pose };
  }

  /** Hand the hub's reply back to the simulated phone, exactly as ServerTransport does. */
  function reply(index, r) { active[index].receiptToken = r?.receiptToken ?? null; }

  return { phones: active, agents, truth, frame, reply, walls, planes: allPlanes };
}
