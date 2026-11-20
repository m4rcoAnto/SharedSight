// Ground-plane geometry used by the world model. Convention (same as ARKit): right-handed, +Y up, metres,
// camera looking along its local -Z, poses as column-major 4x4 arrays.

export const finite = n => typeof n === 'number' && Number.isFinite(n);

export function cameraFromPose(m) {
  // Viewing direction projected on the floor. Undefined (null yaw) when the phone points straight up or down.
  const fx = -m[8], fz = -m[10], len = Math.hypot(fx, fz);
  return { x: m[12], y: m[13], z: m[14], yaw: len > 0.2 ? Math.atan2(fx, -fz) : null, fx: len > 0.2 ? fx / len : 0, fz: len > 0.2 ? fz / len : 0 };
}

/** Pose looking along `yaw` (radians, 0 = -Z, positive toward +X) from (x, y, z). Used by tests and the simulator. */
export function poseFromYaw(x, y, z, yaw) {
  const c = Math.cos(yaw), s = Math.sin(yaw);
  // Columns: right, up, back (camera looks along -back).
  return [c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, x, y, z, 1];
}

/** A vertical plane seen from above is a segment. Returns null for degenerate or non-vertical input. */
export function wallFromPlane(plane) {
  const v = plane.vertices;
  if (!plane.vertical || !v || v.length < 3) return null;
  let far = 0, a = v[0], b = v[0];
  for (const p of v) { const d = (p.x - v[0].x) ** 2 + (p.z - v[0].z) ** 2; if (d > far) { far = d; a = p; } }
  far = 0;
  for (const p of v) { const d = (p.x - a.x) ** 2 + (p.z - a.z) ** 2; if (d > far) { far = d; b = p; } }
  if (far < 0.04) return null; // shorter than 20 cm: noise
  let y0 = Infinity, y1 = -Infinity;
  for (const p of v) { if (p.y < y0) y0 = p.y; if (p.y > y1) y1 = p.y; }
  return { id: plane.id, kind: plane.kind ?? 'wall', ax: a.x, az: a.z, bx: b.x, bz: b.z, y0, y1 };
}

/** Parameter t in [0,1] along p->q where it crosses segment a->b, or null. */
export function segmentHit(px, pz, qx, qz, ax, az, bx, bz) {
  const rx = qx - px, rz = qz - pz, sx = bx - ax, sz = bz - az;
  const den = rx * sz - rz * sx;
  if (Math.abs(den) < 1e-9) return null;
  const t = ((ax - px) * sz - (az - pz) * sx) / den;
  const u = ((ax - px) * rz - (az - pz) * rx) / den;
  return t > 1e-6 && t < 1 - 1e-6 && u >= 0 && u <= 1 ? t : null;
}

/** Shortest distance from point c to segment p->q, and the parameter of the closest point. */
export function pointSegment(cx, cz, px, pz, qx, qz) {
  const dx = qx - px, dz = qz - pz, l2 = dx * dx + dz * dz;
  const t = l2 > 0 ? Math.min(1, Math.max(0, ((cx - px) * dx + (cz - pz) * dz) / l2)) : 0;
  return { d: Math.hypot(cx - (px + t * dx), cz - (pz + t * dz)), t };
}

/**
 * Why a camera does or does not have a line of sight to a target standing on the floor.
 *   camera: {x,y,z,fx,fz,yaw}, fovDeg: horizontal field of view of the upright image, range in metres
 *   target: {x,z,y (floor height), h (height), r (radius)}
 *   walls: wallFromPlane() output; blockers: [{x,z,y,h,r,id}] other objects that could hide the target
 * Returns {relation: 'visible'|'partial'|'occluded'|'outOfView'|'outOfRange'|'unknown', occluder?, bearingDeg, distance}
 * 'occluded' means both the middle and the top of the target are hidden: a detector cannot be expected to see it.
 */
