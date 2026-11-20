// Where a hidden mover can be: a cloud of possible positions (a particle filter), not a single point.
//
// The car under the bridge, the person behind the door: from the moment it disappears, each particle is one
// possible "it" — starting from the last measured position and velocity with their uncertainty — and moves on:
//   * at its own velocity, which changes a little (people slow down, stop, turn), never beyond a top speed;
//   * a measured wall stops it (it is not crossed);
//   * when a phone looks at a place and does NOT see it there, the particles in that place are removed.
// What is left is where it can still be: behind the bridge pier, behind the couch, past the door. Its spread grows
// with time. When almost nothing is left, it is not where it could have gone: said as such, never as "all clear".

import { moveWithWalls } from './geometry.mjs';

/** Top speed and how quickly velocity can change (random walk, m/s per √s), by kind of mover. */
const KIND = {
  person: { vmax: 2.5, acc: 0.25 },
  car: { vmax: 20, acc: 1.2 }, truck: { vmax: 16, acc: 0.9 }, bus: { vmax: 14, acc: 0.8 }, motorcycle: { vmax: 22, acc: 1.5 },
  bicycle: { vmax: 9, acc: 0.8 }, skateboard: { vmax: 6, acc: 0.8 },
  dog: { vmax: 6, acc: 1.0 }, cat: { vmax: 5, acc: 1.0 },
};
const DEFAULT = { vmax: 3, acc: 0.6 };

export const CLOUD_DEFAULTS = {
  n: 150,               // particles
  step: 0.1,            // s: propagation step
  resampleBelow: 40,    // particles: below this the survivors are resampled back to n (mass is kept separately)
  stillVelocitySigma: 0.25,   // m/s: velocity spread at the start for something that was standing still
};

export class Cloud {
  /** base: {ax, az, t} Kalman state at the last measurement (ms); seed makes it reproducible. */
  /** still: its velocity was not significant at the last measurement. It then starts at rest with a modest
   *  velocity spread (measurement jitter is not motion); it can still start walking (random walk on velocity). */
  constructor(label, base, y, seed, options = {}, still = false) {
    this.o = { ...CLOUD_DEFAULTS, ...options };
    this.kind = KIND[label] ?? DEFAULT;
    this.rand = mulberry32(seed);
    this.t = base.t; this.y = y;
    this.mass = 1;             // probability, under the model, that it is still somewhere the phones did not look
    this.p = [];
    const at = a => still ? { ...a, v: 0, c12: 0, c22: Math.min(a.c22, this.o.stillVelocitySigma ** 2) } : a;
    for (let i = 0; i < this.o.n; i++) {
      const [px, vx] = this.draw(at(base.ax)), [pz, vz] = this.draw(at(base.az));
      this.p.push(this.cap({ x: px, z: pz, vx, vz }));
    }
  }

  /** Position and velocity from one axis' Gaussian, with their correlation. */
  draw(a) {
    const s1 = Math.sqrt(Math.max(a.c11, 0)), s2 = Math.sqrt(Math.max(a.c22, 0));
    const rho = s1 > 0 && s2 > 0 ? Math.max(-1, Math.min(1, a.c12 / (s1 * s2))) : 0;
    const n1 = this.gauss(), n2 = this.gauss();
    return [a.p + s1 * n1, a.v + s2 * (rho * n1 + Math.sqrt(1 - rho * rho) * n2)];
  }

  cap(q) {
    const v = Math.hypot(q.vx, q.vz);
    if (v > this.kind.vmax) { q.vx *= this.kind.vmax / v; q.vz *= this.kind.vmax / v; }
    return q;
  }

  /** Moves every particle to time t (ms), in fixed steps so the result does not depend on how often it is called. */
  advanceTo(t, walls) {
    while (this.t + this.o.step * 1000 <= t) {
      const dt = this.o.step, k = this.kind.acc * Math.sqrt(dt);
      for (const q of this.p) {
        q.vx += k * this.gauss(); q.vz += k * this.gauss(); this.cap(q);
        const m = moveWithWalls(q.x, q.z, q.vx * dt, q.vz * dt, walls, this.y);
        q.x = m.x; q.z = m.z;
        if (m.hit) { q.vx = 0; q.vz = 0; }            // a wall stops it; it is not crossed
      }
      this.t += this.o.step * 1000;
    }
  }

  /**
   * A phone looked and did not see it: particles it would have seen are removed. Detector misses are handled by the
   * caller (grace period, and at most a few prunings per second: consecutive frames are not independent evidence).
   * The cloud ends empty only when every place it could be has been seen empty.
   */
  prune(isVisible) {
    const before = this.p.length;
    this.p = this.p.filter(q => !isVisible(q));
    if (!before) return;
    this.mass *= this.p.length / before;
    if (this.p.length && this.p.length < this.o.resampleBelow) {
      const keep = this.p;
      this.p = Array.from({ length: this.o.n }, () => {
        const s = keep[Math.floor(this.rand() * keep.length)];
        return { x: s.x + 0.08 * this.gauss(), z: s.z + 0.08 * this.gauss(), vx: s.vx, vz: s.vz };
      });
    }
  }

  get empty() { return this.p.length === 0; }

  /** Mean position and spread (the larger standard deviation of x and z). */
  stats() {
    const n = this.p.length;
    if (!n) return { x: NaN, z: NaN, sigma: Infinity };
    let x = 0, z = 0;
    for (const q of this.p) { x += q.x; z += q.z; }
    x /= n; z /= n;
    let sx = 0, sz = 0;
    for (const q of this.p) { sx += (q.x - x) ** 2; sz += (q.z - z) ** 2; }
    return { x, z, sigma: Math.sqrt(Math.max(sx, sz) / n) };
  }

  /** A few points for drawing (every k-th particle). */
  sample(count = 60) {
    const k = Math.max(1, Math.floor(this.p.length / count));
    return this.p.filter((_, i) => i % k === 0).map(q => [Math.round(q.x * 100) / 100, Math.round(q.z * 100) / 100]);
  }

  gauss() {
    let u = 0, v = 0;
    while (u === 0) u = this.rand();
    while (v === 0) v = this.rand();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  }
}

function mulberry32(a) {
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
