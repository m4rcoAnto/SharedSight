// Room perimeter of one shared space, built from every wall patch any phone has ever reported.
//
// ARKit reports a wall as small vertical patches that grow, merge into each other (the old anchor disappears, a new
// one takes over), and vanish from a phone's list when its tracking hiccups. Drawing the latest list therefore makes
// walls flicker and never closes a room. Here:
//   1. every patch is REMEMBERED (keyed by phone and anchor), so a merge, a renamed anchor or a tracking hiccup
//      changes nothing that was already seen;
//   2. the room's axes come from the patches themselves (rooms are almost always right-angled), and patches within
//      15° of an axis are snapped to it;
//   3. patches on the same line become one wall line, with the parts actually seen kept as intervals;
//   4. as soon as one wall is known, a closed four-sided perimeter is proposed: each side is placed on the best wall
//      line seen on that side, or — when that side has never been seen — just beyond everything known to be inside
//      the room (floor, phones, the ends of the perpendicular walls). Seen parts are 'wall' (or 'door'/'window');
//      everything else is 'inferred', and is drawn and treated as such: an estimate, never a measurement.
// Only what was measured blocks sight in the world model; inferred sides never do.

import { wallFromPlane } from './geometry.mjs';

export const PERIMETER_DEFAULTS = {
  minPatch: 0.3,          // m: shorter vertical patches are noise
  minWallTop: 1.0,        // m above the floor: a lower vertical surface is furniture (a couch back), not a wall
  raisedStart: 1.5,       // m: a wall patch starting this high is above an opening (door lintel)
  snapDeg: 15,            // patches within this angle of a room axis are snapped to it
  lineTolerance: 0.3,     // m: patches closer than this across their normal are the same wall line
  gapJoin: 0.3,           // m: seen parts closer than this along a line are joined
  margin: 0.3,            // m: an inferred side is placed this far beyond the farthest evidence
  minSide: 1.2,           // m: smallest room dimension proposed
  axisHoldDeg: 6,         // the axes only move when the evidence turns them by more than this
  minSeenWall: 0.8,       // m of wall seen in total before a perimeter is proposed (outdoors: none)
  absorb: 0.8,            // m: a parallel line this close to a side is the same wall (ARKit offset, a wardrobe's front)
  minInterior: 1.0,       // m seen: shorter inside pieces are not drawn as walls (furniture sides, noise)
  passWidth: 0.9,         // m: width of the opening carved where something was seen through a continued wall
  beyond: 0.5,            // m (or 2.5 sigma): how far behind a measured wall an object must be to count as a reflection
  minSideSeen: 0.6,       // m seen on a line before it can be a side of the room
  gapMax: 1.2,            // m: free space must reach a wall without a larger unobserved gap for it to bound the room
  nearWall: 4.0,          // m: a wall this close to where a phone stood bounds its room even before free space is mapped
  strip: 1.0,             // m: half-width of the corridor in which free space is looked for
  cover: 1.0,             // m: a wall line bounds a point if the point lies within its seen extent plus this
  cornerSnap: 0.3,        // m: a perpendicular wall this close to a line's end is the corner where it stops
  insideMaxLen: 2.6,      // m: longest piece that can be an obstacle inside the room (screen, rack, shelf)
  behind: 0.4,            // m: free space this far behind a line (and up to 2.5 m more) makes it an inside obstacle
  minHalf: 0.6,           // m: an inferred side is at least this far from where a phone stood (plus the margin)
  maxVisited: 160,        // most recent phone positions used to find rooms
  minVisits: 3,           // a room needs this many positions in it (one stray position is not a room)
  maxRooms: 6,
  minDiagonal: 1.5,       // m: shorter walls that fit neither room axis are not drawn (open doors, furniture, noise)
  scanCell: 0.25,         // m: depth-scan hits are kept one per cell and direction
  scanHalf: 0.3,          // m: half-width of wall attributed to one scan hit
  scanMinCount: 2,        // a scan cell counts once it was hit in this many scans (a passer-by is not a wall)
  maxPatches: 600, maxPoints: 400,
};

const DEG = Math.PI / 180;
const OPEN = new Set(['door', 'window', 'opening']);   // parts of a wall line that are not solid wall
const q = n => Math.round(n * 20) / 20;           // 5 cm: the resolution at which the perimeter is said to change

