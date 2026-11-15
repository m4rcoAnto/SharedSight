// Low-poly, soft-edged models for every class the detector can name. They are illustrations of the CLASS, scaled
// to the measured height / width when a phone could measure them: never a reconstruction of the real object's shape.
import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { classInfo } from '/shared/classes.mjs';

const geo = new Map();
const cached = (key, make) => { let g = geo.get(key); if (!g) { g = make(); geo.set(key, g); } return g; };
const rbox = (w, h, d, r = 0.04) => cached(`rb${w},${h},${d},${r}`, () => new RoundedBoxGeometry(w, h, d, 3, Math.min(r, w / 2, h / 2, d / 2)));
const cylG = (rt, rb, h, s = 14) => cached(`cy${rt},${rb},${h},${s}`, () => new THREE.CylinderGeometry(rt, rb, h, s));
const sphG = (r, s = 14) => cached(`sp${r},${s}`, () => new THREE.SphereGeometry(r, s, Math.max(8, s - 4)));
const icoG = (r, d = 1) => cached(`ic${r},${d}`, () => new THREE.IcosahedronGeometry(r, d));
const coneG = (r, h, s = 12) => cached(`co${r},${h},${s}`, () => new THREE.ConeGeometry(r, h, s));
const torG = (r, t) => cached(`to${r},${t}`, () => new THREE.TorusGeometry(r, t, 8, 20));

class Kit {
  constructor() { this.group = new THREE.Group(); this.mats = new Map(); }
  mat(color) {
    let m = this.mats.get(color);
    if (!m) { m = new THREE.MeshLambertMaterial({ color }); this.mats.set(color, m); }
    return m;
  }
  add(geometry, color, x = 0, y = 0, z = 0, parent = this.group) {
    const mesh = new THREE.Mesh(geometry, this.mat(color));
    mesh.position.set(x, y, z); mesh.castShadow = true; mesh.receiveShadow = true; parent.add(mesh); return mesh;
  }
  box(w, h, d, color, x, y, z, r, parent) { return this.add(rbox(w, h, d, r), color, x, y, z, parent); }
  cyl(rt, rb, h, color, x, y, z, parent) { return this.add(cylG(rt, rb, h), color, x, y, z, parent); }
  sph(r, color, x, y, z, parent) { return this.add(sphG(r), color, x, y, z, parent); }
  pivot(x, y, z, parent = this.group) { const g = new THREE.Group(); g.position.set(x, y, z); parent.add(g); return g; }
}

// Palette close to the reference illustration: cream upholstery, maroon accent, dark wood, terracotta, leaf green.
const P = { cream: 0xefe6d2, creamDark: 0xe2d6bd, maroon: 0x7b3a3c, wood: 0x5a3b29, woodDark: 0x3d2a20, ink: 0x2b2a2e, metal: 0x8d9299,
  leaf: 0x3f8050, leafDark: 0x2f6a43, terracotta: 0xe9b9a2, white: 0xf7f4ee, glass: 0xbfd3dc, skin: [0xf0c7a4, 0xd9a47c, 0xb07b54, 0x8a5a3c],
  cloth: [0x6c8fb3, 0xd98b6a, 0x7fae8c, 0xc9a54c, 0x9a83b8, 0xcf6f7f, 0x5f9aa0, 0xe3b98a], steel: 0xc9cdd2, red: 0xc8483f, yellow: 0xe7b93e, blue: 0x5b87b8 };
const pick = (list, seed) => list[Math.abs(seed) % list.length];
const hash = s => { let h = 0; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) | 0; return h; };

