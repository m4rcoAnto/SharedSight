// World model of one shared space (one marker frame, or one unaligned phone).
//
// Metric motion uses constant velocity and continuous process noise. Missing detections never invent
// a turn, braking or a hiding place. A measured wall conflict invalidates the prediction.
// Report expiration is distinct from object disappearance and retains a diagnostic reason.
import { classInfo, compatible, relevant } from './shared/classes.mjs';
import { cameraFromPose, wallFromPlane, sightRelation, moveWithWalls } from './geometry.mjs';
import { Perimeter } from './perimeter.mjs';
import { Cloud } from './cloud.mjs';

export const WORLD_DEFAULTS = {
  observedHoldMs: 450,      // a device "sees" an object this long after its last measurement of it
  deviceStaleMs: 3000,      // same limit the hub uses for a live device
  rangeM: 10,               // beyond this a phone is not expected to detect anything
  defaultFovDeg: 55,
  alignSigmaM: 0.12,        // residual marker-alignment error added to every measurement
  gateChi2: 9.21,           // 99 % for 2 degrees of freedom
  maxJumpDynamicM: 1.6, maxJumpStaticM: 0.9,
  noiseObserved: 0.22, noiseHidden: 0.1,    // x class acceleration^2 = white-noise-acceleration density (m^2/s^3)
  hiddenMaxMs: 8000, hiddenMaxSigmaM: 2.0,
  missGraceMs: 900,         // in clear view of a camera but undetected this long => dropped
  staticMissMs: 4000,
  staticMemoryMs: 300000,   // furniture nobody is looking at is remembered (and shown as remembered)
  lostHoldMs: 1500,
  mergeRadiusM: 0.55,
  maxEntities: 256,
  forecastS: [0.5, 1, 1.5, 2],
  minMovingSpeed: 0.3,      // m/s: slower estimated motion is not applied to predictions (standing people do not drift)
  cloudMinMass: 0.05,       // a hidden mover's cloud with less than 5% probability left: every place it could be was seen empty
  prunePeriodMs: 300,       // a phone's "not seen here" is applied to a hidden mover's cloud at most this often
  cloudMaxSigmaM: 2.5,      // spread of the cloud beyond which the estimate is too vague to be useful
};

class Axis {                                 // one coordinate: position + velocity, same maths as ScalarCVFilter (Swift)
  constructor(p, pv, vv) { this.p = p; this.v = 0; this.c11 = pv; this.c12 = 0; this.c22 = vv; }
  predict(dt, density) {
    this.p += this.v * dt;
    const n11 = this.c11 + dt * (2 * this.c12 + dt * this.c22) + density * dt * dt * dt / 3;
    const n12 = this.c12 + dt * this.c22 + density * dt * dt / 2;
    this.c22 += density * dt; this.c11 = n11; this.c12 = n12;
  }
  update(z, r) {
    const s = this.c11 + r; if (!(s > 0)) return;
    const k1 = this.c11 / s, k2 = this.c12 / s, y = z - this.p;
    this.p += k1 * y; this.v += k2 * y;
    const n11 = (1 - k1) * this.c11, n12 = (1 - k1) * this.c12, n22 = this.c22 - k2 * this.c12;
    this.c11 = n11; this.c12 = n12; this.c22 = Math.max(n22, 0);
  }
}

export class WorldModel {
  constructor(options = {}) {
    this.o = { ...WORLD_DEFAULTS, ...options };
    this.entities = new Map();
    this.devices = new Map();        // deviceID -> {name, cam, fov, t, tracking}
    this.wallsByDevice = new Map();
    this.walls = [];
    this.bindings = new Map();       // `${deviceID}|${localID}` -> entity id
    this.events = [];
    this.invalidations = new Map(); // Last rejection/expiration reason, retained until reacquisition/reset.
    this.nextID = 1; this.eventSeq = 0; this.now = 0;
    this.perimeter = new Perimeter(options.perimeter);
  }

  /** Line of sight uses the walls phones report now plus every wall part measured before (the perimeter memory). */
  refreshWalls() {
    this.perimeter.update();
    this.walls = [...[...this.wallsByDevice.values()].flat(), ...this.perimeter.measuredWalls()];
  }

  // ---- inputs -------------------------------------------------------------------------------------------------

  setPlanes(deviceID, planes) {
    this.wallsByDevice.set(deviceID, (planes ?? []).map(wallFromPlane).filter(Boolean));
    this.perimeter.ingest(deviceID, planes, this.devices.get(deviceID)?.cam ?? null);
    this.refreshWalls();
  }

