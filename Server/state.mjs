// In-memory hub state: the latest frame of every phone plus one fused WorldModel per shared space.
// Only measured points are accepted. Missing geometry stays missing.
import { randomUUID } from 'node:crypto';
import { WorldModel } from './world.mjs';

const finite = n => typeof n === 'number' && Number.isFinite(n);
const str = (s, n = 100) => typeof s === 'string' && s.length > 0 && s.length <= n;
const vec = v => v && ['x', 'y', 'z'].every(k => finite(v[k]) && Math.abs(v[k]) < 10000);
const optional = (v, test) => v == null || test(v);

/** v1/v2 ingest remains available for diagnostics; only v3 supplies bounded observation ages. */
export function validate(f) {
  if (!f || ![1, 2, 3].includes(f.version) || !['deviceID', 'name', 'session', 'epoch'].every(k => str(f[k])) ||
      !Number.isSafeInteger(f.sequence) || f.sequence < 0 || typeof f.tracking !== 'boolean' ||
      !(f.anchorID == null || str(f.anchorID)) || !Array.isArray(f.objects) || f.objects.length > 64) return false;
  if (f.version === 3 && (!finite(f.t) || !finite(f.sent) || f.t < 0 || f.sent < f.t ||
      !optional(f.receiptToken, v => str(v)) || !f.objects.every(o =>
        o && ['measurement', 'prediction', 'bearing'].includes(o.evidence) &&
        (o.evidence !== 'measurement' || (vec(o.position) && finite(o.measuredAt) && o.measuredAt >= 0 && o.measuredAt <= f.t))))) return false;
  if (f.version === 1 ? !Array.isArray(f.planes) : !(f.planes == null || Array.isArray(f.planes))) return false;
  if (f.planes && f.planes.length > 128) return false;
  if (!optional(f.scan, a => Array.isArray(a) && a.length <= 64 && a.every(h => h && ['x', 'z', 'nx', 'nz'].every(k => finite(h[k]) && Math.abs(h[k]) < 10000)))) return false;
  if (f.camera != null && (!Array.isArray(f.camera.m) || f.camera.m.length !== 16 || !f.camera.m.every(finite))) return false;
  if (f.jpeg != null && (typeof f.jpeg !== 'string' || f.jpeg.length > 400000 || !/^\/9j\/[A-Za-z0-9+/\r\n]*={0,2}$/.test(f.jpeg))) return false;
  if (!optional(f.fov, v => finite(v) && v >= 10 && v <= 170) || !optional(f.t, finite) || !optional(f.sent, finite)) return false;
  if (!f.objects.every(o => o && Number.isSafeInteger(o.id) && str(o.label) && finite(o.confidence) && o.confidence >= 0 && o.confidence <= 1 &&
      o.box && ['x', 'y', 'w', 'h'].every(k => finite(o.box[k]) && o.box[k] >= 0 && o.box[k] <= 1) &&
      (o.position == null || vec(o.position)) && (o.sigma == null || (finite(o.sigma) && o.sigma >= 0)) &&
      optional(o.size, s => ['w', 'h'].every(k => finite(s[k]) && s[k] > 0 && s[k] < 50)))) return false;
  return (f.planes ?? []).every(p => p && str(p.id) && typeof p.vertical === 'boolean' && optional(p.kind, k => str(k, 20)) &&
    Array.isArray(p.vertices) && p.vertices.length <= 4096 &&
    p.vertices.every(vec) && Array.isArray(p.triangles) && p.triangles.length <= 24576 && p.triangles.length % 3 === 0 &&
    p.triangles.every(i => Number.isInteger(i) && i >= 0 && i < p.vertices.length));
}

const spaceOf = f => f.anchorID ? `shared:${f.anchorID}` : `local:${f.deviceID}`;

export class RoomStore {
  constructor(clock = () => performance.now(), worldOptions = {}) {
    this.clock = clock; this.worldOptions = worldOptions;
    this.devices = new Map();     // JSON [session, deviceID] -> record
    this.worlds = new Map();      // `${session}\n${space}` -> WorldModel
    this.epochs = new Map(); // Retained after pruning: a retired epoch must never become current again.
    this.revision = 0;            // bumps on every accepted frame; lets the push loop skip idle ticks
  }