function person(k, seed) {
  const skin = pick(P.skin, seed), shirt = pick(P.cloth, seed >> 2), pants = pick([0x39424e, 0x4a4038, 0x2f3a4d, 0x555a60], seed >> 4);
  const parts = { legs: [], arms: [] };
  for (const s of [-1, 1]) {
    const hip = k.pivot(s * 0.1, 0.86, 0); k.cyl(0.075, 0.065, 0.82, pants, 0, -0.41, 0, hip); k.box(0.11, 0.07, 0.22, P.ink, 0, -0.83, 0.04, 0.03, hip); parts.legs.push(hip);
    const shoulder = k.pivot(s * 0.25, 1.4, 0); k.cyl(0.055, 0.048, 0.58, shirt, 0, -0.27, 0, shoulder); k.sph(0.055, skin, 0, -0.58, 0, shoulder); parts.arms.push(shoulder);
  }
  k.box(0.4, 0.62, 0.24, shirt, 0, 1.15, 0, 0.1);
  k.cyl(0.05, 0.055, 0.08, skin, 0, 1.49, 0);
  k.sph(0.13, skin, 0, 1.61, 0);
  const hair = k.add(sphG(0.137), pick([0x2b2220, 0x4a3323, 0x6b4a2a, 0x1e1e22, 0x8a6a3c], seed >> 6), 0, 1.635, -0.015); hair.scale.set(1, 0.82, 1);
  k.group.userData.walk = (phase, amount) => {
    const a = Math.sin(phase) * 0.55 * amount;
    parts.legs[0].rotation.x = a; parts.legs[1].rotation.x = -a; parts.arms[0].rotation.x = -a * 0.8; parts.arms[1].rotation.x = a * 0.8;
  };
  k.group.userData.stride = 1.4;
}

function quadruped(k, o) {
  // o: len, bodyH, legH, width, color, head, neck (length), ears: 'up'|'down'|'none', tail, snout, extra
  const y = o.legH + o.bodyH / 2, legs = [];
  k.box(o.width, o.bodyH, o.len, o.color, 0, y, 0, Math.min(o.bodyH, o.width) * 0.45);
  for (const sx of [-1, 1]) for (const sz of [-1, 1]) {
    const p = k.pivot(sx * o.width * 0.32, o.legH + 0.02, sz * o.len * 0.36);
    k.cyl(o.width * 0.14, o.width * 0.11, o.legH, o.legColor ?? o.color, 0, -o.legH / 2, 0, p); legs.push(p);
  }
  const neck = k.pivot(0, y + o.bodyH * 0.25, o.len / 2 - o.width * 0.15);
  neck.rotation.x = -(o.neckTilt ?? 0.5);
  if (o.neck > 0.05) k.cyl(o.width * 0.22, o.width * 0.27, o.neck, o.color, 0, o.neck / 2, 0, neck);
  const head = k.pivot(0, o.neck, 0, neck); head.rotation.x = (o.neckTilt ?? 0.5) + 0.15;
  k.box(o.head * 0.85, o.head * 0.8, o.head * 1.15, o.headColor ?? o.color, 0, o.head * 0.2, o.head * 0.35, o.head * 0.3, head);
  if (o.snout) k.box(o.head * 0.5, o.head * 0.4, o.head * 0.6, o.snoutColor ?? o.color, 0, o.head * 0.05, o.head * 1.0, o.head * 0.15, head);
  k.sph(o.head * 0.09, P.ink, 0, o.head * 0.02 + (o.snout ? 0.06 * o.head : 0.1 * o.head), o.head * (o.snout ? 1.3 : 0.93), head);
  for (const s of [-1, 1]) {
    k.sph(o.head * 0.06, P.ink, s * o.head * 0.27, o.head * 0.38, o.head * 0.78, head);
    if (o.ears === 'up') { const e = k.add(coneG(o.head * 0.17, o.head * 0.36, 4), o.earColor ?? o.color, s * o.head * 0.28, o.head * 0.72, o.head * 0.1, head); e.rotation.y = Math.PI / 4; }
    if (o.ears === 'down') { const e = k.box(o.head * 0.16, o.head * 0.5, o.head * 0.32, o.earColor ?? o.color, s * o.head * 0.48, o.head * 0.25, o.head * 0.15, o.head * 0.07, head); e.rotation.z = s * 0.25; }
  }
  let tail = null;
  if (o.tail) { tail = k.pivot(0, y + o.bodyH * 0.3, -o.len / 2); tail.rotation.x = -0.9; k.cyl(o.width * 0.07, o.width * 0.04, o.tail, o.tailColor ?? o.color, 0, o.tail / 2, 0, tail); }
  o.extra?.(k, { y, head, neck });
  k.group.userData.walk = (phase, amount) => {
    const a = Math.sin(phase) * 0.6 * amount;
    legs[0].rotation.x = a; legs[3].rotation.x = a; legs[1].rotation.x = -a; legs[2].rotation.x = -a;
    if (tail) tail.rotation.z = Math.sin(phase * 1.7) * 0.5 * Math.max(amount, 0.25);
  };
  k.group.userData.stride = o.len * 1.1;
}

