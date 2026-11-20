import Foundation

/// A vertical surface (wall, closed or open door leaf, window) seen from above: a segment with a height span.
/// Built only from surfaces the phone actually measured.
public struct WallSegment: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case wall, door, window }
    public var ax: Double, az: Double, bx: Double, bz: Double
    public var y0: Double, y1: Double
    public var kind: Kind

    public init(ax: Double, az: Double, bx: Double, bz: Double, y0: Double, y1: Double, kind: Kind = .wall) {
        self.ax = ax; self.az = az; self.bx = bx; self.bz = bz; self.y0 = y0; self.y1 = y1; self.kind = kind
    }

    /// Footprint of a vertical plane from its vertices (any frame with +Y up). Nil for degenerate input.
    public init?(vertices: [Vec3], kind: Kind = .wall) {
        guard vertices.count >= 3 else { return nil }
        func farthest(from p: Vec3) -> (Vec3, Double) {
            var best = p, far = 0.0
            for v in vertices { let d = (v.x - p.x) * (v.x - p.x) + (v.z - p.z) * (v.z - p.z); if d > far { far = d; best = v } }
            return (best, far)
        }
        let a = farthest(from: vertices[0]).0
        let (b, length2) = farthest(from: a)
        guard length2 >= 0.04 else { return nil }      // shorter than 20 cm: noise
        self.init(ax: a.x, az: a.z, bx: b.x, bz: b.z, y0: vertices.map(\.y).min() ?? 0, y1: vertices.map(\.y).max() ?? 0, kind: kind)
    }
}

/// What hides an object from a camera. `object` = another detected thing standing in the line of sight.
public enum OccluderKind: String, Codable, Sendable { case wall, door, object }

/// Why a camera does or does not have a line of sight to something standing on the floor.
public enum SightRelation: Equatable, Sendable {
    case visible
    case partial                     // part of it is hidden; a detector may still see it
    case occluded(OccluderKind)      // middle and top both hidden: a detector cannot be expected to see it
    case outOfView
    case outOfRange
}

/// A camera reduced to what floor-plan reasoning needs. Nil when the phone points up or down: no heading on the floor.
public struct FloorCamera: Equatable, Sendable {
    public var x: Double, y: Double, z: Double
    public var fx: Double, fz: Double          // unit viewing direction projected on the floor

    public init?(pose: Pose) {
        let f = pose.axis(2) * -1                // camera looks along its local -Z
        let length = (f.x * f.x + f.z * f.z).squareRoot()
        guard length >= 0.2 else { return nil }
        let t = pose.translation
        x = t.x; y = t.y; z = t.z; fx = f.x / length; fz = f.z / length
    }

    public init(x: Double, y: Double, z: Double, headingX: Double, headingZ: Double) {
        let l = max((headingX * headingX + headingZ * headingZ).squareRoot(), 1e-9)
        self.x = x; self.y = y; self.z = z; fx = headingX / l; fz = headingZ / l
    }

    /// Horizontal distance and bearing (degrees, + to the right of the viewing direction) of a floor point.
    public func locate(x px: Double, z pz: Double) -> (distance: Double, bearingDeg: Double) {
        let dx = px - x, dz = pz - z
        return ((dx * dx + dz * dz).squareRoot(), atan2(dx * -fz + dz * fx, dx * fx + dz * fz) * 180 / .pi)
    }
}

public struct SightTarget: Equatable, Sendable {
    public var id: Int?
    public var x: Double, z: Double, floorY: Double, height: Double, radius: Double
    public init(id: Int? = nil, x: Double, z: Double, floorY: Double, height: Double, radius: Double) {
        self.id = id; self.x = x; self.z = z; self.floorY = floorY; self.height = height; self.radius = radius
    }
}

/// Nominal sizes (metres) for the classes that matter to occlusion reasoning. Used only where no size was measured.
public enum NominalSize {
    private static let heights: [String: Double] = [
        "person": 1.7, "bicycle": 1.05, "car": 1.5, "motorcycle": 1.15, "bus": 3.0, "truck": 2.8, "train": 3.5,
        "dog": 0.55, "cat": 0.3, "horse": 1.65, "sheep": 0.85, "cow": 1.45, "bird": 0.22,
        "chair": 0.9, "couch": 0.82, "bench": 0.85, "bed": 0.6, "dining table": 0.75, "potted plant": 0.85,
        "refrigerator": 1.8, "tv": 0.62, "oven": 0.88, "sink": 0.88, "toilet": 0.75, "suitcase": 0.65,
        "traffic light": 3.0, "stop sign": 2.2, "parking meter": 1.3, "fire hydrant": 0.7,
    ]
    private static let widths: [String: Double] = [
        "person": 0.5, "car": 1.8, "bus": 2.5, "truck": 2.4, "couch": 1.9, "bed": 1.6, "dining table": 1.4,
        "refrigerator": 0.7, "bench": 1.5, "horse": 0.55, "cow": 0.65, "dog": 0.25, "chair": 0.5,
    ]
    private static let movers: Set<String> = [
        "person", "bicycle", "car", "motorcycle", "bus", "truck", "train", "boat", "airplane", "skateboard", "sports ball",
        "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe",
    ]
    /// Fixed things big enough to be in the way of someone walking. Small objects (bottles, cups, bags, phones,
    /// books…) are not tracked at all: they are not obstacles for a walking person and only add noise and work.
    private static let obstacles: Set<String> = [
        "chair", "couch", "bed", "dining table", "bench", "potted plant", "toilet", "refrigerator", "oven", "sink", "tv",
        "suitcase", "fire hydrant", "stop sign", "parking meter", "traffic light", "umbrella",
    ]
    /// Worth tracking: whatever can move by itself, and obstacles big enough to walk into.
    public static func isRelevant(_ label: String) -> Bool { movers.contains(label) || obstacles.contains(label) }
    public static func height(_ label: String) -> Double { heights[label] ?? 0.5 }
    public static func width(_ label: String) -> Double { widths[label] ?? 0.4 }
    /// Things that can change place by themselves. Only these get a motion prediction while hidden.
    public static func isMover(_ label: String) -> Bool { movers.contains(label) }
    /// Plausible acceleration in m/s^2 for the motion model.
    public static func acceleration(_ label: String) -> Double {
        switch label {
        case "person": return 1.2
        case "dog", "cat": return 1.6
        case "car", "motorcycle", "truck", "bus": return 2.5
        default: return isMover(label) ? 2.0 : 0.05
        }
    }
}