  /** Depth-scan hits (vertical surfaces met by rays at chest height), in this space's frame. */
  setScan(deviceID, hits) {
    this.perimeter.ingestScan(deviceID, hits, this.devices.get(deviceID)?.cam ?? null);
    if (this.perimeter.dirty) this.refreshWalls();
  }

  removeDevice(deviceID) {
    this.devices.delete(deviceID); this.wallsByDevice.delete(deviceID);
    this.refreshWalls();
    for (const k of [...this.bindings.keys()]) if (k.startsWith(deviceID + '|')) this.bindings.delete(k);
    for (const e of this.entities.values()) e.sources.delete(deviceID);
  }

  /** New AR session on a phone: its local track numbers start again, so old bindings mean nothing. */
  invalidateDevice(deviceID, { keepGeometry = false } = {}) {
    // Conservative reset: discard fused states touched by the invalid coordinate epoch.
    for (const e of [...this.entities.values()]) if (e.sources.has(deviceID)) this.remove(e);
    // Walls measured in the shared marker frame stay valid across AR sessions; a phone's own frame does not.
    if (!keepGeometry) this.perimeter.forgetDevice(deviceID);
    this.removeDevice(deviceID);
  }

  resetBindings(deviceID) {
    for (const k of [...this.bindings.keys()]) if (k.startsWith(deviceID + '|')) this.bindings.delete(k);
  }

  /** One frame from one phone. `objects` carry floor positions already expressed in this space's frame. */
  observe(deviceID, device, objects, t) {
    this.advance(t);
    const cam = device.tracking && device.pose ? cameraFromPose(device.pose) : null;
    const prev = this.devices.get(deviceID);
    // Frame interval of this phone: a throttled phone (3–4 frames/s) must not see its objects blink between frames.
    const interval = prev && t > prev.t ? Math.min(t - prev.t, 2000) : (prev?.interval ?? 0);
    this.devices.set(deviceID, { name: device.name, cam, fov: device.fov ?? this.o.defaultFovDeg, t, tracking: !!device.tracking, interval });
    if (cam) { this.perimeter.addPoint(cam.x, cam.z); if (this.perimeter.dirty) this.refreshWalls(); }
    const measured = objects.filter(o => relevant(o.label)).filter(o => {
      if (o.position && (!Number.isFinite(o.sigma ?? 0.3) || (o.sigma ?? 0.3) < 0 || (o.sigma ?? 0.3) > this.o.hiddenMaxSigmaM)) {
        this.invalidations.set(`${deviceID}|${o.id}`, 'uncertainty'); return false;
      }
      return true;
    }).filter(o => o.position && o.evidence !== 'prediction' && o.evidence !== 'bearing' &&
      (o.ageLowerMs === undefined || (Number.isFinite(o.ageLowerMs) && o.ageLowerMs >= 0 && o.ageLowerMs <= this.o.deviceStaleMs)))
      .filter(o => {
        // A phone cannot see through a measured wall: what appears behind one is a reflection (mirror, glass, gloss).
        // Behind a wall that was only continued (never measured there), it reveals an opening instead.
        if (!cam) return true;
        const verdict = this.perimeter.sight(cam.x, cam.z, o.position.x, o.position.z, o.sigma ?? 0.3);
        if (verdict === 'reflection') { this.invalidations.set(`${deviceID}|${o.id}`, 'reflection'); this.reflections = (this.reflections ?? 0) + 1; return false; }
        return true;
      });
    // Anything measured standing on the floor proves that floor is free space of the room (for the perimeter).
    for (const o of measured) this.perimeter.addFree(deviceID, o.position.x, o.position.z);
    if (this.perimeter.dirty) this.refreshWalls();
    const taken = new Set(), pending = [];

    // 1. A local track that was already linked keeps its link while that stays physically plausible.
    for (const o of measured) {
      const key = `${deviceID}|${o.id}`, e = this.entities.get(this.bindings.get(key));
      if (e && compatible(e.label, o.label) && !taken.has(e.id) && this.distance(e, o) <= this.jumpLimit(e) * 1.5) {
        taken.add(e.id); this.correct(e, o, deviceID, device, t);
      } else { this.bindings.delete(key); pending.push(o); }
    }
    // 2. Everything else: gated nearest-neighbour association, cheapest pairs first.
    const pairs = [];
    for (const o of pending) for (const e of this.entities.values()) {
      if (taken.has(e.id) || e.state === 'lost' || !compatible(e.label, o.label)) continue;
      const d = this.distance(e, o), r = this.measurementVariance(o);
      const s = Math.max(e.ax.c11, e.az.c11) + r, chi = d * d / s;
      if (chi <= this.o.gateChi2 && d <= this.jumpLimit(e)) pairs.push({ o, e, chi });
    }
    pairs.sort((a, b) => a.chi - b.chi);
    const used = new Set();
    for (const { o, e, chi } of pairs) {
      if (used.has(o) || taken.has(e.id)) continue;
      // Two candidates almost as good as each other after an unobserved gap: continuity is not provable.
      const rival = pairs.some(p => p.e === e && p.o !== o && !used.has(p.o) && p.chi <= chi + 1.5);
      if (rival && e.state !== 'observed') e.ambiguous = true;
      used.add(o); taken.add(e.id); this.correct(e, o, deviceID, device, t);
    }
    // 3. Births.
    for (const o of pending) if (!used.has(o) && this.entities.size < this.o.maxEntities) this.birth(o, deviceID, device, t);
    // 4. Negative information: this phone looked and did not see the hidden movers there. Particles it would have
    //    seen (in its field of view, in range, not behind a wall or an object) are removed.
    if (cam) {
      const fov = device.fov ?? this.o.defaultFovDeg, all = this.blockers();
      for (const e of this.entities.values()) {
        // Detectors miss a few frames now and then: absence counts only after the usual grace period.
        if (!e.cloud || taken.has(e.id) || e.state !== 'hidden' || t - e.lastObs < this.o.missGraceMs) continue;
        const last = e.prunedAt?.get(deviceID) ?? -Infinity;
        if (t - last < this.o.prunePeriodMs) continue;
        (e.prunedAt ??= new Map()).set(deviceID, t);
        const others = all.filter(b => b.id !== e.id);
        e.cloud.prune(q => sightRelation(cam, fov, this.o.rangeM, { id: e.id, x: q.x, z: q.z, y: e.y, h: e.h, r: 0.15 }, this.walls, others).relation === 'visible');
      }
    }
    // Bearing-only detections cannot renew a metric measurement or reduce its uncertainty.
    this.classify(t, true);
    this.merge(); // Fusion changes only on input, never on rendering ticks.
  }

