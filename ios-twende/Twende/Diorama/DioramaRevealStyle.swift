import Foundation
import simd

/// Shared finite reveal and permanent edge fields; CPU labels match the Metal coverage.
nonisolated enum DioramaRevealStyle {
    static let feather: Float = 48
    static let variation: Float = 10
    static let support: Float = feather + variation
    static let edgeWidth: Float = 80

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
        return 1 - smooth((distance(p, reveal: reveal) + feather) / (2 * feather))
    }

    static func edgeCoverage(_ p: SIMD3<Float>, bounds: SIMD4<Float>, edges: SIMD4<Float>, frame: SIMD4<Float>) -> Float {
        let world = SIMD2(p.x, p.y) * frame.z + SIMD2(frame.x, frame.y)
        let ripple = variation * (0.6 * sin(world.x * 0.025 + world.y * 0.011)
            + 0.4 * sin(world.y * 0.037 - world.x * 0.009))
        let d = SIMD4(p.x - bounds.x, p.y - bounds.y, bounds.z - p.x, bounds.w - p.y)
        var result: Float = 1
        for i in 0..<4 { result *= 1 - edges[i] * (1 - smooth((d[i] - variation + ripple) / edgeWidth)) }
        return result
    }

    static func sceneCoverage(_ p: SIMD3<Float>, reveal: SIMD4<Float>, bounds: SIMD4<Float>, edges: SIMD4<Float>, state: SIMD4<Float>, frame: SIMD4<Float>) -> Float {
        let transition = coverage(p, reveal: reveal)
        let outer = edgeCoverage(p, bounds: bounds, edges: edges, frame: frame)
        if state.y > 1.5 {
            let full = transition * edgeCoverage(p, bounds: bounds, edges: SIMD4(repeating: 1), frame: frame)
            return outer * (1 - full) * state.x
        }
        return outer * transition * state.x
    }

    private static func smooth(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