const ANIMALS = {
  dog: s => ({ len: 0.72, bodyH: 0.24, legH: 0.28, width: 0.24, color: pick([0xb9824f, 0x6b4a34, 0xd9c5a0, 0x3b3532, 0xe7e1d6], s), head: 0.2, neck: 0.12, ears: 'down', earColor: 0x5a3b29, tail: 0.24, snout: true }),
  cat: s => ({ len: 0.42, bodyH: 0.15, legH: 0.14, width: 0.15, color: pick([0x8d8f94, 0xd8904f, 0x33302e, 0xe9e2d4], s), head: 0.14, neck: 0.04, ears: 'up', tail: 0.3 }),
  horse: () => ({ len: 1.9, bodyH: 0.55, legH: 0.95, width: 0.5, color: 0x8a5a3c, legColor: 0x6b4630, head: 0.42, neck: 0.65, neckTilt: 0.75, ears: 'up', tail: 0.7, tailColor: 0x2b2220, snout: true }),
  zebra: () => ({ len: 1.8, bodyH: 0.5, legH: 0.85, width: 0.46, color: 0xf2efe8, legColor: 0x2b2a2e, head: 0.38, neck: 0.55, neckTilt: 0.75, ears: 'up', tail: 0.5, tailColor: 0x2b2a2e, snout: true, snoutColor: 0x2b2a2e,
    extra: k => { for (let i = -3; i <= 3; i++) k.box(0.47, 0.44, 0.07, 0x2b2a2e, 0, 1.1, i * 0.24, 0.03); } }),
  cow: () => ({ len: 1.9, bodyH: 0.7, legH: 0.7, width: 0.65, color: 0xf2efe8, head: 0.42, neck: 0.25, neckTilt: 0.2, ears: 'down', earColor: 0x2b2a2e, tail: 0.7, snout: true, snoutColor: 0xe6b3aa,
    extra: k => { k.box(0.66, 0.4, 0.6, 0x2b2a2e, 0, 1.15, -0.3, 0.15); k.box(0.3, 0.3, 0.4, 0x2b2a2e, 0.2, 1.0, 0.5, 0.1); } }),
  sheep: () => ({ len: 0.9, bodyH: 0.5, legH: 0.35, width: 0.5, color: 0xf2eee4, legColor: 0x3d3a37, head: 0.24, headColor: 0x3d3a37, neck: 0.1, ears: 'down', earColor: 0x3d3a37, tail: 0 }),
  bear: () => ({ len: 1.5, bodyH: 0.75, legH: 0.45, width: 0.75, color: 0x5a4234, head: 0.45, neck: 0.1, neckTilt: 0.2, ears: 'up', tail: 0, snout: true, snoutColor: 0x8a6a52 }),
  elephant: () => ({ len: 3.2, bodyH: 1.6, legH: 1.3, width: 1.5, color: 0x9a9ca3, head: 1.0, neck: 0.2, neckTilt: 0.2, ears: 'down', tail: 0.9,
    extra: (k, { head }) => { const t = k.cyl(0.14, 0.09, 1.5, 0x9a9ca3, 0, -0.55, 1.05, head); t.rotation.x = 0.25; } }),
  giraffe: () => ({ len: 1.9, bodyH: 0.7, legH: 1.8, width: 0.6, color: 0xe2b765, legColor: 0xd9aa55, head: 0.42, neck: 2.0, neckTilt: 0.3, ears: 'up', tail: 0.8, snout: true,
    extra: k => { for (const [x, y, z] of [[0.31, 2.2, 0.3], [-0.31, 2.1, -0.4], [0.31, 2.0, -0.6], [-0.31, 2.3, 0.5], [0, 2.52, 0]]) k.sph(0.13, 0x9a6a34, x, y, z); } }),
};