  /** Brings every estimate to time t (ms) and re-evaluates who can see what. */
  step(t) { this.advance(t); this.classify(t); }

  // ---- outputs ------------------------------------------------------------------------------------------------

  snapshot() {
    return [...this.entities.values()].map(e => {
      const observers = this.observers(e, this.now);
      return {
        id: e.id, label: e.label, x: round(this.pos(e).x), y: round(e.y), z: round(this.pos(e).z),
        cloud: e.cloud && e.state === 'hidden' && !e.cloud.empty ? e.cloud.sample(60) : undefined,
        vx: e.info.dyn && e.base && this.moving(e.base) ? round(e.ax.v) : 0, vz: e.info.dyn && e.base && this.moving(e.base) ? round(e.az.v) : 0,
        h: round(e.h), w: round(e.w), state: e.state, reason: e.reason ?? null, occluder: e.occluder?.kind ?? null,
        ageMs: Math.max(0, this.now - e.lastObs), ageUncertaintyMs: Number.isFinite(e.ageUncertaintyMs) ? e.ageUncertaintyMs : null,
        stateAt: e.last, receivedAt: e.receivedAt, reportValid: this.reportValid(e, this.now),
        invalidationReason: this.reportInvalidation(e, this.now),
        sigma: round(this.sigma(e)), seenBy: observers, ambiguous: e.ambiguous || undefined,
        path: e.info.dyn && e.state !== 'lost' && e.base && this.moving(e.base) ? this.forecast(e) : undefined,
        exit: e.exit && e.state === 'hidden' ? { x: round(e.exit.x), z: round(e.exit.z), inMs: Math.round(e.exit.t - this.now), halfMs: Math.round(e.exit.half) } : undefined,
      };
    });
  }