  world(session, space, create = true) {
    const key = `${session}\n${space}`;
    let w = this.worlds.get(key);
    if (!w && create) { w = new WorldModel(this.worldOptions); this.worlds.set(key, w); }
    return w;
  }

  leave(rec) {
    const key = `${rec.frame.session}\n${rec.space}`, w = this.worlds.get(key);
    if (!w) return;
    w.removeDevice(rec.frame.deviceID);
    // A room that has been mapped is kept: the walls are still there when a phone comes back.
    if (!w.devices.size && !w.perimeter.patches.size) this.worlds.delete(key);
  }

  prune() {
    for (const [k, d] of this.devices) if (this.clock() - d.received > 30000) { this.leave(d); this.devices.delete(k); }
  }

  /** Returns the HTTP status only (kept for callers that do not need the reply). */
  ingest(frame) { return this.accept(frame).code; }

  /** Validates and stores one frame. v2 frames get `{code: 200, reply}` with what this phone cannot see itself. */
  accept(frame) {
    if (frame && ![1, 2, 3].includes(frame.version)) return { code: 426 };
    if (!validate(frame)) return { code: 400 };
    this.prune();
    const now = this.clock(), key = JSON.stringify([frame.session, frame.deviceID]);
    const old = this.devices.get(key);
    const history = this.epochs.get(key);
    if (history?.retired.has(frame.epoch)) return { code: 409 };
    if (history?.current === frame.epoch && frame.sequence <= history.sequence) return { code: 409 };
    if (old?.frame.epoch === frame.epoch && frame.version === 3 && frame.t < old.frame.t) return { code: 409 };
    if (frame.version === 3 && (frame.sent - frame.t) * 1000 > 3000) return { code: 422 };
    if (!old && this.devices.size >= 32) return { code: 503 };
    if (old?.frame.epoch === frame.epoch && frame.sequence <= old.frame.sequence) return { code: 409 };
    const retired = history?.retired ?? new Set();
    if (history && history.current !== frame.epoch) retired.add(history.current);
    this.epochs.set(key, { current: frame.epoch, sequence: frame.sequence, retired });
    const space = spaceOf(frame), newEpoch = !old || old.frame.epoch !== frame.epoch;
    if (old && (newEpoch || old.space !== space))
      this.world(frame.session, old.space, false)?.invalidateDevice(frame.deviceID, { keepGeometry: old.space === space && space.startsWith('shared:') });
    if (old && (old.space !== space || (newEpoch && !frame.anchorID))) this.leave(old);
    const world = this.world(frame.session, space);


    const rec = old ?? { planes: [], planesRev: 0, jpeg: null, jpegRev: 0, count: 0, fps: 0, latencyMs: null };
    if (old && now > old.received) { const f = 1000 / (now - old.received); rec.fps = rec.fps ? rec.fps + 0.2 * (f - rec.fps) : f; }
    if (frame.planes) { rec.planes = frame.planes; rec.planesRev++; }
    else if (newEpoch && frame.version >= 2) { rec.planes = []; rec.planesRev++; }   // new AR map: old surfaces are void
    if (frame.planes || newEpoch || old?.space !== space || old?.frame.tracking !== frame.tracking)
      world.setPlanes(frame.deviceID, frame.tracking ? rec.planes : []);
    if (frame.scan && frame.tracking) world.setScan(frame.deviceID, frame.scan);
    if (frame.jpeg) { rec.jpeg = frame.jpeg; rec.jpegRev++; rec.jpegAt = now; }
    // Durations only: no phone timestamp is subtracted from a server timestamp.
    const processingMs = finite(frame.t) && finite(frame.sent) && frame.sent >= frame.t ? (frame.sent - frame.t) * 1000 : null;
    const networkUpperMs = !newEpoch && frame.version === 3 && frame.receiptToken === rec.receiptToken &&
      rec.receiptToken && now >= rec.tokenAt ? now - rec.tokenAt : null;
    rec.latencyMs = processingMs; // lower bound, not a measured one-way latency
    if (newEpoch) rec.measurements = new Map();
    const timedObjects = frame.objects.filter(o => {
      if (frame.version !== 3 || o.evidence !== 'measurement') return true;
      if (o.measuredAt <= (rec.measurements.get(o.id) ?? -Infinity)) return false;
      rec.measurements.set(o.id, o.measuredAt);
      return true;
    }).map(o => ({ ...o,
      evidence: frame.version === 3 ? o.evidence : (o.position ? 'measurement' : 'bearing'),
      measuredAt: frame.version === 3 ? o.measuredAt : frame.t,
      ageLowerMs: frame.version === 3 && finite(o.measuredAt) ? (frame.sent - o.measuredAt) * 1000 : processingMs,
      ageUncertaintyMs: networkUpperMs,
    }));
    const { planes, jpeg, scan, ...light } = frame;
    rec.frame = light; rec.received = now; rec.count++; rec.space = space;
    this.devices.set(key, rec);
    this.revision++;
    world.observe(frame.deviceID, { name: frame.name, pose: frame.camera?.m, fov: frame.fov, tracking: frame.tracking && !!frame.camera },
                  frame.tracking ? timedObjects : [], now);
    if (frame.version === 1) return { code: 204 };
    rec.receiptToken = randomUUID(); rec.tokenAt = now;
    return { code: 200, reply: { v: frame.version, epoch: frame.epoch, sequence: frame.sequence, receiptToken: rec.receiptToken, now, advisories: frame.version === 3 ? world.advisoriesFor(frame.deviceID, now) : [], devices: world.cameras(now).filter(c => c.live).length } };
  }

