import CoreLocation
import simd

/// Exposed-edge distance of a connected HD footprint, in the renderer's shared peninsula frame.
/// Interior tile borders are deliberately absent: erosion acts on the union, not on each rectangle.
nonisolated struct DioramaUnionShape: Sendable {
    static let capacity: Int = 9
    let cells: [simd_float4x4]
    let emptyInset: Float

    init(tiles: Set<DioramaTileID>) {
        precondition(tiles.count <= Self.capacity)
        let projection = DioramaProjection(origin: CLLocationCoordinate2D(latitude: -6.75, longitude: 39.28))
        cells = tiles.sorted { $0.key < $1.key }.map { tile in
            let rect = projection.rect(of: tile)
            let exposed = SIMD4<Float>(tiles.contains(tile.offset(dx: -1, dy: 0)) ? 0 : 1,
                tiles.contains(tile.offset(dx: 0, dy: 1)) ? 0 : 1,
                tiles.contains(tile.offset(dx: 1, dy: 0)) ? 0 : 1,
                tiles.contains(tile.offset(dx: 0, dy: -1)) ? 0 : 1)
            return simd_float4x4(columns: (SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.maxX), Float(rect.maxY)),
                exposed, .zero, .zero))
        }
        let low = cells.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, SIMD2($1[0].x, $1[0].y)) }
        let high = cells.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, SIMD2($1[0].z, $1[0].w)) }
        emptyInset = cells.isEmpty ? 0 : simd_length(high - low) + DioramaRevealStyle.support + 2
    }

    /// Fixed-layout tuple mirrors Metal's float4x4[9], without pointers or per-frame buffers.
    func write(to uniforms: inout DioramaShaderUniforms) {
        let padded = cells + Array(repeating: simd_float4x4(), count: Self.capacity - cells.count)
        uniforms.unionShapes = (padded[0], padded[1], padded[2], padded[3], padded[4], padded[5], padded[6], padded[7], padded[8])
    }

    static func coverage(_ local: SIMD3<Float>, uniforms: DioramaShaderUniforms) -> Float {
        guard uniforms.unionState.x > 0.5 else { return 1 }
        let p = SIMD2(local.x, local.y) * uniforms.materialFrame.z + SIMD2(uniforms.materialFrame.x, uniforms.materialFrame.y)
        let c = uniforms.unionShapes
        let cells = [c.0, c.1, c.2, c.3, c.4, c.5, c.6, c.7, c.8]
        var inside: Bool = false
        var squared: Float = .greatestFiniteMagnitude
        for cell in cells.prefix(Int(uniforms.unionState.y)) {
            let b = cell[0], e = cell[1]
            inside = inside || (p.x >= b.x && p.y >= b.y && p.x <= b.z && p.y <= b.w)
            if e.x > 0.5 { squared = min(squared, distanceSquared(p, SIMD2(b.x, b.y), SIMD2(b.x, b.w))) }
            if e.y > 0.5 { squared = min(squared, distanceSquared(p, SIMD2(b.x, b.y), SIMD2(b.z, b.y))) }
            if e.z > 0.5 { squared = min(squared, distanceSquared(p, SIMD2(b.z, b.y), SIMD2(b.z, b.w))) }
            if e.w > 0.5 { squared = min(squared, distanceSquared(p, SIMD2(b.x, b.w), SIMD2(b.z, b.w))) }
        }
        let distance = sqrt(squared) * (inside ? -1 : 1) + uniforms.unionState.z
        let t = min(1, max(0, (distance + DioramaRevealStyle.feather) / (2 * DioramaRevealStyle.feather)))
        return 1 - t * t * (3 - 2 * t)
    }

    private static func distanceSquared(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let v = b - a
        let t = min(1, max(0, simd_dot(p - a, v) / max(simd_dot(v, v), 0.0001)))
        return simd_length_squared(p - (a + v * t))
    }
}