  /**
   * What `deviceID` cannot see but the shared space knows. This is the "another phone's light in my shadow" message:
   *   kind 'seen'      — measured right now by at least one other phone
   *   kind 'estimated' — seen by nobody; position is a motion-model prediction with the stated sigma
   * `localID` is set when this phone itself was tracking the object before losing it (a handoff).
   */
  advisoriesFor(deviceID, t = this.now) {
    const d = this.devices.get(deviceID);
    if (!d || !d.cam || t - d.t > this.o.deviceStaleMs) return [];
    const blockers = this.blockers();
    const out = [];
    for (const e of this.entities.values()) {
      if (!this.reportValid(e, t)) continue; // unbounded age is diagnostic only
      const mine = e.sources.get(deviceID);
      if (mine && t - mine.t + mine.uncertaintyMs <= this.holdFor(deviceID)) continue;                    // this phone sees it itself
      const others = this.observers(e, t).filter(id => id !== deviceID);
      const kind = e.state === 'observed' && others.length ? 'seen'
        : e.state === 'hidden' && e.info.dyn && (e.reason === 'occluded' || e.reason === 'outOfView') ? 'estimated' : null;
      if (!kind) continue;
      const rel = sightRelation(d.cam, d.fov, this.o.rangeM, this.target(e), this.walls, blockers);
      // Beyond 8 m only what moves fast enough to matter soon (a vehicle at 15 m and 10 m/s is 1.5 s away).
      // Beyond this phone's detection range it is, for this phone, simply out of view.
      const fastFar = e.info.dyn && this.speed(e) >= 2 && rel.distance <= 25;
      if (rel.relation === 'outOfRange' && fastFar) rel.relation = 'outOfView';
      if (rel.relation !== 'occluded' && rel.relation !== 'outOfView') continue;
      if (rel.distance > 8 && !fastFar) continue;
      out.push({
        id: e.id, kind, label: e.label, position: { x: round(this.pos(e).x), y: round(e.y), z: round(this.pos(e).z) },
        velocity: e.hits >= 3 && t - e.first >= 200 ? { x: round(e.ax.v), z: round(e.az.v) } : null,
        velocitySigma: e.hits >= 3 && t - e.first >= 200 ? Math.sqrt(Math.max(e.ax.c22, e.az.c22)) : null, sigma: round(Math.hypot(this.sigma(e), this.o.alignSigmaM)),
        relation: rel.relation, occluder: rel.occluder?.kind ?? null, seenBy: others.length,
        localID: mine && t - mine.t <= 10000 ? mine.localID : null, moving: this.speed(e) > 0.3,
        ageUncertaintyMs: Number.isFinite(e.ageUncertaintyMs) ? e.ageUncertaintyMs : null,
        distance: round(rel.distance), ageMs: Math.max(0, Math.round(t - e.lastObs)),
        exit: e.exit ? { x: round(e.exit.x), z: round(e.exit.z), inMs: Math.round(e.exit.t - t), halfMs: Math.round(e.exit.half) } : undefined,
      });
    }
    // People, animals and vehicles first: they are what changes; then whatever is nearest.
    const rank = a => (classInfo(a.label).dyn ? 0 : 1);
    return out.sort((a, b) => rank(a) - rank(b) || a.distance - b.distance).slice(0, 8);
  }

  /** Floor-level description of each live camera, for the dashboard. */
  cameras(t = this.now) {
    return [...this.devices].map(([id, d]) => ({ id, name: d.name, live: t - d.t <= this.o.deviceStaleMs, tracking: d.tracking,
      cam: d.cam ? [round(d.cam.x), round(d.cam.y), round(d.cam.z), d.cam.yaw == null ? null : round(d.cam.yaw)] : null, fov: d.fov }));
  }

  // ---- internals ----------------------------------------------------------------------------------------------