function wheels(k, list, r, w) { for (const [x, z] of list) { const t = k.cyl(r, r, w, P.ink, x, r, z); t.rotation.z = Math.PI / 2; const hub = k.cyl(r * 0.45, r * 0.45, w * 1.05, P.steel, x, r, z); hub.rotation.z = Math.PI / 2; } }

function car(k, seed, o = {}) {
  const c = o.color ?? pick([0x6f9fc8, 0xd9795f, 0xe3c35a, 0x7fb08f, 0xe9e5dc, 0x54585f], seed), L = o.len ?? 4.2, W = o.wid ?? 1.75, H = o.h ?? 1.45;
  k.box(W, H * 0.42, L, c, 0, H * 0.4, 0, 0.16);
  k.box(W * 0.88, H * 0.4, L * (o.cabin ?? 0.52), c, 0, H * 0.78, o.cabinZ ?? -L * 0.04, 0.18);
  k.box(W * 0.9, H * 0.28, L * (o.cabin ?? 0.52) * 0.96, P.glass, 0, H * 0.79, o.cabinZ ?? -L * 0.04, 0.12).scale.set(1.004, 1, 1.01);
  wheels(k, [[-W / 2, L * 0.3], [W / 2, L * 0.3], [-W / 2, -L * 0.3], [W / 2, -L * 0.3]], H * 0.23, 0.22);
  for (const s of [-1, 1]) { k.box(W * 0.2, H * 0.08, 0.05, 0xfff3c4, s * W * 0.32, H * 0.45, L / 2, 0.02); k.box(W * 0.2, H * 0.08, 0.05, P.red, s * W * 0.32, H * 0.45, -L / 2, 0.02); }
}
function longVehicle(k, seed, L, W, H, color, windows = true) {
  k.box(W, H * 0.82, L, color, 0, H * 0.55, 0, 0.2);
  if (windows) { k.box(W * 1.01, H * 0.26, L * 0.86, P.glass, 0, H * 0.68, 0, 0.05); k.box(W * 0.9, H * 0.3, 0.06, P.glass, 0, H * 0.66, L / 2, 0.02); }
  wheels(k, [[-W / 2, L * 0.33], [W / 2, L * 0.33], [-W / 2, -L * 0.33], [W / 2, -L * 0.33]], H * 0.15, 0.3);
}
function twoWheeler(k, seed, motor) {
  const r = motor ? 0.32 : 0.34, L = motor ? 1.4 : 1.05, c = pick([P.red, P.blue, 0x3f8050, 0x333842], seed);
  for (const z of [-L / 2, L / 2]) { const t = k.add(torG(r, motor ? 0.07 : 0.025), P.ink, 0, r + 0.03, z); t.rotation.y = Math.PI / 2; }
  const bar = k.cyl(0.03, 0.03, L * 0.95, c, 0, r + 0.25, 0); bar.rotation.x = Math.PI / 2;
  if (motor) { k.box(0.3, 0.3, 0.7, c, 0, 0.62, 0, 0.1); k.box(0.26, 0.1, 0.55, P.ink, 0, 0.82, -0.15, 0.04); }
  else { const a = k.cyl(0.02, 0.02, 0.6, c, 0, 0.62, -0.15); a.rotation.x = 0.35; k.box(0.12, 0.04, 0.24, P.ink, 0, 0.92, -0.26, 0.02); }
  const fork = k.cyl(0.022, 0.022, 0.7, P.steel, 0, 0.7, L / 2 - 0.1); fork.rotation.x = -0.3;
  const h = k.cyl(0.02, 0.02, 0.5, P.ink, 0, 1.02, L / 2 - 0.2); h.rotation.z = Math.PI / 2;
}

