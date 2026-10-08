import Foundation
import simd

/// Shared finite reveal and permanent edge fields; CPU labels match the Metal coverage.
nonisolated enum DioramaRevealStyle {
    static let feather: Float = 8
    static let variation: Float = 1.5
    static let support: Float = feather + variation
    static let edgeWidth: Float = 12

    /// Grow from every connected side; an isolated tile retains the approved central reveal.
    static func growthSeed(edges: SIMD4<Float>) -> SIMD4<Float> {
        var mask: Int = 0
        for i in 0..<4 where edges[i] < 0.5 { mask |= 1 << i }
        return mask == 0 ? SIMD4(0, 0, -support - 2, 1) : SIMD4(Float(mask), 0, -support - 2, 4)
    }

    static func distance(_ p: SIMD3<Float>, reveal: SIMD4<Float>, bounds: SIMD4<Float> = .zero) -> Float {
        let ripple = variation * (0.6 * sin(p.x * 0.025 + p.y * 0.011)
            + 0.4 * sin(p.y * 0.037 - p.x * 0.009))
        if reveal.w > 3.5 {
            let point = SIMD2(p.x, p.y)
            let mask = Int(reveal.x)
            let a = SIMD2(bounds.x, bounds.y), b = SIMD2(bounds.z, bounds.w)
            let segments = [(a, SIMD2(a.x, b.y)), (a, SIMD2(b.x, a.y)),
                (SIMD2(b.x, a.y), b), (SIMD2(a.x, b.y), b)]
            var nearest: Float = .greatestFiniteMagnitude
            for i in 0..<4 where mask & (1 << i) != 0 {
                let (start, end) = segments[i], delta = end - start
                let t = min(1, max(0, simd_dot(point - start, delta) / max(0.0001, simd_length_squared(delta))))
                nearest = min(nearest, simd_length(point - start - t * delta))
            }
            return nearest - reveal.z + ripple
        }
        if reveal.w > 1.5 {
            let d = p.x * reveal.x + p.y * reveal.y - reveal.z + ripple
            return reveal.w > 2.5 ? -d : d
        }
        let radius = min(12, max(0, reveal.z) * 0.08)
        let q = SIMD2(abs(p.x - reveal.x), abs(p.y - reveal.y)) - SIMD2(repeating: reveal.z - radius)
        return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - radius + ripple
    }

    static func coverage(_ p: SIMD3<Float>, reveal: SIMD4<Float>, bounds: SIMD4<Float> = .zero) -> Float {
        guard reveal.w > 0.5 else { return 1 }
        return 1 - smooth((distance(p, reveal: reveal, bounds: bounds) + feather) / (2 * feather))
    }

    static func edgeCoverage(_ p: SIMD3<Float>, bounds: SIMD4<Float>, edges: SIMD4<Float>, frame: SIMD4<Float>) -> Float {
        let d = SIMD4(p.x - bounds.x, p.y - bounds.y, bounds.z - p.x, bounds.w - p.y)
        var result: Float = 1
        for i in 0..<4 where edges[i] > 0 && d[i] < edgeWidth {
            result *= 1 - edges[i] * (1 - smooth(d[i] / edgeWidth))
        }
        return result
    }

    static func sceneCoverage(_ p: SIMD3<Float>, reveal: SIMD4<Float>, bounds: SIMD4<Float>, edges: SIMD4<Float>, state: SIMD4<Float>, frame: SIMD4<Float>) -> Float {
        let transition = coverage(p, reveal: reveal, bounds: bounds)
        let outer = edgeCoverage(p, bounds: bounds, edges: edges, frame: frame)
        if state.y > 1.5 {
            let full = transition * edgeCoverage(p, bounds: bounds, edges: edges, frame: frame)
            return outer * (1 - full) * state.x
        }
        return outer * transition * state.x
    }

    private static func smooth(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