  distance(e, o) { return Math.hypot(e.ax.p - o.position.x, e.az.p - o.position.z); }
  speed(e) { return Math.hypot(e.ax.v, e.az.v); }
  /** Velocity significantly different from zero: above minMovingSpeed and above two standard deviations. */
  moving(state) {
    const v = Math.hypot(state.ax.v, state.az.v), sv = Math.sqrt(Math.max(state.ax.c22, state.az.c22, 0));
    return v >= this.o.minMovingSpeed && v >= 2 * sv;
  }
  sigma(e) {
    if (e.cloud && e.state !== 'observed') return e.cloud.stats().sigma;
    return Math.sqrt(Math.max(e.ax.c11, e.az.c11));
  }
  measurementVariance(o) { const s = Math.max(o.sigma ?? 0.3, 0.05); return s * s + this.o.alignSigmaM ** 2; }
  jumpLimit(e) {
    const base = e.info.dyn ? this.o.maxJumpDynamicM : this.o.maxJumpStaticM;
    return e.state === 'hidden' && e.info.dyn ? Math.min(base + 2 * this.sigma(e), 3.5) : base;
  }
  /** Where it is believed to be: the measured state, or the centre of its cloud while hidden. */
  pos(e) {
    if (e.cloud && e.state !== 'observed' && !e.cloud.empty) { const c = e.cloud.stats(); return { x: c.x, z: c.z }; }
    return { x: e.ax.p, z: e.az.p };
  }
  target(e) { const p = this.pos(e); return { id: e.id, x: p.x, z: p.z, y: e.y, h: e.h, r: Math.max(e.w, 0.2) / 2 }; }
  blockers() {
    const list = [];
    for (const e of this.entities.values()) {
      if (e.state === 'lost' || e.state === 'hidden') continue;        // only things known to be there can hide others
      list.push({ id: e.id, label: e.label, x: e.ax.p, z: e.az.p, y: e.y, h: e.h, r: Math.max(e.w, 0.2) * 0.45, tall: e.h >= 1.2 });
    }
    return list;
  }
  /** How long a measurement counts as "seen now" for one phone: at least observedHoldMs, longer for a slow phone. */
  // The age bound of a measurement already includes one frame interval (time since the hub's last reply), and the
  // next frame arrives one interval later: two intervals plus a margin.
  holdFor(deviceID) { return Math.max(this.o.observedHoldMs, 2.2 * (this.devices.get(deviceID)?.interval ?? 0) + 100); }
  observers(e, t) {
    const out = [];
    for (const [id, s] of e.sources) {
      const d = this.devices.get(id);
      if (d && t - s.t + s.uncertaintyMs <= this.holdFor(id) && t - d.t <= this.o.deviceStaleMs) out.push(id);
    }
    return out;
  }
  event(type, e, extra = {}) {
    this.events.push({ seq: ++this.eventSeq, t: this.now, type, id: e.id, label: e.label, ...extra });
    if (this.events.length > 40) this.events.shift();
  }

  birth(o, deviceID, device, t) {
    const info = classInfo(o.label), r = this.measurementVariance(o);
    const e = {
      id: `W${this.nextID++}`, label: o.label, votes: new Map([[o.label, o.confidence ?? 0.5]]), info,
      ax: new Axis(o.position.x, r, info.dyn ? 1 : 0), az: new Axis(o.position.z, r, info.dyn ? 1 : 0),
      y: o.position.y, h: info.h, w: info.w, first: t, lastObs: t, last: t, hits: 0, sources: new Map(),
      state: 'observed', reason: null, occluder: null, hiddenSince: null, missSince: null, lostAt: null, ambiguous: false,
    };
    this.entities.set(e.id, e);
    this.correct(e, o, deviceID, device, t, true);
    return e;
  }

  correct(e, o, deviceID, device, t, fresh = false) {
    const previous = e.sources.get(deviceID);
    if (o.measuredAt !== undefined && previous?.measuredAt !== undefined && o.measuredAt <= previous.measuredAt) return;
    // Latest possible measurement time on the server timeline; the real time may be earlier by uncertaintyMs.
    const measuredAtServer = t - (o.ageLowerMs ?? 0);
    const uncertaintyMs = o.ageUncertaintyMs === undefined ? 0 : (o.ageUncertaintyMs ?? Infinity);
    const r = this.measurementVariance(o);
    const wasHidden = e.state === 'hidden' || e.state === 'remembered';
    if (!fresh) { e.ax.update(o.position.x, r); e.az.update(o.position.z, r); }
    e.y += (o.position.y - e.y) * 0.3;
    if (o.size) {       // measured apparent size, clamped around the class's nominal size
      const clamp = (v, n) => Math.min(Math.max(v, n * 0.5), n * 1.6);
      if (finiteP(o.size.h)) e.h += (clamp(o.size.h, e.info.h) - e.h) * 0.15;
      if (finiteP(o.size.w)) e.w += (clamp(o.size.w, e.info.w) - e.w) * 0.15;
    }
    e.votes.set(o.label, (e.votes.get(o.label) ?? 0) + (o.confidence ?? 0.5));
    let best = e.label, score = -1;
    for (const [l, s] of e.votes) if (s > score) { best = l; score = s; }
    if (best !== e.label) { e.label = best; e.info = classInfo(best); }
    e.sources.set(deviceID, { localID: o.id, t: measuredAtServer, uncertaintyMs, measuredAt: o.measuredAt, name: device.name });
    this.bindings.set(`${deviceID}|${o.id}`, e.id);
    e.hits++;
    if (fresh || measuredAtServer >= e.lastObs) { e.lastObs = measuredAtServer; e.ageUncertaintyMs = uncertaintyMs; }
    e.receivedAt = t; e.missSince = null; e.lostAt = null;
    e.base = { ax: { ...e.ax }, az: { ...e.az }, t };
    e.barrierConflict = false; e.excessiveGap = false;
    this.invalidations.delete(e.id); this.invalidations.delete(`${deviceID}|${o.id}`);
    if (wasHidden && e.info.dyn) this.event('reacquired', e, { by: device.name });
    e.state = 'observed'; e.reason = null; e.occluder = null; e.hiddenSince = null; e.announcedHidden = false; e.exit = null;
    e.cloud = null;
  }