export class Perimeter {
  constructor(options = {}) {
    this.o = { ...PERIMETER_DEFAULTS, ...options };
    this.patches = new Map();   // `${device}|${planeID}` -> {ax, az, bx, bz, y0, y1, kind, device}
    this.floors = new Map();    // `${device}|${planeID}` -> {y, points: [[x, z]...]}
    this.points = [];           // phone positions on the floor (inside the room by definition)
    this.passes = [];           // [x, z] where a phone saw something through a continued (not measured) wall,
                                // or where a person/animal was measured walking across a wall line (a doorway)
    this.scan = new Map();      // `${device}|cell|direction` -> {x, z, nx, nz, n}: vertical surfaces hit by depth rays
    this.free = new Map();      // `${device}|cell` -> [x, z]: floor crossed by depth rays (free space, not a wall)
    this.axis = null;
    this.rev = 0; this.signature = ''; this.room = null; this.dirty = false;
  }

  /** Planes of one phone, as received. An empty list (tracking lost, nothing new) forgets nothing. */
  ingest(device, planes, cam = null) {
    for (const p of planes ?? []) {
      const key = `${device}|${p.id}`;
      if (p.vertical) {
        const w = wallFromPlane(p);
        if (!w || Math.hypot(w.bx - w.ax, w.bz - w.az) < this.o.minPatch || w.kind === 'ceiling' || w.kind === 'floor') continue;
        this.patches.set(key, { ...w, device });
        // The phone saw this wall: the space between them is free (a door may hide what is beyond, not what is before).
        if (cam) this.addFreeRay(device, cam, (w.ax + w.bx) / 2, (w.az + w.bz) / 2);
      } else if (p.kind === 'floor' || p.kind == null) {
        const v = p.vertices ?? [];
        if (v.length < 3) continue;
        const y = v.reduce((s, a) => s + a.y, 0) / v.length;
        const step = Math.max(1, Math.floor(v.length / 24));
        this.floors.set(key, { y, kind: p.kind ?? null, points: v.filter((_, i) => i % step === 0).map(a => [a.x, a.z]) });
      }
    }
    if (this.patches.size > this.o.maxPatches) for (const k of [...this.patches.keys()].slice(0, this.patches.size - this.o.maxPatches)) this.patches.delete(k);
    this.dirty = true;
  }

  /**
   * Depth-scan hits of one phone: points where a ray at about chest height met a vertical surface, with the surface's
   * horizontal normal. They show walls metres away long before ARKit has built a plane there.
   */
  ingestScan(device, hits, cam = null) {
    for (const h of hits ?? []) {
      // The ray from the phone to the wall crossed free space: remembered (one point per 0.5 m cell) as evidence
      // that the room reaches that far.
      if (cam && Number.isFinite(h.x) && Number.isFinite(h.z)) this.addFreeRay(device, cam, h.x, h.z);
      const l = Math.hypot(h.nx, h.nz);
      if (!(l > 0.5) || !Number.isFinite(h.x) || !Number.isFinite(h.z)) continue;
      const c = this.o.scanCell, dir = Math.round(((Math.atan2(h.nz, h.nx) / Math.PI * 180) % 180 + 180) % 180 / 15);
      const key = `${device}|${Math.round(h.x / c)}|${Math.round(h.z / c)}|${dir}`, old = this.scan.get(key);
      if (old) { if (++old.n === this.o.scanMinCount) this.dirty = true; }
      else {
        this.scan.set(key, { x: h.x, z: h.z, nx: h.nx / l, nz: h.nz / l, n: 1 });
        if (this.o.scanMinCount <= 1) this.dirty = true;
        if (this.scan.size > 4000) this.scan.delete(this.scan.keys().next().value);
      }
    }
  }

  /** One point of floor known to be free (something stood there). */
  addFree(device, x, z) {
    if (!Number.isFinite(x) || !Number.isFinite(z)) return;
    const key = `${device}|${Math.round(x * 2)}|${Math.round(z * 2)}`;
    if (this.free.has(key)) return;
    this.free.set(key, [x, z]); this.dirty = true;
    if (this.free.size > 3000) this.free.delete(this.free.keys().next().value);
  }

  /** Points every 0.5 m along a free line of sight from a phone to (x, z), stopping 0.3 m short of it. */
  addFreeRay(device, cam, tx, tz) {
    // Only short rays: a wall 5 m away may well have been seen through a doorway, and a ray through a doorway
    // proves nothing about the room on either side of it.
    const d = Math.hypot(tx - cam.x, tz - cam.z);
    if (!(d > 0.8) || d > this.o.nearWall) return;
    for (let t = 0.5; t < d - 0.3; t += 0.5) {
      const x = cam.x + (tx - cam.x) * t / d, z = cam.z + (tz - cam.z) * t / d, key = `${device}|${Math.round(x * 2)}|${Math.round(z * 2)}`;
      if (!this.free.has(key)) { this.free.set(key, [x, z]); this.dirty = true; if (this.free.size > 3000) this.free.delete(this.free.keys().next().value); }
    }
  }

