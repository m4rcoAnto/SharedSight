import Foundation

/// Axis-aligned rectangle in normalised image coordinates (origin top-left, x right, y down, range 0...1).
public struct NormRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double

    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public init(cx: Double, cy: Double, w: Double, h: Double) { self.init(x: cx - w / 2, y: cy - h / 2, w: w, h: h) }

    public var cx: Double { x + w / 2 }
    public var cy: Double { y + h / 2 }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var area: Double { max(0, w) * max(0, h) }

    public func intersection(_ o: NormRect) -> Double {
        let iw = min(maxX, o.maxX) - max(x, o.x)
        let ih = min(maxY, o.maxY) - max(y, o.y)
        return (iw > 0 && ih > 0) ? iw * ih : 0
    }

    public func iou(_ o: NormRect) -> Double {
        let i = intersection(o)
        let u = area + o.area - i
        return u > 0 ? i / u : 0
    }

    /// Fraction of this rectangle covered by `o`.
    public func coveredFraction(by o: NormRect) -> Double { area > 0 ? intersection(o) / area : 0 }

    public var clampedToUnit: NormRect {
        let x0 = min(max(x, 0), 1), y0 = min(max(y, 0), 1)
        let x1 = min(max(maxX, 0), 1), y1 = min(max(maxY, 0), 1)
        return NormRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }
}

public struct Vec3: Codable, Equatable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { dot(self).squareRoot() }
}

/// Rigid transform stored as a column-major 4x4 matrix (same layout as simd_float4x4 / ARKit).
/// World convention: right-handed, +Y up (ARKit gravity alignment). Camera looks along its local -Z.
public struct Pose: Codable, Equatable, Sendable {
    public var m: [Double]

    public init(columnMajor m: [Double]) {
        precondition(m.count == 16, "Pose needs 16 values")
        self.m = m
    }

    public static let identity = Pose(columnMajor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    /// Rotation of `yawDeg` about +Y followed by translation `t` (test / calibration helper).
    public static func yaw(_ yawDeg: Double, translation t: Vec3) -> Pose {
        let a = yawDeg * .pi / 180, c = cos(a), s = sin(a)
        return Pose(columnMajor: [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, t.x, t.y, t.z, 1])
    }

    public var translation: Vec3 { Vec3(m[12], m[13], m[14]) }
    public func axis(_ i: Int) -> Vec3 { Vec3(m[i * 4], m[i * 4 + 1], m[i * 4 + 2]) }

    public func transform(_ p: Vec3) -> Vec3 {
        Vec3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
             m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
             m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
    }

    /// Inverse valid for rigid transforms (rotation + translation).
    public func inverseRigid() -> Pose {
        let t = translation
        let ax = axis(0), ay = axis(1), az = axis(2)
        return Pose(columnMajor: [ax.x, ay.x, az.x, 0, ax.y, ay.y, az.y, 0, ax.z, ay.z, az.z, 0,
                                  -ax.dot(t), -ay.dot(t), -az.dot(t), 1])
    }

    public static func * (a: Pose, b: Pose) -> Pose {
        var r = [Double](repeating: 0, count: 16)
        for c in 0..<4 { for row in 0..<4 {
            var s = 0.0
            for k in 0..<4 { s += a.m[k * 4 + row] * b.m[c * 4 + k] }
            r[c * 4 + row] = s
        } }
        return Pose(columnMajor: r)
    }
}