  reportInvalidation(e, t) {
    if (e.state === 'lost') return this.invalidations.get(e.id) ?? e.reason;
    if (e.reason === 'unconfirmed') return 'unconfirmed';
    if (e.reason === 'noCamera') return 'missingPose';
    if (!Number.isFinite(e.ageUncertaintyMs)) return 'unknownAge';
    if (t - e.lastObs + e.ageUncertaintyMs > this.o.hiddenMaxMs) return 'age';
    if (this.sigma(e) > this.o.hiddenMaxSigmaM) return 'uncertainty';
    return null;
  }

  reportValid(e, t) { return this.reportInvalidation(e, t) === null; }

  advance(t) {
    if (!Number.isFinite(t) || t <= this.now) return;
    for (const e of this.entities.values()) {
      // Re-evaluate from the last correction, so even expiration/collision diagnostics are independent of tick rate.
      const dt = (t - e.base.t) / 1000;
      e.last = t;
      if (dt <= 0) continue;
      if (dt > 30) { e.excessiveGap = true; continue; }
      Object.assign(e.ax, e.base.ax); Object.assign(e.az, e.base.az);
      const acc2 = e.info.acc * e.info.acc;
      if (!e.info.dyn) {
        e.ax.c11 += acc2 * dt; e.az.c11 += acc2 * dt;
        continue;
      }
      const density = acc2 * Math.max(this.o.noiseObserved, this.o.noiseHidden);
      e.ax.predict(dt, density); e.az.predict(dt, density);
      // Someone standing still has a velocity estimate that is never exactly zero; moving them by it makes still
      // people drift. Motion is applied only when it is significant; otherwise only the uncertainty grows.
      if (!this.moving(e.base)) { e.ax.p = e.base.ax.p; e.az.p = e.base.az.p; }
      const moved = moveWithWalls(e.base.ax.p, e.base.az.p, e.ax.p - e.base.ax.p, e.az.p - e.base.az.p, this.walls, e.y);
      e.barrierConflict = !!moved.hit;
      // This is only the last admissible diagnostic position, never a report of a stopped/turning object.
      if (moved.hit) { e.ax.p = moved.x; e.az.p = moved.z; }
      if (e.cloud) e.cloud.advanceTo(t, this.walls);
    }
    this.now = t;
  }