  /** A phone standing somewhere is inside the room. Stored sparsely (one point per 30 cm walked). */
  addPoint(x, z) {
    if (!Number.isFinite(x) || !Number.isFinite(z)) return;
    if (this.points.some(([a, b]) => Math.hypot(a - x, b - z) < 0.3)) return;
    this.points.push([x, z]);
    if (this.points.length > this.o.maxPoints) this.points.shift();
    this.dirty = true;
  }

  /** A phone whose coordinates are no longer valid (new AR session, not marker-aligned): drop what it reported. */
  forgetDevice(device) {
    for (const k of [...this.patches.keys()]) if (k.startsWith(device + '|')) this.patches.delete(k);
    for (const k of [...this.floors.keys()]) if (k.startsWith(device + '|')) this.floors.delete(k);
    for (const k of [...this.scan.keys()]) if (k.startsWith(device + '|')) this.scan.delete(k);
    for (const k of [...this.free.keys()]) if (k.startsWith(device + '|')) this.free.delete(k);
    this.dirty = true;
  }

  /** Recomputes only when something new arrived. `rev` changes only when the result changes by 5 cm or more. */
  update() {
    if (!this.dirty) return this.room;
    this.dirty = false;
    const room = this.compute();
    const signature = JSON.stringify(room);
    if (signature !== this.signature) { this.signature = signature; this.room = room; this.rev++; }
    return this.room;
  }

  floorY() {
    const ys = [...this.floors.values()].filter(f => f.kind === 'floor').map(f => f.y);
    const all = ys.length ? ys : [...this.floors.values()].map(f => f.y);
    if (all.length) return Math.min(...all);
    const walls = [...this.patches.values()];
    return walls.length ? Math.min(...walls.map(w => w.y0)) : 0;
  }