  /** Advances every world model to now. Called by the push loop so motion stays smooth between phone frames. */
  tick() { const now = this.clock(); for (const w of this.worlds.values()) w.step(now); return now; }

  records(session) { return [...this.devices.values()].filter(d => d.frame.session === session); }

  /** Full state, self-describing. Used by GET /api/state and by tests; the dashboard uses stream(). */
  snapshot(session) {
    this.prune(); const now = this.tick();
    return { now, devices: this.records(session).map(d => {
      const ageMs = now - d.received, live = ageMs < 3000;
      return { ...d.frame, ageMs, live, count: d.count, space: d.space,
        // A frozen camera must never look like a live measurement.
        objects: live ? d.frame.objects : [], planes: live ? d.planes : [],
        camera: live ? d.frame.camera ?? null : null, jpeg: live ? d.jpeg : null };
    }), spaces: this.spaces(session) };
  }

  spaces(session) {
    const out = [];
    for (const [key, w] of this.worlds) {
      const [s, space] = key.split('\n');
      if (s === session) out.push({ key: space, entities: w.snapshot(), cameras: w.cameras(), events: w.events });
    }
    return out;
  }

  /** Compact message for the dashboard push stream: no surfaces, no pictures. */
  stream(session) {
    this.prune(); const now = this.tick();
    return { type: 'world', t: now, devices: this.records(session).map(d => {
      const ageMs = now - d.received, live = ageMs < 3000, f = d.frame;
      return { id: f.deviceID, name: f.name, space: d.space, live, ageMs, tracking: f.tracking, aligned: !!f.anchorID, count: d.count,
        fps: Math.round(d.fps * 10) / 10, latencyMs: d.latencyMs == null ? null : Math.round(d.latencyMs),
        planesRev: d.planesRev, previewRev: live && d.jpeg ? d.jpegRev : 0,
        objects: live ? f.objects.map(o => ({ id: o.id, label: o.label, c: o.confidence, box: o.box, p: !!o.position })) : [] };
    }), spaces: this.spaces(session) };
  }

  /** The perimeter of every space of a session, with a revision that changes only when the room changes. */
  rooms(session) {
    const out = [];
    for (const [key, w] of this.worlds) {
      const [s, space] = key.split('\n');
      if (s === session) out.push({ space, rev: w.perimeter.rev, room: w.perimeter.room });
    }
    return out;
  }

  surfaces(session) {
    return this.records(session).map(d => ({ device: d.frame.deviceID, space: d.space, rev: d.planesRev,
      planes: this.clock() - d.received < 3000 && d.frame.tracking ? d.planes : [] }));
  }

  preview(session, deviceID) {
    const d = this.devices.get(JSON.stringify([session, deviceID]));
    return d?.jpeg && this.clock() - d.received < 3000 ? Buffer.from(d.jpeg, 'base64') : null;
  }
}
