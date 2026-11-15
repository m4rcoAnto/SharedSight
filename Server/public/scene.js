// The illustrated room. Everything drawn here comes from the hub: surfaces measured by ARKit, fused object
// positions, camera poses. Models are class illustrations; translucent ones are predictions, never measurements.
//
// Smoothness: nothing is rebuilt per update. Objects persist and are moved; the hub's 30 Hz states are buffered
// and interpolated at display rate with a short delay, and extrapolated with their velocity when a state is late.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { createModel } from '/models.js';
import { classInfo } from '/shared/classes.mjs';
import { wallFromPlane, visibilityFan } from '/shared/geometry.mjs';

export const DEVICE_COLORS = ['#2f7fd1', '#e0722f', '#2f9d6a', '#a45bc7', '#c7a02f', '#d14f7a'];
const BG = 0xf3eee3, WALL = 0xfbf7ee, WALL_TOP = 0xe9e1d0;
// The view runs 100 ms behind the hub, so that between two phone frames (20 per second) it always has a state
// before and after to interpolate between: continuous motion instead of a sequence of snapshots.
const INTERP_DELAY = 100, MAX_EXTRAPOLATE = 250;   // ms; states that are late are extrapolated with their velocity
const lerp = (a, b, k) => a + (b - a) * k;
const angleLerp = (a, b, k) => { let d = ((b - a + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI; return a + d * k; };

function parquet() {
  const c = document.createElement('canvas'); c.width = c.height = 512;
  const g = c.getContext('2d'); g.fillStyle = '#c79a5e'; g.fillRect(0, 0, 512, 512);
  const tones = ['#d2a469', '#c99b60', '#bf9156', '#d8ad74', '#c4955a'];
  let n = 0;
  for (let y = -64; y < 576; y += 32) for (let x = -64; x < 576; x += 64) {       // herringbone: alternating diagonal planks
    for (const flip of [0, 1]) {
      g.save(); g.translate(x + (flip ? 32 : 0), y + (flip ? 16 : 0)); g.rotate(flip ? Math.PI / 4 : -Math.PI / 4);
      g.fillStyle = tones[(n++ * 7) % tones.length]; g.fillRect(-22, -7, 44, 14);
      g.strokeStyle = 'rgba(90,60,30,.35)'; g.lineWidth = 1; g.strokeRect(-22, -7, 44, 14); g.restore();
    }
  }
  const t = new THREE.CanvasTexture(c); t.wrapS = t.wrapT = THREE.RepeatWrapping; t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4;
  return t;
}

function textSprite() {
  const canvas = document.createElement('canvas'); canvas.width = 384; canvas.height = 64;
  const texture = new THREE.CanvasTexture(canvas); texture.colorSpace = THREE.SRGBColorSpace;
  const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: texture, depthTest: false, transparent: true }));
  sprite.renderOrder = 20; sprite.userData = { canvas, texture, text: null };
  return sprite;
}
function drawLabel(sprite, text, dots = [], muted = false) {
  const key = text + '|' + dots.join() + muted;
  if (sprite.userData.text === key) return;
  sprite.userData.text = key;
  const { canvas, texture } = sprite.userData, g = canvas.getContext('2d');
  g.clearRect(0, 0, canvas.width, canvas.height); g.font = '600 30px -apple-system, "Segoe UI", Inter, sans-serif';
  const w = Math.min(g.measureText(text).width + 32 + dots.length * 22, canvas.width - 4), x0 = (canvas.width - w) / 2;
  g.fillStyle = muted ? 'rgba(255,255,255,.72)' : 'rgba(255,255,255,.94)'; g.strokeStyle = 'rgba(60,50,40,.22)'; g.lineWidth = 2;
  g.beginPath(); g.roundRect(x0, 6, w, 52, 26); g.fill(); g.stroke();
  g.fillStyle = muted ? '#7d7468' : '#2f2a25'; g.textBaseline = 'middle'; g.fillText(text, x0 + 16, 34, canvas.width - 40 - dots.length * 22);
  dots.forEach((color, i) => { g.fillStyle = color; g.beginPath(); g.arc(x0 + w - 18 - i * 22, 32, 8, 0, 7); g.fill(); });
  texture.needsUpdate = true;
}

export class SceneView {
  constructor(host, { labelFor = l => l, onStats = () => {} } = {}) {
    this.host = host; this.labelFor = labelFor; this.onStats = onStats;
    this.space = null; this.surfaces = new Map(); this.rooms = new Map(); this.entities = new Map(); this.cams = new Map(); this.deviceColor = new Map();
    this.options = { zones: true, labels: true };
    this.offset = null; this.userMoved = false; this.framed = false; this.quality = 2; this.slow = 0; this.frameMs = 16; this.frames = 0; this.statAt = 0;
    this.bounds = new THREE.Box3(new THREE.Vector3(-3, 0, -3), new THREE.Vector3(3, 2.5, 3)); this.center = new THREE.Vector3();
    try { this.init(); } catch (error) { this.failed = true; console.error(error); }
  }