  compute() {
    const floorY = this.floorY();
    // A patch that starts well above the floor is the wall over an opening (a door's lintel): the opening is below it.
    const patches = [...this.patches.values()]
      .map(w => w.kind !== 'door' && w.kind !== 'window' && w.y0 - floorY >= this.o.raisedStart ? { ...w, kind: 'opening' } : w)
      .filter(w => OPEN.has(w.kind) || w.y1 - floorY >= this.o.minWallTop);
    // Depth-scan hits seen more than once are short pieces of wall at their own place and direction.
    for (const h of this.scan.values()) {
      if (h.n < this.o.scanMinCount) continue;
      const tx = -h.nz * this.o.scanHalf, tz = h.nx * this.o.scanHalf;
      patches.push({ ax: h.x - tx, az: h.z - tz, bx: h.x + tx, bz: h.z + tz, y0: floorY, y1: floorY + 2.4, kind: 'wall', scan: true });
    }
    const seen = patches.filter(w => !OPEN.has(w.kind)).reduce((s, w) => s + Math.hypot(w.bx - w.ax, w.bz - w.az), 0);
    if (seen < this.o.minSeenWall) return null;

    // 1. Room axes: length-weighted mean of the wall directions modulo 90°.
    let C = 0, S = 0;
    for (const w of patches) {
      const len = Math.hypot(w.bx - w.ax, w.bz - w.az), a = Math.atan2(w.bz - w.az, w.bx - w.ax);
      C += len * Math.cos(4 * a); S += len * Math.sin(4 * a);
    }
    let axis = Math.atan2(S, C) / 4;
    if (this.axis != null) {
      let d = axis - this.axis; d -= Math.round(d / (Math.PI / 2)) * (Math.PI / 2);
      axis = Math.abs(d) < this.o.axisHoldDeg * DEG ? this.axis : axis;
    }
    this.axis = axis;
    const c = Math.cos(axis), s = Math.sin(axis);
    const toU = (x, z) => x * c + z * s, toV = (x, z) => -x * s + z * c;
    const toXZ = (u, v) => [u * c - v * s, u * s + v * c];
    const passList = this.passes.map(([x, z]) => [toU(x, z), toV(x, z)]), half = this.o.passWidth / 2;

    // 2. Snap patches to the axes: family 0 runs along u (constant v), family 1 along v (constant u).
    const fam = [[], []], diagonal = [];
    for (const w of patches) {
      const a = Math.atan2(w.bz - w.az, w.bx - w.ax) - axis;
      let d = a - Math.round(a / (Math.PI / 2)) * (Math.PI / 2);
      const k = ((Math.round(a / (Math.PI / 2)) % 2) + 2) % 2;
      if (Math.abs(d) > this.o.snapDeg * DEG) { diagonal.push(w); continue; }
      const ua = toU(w.ax, w.az), va = toV(w.ax, w.az), ub = toU(w.bx, w.bz), vb = toV(w.bx, w.bz);
      const len = Math.hypot(w.bx - w.ax, w.bz - w.az);
      if (k === 0) fam[0].push({ off: (va + vb) / 2, s0: Math.min(ua, ub), s1: Math.max(ua, ub), len, kind: w.kind, y1: w.y1 });
      else fam[1].push({ off: (ua + ub) / 2, s0: Math.min(va, vb), s1: Math.max(va, vb), len, kind: w.kind, y1: w.y1 });
    }

    // 3. Lines: patches within lineTolerance across the normal, length-weighted offset; seen intervals joined.
    const lines = fam.map(list => {
      const out = [];
      for (const p of [...list].sort((a, b) => a.off - b.off)) {
        const last = out[out.length - 1];
        if (last && p.off - last.off <= this.o.lineTolerance) {
          last.off = (last.off * last.weight + p.off * p.len) / (last.weight + p.len); last.weight += p.len; last.items.push(p);
        } else out.push({ off: p.off, weight: p.len, items: [p] });
      }
      for (const l of out) {
        l.walls = joined(l.items.filter(p => !OPEN.has(p.kind)), this.o.gapJoin);
        l.openings = l.items.filter(p => OPEN.has(p.kind)).map(p => ({ s0: p.s0, s1: p.s1, kind: p.kind }));
        l.seen = l.walls.reduce((t, i) => t + i.s1 - i.s0, 0);
        l.lo = Math.min(...l.items.map(p => p.s0)); l.hi = Math.max(...l.items.map(p => p.s1));
      }
      return out;
    });

    for (let k = 0; k < 2; k++) lines[k].forEach((l, i) => { l.id = `${k}:${i}`; l.walls = l.walls.flatMap(w => cut({ ...w, kind: 'wall' }, l.openings)); });
    // How far each wall line may be continued: `cover` beyond its seen ends, but never past a corner, i.e. a
    // perpendicular wall that reaches this line (a wall ends where another one meets it).
    for (let k = 0; k < 2; k++) for (const l of lines[k]) {
      const meets = lines[1 - k].filter(m => m.seen >= 0.3 && l.off >= m.lo - this.o.cornerSnap && l.off <= m.hi + this.o.cornerSnap).map(m => m.off);
      const below = meets.filter(o => o <= l.lo + this.o.cornerSnap), above = meets.filter(o => o >= l.hi - this.o.cornerSnap);
      l.coverLo = Math.max(l.lo - this.o.cover, below.length ? Math.max(...below) : -Infinity);
      l.coverHi = Math.min(l.hi + this.o.cover, above.length ? Math.min(...above) : Infinity);
    }

    // 4. Free space actually observed, in (u, v): where phones stood, the floor ARKit found, and points along
    //    depth rays (a ray that met a wall 4 m away crossed 4 m of free space).
    const free = [];
    for (const f of this.floors.values()) if (f.kind === 'floor' || Math.abs(f.y - floorY) < 0.25) for (const [x, z] of f.points) free.push([toU(x, z), toV(x, z)]);
    for (const [x, z] of this.free.values()) free.push([toU(x, z), toV(x, z)]);
    const visited = this.points.map(([x, z]) => [toU(x, z), toV(x, z)]);
    free.push(...visited);
    if (!visited.length) return null;

    // How far free space reaches from (u, v) in one direction, without a gap larger than gapMax, inside a strip.
    const reach = (pu, pv, k, sign) => {
      const ts = [];
      for (const [eu, ev] of free) {
        const along = k === 0 ? eu - pu : ev - pv, t = (k === 0 ? ev - pv : eu - pu) * sign;
        if (Math.abs(along) <= this.o.strip && t >= 0) ts.push(t);
      }
      ts.sort((x, y) => x - y);
      let r = 0;
      for (const t of ts) { if (t - r > this.o.gapMax) break; r = Math.max(r, t); }
      return r;
    };

    // 5. The room around one visited point: in each direction the NEAREST wall line that covers it and that free
    //    space actually reaches (a wall seen 5 m away through a doorway does not bound this room); parallel lines
    //    just beyond it are the same wall. Without such a wall the side is inferred where free space ends.
    const sideFor = (pu, pv, k, sign) => {
      const across = k === 0 ? pv : pu, along = k === 0 ? pu : pv, r = reach(pu, pv, k, sign);
      const cands = lines[k].filter(l => (l.off - across) * sign > 0.15 && l.seen >= this.o.minSideSeen &&
        along >= l.coverLo && along <= l.coverHi).sort((x, y) => (x.off - across) * sign - (y.off - across) * sign);
      // A line with free space observed right behind it (floor, people walking) is an obstacle INSIDE the room
      // (a screen, a drying rack, a shelf), not its boundary: look further.
      // Only short pieces without doors qualify: a long line or one with a doorway is a partition between rooms.
      const beyondFree = l => !l.openings.length && l.walls.length &&
        Math.max(...l.walls.map(w => w.s1)) - Math.min(...l.walls.map(w => w.s0)) <= this.o.insideMaxLen && free.some(([eu, ev]) => {
        const a = k === 0 ? eu - pu : ev - pv, t = ((k === 0 ? ev : eu) - l.off) * sign;
        return Math.abs(a) <= this.o.strip && t >= this.o.behind && t <= this.o.behind + 2.5;
      });
      const near = cands.find(l => !beyondFree(l));
      if (near && (near.off - across) * sign <= Math.max(this.o.nearWall, r + this.o.gapMax)) {
        // Parallel lines within `absorb` of it, on either side, are the same wall (ARKit offset, a wardrobe front).
        const same = lines[k].filter(l => Math.abs(l.off - near.off) <= this.o.absorb && (l.off - across) * sign > 0.15);
        const outer = same.reduce((m, l) => ((l.off - m.off) * sign > 0 && l.seen >= 0.3 ? l : m), near);
        return { off: outer.off, seen: true, key: `L${near.id}`, ids: same.map(l => l.id),
          line: { off: outer.off, walls: joined(same.flatMap(l => l.walls), this.o.gapJoin), openings: same.flatMap(l => l.openings) } };
      }
      return { off: across + sign * (Math.max(r, this.o.minHalf) + this.o.margin), seen: false, key: 'I', line: null, ids: [] };
    };

    // 6. One room per set of visited points that share the same walls. Inferred sides take the farthest free space.
    const groups = new Map();
    const recent = visited.slice(-this.o.maxVisited);
    recent.forEach(([pu, pv], i) => {
      const sides = [sideFor(pu, pv, 0, -1), sideFor(pu, pv, 1, 1), sideFor(pu, pv, 0, 1), sideFor(pu, pv, 1, -1)];   // vLo, uHi, vHi, uLo
      const key = sides.map(x => x.key).join('|');
      const g = groups.get(key);
      if (!g) { groups.set(key, { sides, last: i, n: 1 }); return; }
      g.last = i; g.n++;
      g.sides.forEach((x, j) => { if (!x.seen) x.off = j === 0 || j === 3 ? Math.min(x.off, sides[j].off) : Math.max(x.off, sides[j].off); });
    });
    // Each visited point belongs to the best room that contains it (most sides actually seen, then most visits):
    // fragments made near a wall not yet reached dissolve into the room they are part of.
    const all = [...groups.values()];
    const box = g => { const [vLo, uHi, vHi, uLo] = g.sides; return { u0: uLo.off, u1: uHi.off, v0: vLo.off, v1: vHi.off }; };
    const score = g => g.sides.filter(x => x.seen).length * 1000 + g.n;
    const contains = (g, [u, v]) => { const b = box(g); return u >= b.u0 - 0.05 && u <= b.u1 + 0.05 && v >= b.v0 - 0.05 && v <= b.v1 + 0.05; };
    const ranked = [...all].sort((a, b) => score(b) - score(a));
    for (const g of all) g.members = 0;
    let current = null;
    recent.forEach((pt, i) => {
      const best = ranked.find(g => contains(g, pt));
      if (!best) return;
      best.members++;
      if (i === recent.length - 1) current = best;
    });
    const keep = all.filter(g => g === current || g.members >= this.o.minVisits)
      .filter((g, _, list) => g === current || !list.some(h => h !== g && score(h) > score(g) && (() => {      // nested in a better room
        const a = box(g), b = box(h); return a.u0 >= b.u0 - 0.1 && a.u1 <= b.u1 + 0.1 && a.v0 >= b.v0 - 0.1 && a.v1 <= b.v1 + 0.1;
      })()))
      .sort((a, b) => (a === current ? -1 : b === current ? 1 : b.last - a.last)).slice(0, this.o.maxRooms);

    const describe = (s, along0, along1, constIsV) => {
      const parts = [], seenParts = [];
      if (s.line) {
        // Where a phone saw through this side, or someone was measured walking through it, there is an opening,
        // whatever was continued or measured there: it is cut out of walls and doors alike.
        const passed = passesOn(constIsV ? 0 : 1, s.off).filter(o => o.s1 > along0 && o.s0 < along1)
          .map(o => ({ s0: Math.max(o.s0, along0), s1: Math.min(o.s1, along1), kind: 'opening' }));
        for (const i of s.line.walls) seenParts.push({ s0: Math.max(i.s0, along0), s1: Math.min(i.s1, along1), kind: 'wall' });
        for (const o of s.line.openings) for (const piece of o.kind === 'door' ? cut(o, passed) : [o])
          seenParts.push({ s0: Math.max(piece.s0, along0), s1: Math.min(piece.s1, along1), kind: o.kind });
        seenParts.push(...passed);
      }
      // A wall seen on a side is a wall along the whole side, corner to corner, until something is seen through it:
      // the parts nobody measured are 'extended' (believed), not 'inferred' (guessed side).
      const gap = s.line ? 'extended' : 'inferred';
      const openings = seenParts.filter(p => p.kind !== 'wall' && p.s1 - p.s0 >= 0.1);
      const walls = seenParts.filter(p => p.kind === 'wall').flatMap(p => cut(p, openings));
      const valid = [...walls, ...openings].filter(p => p.s1 - p.s0 >= 0.1).sort((a, b) => a.s0 - b.s0);
      let cursor = along0;
      for (const p of valid) {
        if (p.s0 > cursor + 0.05) parts.push({ s0: cursor, s1: p.s0, kind: gap });
        const start = Math.max(p.s0, cursor);
        if (p.s1 > start) parts.push({ s0: start, s1: p.s1, kind: p.kind });
        cursor = Math.max(cursor, p.s1);
      }
      if (along1 > cursor + 0.05) parts.push({ s0: cursor, s1: along1, kind: gap });
      return parts.map(p => {
        const [ax, az] = constIsV ? toXZ(p.s0, s.off) : toXZ(s.off, p.s0);
        const [bx, bz] = constIsV ? toXZ(p.s1, s.off) : toXZ(s.off, p.s1);
        return { kind: p.kind, ax: q(ax), az: q(az), bx: q(bx), bz: q(bz) };
      });
    };
    // Recorded passages lying on the line `off` of family k (0: along u, 1: along v), as intervals along it.
    function passesOn(k, off) { return passList.filter(p => Math.abs(p[1 - k] - off) <= 0.35).map(p => ({ s0: p[k] - half, s1: p[k] + half })); }
    const seg = (k, off, s0, s1, kind) => {
      const [ax, az] = k === 0 ? toXZ(s0, off) : toXZ(off, s0), [bx, bz] = k === 0 ? toXZ(s1, off) : toXZ(off, s1);
      return { kind, ax: q(ax), az: q(az), bx: q(bx), bz: q(bz) };
    };
    const tops = patches.filter(w => !OPEN.has(w.kind) && !w.scan).map(w => w.y1 - floorY).sort((a, b) => a - b);
    const height = Math.min(Math.max(tops[Math.floor(tops.length / 2)] ?? 2.6, 2.2), 3.2);

    const rooms = keep.map(g => {
      const [vLo, uHi, vHi, uLo] = g.sides;
      const grow = (lo, hi) => {
        const lack = this.o.minSide - (hi.off - lo.off);
        if (lack > 0) { if (!hi.seen) hi.off += lack; else if (!lo.seen) lo.off -= lack; else { lo.off -= lack / 2; hi.off += lack / 2; } }
      };
      grow(vLo, vHi); grow(uLo, uHi);
      const sides = [
        ...describe(vLo, uLo.off, uHi.off, true), ...describe(uHi, vLo.off, vHi.off, false),
        ...describe(vHi, uLo.off, uHi.off, true), ...describe(uLo, vLo.off, vHi.off, false),
      ];
      // Inside walls: other seen lines strictly inside this room, clipped to it (a partition, a wardrobe back).
      const used = new Set(g.sides.flatMap(x => x.ids)), interior = [];
      const box = [[uLo.off, uHi.off], [vLo.off, vHi.off]];
      for (let k = 0; k < 2; k++) for (const l of lines[k]) {
        const [a0, a1] = box[k], [c0, c1] = box[1 - k];
        if (used.has(l.id) || l.seen < this.o.minInterior || l.off <= c0 + this.o.lineTolerance || l.off >= c1 - this.o.lineTolerance) continue;
        const passed = passesOn(k, l.off);
        for (const w of l.walls.flatMap(w => cut(w, passed))) { const s0 = Math.max(w.s0, a0), s1 = Math.min(w.s1, a1); if (s1 - s0 >= 0.3) interior.push(seg(k, l.off, s0, s1, 'wall')); }
        for (const o of l.openings.flatMap(o => o.kind === 'door' ? cut(o, passed) : [o])) { const s0 = Math.max(o.s0, a0), s1 = Math.min(o.s1, a1); if (s1 - s0 >= 0.3) interior.push(seg(k, l.off, s0, s1, o.kind)); }
        for (const o of passed) { const s0 = Math.max(o.s0, a0), s1 = Math.min(o.s1, a1); if (s1 - s0 >= 0.3) interior.push(seg(k, l.off, s0, s1, 'opening')); }
      }
      for (const w of diagonal) {
        if (OPEN.has(w.kind) || w.scan || Math.hypot(w.bx - w.ax, w.bz - w.az) < this.o.minDiagonal) continue;
        const inA = [[w.ax, w.az], [w.bx, w.bz]].every(([x, z]) => { const u = toU(x, z), v = toV(x, z); return u > uLo.off && u < uHi.off && v > vLo.off && v < vHi.off; });
        if (inA) interior.push({ kind: 'wall', ax: q(w.ax), az: q(w.az), bx: q(w.bx), bz: q(w.bz) });
      }
      const corners = [toXZ(uLo.off, vLo.off), toXZ(uHi.off, vLo.off), toXZ(uHi.off, vHi.off), toXZ(uLo.off, vHi.off)].map(([x, z]) => [q(x), q(z)]);
      return { corners, sides, interior, seenSides: g.sides.filter(x => x.seen).length };
    });
    return { axisDeg: Math.round(axis / DEG * 10) / 10, floorY: q(floorY), height: q(height), ...rooms[0], rooms };
  }