export function sightRelation(camera, fovDeg, range, target, walls, blockers = []) {
  const dx = target.x - camera.x, dz = target.z - camera.z, dist = Math.hypot(dx, dz);
  if (camera.yaw == null) return { relation: 'unknown', distance: dist, bearingDeg: null };
  const bearing = Math.atan2(dx * -camera.fz + dz * camera.fx, dx * camera.fx + dz * camera.fz) * 180 / Math.PI;
  const out = { distance: dist, bearingDeg: bearing };
  if (dist > range) return { ...out, relation: 'outOfRange' };
  if (Math.abs(bearing) > fovDeg / 2 - 2) return { ...out, relation: 'outOfView' };
  // Two sight lines: to the middle and to the top of the target. Each is tested in plan view, then in height.
  const checks = [target.y + target.h * 0.5, target.y + target.h * 0.92];
  let hidden = 0, occluder = null;
  for (const ty of checks) {
    let blocked = null;
    for (const w of walls) {
      if (w.kind === 'window') continue; // glass: the camera sees through it
      const t = segmentHit(camera.x, camera.z, target.x, target.z, w.ax, w.az, w.bx, w.bz);
      if (t == null) continue;
      const y = camera.y + t * (ty - camera.y);
      if (y >= w.y0 - 0.05 && y <= w.y1 + 0.05) { blocked = { kind: w.kind === 'door' ? 'door' : 'wall', id: w.id }; break; }
    }
    if (!blocked) for (const b of blockers) {
      if (b.id === target.id) continue;
      const near = pointSegment(b.x, b.z, camera.x, camera.z, target.x, target.z);
      if (near.t <= 0.02 || near.t >= 0.98 || near.d > b.r) continue;
      if (near.t * dist > dist - target.r) continue;            // touching the target itself, not in front of it
      const y = camera.y + near.t * (ty - camera.y);
      if (y <= b.y + b.h) { blocked = { kind: 'object', id: b.id, label: b.label }; break; }
    }
    if (blocked) { hidden++; occluder = blocked; }
  }
  if (hidden === checks.length) return { ...out, relation: 'occluded', occluder };
  return { ...out, relation: hidden ? 'partial' : 'visible', occluder: hidden ? occluder : undefined };
}

/** Moves p by (dx, dz) but never through a wall: the step stops just before the first wall it would cross. */
export function moveWithWalls(px, pz, dx, dz, walls, floorY = 0) {
  let best = null, wall = null;
  for (const w of walls) {
    if (w.y0 > floorY + 0.5) continue;                 // lintel, window frame: nothing to walk into
    const t = segmentHit(px, pz, px + dx, pz + dz, w.ax, w.az, w.bx, w.bz);
    if (t != null && (best == null || t < best)) { best = t; wall = w; }
  }
  if (best == null) return { x: px + dx, z: pz + dz, hit: null };
  const k = Math.max(0, best - 0.05 / Math.max(Math.hypot(dx, dz), 1e-6));
  return { x: px + dx * k, z: pz + dz * k, hit: wall };
}

/** Floor region a camera can currently see, as a fan polygon [x0,z0,x1,z1,...] starting at the camera. */
export function visibilityFan(camera, fovDeg, range, walls, blockers = [], rays = 48, floorY = 0) {
  if (camera.yaw == null) return [];
  const out = [camera.x, camera.z], half = fovDeg * Math.PI / 360;
  for (let i = 0; i <= rays; i++) {
    const a = camera.yaw - half + (2 * half * i) / rays;
    const dx = Math.sin(a), dz = -Math.cos(a);
    let t = range;
    for (const w of walls) {
      if (w.kind === 'window' || w.y1 < camera.y - 0.6 || w.y0 > floorY + 0.6) continue;   // low or raised walls do not hide the floor beyond
      const h = segmentHit(camera.x, camera.z, camera.x + dx * range, camera.z + dz * range, w.ax, w.az, w.bx, w.bz);
      if (h != null && h * range < t) t = h * range;
    }
    for (const b of blockers) {
      if (!b.tall) continue;
      const ox = b.x - camera.x, oz = b.z - camera.z, along = ox * dx + oz * dz;
      if (along <= 0 || along >= t) continue;
      const off2 = ox * ox + oz * oz - along * along;
      if (off2 < b.r * b.r) t = Math.max(0.05, along - Math.sqrt(b.r * b.r - off2));
    }
    out.push(camera.x + dx * t, camera.z + dz * t);
  }
  return out;
}