  classify(t, hasNewFrame = false) {
    const live = [...this.devices].filter(([, d]) => d.cam && d.tracking && t - d.t <= this.o.deviceStaleMs);
    const blockers = this.blockers();
    for (const e of [...this.entities.values()]) {
      const age = t - e.lastObs;
      if (e.info.dyn && age > this.o.hiddenMaxMs + this.o.lostHoldMs) { this.remove(e); continue; }
      if (!e.info.dyn && age > this.o.staticMemoryMs) { this.invalidations.set(e.id, 'age'); this.remove(e); continue; }
      if (e.excessiveGap) { this.lose(e, t, 'excessiveGap'); continue; }
      // A hidden mover with a cloud: the phones looked everywhere it could have gone and it was not there.
      if (e.cloud && e.state === 'hidden' && (e.cloud.empty || e.cloud.mass < this.o.cloudMinMass)) {
        this.lose(e, t, e.exit ? 'missedExit' : 'notThere'); continue;
      }
      if (e.barrierConflict && !e.cloud) { this.lose(e, t, 'barrierConflict'); continue; }
      if (e.cloud && e.state === 'hidden' && this.sigma(e) > this.o.cloudMaxSigmaM) {
        // Past its expected exit and still not seen: the honest reason is that it did not come out where expected.
        this.lose(e, t, e.exit && t > e.exit.t + e.exit.half ? 'missedExit' : 'uncertainty'); continue; }
      if (!e.cloud && this.sigma(e) > this.o.hiddenMaxSigmaM) { this.lose(e, t, 'uncertainty'); continue; }
      if (age > this.o.hiddenMaxMs && e.info.dyn) { this.lose(e, t, 'age'); continue; }
      if (e.state === 'lost') continue;
      const seenBy = this.observers(e, t);
      if (seenBy.length) {
        // Handoff bookkeeping: a phone that was tracking it has lost it behind something while another still sees it.
        for (const [id, s] of e.info.dyn ? e.sources : []) {
          if (seenBy.includes(id) || s.handed || t - s.t > 2500 || t - s.t + s.uncertaintyMs <= this.holdFor(id)) continue;
          const d = this.devices.get(id);
          if (!d?.cam) continue;
          const rel = sightRelation(d.cam, d.fov, this.o.rangeM, this.target(e), this.walls, blockers);
          if (rel.relation === 'occluded' || rel.relation === 'outOfView') {
            s.handed = true;
            this.event('handoff', e, { from: d.name, to: this.devices.get(seenBy[0])?.name, relation: rel.relation, occluder: rel.occluder?.kind ?? null });
          }
        }
        for (const id of seenBy) e.sources.get(id).handed = false;
        e.state = 'observed'; e.reason = null; this.invalidations.delete(e.id);
        continue;
      }
      if (!live.length) { e.state = e.info.dyn ? 'hidden' : 'remembered'; e.reason = 'noCamera'; this.invalidations.set(e.id, 'missingPose'); continue; }

      let visible = false, occluded = null, lastOwner = null, lastT = -Infinity;
      for (const [id, s] of e.sources) if (s.t > lastT) { lastT = s.t; lastOwner = id; }
      for (const [id, d] of live) {
        const rel = sightRelation(d.cam, d.fov, this.o.rangeM, this.target(e), this.walls, blockers);
        if (rel.relation === 'visible') visible = true;
        else if ((rel.relation === 'occluded' || rel.relation === 'partial') && (!occluded || id === lastOwner)) occluded = rel.occluder ?? { kind: 'object' };
      }
      const was = e.state;
      // From the moment a mover is hidden it gets its cloud of possible positions (seeded, so replays are identical).
      if (e.info.dyn && !e.cloud && e.base && was === 'observed') {
        e.cloud = new Cloud(e.label, e.base, e.y, e.id.split('').reduce((h, ch) => (h * 31 + ch.charCodeAt(0)) | 0, e.hits), {}, !this.moving(e.base));
        e.cloud.advanceTo(t, this.walls);
      }
      if (visible && e.cloud) {
        // The centre of the cloud is in plain view and it is not there: said as "unconfirmed". It is not dropped here:
        // the frames prune the cloud, and what survives is where it can still be.
        e.state = 'hidden'; e.reason = 'unconfirmed'; e.occluder = null; this.invalidations.set(e.id, 'unconfirmed');
        if (was === 'observed') e.hiddenSince = t;
        continue;
      }
      if (visible) {
        // In a camera's clear view, yet not detected: tolerate a short detector dropout, then stop claiming it.
        e.state = e.info.dyn ? 'hidden' : 'remembered'; e.reason = 'unconfirmed'; e.occluder = null;
        this.invalidations.set(e.id, 'unconfirmed');
        // A render tick is not new negative evidence. Only a received frame can confirm absence.
        // It was expected to come out from behind something and the place is now in plain view, empty: it stopped or
        // turned back there. Said as such ("did not come out where expected"), never as "gone".
        if (hasNewFrame && age > (e.info.dyn ? this.o.missGraceMs : this.o.staticMissMs)) { this.lose(e, t, e.exit ? 'missedExit' : 'unconfirmed'); continue; }
      } else {
        e.missSince = null;
        e.state = e.info.dyn ? 'hidden' : 'remembered';
        e.reason = occluded ? 'occluded' : 'outOfView'; e.occluder = occluded; this.invalidations.delete(e.id);
      }
      if (was === 'observed') e.hiddenSince = t;
      // Where and when it should come out from behind what hides it (the car under the bridge), from where the phone
      // that was following it stands. Recomputed twice a second: the phone moves too.
      if (e.info.dyn && e.reason === 'occluded' && e.base && this.moving(e.base)) {
        if (!e.exit || t - e.exit.at >= 500) e.exit = this.exitWindow(e, lastOwner, t, blockers) ?? (e.exit && t <= e.exit.t + e.exit.half ? e.exit : null);
      } else if (e.reason !== 'unconfirmed') e.exit = null;
      if (e.info.dyn && e.reason !== 'unconfirmed' && !e.announcedHidden) { e.announcedHidden = true; this.event('hidden', e, { reason: e.reason, occluder: e.occluder?.kind ?? null }); }
    }
  }