  /**
   * A phone at (cx, cz) measured something at (px, pz). Physically, it cannot see through a wall:
   *   'reflection'  the point is more than `beyond` behind a MEASURED wall (a mirror, a glossy door): reject it;
   *   'passThrough' it is behind a CONTINUED wall: that part is in fact open (a doorway nobody measured) — remembered;
   *   'ok'          nothing in between.
   * Only applied when the phone itself is inside the perimeter; windows never block.
   */
  sight(cx, cz, px, pz, sigma = 0) {
    const r = this.room;
    if (!r || !(r.rooms ?? [r]).some(x => insideQuad(x.corners, cx, cz, 0.2))) return 'ok';
    const all = (r.rooms ?? [r]).flatMap(x => [...x.sides, ...x.interior]);
    const d = Math.hypot(px - cx, pz - cz);
    // Someone standing against a wall, measured with error, must never be mistaken for a reflection: the point has
    // to be clearly behind the wall (a mirror image is as far behind the mirror as the person is in front of it).
    const beyond = Math.max(this.o.beyond, 2.5 * sigma), lenient = Math.min(beyond, 0.3);
    if (d <= lenient + 0.05) return 'ok';
    const end = m => { const k = (d - m) / d; return [cx + (px - cx) * k, cz + (pz - cz) * k]; };
    const [sx, sz] = end(Math.min(beyond, d - 0.01)), [lx, lz] = end(lenient);     // stop short of the point
    let verdict = 'ok', hit = null;
    for (const p of all) {
      if (p.kind === 'wall' || p.kind === 'door') {
        if (d > beyond + 0.05 && segCross(cx, cz, sx, sz, p.ax, p.az, p.bx, p.bz) != null) return 'reflection';
      } else if (p.kind === 'extended') {
        const t = segCross(cx, cz, lx, lz, p.ax, p.az, p.bx, p.bz);
        if (t != null) { verdict = 'passThrough'; hit = [cx + (lx - cx) * t, cz + (lz - cz) * t]; }
      }
    }
    if (hit && !this.passes.some(([x, z]) => Math.hypot(x - hit[0], z - hit[1]) < 0.3)) {
      this.passes.push(hit); if (this.passes.length > 200) this.passes.shift();
      this.dirty = true;
    }
    return verdict;
  }