function couch(k) {
  const W = 1.9, D = 0.9;
  k.box(W, 0.2, D, P.creamDark, 0, 0.24, 0, 0.07);
  for (const s of [-1, 1]) { k.box(W * 0.46, 0.2, D * 0.74, P.cream, s * W * 0.235, 0.42, 0.06, 0.09); k.box(W * 0.46, 0.4, 0.24, P.cream, s * W * 0.235, 0.62, -D / 2 + 0.15, 0.1).rotation.x = -0.12; k.box(0.2, 0.36, D, P.cream, s * (W / 2 - 0.1), 0.46, 0, 0.09); }
  for (const x of [-W / 2 + 0.12, W / 2 - 0.12]) for (const z of [-D / 2 + 0.1, D / 2 - 0.1]) k.cyl(0.025, 0.02, 0.14, P.ink, x, 0.07, z);
}
function armchair(k) {
  k.box(0.74, 0.32, 0.74, P.maroon, 0, 0.26, 0, 0.14); k.box(0.74, 0.5, 0.24, P.maroon, 0, 0.6, -0.27, 0.12);
  for (const s of [-1, 1]) k.box(0.2, 0.34, 0.7, P.maroon, s * 0.3, 0.44, 0.02, 0.1);
  k.box(0.44, 0.12, 0.5, 0x8a4446, 0, 0.45, 0.06, 0.06);
}
function table(k) {
  k.box(1.4, 0.07, 0.85, P.wood, 0, 0.72, 0, 0.02); k.box(1.3, 0.05, 0.75, P.woodDark, 0, 0.66, 0, 0.02);
  for (const x of [-0.6, 0.6]) for (const z of [-0.33, 0.33]) k.box(0.08, 0.66, 0.08, P.woodDark, x, 0.33, z, 0.01);
}
function plant(k, seed) {
  const pot = seed % 3 === 0 ? P.white : seed % 3 === 1 ? P.terracotta : 0x3a3b40;
  k.cyl(0.17, 0.12, 0.26, pot, 0, 0.13, 0); k.cyl(0.15, 0.15, 0.02, 0x4a3323, 0, 0.26, 0);
  if (seed % 4 === 3) {      // tall flowering stem
    const stem = k.cyl(0.012, 0.014, 0.75, P.leafDark, 0.02, 0.63, 0); stem.rotation.z = -0.08;
    for (const [x, y] of [[0.05, 0.92], [0.02, 1.0], [0.07, 0.84]]) k.add(icoG(0.045, 0), 0xc23fb3, x, y, 0);
    for (const a of [0.4, -0.5, 2.6]) { const l = k.box(0.09, 0.02, 0.36, P.leaf, Math.sin(a) * 0.14, 0.34, Math.cos(a) * 0.14, 0.01); l.rotation.set(-0.5, a, 0); }
  } else {
    k.cyl(0.022, 0.03, 0.34, P.woodDark, 0, 0.42, 0);
    for (const [x, y, z, r] of [[0, 0.72, 0, 0.2], [0.13, 0.62, 0.05, 0.14], [-0.12, 0.64, -0.06, 0.15], [0.02, 0.6, -0.14, 0.13], [-0.03, 0.86, 0.04, 0.13]])
      k.add(icoG(r, 0), (x + z > 0) ? P.leaf : P.leafDark, x, y, z).rotation.set(x * 9, y * 7, z * 5);
  }
}
function bed(k) {
  k.box(1.6, 0.28, 2.0, P.wood, 0, 0.18, 0, 0.04); k.box(1.5, 0.2, 1.9, P.white, 0, 0.42, 0, 0.08);
  k.box(1.52, 0.1, 1.2, 0x9db3c4, 0, 0.5, 0.33, 0.05); k.box(1.6, 0.75, 0.1, P.wood, 0, 0.5, -1.0, 0.03);
  for (const s of [-1, 1]) k.box(0.55, 0.12, 0.36, P.cream, s * 0.38, 0.57, -0.7, 0.06);
}
function tv(k) { k.box(1.05, 0.6, 0.05, P.ink, 0, 0.36, 0, 0.02); k.box(0.97, 0.52, 0.01, 0x47607a, 0, 0.36, 0.027, 0.005); k.box(0.3, 0.03, 0.2, P.ink, 0, 0.015, 0, 0.01); k.box(0.06, 0.08, 0.04, P.ink, 0, 0.05, 0, 0.01); }
function fridge(k) { k.box(0.7, 1.8, 0.7, P.steel, 0, 0.9, 0, 0.04); k.box(0.66, 0.01, 0.02, 0x8d9299, 0, 1.25, 0.351, 0.004); for (const y of [0.9, 1.5]) k.box(0.03, 0.3, 0.04, 0x8d9299, 0.26, y, 0.37, 0.01); }
function toilet(k) { k.cyl(0.2, 0.15, 0.38, P.white, 0, 0.19, 0.1); k.box(0.42, 0.06, 0.5, P.white, 0, 0.41, 0.08, 0.03); k.box(0.42, 0.36, 0.18, P.white, 0, 0.56, -0.23, 0.04); }
function bench(k) { k.box(1.5, 0.06, 0.42, P.wood, 0, 0.44, 0.04, 0.02); k.box(1.5, 0.34, 0.05, P.wood, 0, 0.7, -0.17, 0.02); for (const x of [-0.62, 0.62]) { k.box(0.06, 0.44, 0.4, P.ink, x, 0.22, 0.04, 0.01); k.box(0.06, 0.45, 0.05, P.ink, x, 0.62, -0.17, 0.01); } }
function appliance(k, w, h, d, door = P.ink) { k.box(w, h, d, P.steel, 0, h / 2, 0, 0.03); k.box(w * 0.8, h * 0.6, 0.02, door, 0, h * 0.48, d / 2, 0.01); }
function pole(k, h, r = 0.04, color = P.metal) { k.cyl(r, r, h, color, 0, h / 2, 0); }