  /**
   * First point along the straight, constant-velocity path where `deviceID` would see the object again, and the time
   * window around it (two standard deviations of position at that time, turned into time by the speed).
   * Null when the path meets a wall first or stays hidden for as long as the estimate is kept.
   */
  exitWindow(e, deviceID, t, blockers) {
    const d = this.devices.get(deviceID);
    if (!d?.cam) return null;
    const vx = e.base.ax.v, vz = e.base.az.v, speed = Math.hypot(vx, vz), others = blockers.filter(b => b.id !== e.id);
    const horizon = Math.min((this.o.hiddenMaxMs - (t - e.lastObs)) / 1000, 8);
    for (let s = 0.1; s <= horizon; s += 0.1) {
      if (moveWithWalls(e.ax.p, e.az.p, vx * s, vz * s, this.walls, e.y).hit) return null;
      const x = e.ax.p + vx * s, z = e.az.p + vz * s;
      const rel = sightRelation(d.cam, d.fov, this.o.rangeM, { id: e.id, x, z, y: e.y, h: e.h, r: Math.max(e.w, 0.2) / 2 }, this.walls, others);
      if (rel.relation !== 'visible') continue;
      const a = e.ax.c11 >= e.az.c11 ? e.ax : e.az;
      const sigma = Math.sqrt(Math.max(a.c11 + 2 * s * a.c12 + s * s * a.c22, 0));
      return { at: t, t: t + s * 1000, x, z, half: Math.min(Math.max(2 * sigma / speed, 0.3), 2) * 1000 };
    }
    return null;
  }

  lose(e, t, why) {
    if (!e.info.dyn) { this.invalidations.set(e.id, why); this.remove(e); return; }
    const newlyLost = e.state !== 'lost';
    e.state = 'lost'; e.reason = why; e.lostAt ??= t; this.invalidations.set(e.id, why);
    if (newlyLost) this.event('lost', e, { reason: why });
  }

  remove(e) {
    this.entities.delete(e.id);
    for (const [k, v] of this.bindings) if (v === e.id) this.bindings.delete(k);
  }

  /** Two phones can start a track for the same object before alignment noise lets them associate. Oldest ID wins. */
  merge() {
    const list = [...this.entities.values()].filter(e => e.state === 'observed');
    for (let i = 0; i < list.length; i++) for (let j = i + 1; j < list.length; j++) {
      const a = list[i], b = list[j];
      if (!this.entities.has(a.id) || !this.entities.has(b.id) || !compatible(a.label, b.label)) continue;
      if ([...a.sources.keys()].some(id => b.sources.has(id) && this.now - b.sources.get(id).t <= this.o.observedHoldMs
          && this.now - a.sources.get(id).t <= this.o.observedHoldMs)) continue;   // one phone sees both: two objects
      if (Math.hypot(a.ax.p - b.ax.p, a.az.p - b.az.p) > this.o.mergeRadiusM) continue;
      if (a.info.dyn && Math.hypot(a.ax.v - b.ax.v, a.az.v - b.az.v) > 1.0) continue;
      const [keep, drop] = a.first <= b.first ? [a, b] : [b, a];
      for (const [id, s] of drop.sources) if (!keep.sources.has(id) || keep.sources.get(id).t < s.t) keep.sources.set(id, s);
      for (const [k, v] of this.bindings) if (v === drop.id) this.bindings.set(k, keep.id);
      keep.hits += drop.hits;
      this.entities.delete(drop.id);
    }
  }

  forecast(e) {
    const out = []; let x = e.ax.p, z = e.az.p, vx = e.ax.v, vz = e.az.v, prev = 0;
    for (const s of this.o.forecastS) {
      const dt = s - prev; prev = s;
      const m = moveWithWalls(x, z, vx * dt, vz * dt, this.walls, e.y);
      x = m.x; z = m.z;
      out.push(round(x), round(z));
      if (m.hit) break;
    }
    return out;
  }
}

const round = n => Math.round(n * 1000) / 1000;
const finiteP = n => typeof n === 'number' && Number.isFinite(n) && n > 0;
