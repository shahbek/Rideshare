import simd

/// Bounds how far cached screen-space effects (AO, bloom, reflection) have drifted on screen.
///
/// Rays through a 3×3 grid of the new view are intersected with two horizontal planes that bracket
/// the visible scene, then projected with both transforms. When every probe moves less than one
/// effect texel, re-rendering the effect would only shift it by a sub-texel amount, so the cached
/// output is kept. Any probe that cannot be measured forces a re-render.
nonisolated enum DioramaEffectDrift {
    /// Largest probe displacement between the cached and current transforms, in drawable pixels.
    static func pixels(from cached: simd_double4x4, to current: simd_double4x4,
                       width: Int, height: Int, planes: SIMD2<Double>) -> Double {
        guard cached != current else { return 0 }
        let inverse = current.inverse
        let half = SIMD2<Double>(Double(width), Double(height)) * 0.5
        var worst: Double = 0
        var measured = 0
        for gy in 0..<3 {
            for gx in 0..<3 {
                let ndc = SIMD2<Double>(Double(gx) - 1, Double(gy) - 1) * 0.92
                let a = inverse * SIMD4(ndc.x, ndc.y, 0, 1)
                let b = inverse * SIMD4(ndc.x, ndc.y, 0.5, 1)
                guard abs(a.w) > 1e-12, abs(b.w) > 1e-12 else { return .infinity }
                let p0 = SIMD3(a.x, a.y, a.z) / a.w, p1 = SIMD3(b.x, b.y, b.z) / b.w
                let direction = p1 - p0
                guard abs(direction.z) > 1e-9 else { continue }
                for plane in [planes.x, planes.y] {
                    let point = p0 + direction * ((plane - p0.z) / direction.z)
                    guard point.x.isFinite, point.y.isFinite else { continue }
                    let now = current * SIMD4(point, 1)
                    // Above the horizon the plane lies behind the camera: not visible, nothing to compare.
                    guard now.w > 1e-6 else { continue }
                    let before = cached * SIMD4(point, 1)
                    guard before.w > 1e-6 else { return .infinity }
                    let shift = (SIMD2(before.x, before.y) / before.w - SIMD2(now.x, now.y) / now.w) * half
                    guard shift.x.isFinite, shift.y.isFinite else { return .infinity }
                    worst = max(worst, simd_length(shift))
                    measured += 1
                }
            }
        }
        return measured == 0 ? .infinity : worst
    }
}