  init() {
    const r = this.renderer = new THREE.WebGLRenderer({ antialias: true, stencil: true, powerPreference: 'high-performance' });
    r.setPixelRatio(Math.min(devicePixelRatio, 2)); r.setClearColor(BG); r.shadowMap.enabled = true; r.shadowMap.type = THREE.PCFSoftShadowMap;
    this.host.prepend(r.domElement);
    this.scene = new THREE.Scene();
    this.camera = new THREE.OrthographicCamera(-5, 5, 5, -5, -50, 200);
    this.controls = new OrbitControls(this.camera, r.domElement);
    Object.assign(this.controls, { enableDamping: true, dampingFactor: 0.12, maxPolarAngle: Math.PI * 0.47, minZoom: 0.25, maxZoom: 6, zoomSpeed: 1.2 });
    this.controls.addEventListener('start', () => { this.userMoved = true; });
    this.scene.add(new THREE.HemisphereLight(0xffffff, 0xefe6d6, 2.85));
    const sun = this.sun = new THREE.DirectionalLight(0xfff4e2, 1.15);
    sun.castShadow = true; sun.shadow.mapSize.set(2048, 2048); sun.shadow.bias = -0.0004; sun.shadow.normalBias = 0.03; sun.shadow.radius = 5;
    this.scene.add(sun, sun.target);
    this.env = new THREE.Group(); this.zoneGroup = new THREE.Group(); this.things = new THREE.Group(); this.camGroup = new THREE.Group();
    this.scene.add(this.env, this.zoneGroup, this.things, this.camGroup);
    this.floorMap = parquet();
    this.materials = {
      floorIn: new THREE.MeshLambertMaterial({ map: this.floorMap }), floorOut: new THREE.MeshLambertMaterial({ color: 0xd6dccb }),
      ground: new THREE.MeshLambertMaterial({ color: 0xe9e3d5 }), wall: new THREE.MeshLambertMaterial({ color: WALL }), wallTop: new THREE.MeshLambertMaterial({ color: WALL_TOP }),
      frame: new THREE.MeshLambertMaterial({ color: 0x3b3a3d }), glass: new THREE.MeshLambertMaterial({ color: 0xcfdde3 }), door: new THREE.MeshLambertMaterial({ color: 0x9a6b45 }),
      slab: new THREE.MeshLambertMaterial({ color: 0xd9cdb6, transparent: true, opacity: 0.75 }),
      // A side of the room nobody has seen yet: drawn as an estimate, never as a wall.
      inferred: new THREE.MeshBasicMaterial({ color: 0x8d97b5, transparent: true, opacity: 0.16, depthWrite: false, side: THREE.DoubleSide }),
      inferredEdge: new THREE.LineDashedMaterial({ color: 0x5b6b9a, dashSize: 0.18, gapSize: 0.12, transparent: true, opacity: 0.75 }),
      // "Zone d'ombra": cameras' visible floor is written to the stencil; the dim layer is drawn everywhere else.
      fan: new THREE.MeshBasicMaterial({ colorWrite: false, depthWrite: false, depthTest: false, transparent: true, stencilWrite: true, stencilRef: 1, stencilFunc: THREE.AlwaysStencilFunc, stencilZPass: THREE.ReplaceStencilOp, side: THREE.DoubleSide }),
      shade: new THREE.MeshBasicMaterial({ color: 0x27324a, transparent: true, opacity: 0.3, depthWrite: false, stencilWrite: true, stencilRef: 1, stencilFunc: THREE.NotEqualStencilFunc, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2, side: THREE.DoubleSide }),
    };
    this.ground = new THREE.Mesh(new THREE.CircleGeometry(1, 64), this.materials.ground);
    this.ground.rotation.x = -Math.PI / 2; this.ground.position.y = -0.02; this.ground.receiveShadow = true; this.scene.add(this.ground);
    new ResizeObserver(() => this.resize()).observe(this.host); this.resize(); this.resetView();
    this.last = performance.now();
    r.setAnimationLoop(now => this.frame(now));
  }

  // ---- data in ------------------------------------------------------------------------------------------------

  setSpace(key) { if (key === this.space) return; this.space = key; this.framed = false; this.clearThings(); this.rebuildEnvironment(); }
  setOptions(o) { Object.assign(this.options, o); this.zoneGroup.visible = this.options.zones; }
  setSurfaces(device, space, planes) { this.surfaces.set(device, { space, planes }); if (space === this.space) this.rebuildEnvironment(); }
  /** The hub's room perimeter for one space (null: no wall known yet, or outdoors). */
  setRoom(space, room) { this.rooms.set(space, room); if (space === this.space) this.rebuildEnvironment(); }
  colorOf(device) { if (!this.deviceColor.has(device)) this.deviceColor.set(device, DEVICE_COLORS[this.deviceColor.size % DEVICE_COLORS.length]); return this.deviceColor.get(device); }

  /** One 'world' message from the hub. */
  update(msg) {
    if (this.failed) return;
    const now = performance.now(), lag = now - msg.t;
    this.offset = this.offset == null ? lag : Math.min(this.offset + 0.02, lag);   // follow the fastest path, drift slowly
    const liveDevices = new Set(msg.devices.filter(d => d.live).map(d => d.id));
    let stale = false;
    for (const [device, s] of this.surfaces) if (s.space === this.space && !liveDevices.has(device) && s.planes.length) { s.planes = []; stale = true; }
    if (stale) this.rebuildEnvironment();
    const space = msg.spaces.find(s => s.key === this.space);
    const seen = new Set();
    for (const e of space?.entities ?? []) {
      seen.add(e.id);
      let v = this.entities.get(e.id);
      if (!v || v.label !== e.label) { if (v) this.dropEntity(v); v = this.makeEntity(e); }
      v.buffer.push({ t: msg.t, x: e.x, z: e.z, vx: e.vx, vz: e.vz }); if (v.buffer.length > 6) v.buffer.shift();
      v.data = e; v.gone = false;
    }
    for (const v of this.entities.values()) if (!seen.has(v.id)) v.gone = true;
    const camsSeen = new Set();
    for (const c of space?.cameras ?? []) {
      if (!c.cam || !c.live) continue;
      camsSeen.add(c.id);
      let v = this.cams.get(c.id);
      if (!v) v = this.makeCamera(c);
      v.buffer.push({ t: msg.t, x: c.cam[0], y: c.cam[1], z: c.cam[2], yaw: c.cam[3] }); if (v.buffer.length > 6) v.buffer.shift();
      v.data = c;
    }
    for (const [id, v] of this.cams) if (!camsSeen.has(id)) { this.camGroup.remove(v.group); this.zoneGroup.remove(v.fan, v.outline); v.fan.geometry.dispose(); v.outline.geometry.dispose(); this.cams.delete(id); }
    if (!this.framed && (this.entities.size || this.cams.size || this.floorMeshes?.length)) { this.fit(); this.framed = true; }
  }

  // ---- environment --------------------------------------------------------------------------------------------

