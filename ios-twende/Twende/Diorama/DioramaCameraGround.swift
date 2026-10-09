import Foundation
import simd

/// Queries the existing packed terrain, never downloads elevation or rebuilds geometry for the camera.
/// Keep the last supporting triangle so most interpolation frames need only three barycentric weights.
nonisolated struct DioramaCameraGround {
    private var lastTriangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)?

    mutating func height(_ p: DV2, vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [DioramaRenderLayer.Range]) -> Double? {
        let point = SIMD2<Float>(Float(p.x), Float(p.y))
        if let t = lastTriangle, let h = Self.height(point, t.0, t.1, t.2) { return h }
        for range in ranges where range.category == .ground && point.x >= range.minimum.x && point.x <= range.maximum.x
            && point.y >= range.minimum.y && point.y <= range.maximum.y {
            for i in stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                let a = vertices[Int(indices[i])], b = vertices[Int(indices[i + 1])], c = vertices[Int(indices[i + 2])]
                // The painted heightfield, not pool coping, rock faces, stairs or architecture.
                guard a.appearance.y == 9 && b.appearance.y == 9 && c.appearance.y == 9 else { continue }
                let x = SIMD3(a.position.x, a.position.y, a.position.z)
                let y = SIMD3(b.position.x, b.position.y, b.position.z)
                let z = SIMD3(c.position.x, c.position.y, c.position.z)
                if let h = Self.height(point, x, y, z) { lastTriangle = (x, y, z); return h }
            }
        }
        lastTriangle = nil
        return nil
    }
    /// Resident shared-buffer form (packed vertices; painted heightfield code 9).
    mutating func height(_ p: DV2, ranges: [DioramaRenderLayer.Range], index: (Int) -> UInt32,
                         position: (Int) -> SIMD4<Float>, isGround: (Int) -> Bool) -> Double? {
        let point = SIMD2<Float>(Float(p.x), Float(p.y))
        if let t = lastTriangle, let h = Self.height(point, t.0, t.1, t.2) { return h }
        for range in ranges where range.category == .ground && point.x >= range.minimum.x && point.x <= range.maximum.x
            && point.y >= range.minimum.y && point.y <= range.maximum.y {
            for i in stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                let ia = Int(index(i)), ib = Int(index(i + 1)), ic = Int(index(i + 2))
                guard isGround(ia), isGround(ib), isGround(ic) else { continue }
                let a = position(ia), b = position(ib), c = position(ic)
                let x = SIMD3(a.x, a.y, a.z), y = SIMD3(b.x, b.y, b.z), z = SIMD3(c.x, c.y, c.z)
                if let h = Self.height(point, x, y, z) { lastTriangle = (x, y, z); return h }
            }
        }
        lastTriangle = nil
        return nil
    }
    /// Grid-accelerated form: only the triangles overlapping the query's 8 m cell are tested.
    mutating func height(_ p: DV2, grid: DioramaGroundIndex, index: (Int) -> UInt32, position: (Int) -> SIMD4<Float>) -> Double? {
        let point = SIMD2<Float>(Float(p.x), Float(p.y))
        if let t = lastTriangle, let h = Self.height(point, t.0, t.1, t.2) { return h }
        for start in grid.candidates(point) {
            let i = Int(start)
            let a = position(Int(index(i))), b = position(Int(index(i + 1))), c = position(Int(index(i + 2)))
            let x = SIMD3(a.x, a.y, a.z), y = SIMD3(b.x, b.y, b.z), z = SIMD3(c.x, c.y, c.z)
            if let h = Self.height(point, x, y, z) { lastTriangle = (x, y, z); return h }
        }
        lastTriangle = nil
        return nil
    }
    private static func height(_ p: SIMD2<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Double? {
        let v0 = SIMD2(b.x - a.x, b.y - a.y), v1 = SIMD2(c.x - a.x, c.y - a.y)
        let v2 = p - SIMD2(a.x, a.y)
        let determinant = v0.x * v1.y - v1.x * v0.y
        guard abs(determinant) > 0.00001 else { return nil }
        let u = (v2.x * v1.y - v1.x * v2.y) / determinant
        let v = (v0.x * v2.y - v2.x * v0.y) / determinant
        guard u >= -0.0001, v >= -0.0001, u + v <= 1.0001 else { return nil }
        return Double(a.z + u * (b.z - a.z) + v * (c.z - a.z))
    }
}