  /**
   * A person or animal was MEASURED at (x0, z0) and shortly after at (x1, z1). If the straight line between the two
   * crosses a wall part (measured, continued, or a door) with both ends clearly on opposite sides, they walked
   * through it: a passage is remembered there and that part becomes an 'opening' at the next update.
   * The margin is larger for measured walls and doors, so that position noise next to a wall never opens it.
   */
  addCrossing(x0, z0, x1, z1) {
    const r = this.room;
    if (!r || ![x0, z0, x1, z1].every(Number.isFinite) || Math.hypot(x1 - x0, z1 - z0) > 2.5) return false;
    let found = false;
    for (const p of (r.rooms ?? [r]).flatMap(x => [...x.sides, ...x.interior])) {
      if (p.kind !== 'wall' && p.kind !== 'door' && p.kind !== 'extended') continue;
      const t = segCross(x0, z0, x1, z1, p.ax, p.az, p.bx, p.bz);
      if (t == null) continue;
      const dx = p.bx - p.ax, dz = p.bz - p.az, len = Math.hypot(dx, dz) || 1, margin = p.kind === 'extended' ? 0.2 : 0.3;
      const side = (x, z) => ((x - p.ax) * dz - (z - p.az) * dx) / len;
      if (Math.abs(side(x0, z0)) < margin || Math.abs(side(x1, z1)) < margin) continue;
      const hit = [x0 + (x1 - x0) * t, z0 + (z1 - z0) * t];
      found = true;
      if (this.passes.some(([x, z]) => Math.hypot(x - hit[0], z - hit[1]) < 0.3)) continue;
      this.passes.push(hit); if (this.passes.length > 200) this.passes.shift();
      this.dirty = true;
    }
    return found;
  }