  rebuildEnvironment() {
    if (this.failed) return;
    this.env.traverse(o => { if (o.isMesh || o.isLine) o.geometry.dispose(); }); this.env.clear();
    for (const m of this.shadeMeshes ?? []) { this.zoneGroup.remove(m); }
    this.walls = []; this.wallViews = []; this.floorMeshes = []; this.shadeMeshes = [];
    const planes = [...this.surfaces.values()].filter(s => s.space === this.space).flatMap(s => s.planes);
    const room = this.rooms.get(this.space);
    if (room) return this.buildRoom(room, planes);
    const horizontals = planes.filter(p => !p.vertical && p.triangles.length), verticals = planes.filter(p => p.vertical);
    const heights = horizontals.map(p => p.vertices.reduce((s, v) => s + v.y, 0) / p.vertices.length);
    const floors = heights.filter((h, i) => horizontals[i].kind === 'floor');
    const floorY = this.floorY = floors.length ? Math.min(...floors) : horizontals.length ? Math.min(...heights) : 0;
    const indoor = verticals.length > 0;
    const box = new THREE.Box3();
    horizontals.forEach((p, i) => {
      const kind = p.kind ?? (heights[i] - floorY < 0.25 ? 'floor' : 'surface');
      if (kind === 'ceiling' || heights[i] - floorY > 2.1) return;                    // a ceiling would hide the room
      const isFloor = kind === 'floor' || heights[i] - floorY < 0.25;
      const g = new THREE.BufferGeometry(), pos = [], uv = [];
      for (const v of p.vertices) { pos.push(v.x, v.y, v.z); uv.push(v.x / 1.8, v.z / 1.8); box.expandByPoint(new THREE.Vector3(v.x, v.y, v.z)); }
      g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
      g.setIndex(p.triangles); g.computeVertexNormals();
      const mesh = new THREE.Mesh(g, isFloor ? (indoor ? this.materials.floorIn : this.materials.floorOut) : this.materials.slab);
      mesh.material.side = THREE.DoubleSide; mesh.receiveShadow = true; this.env.add(mesh);
      if (isFloor) {
        this.floorMeshes.push(mesh);
        const shade = new THREE.Mesh(g, this.materials.shade); shade.renderOrder = 2; this.zoneGroup.add(shade); this.shadeMeshes.push(shade);
      }
    });
    this.walls = verticals.map(wallFromPlane).filter(Boolean);
    for (const w of this.walls) { box.expandByPoint(new THREE.Vector3(w.ax, w.y0, w.az)); box.expandByPoint(new THREE.Vector3(w.bx, w.y1, w.bz)); }
    if (!box.isEmpty()) { this.bounds.copy(box); this.bounds.getCenter(this.center); }
    for (const w of mergeWalls(this.walls)) this.addWall(w);
    this.ground.visible = !this.floorMeshes.length;
    for (const v of this.entities.values()) v.facing = null;          // furniture may now have a wall to stand against
    if (!this.userMoved && this.framed) this.fit();
  }

  /** Closed room from the hub's perimeter: one floor, seen walls (with doors and windows), estimated sides. */
  buildRoom(room, planes) {
    const y = this.floorY = room.floorY, H = room.height;
    const box = new THREE.Box3(), rooms = room.rooms ?? [room];
    // One floor per room (each a convex quadrilateral), parquet, plus the "shadow zone" layer on top of it.
    // Rooms that overlap are lifted by a millimetre each so their floors do not flicker against each other.
    rooms.forEach((r, i) => {
      const g = new THREE.BufferGeometry(), pos = [], uv = [], fy = y + 0.001 * i;
      for (const [x, z] of r.corners) { pos.push(x, fy, z); uv.push(x / 1.8, z / 1.8); box.expandByPoint(new THREE.Vector3(x, y, z)); }
      g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
      g.setIndex([0, 2, 1, 0, 3, 2]); g.computeVertexNormals();
      const floor = new THREE.Mesh(g, this.materials.floorIn); floor.material.side = THREE.DoubleSide; floor.receiveShadow = true;
      this.env.add(floor); this.floorMeshes.push(floor);
      const shade = new THREE.Mesh(g, this.materials.shade); shade.renderOrder = 2; this.zoneGroup.add(shade); this.shadeMeshes.push(shade);
    });
    box.expandByPoint(new THREE.Vector3(rooms[0].corners[0][0], y + H, rooms[0].corners[0][1]));
    this.bounds.copy(box); this.bounds.getCenter(this.center);
    // Raised horizontal surfaces measured by ARKit (0.3–1.3 m: tables, desks, counters) become real tables:
    // a top square to the room and four legs down to the floor, not a slab floating in the air.
    this.tables = [];
    const ax = (room.axisDeg ?? 0) * Math.PI / 180, ca = Math.cos(ax), sa = Math.sin(ax);
    for (const p of planes.filter(p => !p.vertical && p.vertices.length >= 3)) {
      const h = p.vertices.reduce((t, v) => t + v.y, 0) / p.vertices.length - y;
      if (h < 0.3 || h > 1.3 || p.kind === 'ceiling' || p.kind === 'floor') continue;
      const us = p.vertices.map(v => v.x * ca + v.z * sa), vs = p.vertices.map(v => -v.x * sa + v.z * ca);
      const t = { u0: Math.min(...us), u1: Math.max(...us), v0: Math.min(...vs), v1: Math.max(...vs), ca, sa };
      if (t.u1 - t.u0 < 0.25 || t.v1 - t.v0 < 0.25) continue;
      this.tables.push(t); this.addTable(t, y, h);
    }
    // Walls. Measured parts become solid walls / doors / windows; never-seen parts are estimates.
    const wall = (p, y0, y1, kind = p.kind) => this.addWall({ kind, ax: p.ax, az: p.az, bx: p.bx, bz: p.bz, y0, y1 });
    this.walls = [];
    // A wall shared by two rooms is drawn once: parts are taken strongest first (measured, then openings, then
    // continued, then estimated) and a part lying on an already drawn one is skipped.
    const rank = { wall: 5, door: 4, window: 4, opening: 3, extended: 2, inferred: 1 };
    const drawn = [], onDrawn = p => drawn.some(d => {
      const dx = d.bx - d.ax, dz = d.bz - d.az, L = Math.hypot(dx, dz) || 1;
      const off = q => Math.abs(((q[0] - d.ax) * dz - (q[1] - d.az) * dx) / L), at = q => ((q[0] - d.ax) * dx + (q[1] - d.az) * dz) / L;
      const a = [p.ax, p.az], b = [p.bx, p.bz];
      return off(a) < 0.08 && off(b) < 0.08 && Math.min(at(a), at(b)) >= -0.05 && Math.max(at(a), at(b)) <= L + 0.05;
    });
    const parts = rooms.flatMap(r => [...r.sides, ...r.interior]).sort((a, b) => (rank[b.kind] ?? 0) - (rank[a.kind] ?? 0));
    for (const p of parts) {
      if (onDrawn(p)) continue;
      drawn.push(p);
      if (p.kind === 'inferred') { this.addInferredWall(p, y, H); continue; }
      if (p.kind === 'door') { wall(p, y, y + Math.min(2.05, H)); if (H > 2.15) wall(p, y + 2.05, y + H, 'wall'); }
      else if (p.kind === 'opening') { if (H > 2.15) wall(p, y + 2.05, y + H, 'wall'); continue; }   // a doorway: only the wall above it
      else if (p.kind === 'window') { wall(p, y, y + 0.9, 'wall'); wall(p, y + 0.9, y + Math.min(2.1, H)); if (H > 2.2) wall(p, y + 2.1, y + H, 'wall'); }
      else wall(p, y, y + H);
      this.walls.push({ kind: p.kind, ax: p.ax, az: p.az, bx: p.bx, bz: p.bz, y0: y, y1: y + H });
    }
    this.ground.visible = false;
    for (const v of this.entities.values()) v.facing = null;
    if (!this.userMoved && this.framed) this.fit();
  }

