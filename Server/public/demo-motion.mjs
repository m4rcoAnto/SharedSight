// Demo only: constant-velocity forecast, 3 s horizon, conservative footprints.
export function forecastMotion(entities, walls = [], horizon = 3) {
  const valid = entities.filter(e => e.state !== 'lost' && Number.isFinite(e.x) && Number.isFinite(e.z));
  const radius = e => Math.max(0.15, (e.w || 0.5) / 2);
  const velocity = e => ({ x: e.vx || 0, z: e.vz || 0 });
  const distanceToWall = (x, z, w) => {
    const dx = w.bx - w.ax, dz = w.bz - w.az;
    const k = Math.max(0, Math.min(1, ((x - w.ax) * dx + (z - w.az) * dz) / (dx * dx + dz * dz || 1)));
    return Math.hypot(x - w.ax - k * dx, z - w.az - k * dz);
  };
  return valid.filter(e => Math.hypot(e.vx || 0, e.vz || 0) > 0.15).map(e => {
    const v = velocity(e), points = [[e.x, e.z]];
    let hit = null;
    for (let i = 0; i <= Math.round(horizon / 0.025); i++) {
      const t = i * 0.025, x = e.x + v.x * t, z = e.z + v.z * t;
      const wall = walls.find(w => w.y0 < (e.y || 0) + (e.h || 1) && w.y1 > (e.y || 0) + 0.05 && distanceToWall(x, z, w) <= radius(e) + 0.08);
      const obstacle = valid.find(o => {
        if (o.id === e.id || (o.y || 0) >= (e.y || 0) + (e.h || 1) || (o.y || 0) + (o.h || 1) <= (e.y || 0)) return false;
        const ov = velocity(o);
        return Math.hypot(x - o.x - ov.x * t, z - o.z - ov.z * t) <= radius(e) + radius(o) + 0.08;
      });
      if (i > 0) points.push([x, z]);
      if (wall || obstacle) { hit = { t, x, z, label: wall ? (wall.kind === 'door' ? 'porta' : 'parete') : obstacle.label, id: wall?.id ?? obstacle?.id }; break; }
    }
    return { id: e.id, label: e.label, estimated: e.state === 'hidden', points, hit };
  });
}