/// Floor-plan line-of-sight tests. Same rules as the hub (Server/geometry.mjs), so a phone alone and the hub agree.
public enum SightGeometry {
    /// Parameter in (0,1) along p->q where it crosses segment a->b, or nil.
    public static func segmentHit(px: Double, pz: Double, qx: Double, qz: Double, _ w: WallSegment) -> Double? {
        let rx = qx - px, rz = qz - pz, sx = w.bx - w.ax, sz = w.bz - w.az
        let den = rx * sz - rz * sx
        guard abs(den) > 1e-9 else { return nil }
        let t = ((w.ax - px) * sz - (w.az - pz) * sx) / den
        let u = ((w.ax - px) * rz - (w.az - pz) * rx) / den
        return (t > 1e-6 && t < 1 - 1e-6 && u >= 0 && u <= 1) ? t : nil
    }

    public static func relation(camera: FloorCamera, fovDeg: Double, range: Double, target: SightTarget,
                                walls: [WallSegment], blockers: [SightTarget] = [])
        -> (relation: SightRelation, distance: Double, bearingDeg: Double) {
        let (distance, bearing) = camera.locate(x: target.x, z: target.z)
        if distance > range { return (.outOfRange, distance, bearing) }
        if abs(bearing) > fovDeg / 2 - 2 { return (.outOfView, distance, bearing) }
        var hidden = 0
        var occluder: OccluderKind?
        let checks = [target.floorY + target.height * 0.5, target.floorY + target.height * 0.92]
        for sightY in checks {
            var blocked: OccluderKind?
            for w in walls where w.kind != .window {                    // glass: the camera sees through it
                guard let t = segmentHit(px: camera.x, pz: camera.z, qx: target.x, qz: target.z, w) else { continue }
                let y = camera.y + t * (sightY - camera.y)
                if y >= w.y0 - 0.05 && y <= w.y1 + 0.05 { blocked = w.kind == .door ? .door : .wall; break }
            }
            if blocked == nil {
                for b in blockers where !(b.id != nil && b.id == target.id) {
                    let dx = target.x - camera.x, dz = target.z - camera.z, l2 = dx * dx + dz * dz
                    guard l2 > 0 else { continue }
                    let t = min(1, max(0, ((b.x - camera.x) * dx + (b.z - camera.z) * dz) / l2))
                    let ox = b.x - (camera.x + t * dx), oz = b.z - (camera.z + t * dz)
                    guard t > 0.02, t < 0.98, (ox * ox + oz * oz).squareRoot() <= b.radius, t * distance <= distance - target.radius else { continue }
                    if camera.y + t * (sightY - camera.y) <= b.floorY + b.height { blocked = .object; break }
                }
            }
            if let blocked { hidden += 1; occluder = blocked }
        }
        if hidden == checks.count, let occluder { return (.occluded(occluder), distance, bearing) }
        return (hidden > 0 ? .partial : .visible, distance, bearing)
    }

    /// Moves a floor point by (dx, dz) but never through a wall: the step stops just before the first one crossed.
    public static func move(x: Double, z: Double, dx: Double, dz: Double, walls: [WallSegment], floorY: Double)
        -> (x: Double, z: Double, hit: WallSegment?) {
        var best: Double?
        var wall: WallSegment?
        for w in walls where w.y0 <= floorY + 0.5 {                     // lintels and window frames are not in the way
            if let t = segmentHit(px: x, pz: z, qx: x + dx, qz: z + dz, w), best == nil || t < best! { best = t; wall = w }
        }
        guard let t = best else { return (x + dx, z + dz, nil) }
        let k = max(0, t - 0.05 / max((dx * dx + dz * dz).squareRoot(), 1e-6))
        return (x + dx * k, z + dz * k, wall)
    }
}