  addTable(t, floorY, h) {
    const group = new THREE.Group(), w = t.u1 - t.u0, d = t.v1 - t.v0, cu = (t.u0 + t.u1) / 2, cv = (t.v0 + t.v1) / 2;
    group.position.set(cu * t.ca - cv * t.sa, floorY, cu * t.sa + cv * t.ca); group.rotation.y = -Math.atan2(t.sa, t.ca);
    const top = new THREE.Mesh(new THREE.BoxGeometry(w, 0.04, d), this.materials.door); top.position.y = h - 0.02;
    group.add(top);
    for (const [i, j] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
      const leg = new THREE.Mesh(new THREE.BoxGeometry(0.05, h - 0.04, 0.05), this.materials.door);
      leg.position.set(i * (w / 2 - 0.06), (h - 0.04) / 2, j * (d / 2 - 0.06)); group.add(leg);
    }
    group.traverse(o => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } });
    this.env.add(group);
  }

  /** Height factor of a wall for the current viewpoint: lowered when it stands between the viewer and the room. */
  cutTarget(w) {
    const vx = this.camera.position.x - this.controls.target.x, vz = this.camera.position.z - this.controls.target.z, vl = Math.hypot(vx, vz) || 1;
    const facing = (w.nx * vx + w.nz * vz) / vl > 0.12;
    return facing ? (w.raised ? 0.0001 : Math.min(0.14 / w.full, 1)) : 1;
  }
  /** A rebuilt wall starts at the height the viewpoint asks for: no pop-up to full height on every room update. */
  placeView(view) {
    view.k = this.cutTarget(view); view.holder.scale.y = view.k; view.holder.visible = view.k > 0.01;
    this.wallViews.push(view);
  }

  addInferredWall(p, y, H) {
    const dx = p.bx - p.ax, dz = p.bz - p.az, len = Math.hypot(dx, dz);
    if (len < 0.05) return;
    const h = Math.min(H, 1.1), holder = new THREE.Group();
    holder.position.set((p.ax + p.bx) / 2, y, (p.az + p.bz) / 2); holder.rotation.y = Math.atan2(-dz, dx);
    const panel = new THREE.Mesh(new THREE.PlaneGeometry(len, h), this.materials.inferred); panel.position.y = h / 2; panel.renderOrder = 3;
    const edge = new THREE.Line(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(-len / 2, h, 0), new THREE.Vector3(len / 2, h, 0)]), this.materials.inferredEdge);
    edge.computeLineDistances();
    const base = new THREE.Line(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(-len / 2, 0.02, 0), new THREE.Vector3(len / 2, 0.02, 0)]), this.materials.inferredEdge);
    base.computeLineDistances();
    holder.add(panel, edge, base); this.env.add(holder);
    let nx = -dz / len, nz = dx / len;
    if ((holder.position.x - this.center.x) * nx + (holder.position.z - this.center.z) * nz < 0) { nx = -nx; nz = -nz; }
    this.placeView({ holder, nx, nz, k: 1, raised: false, full: h });
  }

  addWall(w) {
    const dx = w.bx - w.ax, dz = w.bz - w.az, len = Math.hypot(dx, dz), h = Math.max(w.y1 - w.y0, 0.05), angle = Math.atan2(-dz, dx);
    const holder = new THREE.Group(); holder.position.set((w.ax + w.bx) / 2, w.y0, (w.az + w.bz) / 2); holder.rotation.y = angle;
    let mesh;
    if (w.kind === 'window') {
      mesh = new THREE.Group();
      const frame = new THREE.Mesh(new THREE.BoxGeometry(len, h, 0.16), this.materials.frame); frame.position.y = h / 2;
      const glass = new THREE.Mesh(new THREE.BoxGeometry(len - 0.16, h - 0.16, 0.18), this.materials.glass); glass.position.y = h / 2;
      mesh.add(frame, glass);
      for (let i = 1; i < 2; i++) { const bar = new THREE.Mesh(new THREE.BoxGeometry(0.05, h - 0.1, 0.2), this.materials.frame); bar.position.set(0, h / 2, 0); mesh.add(bar); }
      for (const y of [h / 3, 2 * h / 3]) { const bar = new THREE.Mesh(new THREE.BoxGeometry(len - 0.1, 0.05, 0.2), this.materials.frame); bar.position.y = y; mesh.add(bar); }
    } else if (w.kind === 'door') {
      mesh = new THREE.Mesh(new THREE.BoxGeometry(len, h, 0.06), this.materials.door); mesh.position.y = h / 2;
      const knob = new THREE.Mesh(new THREE.SphereGeometry(0.045, 10, 8), this.materials.frame); knob.position.set(len / 2 - 0.1, 0, 0.06); mesh.add(knob);
    } else {
      mesh = new THREE.Mesh(new THREE.BoxGeometry(len + 0.1, h, 0.1), [this.materials.wall, this.materials.wall, this.materials.wallTop, this.materials.wall, this.materials.wall, this.materials.wall]);
      mesh.position.y = h / 2;
    }
    mesh.traverse(o => { if (o.isMesh) { o.castShadow = w.kind !== 'window'; o.receiveShadow = true; } });
    holder.add(mesh); this.env.add(holder);
    // Outward normal: away from the middle of the mapped area. Walls between the viewer and the room are lowered.
    let nx = -dz / len, nz = dx / len;
    if ((holder.position.x - this.center.x) * nx + (holder.position.z - this.center.z) * nz < 0) { nx = -nx; nz = -nz; }
    this.placeView({ holder, nx, nz, k: 1, raised: w.y0 - this.floorY > 0.4, full: h });
  }

  // ---- objects ------------------------------------------------------------------------------------------------

  makeEntity(e) {
    const group = new THREE.Group(), model = createModel(e.label, e.id), info = classInfo(e.label);
    const ring = new THREE.Mesh(new THREE.RingGeometry(0.93, 1, 48), new THREE.MeshBasicMaterial({ color: 0x5b6b9a, transparent: true, opacity: 0, depthWrite: false, side: THREE.DoubleSide }));
    ring.rotation.x = -Math.PI / 2; ring.position.y = 0.02; ring.renderOrder = 5;
    const disc = new THREE.Mesh(new THREE.CircleGeometry(1, 40), new THREE.MeshBasicMaterial({ color: 0x5b6b9a, transparent: true, opacity: 0, depthWrite: false }));
    disc.rotation.x = -Math.PI / 2; disc.position.y = 0.018; disc.renderOrder = 4;
    // Both attributes are allocated once and rewritten in place: nothing is created per frame.
    const pathGeometry = new THREE.BufferGeometry().setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(15), 3))
      .setAttribute('lineDistance', new THREE.Float32BufferAttribute(new Float32Array(5), 1));
    const path = new THREE.Line(pathGeometry,
      new THREE.LineDashedMaterial({ color: 0x3a4a78, dashSize: 0.14, gapSize: 0.1, transparent: true, opacity: 0.85, depthTest: false }));
    path.frustumCulled = false; path.renderOrder = 6; path.visible = false;
    const label = textSprite();
    // Where a hidden mover is expected to come out from behind what hides it (shown only while that is expected).
    const exit = new THREE.Mesh(new THREE.RingGeometry(0.26, 0.36, 40), new THREE.MeshBasicMaterial({ color: 0x0a84ff, transparent: true, opacity: 0, depthWrite: false, depthTest: false, side: THREE.DoubleSide }));
    exit.rotation.x = -Math.PI / 2; exit.renderOrder = 7; exit.visible = false;
    // Where a hidden mover can be: its cloud of possible positions, as soft dots on the floor (preallocated).
    const cloud = new THREE.Points(new THREE.BufferGeometry().setAttribute('position', new THREE.BufferAttribute(new Float32Array(64 * 3), 3)),
      new THREE.PointsMaterial({ map: dotTexture(), alphaTest: 0.05, color: 0xc8553d, size: 10, transparent: true, opacity: 0.7, depthWrite: false, depthTest: false, sizeAttenuation: false }));
    cloud.renderOrder = 6; cloud.visible = false; cloud.frustumCulled = false;
    group.add(model); this.things.add(group, ring, disc, path, label, exit, cloud);
    const v = { id: e.id, label: e.label, info, group, model, ring, disc, path, exit, cloud, labelSprite: label, buffer: [], data: e, x: e.x, z: e.z, y: e.y,
      yaw: null, facing: null, phase: Math.random() * 6, opacity: 0, shown: 0, sigma: 0.3, gone: false, transparent: false };
    this.entities.set(e.id, v);
    return v;
  }

  dropEntity(v) {
    this.things.remove(v.group, v.ring, v.disc, v.path, v.labelSprite, v.exit, v.cloud);
    v.exit.geometry.dispose(); v.exit.material.dispose(); v.cloud.geometry.dispose(); v.cloud.material.dispose();
    for (const m of v.model.userData.materials) m.dispose();
    v.ring.geometry.dispose(); v.ring.material.dispose(); v.disc.geometry.dispose(); v.disc.material.dispose(); v.path.geometry.dispose(); v.path.material.dispose();
    v.labelSprite.material.map.dispose(); v.labelSprite.material.dispose();
    this.entities.delete(v.id);
  }
  clearThings() { for (const v of [...this.entities.values()]) this.dropEntity(v); for (const [id, v] of this.cams) { this.camGroup.remove(v.group); this.zoneGroup.remove(v.fan, v.outline); this.cams.delete(id); } }

  makeCamera(c) {
    const color = new THREE.Color(this.colorOf(c.id)), group = new THREE.Group(), body = new THREE.Group();
    const phone = new THREE.Mesh(new THREE.BoxGeometry(0.09, 0.18, 0.02), new THREE.MeshLambertMaterial({ color: 0x2b2a2e })); phone.castShadow = true;
    const screen = new THREE.Mesh(new THREE.BoxGeometry(0.078, 0.165, 0.004), new THREE.MeshBasicMaterial({ color })); screen.position.z = 0.012;
    const cone = new THREE.Mesh(new THREE.ConeGeometry(0.07, 0.16, 4, 1, true), new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.55, side: THREE.DoubleSide }));
    cone.rotation.x = Math.PI / 2; cone.rotation.y = Math.PI / 4; cone.position.z = -0.1;
    body.add(phone, screen, cone);
    const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.008, 0.008, 1, 6), new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.5 }));
    const foot = new THREE.Mesh(new THREE.CircleGeometry(0.11, 24), new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.8, depthWrite: false }));
    foot.rotation.x = -Math.PI / 2;
    const label = textSprite(); drawLabel(label, c.name, [this.colorOf(c.id)]);
    group.add(body, pole, foot, label); this.camGroup.add(group);
    const fanGeometry = new THREE.BufferGeometry(); fanGeometry.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(52 * 3), 3));
    const index = []; for (let i = 1; i < 50; i++) index.push(0, i, i + 1); fanGeometry.setIndex(index);
    const fan = new THREE.Mesh(fanGeometry, this.materials.fan); fan.renderOrder = 1; fan.frustumCulled = false;
    const outline = new THREE.LineLoop(new THREE.BufferGeometry().setAttribute('position', fanGeometry.getAttribute('position')), new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.32, depthTest: false }));
    outline.renderOrder = 3; outline.frustumCulled = false; outline.geometry.setDrawRange(0, 50);
    this.zoneGroup.add(fan, outline);
    const v = { id: c.id, group, body, pole, foot, label, fan, outline, buffer: [], data: c, x: c.cam[0], y: c.cam[1], z: c.cam[2], yaw: c.cam[3] ?? 0, fanAt: 0 };
    this.cams.set(c.id, v);
    return v;
  }

  // ---- view ---------------------------------------------------------------------------------------------------

  resize() {
    if (this.failed) return;
    const w = Math.max(this.host.clientWidth, 1), h = Math.max(this.host.clientHeight, 1), a = w / h;
    this.renderer.setSize(w, h, false);
    Object.assign(this.camera, { left: -5 * a, right: 5 * a, top: 5, bottom: -5 }); this.camera.updateProjectionMatrix();
  }
  fit(direction = new THREE.Vector3(0.9, 0.85, 1)) {
    // Frame what is measured: the mapped surfaces, the phones, and objects somebody sees. Estimates do not move the view.
    const box = this.bounds.clone();
    for (const v of this.entities.values()) if (v.data.state === 'observed' || v.data.state === 'remembered') box.expandByPoint(new THREE.Vector3(v.x, v.y + Math.max(v.data.h, 0.3), v.z));
    for (const v of this.cams.values()) box.expandByPoint(new THREE.Vector3(v.x, v.y + 0.4, v.z));
    const size = box.getSize(new THREE.Vector3()), center = box.getCenter(new THREE.Vector3()), span = Math.hypot(size.x, size.z) + 1.2;
    const dir = direction.clone().normalize(), cam = this.camera;
    this.controls.target.copy(center); cam.position.copy(center).addScaledVector(dir, 30); cam.zoom = 1; cam.lookAt(center); cam.updateMatrixWorld();
    // Exact fit: project the eight corners on the screen axes, centre them, then zoom until they fill the viewport.
    const right = new THREE.Vector3().setFromMatrixColumn(cam.matrixWorld, 0), up = new THREE.Vector3().setFromMatrixColumn(cam.matrixWorld, 1), p = new THREE.Vector3();
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    for (let i = 0; i < 8; i++) {
      p.set(i & 1 ? box.max.x : box.min.x, i & 2 ? box.max.y : box.min.y, i & 4 ? box.max.z : box.min.z).sub(center);
      const x = p.dot(right), y = p.dot(up); x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y);
    }
    const shift = right.clone().multiplyScalar((x0 + x1) / 2).addScaledVector(up, (y0 + y1) / 2);
    this.controls.target.add(shift); cam.position.add(shift);
    const w = Math.max(this.host.clientWidth, 1), h = Math.max(this.host.clientHeight, 1), a = w / h;
    // Leave room for the controls drawn over the top and bottom edges of the view (about 64 px each).
    const usable = Math.max(1 - 128 / h, 0.5);
    cam.zoom = THREE.MathUtils.clamp(Math.min(10 * a / ((x1 - x0) * 1.06 + 0.2), 10 * usable / ((y1 - y0) + 0.2)), 0.25, 4);
    cam.updateProjectionMatrix(); this.controls.update();
    this.ground.scale.setScalar(span * 0.8); this.ground.position.set(center.x, (this.floorY ?? 0) - 0.02, center.z);
    const s = this.sun; s.target.position.copy(center); s.position.copy(center).add(new THREE.Vector3(span * 0.3, span * 1.2 + 4, span * 0.55));
    Object.assign(s.shadow.camera, { left: -span, right: span, top: span, bottom: -span, near: 0.5, far: span * 3 + 12 }); s.shadow.camera.updateProjectionMatrix();
  }
  resetView() { this.userMoved = false; this.fit(); }
  topView() { this.userMoved = true; this.fit(new THREE.Vector3(0.0001, 1, 0.02)); }

  sample(buffer, at) {
    const n = buffer.length; if (!n) return null;
    for (let i = n - 1; i > 0; i--) {
      const a = buffer[i - 1], b = buffer[i];
      if (at >= a.t && at <= b.t) { const k = (at - a.t) / Math.max(b.t - a.t, 1); return { a, b, k }; }
    }
    return at < buffer[0].t ? { a: buffer[0], b: buffer[0], k: 0 } : { a: buffer[n - 1], b: buffer[n - 1], k: 0, late: Math.min(at - buffer[n - 1].t, MAX_EXTRAPOLATE) / 1000 };
  }

  frame(now) {
    const dt = Math.min((now - this.last) / 1000, 0.1); this.last = now;
    this.frameMs = lerp(this.frameMs, dt * 1000, 0.05);
    const at = now - (this.offset ?? 0) - INTERP_DELAY, ease = 1 - Math.exp(-dt * 10);
    const pxPerUnit = this.host.clientHeight / (10 / this.camera.zoom), labelH = 26 / pxPerUnit;
    this.controls.update();

    // Lower the walls that stand between the viewer and the room (cut-away, like a doll's house).
    for (const w of this.wallViews ?? []) {
      const target = this.cutTarget(w);
      if (Math.abs(w.k - target) > 0.001) { w.k = lerp(w.k, target, 1 - Math.exp(-dt * 9)); w.holder.scale.y = w.k; w.holder.visible = w.k > 0.01; }
    }

    for (const v of this.entities.values()) {
      const e = v.data, s = this.sample(v.buffer, at);
      if (s) {
        let x = lerp(s.a.x, s.b.x, s.k), z = lerp(s.a.z, s.b.z, s.k);
        if (s.late && !v.gone) { x += s.b.vx * s.late; z += s.b.vz * s.late; }
        // Glide, never hop: the drawn object advances with the track's velocity (which is smooth) and only the
        // remaining position error is absorbed gradually. Measurement noise of a few centimetres per update would
        // otherwise show as vibration at display rate. A large correction (an estimate meeting reality) closes faster.
        const ox = v.x, oz = v.z;
        if (v.info.dyn && e.state !== 'lost' && !v.gone) { v.x += lerp(s.a.vx, s.b.vx, s.k) * dt; v.z += lerp(s.a.vz, s.b.vz, s.k) * dt; }
        const dx = x - v.x, dz = z - v.z, error = Math.hypot(dx, dz);
        if (error > 2.5) { v.x = x; v.z = z; } else { const k = 1 - Math.exp(-dt * (error > 0.5 ? 14 : 6)); v.x += dx * k; v.z += dz * k; }
        const step = Math.hypot(v.x - ox, v.z - oz);
        v.y = lerp(v.y, e.y, ease);
        const speed = Math.hypot(e.vx, e.vz), moving = v.info.dyn && speed > 0.2 && e.state !== 'lost';
        if (moving) { const yaw = Math.atan2(e.vx, e.vz); v.yaw = v.yaw == null ? yaw : angleLerp(v.yaw, yaw, 1 - Math.exp(-dt * 7)); v.phase += Math.min(step, 0.3) / (v.model.userData.stride ?? 1) * Math.PI * 2; }
        v.model.userData.walk?.(v.phase, lerp(v.walkAmount ?? 0, moving ? 1 : 0, ease)); v.walkAmount = lerp(v.walkAmount ?? 0, moving ? 1 : 0, ease);
      }
      if (!v.info.dyn && v.facing == null) v.facing = this.furnitureFacing(v);
      v.group.position.set(v.x, v.y, v.z); v.group.rotation.y = v.info.dyn ? (v.yaw ?? 0) : v.facing;
      const n = v.model.userData.nominal, sw = THREE.MathUtils.clamp(e.w / n.w, 0.6, 1.6), sh = THREE.MathUtils.clamp(e.h / n.h, 0.6, 1.6);
      v.model.scale.set(lerp(v.model.scale.x, sw, ease), lerp(v.model.scale.y, sh, ease), lerp(v.model.scale.z, sw, ease));

      // Solid = measured now (or furniture remembered in place). Translucent = estimate. Fading = lost.
      const estimate = e.state === 'hidden' && e.reason !== 'unconfirmed';
      // A table already drawn from its measured surface is not drawn a second time from the detector's guess.
      const measuredTable = v.label === 'dining table' && (this.tables ?? []).some(t => insideRect(t, v.x, v.z, 0.4));
      const target = v.gone || e.state === 'lost' || measuredTable ? 0 : estimate ? 0.36 : e.state === 'remembered' ? 0.9 : 1;
      v.opacity = lerp(v.opacity, target, 1 - Math.exp(-dt * (target < v.opacity ? 6 : 12)));
      const transparent = v.opacity < 0.985;
      if (transparent !== v.transparent || transparent) for (const m of v.model.userData.materials) { m.transparent = transparent; m.opacity = v.opacity; m.depthWrite = v.opacity > 0.6; if (transparent !== v.transparent) m.needsUpdate = true; }
      v.transparent = transparent;
      const casting = v.opacity > 0.6;
      if (casting !== v.casting) { v.casting = casting; v.model.traverse(o => { if (o.isMesh) o.castShadow = casting; }); }
      if (v.gone && v.opacity < 0.02) { this.dropEntity(v); continue; }

      v.sigma = lerp(v.sigma, estimate ? Math.max(e.sigma, 0.3) : 0.3, ease);
      const ringOpacity = estimate ? 0.75 : 0;
      v.ring.material.opacity = lerp(v.ring.material.opacity, ringOpacity, ease); v.disc.material.opacity = lerp(v.disc.material.opacity, estimate ? 0.13 : 0, ease);
      v.ring.visible = v.disc.visible = v.ring.material.opacity > 0.01;
      v.ring.position.set(v.x, v.y + 0.02, v.z); v.disc.position.set(v.x, v.y + 0.018, v.z); v.ring.scale.setScalar(v.sigma); v.disc.scale.setScalar(v.sigma);

      if (e.path && !v.gone) {
        const p = v.path.geometry.getAttribute('position'), d = v.path.geometry.getAttribute('lineDistance');
        let i = 0, px = v.x, pz = v.z, run = 0; p.setXYZ(i, px, v.y + 0.04, pz); d.setX(i++, 0);
        for (let j = 0; j + 1 < e.path.length && i < 5; j += 2) {
          const qx = e.path[j], qz = e.path[j + 1]; run += Math.hypot(qx - px, qz - pz); px = qx; pz = qz;
          p.setXYZ(i, qx, v.y + 0.04, qz); d.setX(i++, run);
        }
        v.path.geometry.setDrawRange(0, i); p.needsUpdate = true; d.needsUpdate = true; v.path.visible = true;
        v.path.material.opacity = estimate ? 0.9 : 0.45;
      } else v.path.visible = false;

      // Movers and estimates are always named; furniture in plain view is named once the viewer zooms in.
      // Cloud of possible positions while hidden: fainter as it spreads.
      const pts = estimate && !v.gone && e.cloud?.length ? e.cloud : null;
      v.cloud.visible = !!pts;
      if (pts) {
        const arr = v.cloud.geometry.attributes.position.array, n = Math.min(pts.length, 64);
        for (let i = 0; i < n; i++) { arr[i * 3] = pts[i][0]; arr[i * 3 + 1] = v.y + 0.04; arr[i * 3 + 2] = pts[i][1]; }
        v.cloud.geometry.setDrawRange(0, n); v.cloud.geometry.attributes.position.needsUpdate = true;
        v.cloud.material.color.setHex(v.info.dyn ? 0xc8553d : 0x8d97b5);
        v.cloud.material.opacity = THREE.MathUtils.clamp(0.95 - e.sigma * 0.2, 0.45, 0.9);
      }
      // Expected exit: a ring on the floor where it should reappear, brighter as the moment comes, orange once overdue.
      const ex = estimate && !v.gone ? e.exit : null;
      v.exit.visible = !!ex;
      if (ex) {
        v.exit.position.set(ex.x, v.y + 0.035, ex.z);
        const due = ex.inMs <= 0, pulse = 0.5 + 0.5 * Math.sin(now / 180);
        v.exit.material.color.setHex(due ? 0xff9f0a : 0x0a84ff);
        v.exit.material.opacity = due ? 0.55 + 0.35 * pulse : THREE.MathUtils.clamp(1 - ex.inMs / 4000, 0.35, 0.9);
        v.exit.scale.setScalar(due ? 1 + 0.12 * pulse : 1);
      }
      // "Lost" is said for 1.5 s, then the label goes: a lost estimate has no place to be shown at.
      if (e.state === 'lost') v.lostAt ??= now; else v.lostAt = null;
      const lostLong = v.lostAt != null && now - v.lostAt > 1500;
      const showLabel = this.options.labels && !v.gone && !lostLong && (v.info.dyn || estimate || this.camera.zoom > 1.75);
      v.labelSprite.visible = showLabel;
      if (showLabel) {
        const exitText = !e.exit ? '' : e.exit.inMs > 150 ? ` · esce tra ${(Math.ceil(e.exit.inMs / 500) / 2).toFixed(1).replace('.', ',')} s` : ' · attesa ora';
        const suffix = e.state === 'lost' ? ' · persa' : estimate ? (exitText || ` · stimata ±${e.sigma.toFixed(1).replace('.', ',')} m`) : e.state === 'remembered' ? ' · ricordato' : '';
        drawLabel(v.labelSprite, this.labelFor(e.label) + suffix, (e.seenBy ?? []).map(id => this.colorOf(id)), e.state !== 'observed');
        v.labelSprite.position.set(v.x, v.y + Math.max(e.h, 0.3) + 0.28, v.z);
        v.labelSprite.scale.set(labelH * 6, labelH, 1);
      }
    }

    const blockers = [];
    for (const v of this.entities.values()) if (v.data.h >= 1.2 && v.data.state !== 'lost' && v.data.state !== 'hidden') blockers.push({ x: v.x, z: v.z, r: Math.max(v.data.w, 0.2) * 0.45, tall: true });
    for (const v of this.cams.values()) {
      const s = this.sample(v.buffer, at);
      if (s) {
        const k = Math.min(1, ease * 2.5);
        v.x = lerp(v.x, lerp(s.a.x, s.b.x, s.k), k); v.y = lerp(v.y, lerp(s.a.y, s.b.y, s.k), k); v.z = lerp(v.z, lerp(s.a.z, s.b.z, s.k), k);
        if (s.b.yaw != null) v.yaw = angleLerp(v.yaw, s.a.yaw == null ? s.b.yaw : angleLerp(s.a.yaw, s.b.yaw, s.k), k);
      }
      const floor = this.floorY ?? 0;
      v.group.position.set(v.x, 0, v.z); v.body.position.y = v.y; v.body.rotation.y = -v.yaw;
      v.pole.position.y = (v.y + floor) / 2; v.pole.scale.y = Math.max(v.y - floor, 0.01); v.foot.position.y = floor + 0.025;
      v.label.visible = this.options.labels; v.label.position.set(0, v.y + 0.32, 0); v.label.scale.set(labelH * 6, labelH, 1);
      if (this.options.zones && now - v.fanAt > 90) {            // ~11 Hz is plenty for the coverage polygons
        v.fanAt = now;
        const fan = visibilityFan({ x: v.x, y: v.y, z: v.z, yaw: v.yaw }, v.data.fov ?? 55, 12, this.walls ?? [], blockers, 48, floor);
        const p = v.fan.geometry.getAttribute('position');
        for (let i = 0; i < 50; i++) { const j = Math.min(i, fan.length / 2 - 1) * 2; p.setXYZ(i, fan[j] ?? v.x, floor + 0.03, fan[j + 1] ?? v.z); }
        p.needsUpdate = true;
      }
    }

    this.renderer.render(this.scene, this.camera);

    // Adaptive quality: hold the frame rate before holding the effects.
    this.frames++; this.slow = this.frameMs > 24 ? this.slow + 1 : Math.max(0, this.slow - 2);
    if (this.slow > 120 && this.quality > 0) {
      this.quality--; this.slow = 0;
      if (this.quality === 1) this.renderer.setPixelRatio(1); else { this.renderer.shadowMap.enabled = false; this.sun.castShadow = false; this.scene.traverse(o => { if (o.material) [].concat(o.material).forEach(m => { m.needsUpdate = true; }); }); }
      this.resize();
    }
    if (now - this.statAt > 500) { this.onStats({ fps: Math.round(this.frames * 1000 / (now - this.statAt)), quality: this.quality }); this.frames = 0; this.statAt = now; }
  }

  /** Furniture has no measured orientation: stand it with its back to the nearest wall, else facing the room's middle. */
  furnitureFacing(v) {
    let best = null, d = 1.4;
    for (const w of this.walls ?? []) {
      if (w.y0 - (this.floorY ?? 0) > 0.4) continue;
      const dx = w.bx - w.ax, dz = w.bz - w.az, l2 = dx * dx + dz * dz, t = Math.min(1, Math.max(0, ((v.x - w.ax) * dx + (v.z - w.az) * dz) / l2));
      const px = w.ax + t * dx, pz = w.az + t * dz, dist = Math.hypot(v.x - px, v.z - pz);
      if (dist < d && dist > 0.05) { d = dist; best = Math.atan2(v.x - px, v.z - pz); }
    }
    if (best != null) return best;
    // Free-standing: square to the room (longest wall), turned toward its middle.
    let axis = 0, longest = 0;
    for (const w of this.walls ?? []) { const l = Math.hypot(w.bx - w.ax, w.bz - w.az); if (l > longest) { longest = l; axis = Math.atan2(w.bx - w.ax, w.bz - w.az); } }
    const cx = this.center.x - v.x, cz = this.center.z - v.z, toward = Math.hypot(cx, cz) > 0.3 ? Math.atan2(cx, cz) : 0;
    return axis + Math.round((toward - axis) / (Math.PI / 2)) * (Math.PI / 2);
  }
}