const BUILD = {
  person, couch, chair: armchair, 'dining table': table, 'potted plant': plant, bed, tv, refrigerator: fridge, toilet, bench,
  car, truck: (k, s) => { car(k, s, { color: pick([0xe9e5dc, 0x6f9fc8, 0xd9795f], s), len: 6.5, wid: 2.4, h: 2.8, cabin: 0.25, cabinZ: 2.2 }); k.box(2.3, 1.9, 4.2, 0xe9e5dc, 0, 1.75, -0.9, 0.08); },
  bus: (k, s) => longVehicle(k, s, 10, 2.5, 3.0, pick([0xe7b93e, 0xd9795f, 0x6f9fc8], s)),
  train: (k, s) => longVehicle(k, s, 14, 2.8, 3.5, 0x9aa4ad),
  boat: k => { k.box(2.0, 0.7, 5, P.white, 0, 0.45, 0, 0.3); k.box(1.4, 0.6, 1.6, 0x6f9fc8, 0, 1.0, -0.6, 0.12); },
  airplane: k => { const f = k.cyl(0.9, 0.9, 9, P.white, 0, 1.9, 0); f.rotation.x = Math.PI / 2; k.box(9, 0.14, 1.6, P.white, 0, 1.8, 0.2, 0.06); k.box(3, 0.1, 0.9, P.white, 0, 2.1, -4, 0.04); k.box(0.12, 1.4, 1.1, 0x6f9fc8, 0, 2.9, -4, 0.04); },
  bicycle: (k, s) => twoWheeler(k, s, false), motorcycle: (k, s) => twoWheeler(k, s, true),
  'traffic light': k => { pole(k, 2.4); k.box(0.3, 0.75, 0.24, P.ink, 0, 2.62, 0, 0.04); [[P.red, 2.86], [P.yellow, 2.62], [0x54b36a, 2.38]].forEach(([c, y]) => k.sph(0.08, c, 0, y, 0.1)); },
  'fire hydrant': k => { k.cyl(0.12, 0.14, 0.5, P.red, 0, 0.25, 0); k.sph(0.12, P.red, 0, 0.5, 0); const a = k.cyl(0.05, 0.05, 0.36, P.red, 0, 0.36, 0); a.rotation.z = Math.PI / 2; },
  'stop sign': k => { pole(k, 2.0, 0.03); const s = k.add(cylG(0.3, 0.3, 0.04, 8), P.red, 0, 2.1, 0); s.rotation.x = Math.PI / 2; s.rotation.z = Math.PI / 8; },
  'parking meter': k => { pole(k, 1.05, 0.035); k.box(0.2, 0.3, 0.14, 0x555a60, 0, 1.2, 0, 0.06); },
  bird: (k, s) => { const c = pick([0x6f9fc8, 0x54585f, 0xd9795f, 0xe9e5dc], s); k.box(0.1, 0.1, 0.18, c, 0, 0.12, 0, 0.05); k.sph(0.05, c, 0, 0.2, 0.08); k.add(coneG(0.015, 0.05, 6), P.yellow, 0, 0.2, 0.14).rotation.x = Math.PI / 2; for (const x of [-0.02, 0.02]) k.cyl(0.006, 0.006, 0.07, P.yellow, x, 0.035, 0); },
  backpack: (k, s) => { const c = pick(P.cloth, s); k.box(0.32, 0.42, 0.18, c, 0, 0.21, 0, 0.08); k.box(0.24, 0.16, 0.06, 0x333842, 0, 0.16, 0.1, 0.03); },
  handbag: (k, s) => { k.box(0.34, 0.22, 0.14, pick([0x8a5a3c, P.maroon, P.ink], s), 0, 0.11, 0, 0.05); const h = k.add(torG(0.09, 0.012), P.ink, 0, 0.24, 0); h.scale.set(1, 0.9, 1); },
  suitcase: (k, s) => { k.box(0.45, 0.6, 0.26, pick([0x6c8fb3, 0x555a60, P.red, 0x3f8050], s), 0, 0.33, 0, 0.06); k.box(0.16, 0.06, 0.03, P.ink, 0, 0.66, 0, 0.01); },
  umbrella: (k, s) => { pole(k, 0.9, 0.012, P.ink); k.add(coneG(0.45, 0.22, 10), pick(P.cloth, s), 0, 0.9, 0); },
  'sports ball': (k, s) => { k.sph(0.11, pick([0xf2efe8, 0xd98b4a, P.yellow], s), 0, 0.11, 0); },
  skateboard: k => { k.box(0.2, 0.02, 0.8, P.wood, 0, 0.09, 0, 0.01); wheels(k, [[-0.08, 0.28], [0.08, 0.28], [-0.08, -0.28], [0.08, -0.28]], 0.03, 0.03); },
  bottle: (k, s) => { const c = pick([0x4f8a6b, 0x6f9fc8, 0x8a5a3c], s); k.cyl(0.04, 0.04, 0.17, c, 0, 0.085, 0); k.cyl(0.015, 0.035, 0.07, c, 0, 0.2, 0); },
  cup: k => { k.cyl(0.04, 0.032, 0.09, P.white, 0, 0.045, 0); },
  'wine glass': k => { k.cyl(0.035, 0.005, 0.08, P.glass, 0, 0.15, 0); k.cyl(0.004, 0.004, 0.1, P.glass, 0, 0.06, 0); k.cyl(0.03, 0.03, 0.006, P.glass, 0, 0.003, 0); },
  bowl: k => { k.cyl(0.085, 0.045, 0.07, P.white, 0, 0.035, 0); },
  vase: (k, s) => { const c = pick([0x3a3b40, 0x6c8fb3, P.terracotta], s); k.cyl(0.05, 0.075, 0.2, c, 0, 0.1, 0); k.cyl(0.035, 0.05, 0.08, c, 0, 0.24, 0); for (const [x, z, a] of [[0.03, 0, 0.3], [-0.03, 0.02, -0.3], [0, -0.03, 0]]) { const l = k.box(0.03, 0.26, 0.01, 0x7fb08f, x, 0.4, z, 0.004); l.rotation.z = -a; } },
  laptop: k => { k.box(0.33, 0.015, 0.23, P.steel, 0, 0.008, 0, 0.005); const s = k.box(0.33, 0.21, 0.012, P.ink, 0, 0.11, -0.115, 0.005); s.rotation.x = -0.2; },
  book: (k, s) => { k.box(0.15, 0.03, 0.22, pick(P.cloth, s), 0, 0.015, 0, 0.004); },
  clock: k => { const c = k.cyl(0.15, 0.15, 0.04, P.white, 0, 0.15, 0); c.rotation.x = Math.PI / 2; k.box(0.012, 0.1, 0.01, P.ink, 0, 0.19, 0.024, 0.002); },
  'teddy bear': k => { k.sph(0.12, 0xb9824f, 0, 0.13, 0); k.sph(0.09, 0xb9824f, 0, 0.31, 0); for (const s of [-1, 1]) { k.sph(0.035, 0xb9824f, s * 0.07, 0.39, 0); k.sph(0.045, 0xb9824f, s * 0.13, 0.17, 0.03); } k.sph(0.035, 0xe2c9a0, 0, 0.29, 0.075); },
  microwave: k => appliance(k, 0.5, 0.3, 0.36), oven: k => appliance(k, 0.6, 0.88, 0.6), toaster: k => appliance(k, 0.28, 0.19, 0.17, P.steel),
  sink: k => { k.box(0.6, 0.84, 0.5, P.white, 0, 0.42, 0, 0.03); k.box(0.46, 0.05, 0.36, P.steel, 0, 0.86, 0, 0.02); const t = k.cyl(0.015, 0.015, 0.18, P.metal, 0, 0.97, -0.17); t.rotation.x = 0.3; },
};
for (const [name, make] of Object.entries(ANIMALS)) BUILD[name] = (k, seed) => quadruped(k, make(seed));

