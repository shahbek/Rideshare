import Foundation
import simd

/// Shared finite reveal support; shader and CPU clipping must agree on the outer envelope.
nonisolated enum DioramaRevealStyle {
    static let feather: Float = 36
    static let variation: Float = 8
    static let support: Float = feather + variation

    static func distance(_ p: SIMD3<Float>, reveal: SIMD4<Float>) -> Float {
        let ripple = variation * (0.6 * sin(p.x * 0.025 + p.y * 0.011)
            + 0.4 * sin(p.y * 0.037 - p.x * 0.009))
        if reveal.w > 1.5 {
            let d = p.x * reveal.x + p.y * reveal.y - reveal.z + ripple
            return reveal.w > 2.5 ? -d : d
        }
        let radius = min(48, max(0, reveal.z) * 0.16)
        let q = SIMD2(abs(p.x - reveal.x), abs(p.y - reveal.y)) - SIMD2(repeating: reveal.z - radius)
        return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - radius + ripple
    }

    static func coverage(_ p: SIMD3<Float>, reveal: SIMD4<Float>) -> Float {
        guard reveal.w > 0.5 else { return 1 }
        let t = min(1, max(0, (distance(p, reveal: reveal) + feather) / (2 * feather)))
        return 1 - t * t * (3 - 2 * t)
    }
}