/** Point within `margin` of a table rectangle expressed in the room's axes. */
function insideRect(t, x, z, margin) {
  const u = x * t.ca + z * t.sa, v = -x * t.sa + z * t.ca;
  return u > t.u0 - margin && u < t.u1 + margin && v > t.v0 - margin && v < t.v1 + margin;
}

/** ARKit reports a wall as several overlapping patches. Patches on the same line are joined into one wall. */
export function mergeWalls(walls) {
  const out = [], solid = walls.filter(w => w.kind !== 'window' && w.kind !== 'door' && w.y0 < 0.5 + Math.min(...walls.map(x => x.y0), 0));
  const special = walls.filter(w => !solid.includes(w));
  const groups = [];
  for (const w of solid) {
    let a = Math.atan2(w.bz - w.az, w.bx - w.ax); if (a < 0) a += Math.PI; if (a >= Math.PI - 1e-6) a -= Math.PI;
    const nx = -Math.sin(a), nz = Math.cos(a), off = w.ax * nx + w.az * nz;
    let g = groups.find(q => Math.min(Math.abs(q.a - a), Math.PI - Math.abs(q.a - a)) < 0.14 && Math.abs(q.off - (w.ax * q.nx + w.az * q.nz)) < 0.18);
    if (!g) { g = { a, nx, nz, off, dx: Math.cos(a), dz: Math.sin(a), items: [] }; groups.push(g); }
    const s0 = w.ax * g.dx + w.az * g.dz, s1 = w.bx * g.dx + w.bz * g.dz;
    g.items.push({ s0: Math.min(s0, s1), s1: Math.max(s0, s1), y0: w.y0, y1: w.y1, id: w.id });
  }
  for (const g of groups) {
    g.items.sort((p, q) => p.s0 - q.s0);
    let cur = null;
    const flush = () => { if (cur) out.push({ id: cur.id, kind: 'wall', ax: g.nx * g.off + g.dx * cur.s0, az: g.nz * g.off + g.dz * cur.s0, bx: g.nx * g.off + g.dx * cur.s1, bz: g.nz * g.off + g.dz * cur.s1, y0: cur.y0, y1: cur.y1 }); };
    for (const it of g.items) {
      if (cur && it.s0 <= cur.s1 + 0.25) { cur.s1 = Math.max(cur.s1, it.s1); cur.y0 = Math.min(cur.y0, it.y0); cur.y1 = Math.max(cur.y1, it.y1); }
      else { flush(); cur = { ...it }; }
    }
    flush();
  }
  return [...out, ...special];
}

// Round soft dot for point clouds (shared).
let _dot = null;
function dotTexture() {
  if (_dot) return _dot;
  const c = document.createElement('canvas'); c.width = c.height = 32;
  const g = c.getContext('2d'), r = g.createRadialGradient(16, 16, 0, 16, 16, 16);
  r.addColorStop(0, 'rgba(255,255,255,1)'); r.addColorStop(0.6, 'rgba(255,255,255,0.8)'); r.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = r; g.fillRect(0, 0, 32, 32);
  return (_dot = new THREE.CanvasTexture(c));
}
