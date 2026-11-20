import Foundation

/// Constant-velocity Kalman filter for one scalar (position, velocity).
/// With diagonal process/measurement noise the 8-state box filter used by SORT/ByteTrack/BoT-SORT
/// (cx, cy, w, h + velocities) decouples exactly into four of these.
struct ScalarCVFilter: Sendable, Equatable {
    var p: Double
    var v: Double = 0
    var c11: Double
    var c12: Double = 0
    var c22: Double

    init(position: Double, positionVariance: Double, velocityVariance: Double) {
        p = position; c11 = positionVariance; c22 = velocityVariance
    }

    mutating func predict(dt: Double, accelSigma: Double) {
        guard dt > 0 else { return }
        p += v * dt
        let q = accelSigma * accelSigma
        let n11 = c11 + dt * (2 * c12 + dt * c22) + q * dt * dt * dt * dt / 4
        let n12 = c12 + dt * c22 + q * dt * dt * dt / 2
        c22 += q * dt * dt
        c11 = n11; c12 = n12
    }

    /// Continuous white-noise-acceleration model: the result does not depend on how the interval is split into steps.
    /// `density` is in (units)^2 / s^3. Used for metric ground-plane tracks (same model as the hub).
    mutating func predict(dt: Double, density: Double) {
        guard dt > 0 else { return }
        p += v * dt
        let n11 = c11 + dt * (2 * c12 + dt * c22) + density * dt * dt * dt / 3
        let n12 = c12 + dt * c22 + density * dt * dt / 2
        c22 += density * dt
        c11 = n11; c12 = n12
    }

    mutating func update(z: Double, r: Double) {
        let s = c11 + r
        guard s > 0 else { return }
        let k1 = c11 / s, k2 = c12 / s, y = z - p
        p += k1 * y
        v += k2 * y
        let n11 = (1 - k1) * c11, n12 = (1 - k1) * c12, n22 = c22 - k2 * c12
        c11 = n11; c12 = n12; c22 = max(n22, 0)
    }
}

/// Bounding-box Kalman filter in normalised image coordinates.
struct BoxKalmanFilter: Sendable, Equatable {
    var cx: ScalarCVFilter, cy: ScalarCVFilter, w: ScalarCVFilter, h: ScalarCVFilter

    init(box: NormRect, measurementSigma: Double) {
        let pv = measurementSigma * measurementSigma * 4
        let vv = 0.25
        cx = ScalarCVFilter(position: box.cx, positionVariance: pv, velocityVariance: vv)
        cy = ScalarCVFilter(position: box.cy, positionVariance: pv, velocityVariance: vv)
        w = ScalarCVFilter(position: box.w, positionVariance: pv, velocityVariance: vv)
        h = ScalarCVFilter(position: box.h, positionVariance: pv, velocityVariance: vv)
    }

    var box: NormRect { NormRect(cx: cx.p, cy: cy.p, w: max(w.p, 0.005), h: max(h.p, 0.005)) }
    var positionSigma: Double { max(cx.c11, cy.c11).squareRoot() }
    var scaleRate: Double { w.v / max(w.p, 0.01) + h.v / max(h.p, 0.01) }

    mutating func predict(dt: Double, accelPosition: Double, accelSize: Double) {
        cx.predict(dt: dt, accelSigma: accelPosition); cy.predict(dt: dt, accelSigma: accelPosition)
        w.predict(dt: dt, accelSigma: accelSize); h.predict(dt: dt, accelSigma: accelSize)
    }

    mutating func update(box: NormRect, r: Double) {
        cx.update(z: box.cx, r: r); cy.update(z: box.cy, r: r)
        w.update(z: box.w, r: r); h.update(z: box.h, r: r)
    }

    /// Camera-motion compensation (BoT-SORT style): move the state with the global image motion.
    mutating func shift(dx: Double, dy: Double) { cx.p += dx; cy.p += dy }
    mutating func inflatePosition(sigma: Double) { cx.c11 += sigma * sigma; cy.c11 += sigma * sigma }
    mutating func setVelocity(vx: Double, vy: Double) { cx.v = vx; cy.v = vy }
}