function generic(k, label, seed) {
  const i = classInfo(label);
  k.box(Math.max(i.w, 0.06), Math.max(i.h, 0.04), Math.max(i.d, 0.06), pick(P.cloth, seed), 0, Math.max(i.h, 0.04) / 2, 0, Math.min(i.w, i.h, i.d) * 0.25);
}

/**
 * Builds the illustration for `label`. Returns a Group whose origin is on the floor and whose front faces +Z.
 * userData: nominal {h, w}, walk(phase, amount)?, stride (metres per walk cycle), materials (for fading).
 */
export function createModel(label, id = '') {
  const k = new Kit(), seed = hash(id);
  (BUILD[label] ?? ((kit, s) => generic(kit, label, s)))(k, seed);
  const info = classInfo(label);
  k.group.userData.nominal = { h: info.h, w: Math.max(info.w, 0.05) };
  k.group.userData.materials = [...k.mats.values()];
  return k.group;
}

/** Tiny emoji-free glyph colour per class group, for lists and labels. */
export const groupColor = label => ({ person: '#c8644a', animal: '#b98345', vehicle: '#4f7fae', furniture: '#8a7a5c', street: '#7a7f87', food: '#6f9d58', prop: '#8a78a8' })[classInfo(label).g] ?? '#8a78a8';