  /** Measured wall segments (perimeter parts actually seen, and inside walls), for line-of-sight in the world model.
   *  Only measurements hide things: continued ('extended') and guessed ('inferred') parts, and openings, never do. */
  measuredWalls() {
    const r = this.room;
    if (!r) return [];
    const y0 = r.floorY, y1 = r.floorY + r.height;
    return (r.rooms ?? [r]).flatMap(x => [...x.sides, ...x.interior]).filter(p => p.kind === 'wall' || p.kind === 'door' || p.kind === 'window')
      .map((p, i) => ({ id: `perimeter-${i}`, kind: p.kind, ax: p.ax, az: p.az, bx: p.bx, bz: p.bz, y0, y1 }));
  }
}

function segCross(px, pz, qx, qz, ax, az, bx, bz) {
  const rx = qx - px, rz = qz - pz, sx = bx - ax, sz = bz - az, den = rx * sz - rz * sx;
  if (Math.abs(den) < 1e-9) return null;
  const t = ((ax - px) * sz - (az - pz) * sx) / den, u = ((ax - px) * rz - (az - pz) * rx) / den;
  return t > 0 && t < 1 && u >= 0 && u <= 1 ? t : null;
}

/** Point inside a convex quadrilateral, at least `margin` from its edges. */
function insideQuad(c, x, z, margin) {
  let sign = 0;
  for (let i = 0; i < 4; i++) {
    const [ax, az] = c[i], [bx, bz] = c[(i + 1) % 4], len = Math.hypot(bx - ax, bz - az) || 1;
    const cross = ((bx - ax) * (z - az) - (bz - az) * (x - ax)) / len;
    if (Math.abs(cross) < margin) return false;
    const sgn = Math.sign(cross);
    if (sign && sgn !== sign) return false;
    sign = sgn;
  }
  return true;
}

/** Wall interval minus the openings that overlap it. */
function cut(part, openings) {
  let pieces = [part];
  for (const o of openings) pieces = pieces.flatMap(p => o.s1 <= p.s0 || o.s0 >= p.s1 ? [p]
    : [{ ...p, s1: o.s0 }, { ...p, s0: o.s1 }].filter(x => x.s1 - x.s0 > 0.05));
  return pieces;
}

/** Union of intervals along a line, joining parts closer than `gap`. */
function joined(items, gap) {
  const out = [];
  for (const i of [...items].sort((a, b) => a.s0 - b.s0)) {
    const last = out[out.length - 1];
    if (last && i.s0 <= last.s1 + gap) last.s1 = Math.max(last.s1, i.s1);
    else out.push({ s0: i.s0, s1: i.s1 });
  }
  return out;
}
