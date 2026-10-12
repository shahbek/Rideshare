import Foundation
import simd

/// Analytic half-planes, evaluated on the existing ground fragment (not raised decal meshes).
nonisolated struct DioramaPaintTriangle: Sendable {
    var edge0: SIMD4<Float>
    var edge1: SIMD4<Float>
    var edge2: SIMD4<Float>
    var color: SIMD4<Float>
    static let empty = Self(edge0: .zero, edge1: .zero, edge2: .zero, color: .zero)
}

nonisolated struct DioramaVectorPaint: Sendable {
    static let cells = 64
    var triangles: [DioramaPaintTriangle] = []
    var table: [SIMD2<UInt32>] = Array(repeating: .zero, count: cells * cells)
    var indices: [UInt32] = []

    /// edge0.w carries the finish layer (pieces of one operation union); edge1.w the raster epoch the
    /// layer was painted in (compact tiles, see `DioramaGroundPainter`).
    init(rings: [(ring: [DV2], color: SIMD4<Float>)] = [], rect: DioramaRect? = nil, layers: [UInt32] = [], epochs: [UInt32] = []) {
        guard let rect else { return }
        var bins = [[UInt32]](repeating: [], count: Self.cells * Self.cells)
        func cell(_ value: Double, _ origin: Double, _ extent: Double) -> Int {
            min(Self.cells - 1, max(0, Int(floor((value - origin) / extent * Double(Self.cells)))))
        }
        for (operation, item) in rings.enumerated() {
            // Airport finish operations union their pieces before compositing; ordinary lane paint stays unchanged.
            let layer = operation < layers.count ? Float(layers[operation]) : 0
            let epoch = operation < epochs.count ? Float(epochs[operation]) : layer
            let ring = DioramaPolygon.counterClockwise(item.ring)
            let ringBounds = DioramaRect.bounding(ring)
            guard ringBounds.maxX >= rect.minX - 0.6, ringBounds.minX <= rect.maxX + 0.6,
                  ringBounds.maxY >= rect.minY - 0.6, ringBounds.minY <= rect.maxY + 0.6 else { continue }
            for (i, j, k) in DioramaPolygon.triangulate(ring) {
                let points = [ring[i], ring[j], ring[k]]
                func edge(_ a: DV2, _ b: DV2, _ w: Float) -> SIMD4<Float> {
                    let inward = (b - a).normalized.left
                    return SIMD4(Float(inward.x), Float(inward.y), Float(-inward.dot(a)), w)
                }
                let index = UInt32(triangles.count)
                triangles.append(.init(edge0: edge(points[0], points[1], layer), edge1: edge(points[1], points[2], epoch),
                                       edge2: edge(points[2], points[0], layer), color: item.color))
                let bounds = DioramaRect.bounding(points).expanded(by: 0.6)
                for y in cell(bounds.minY, rect.minY, rect.height)...cell(bounds.maxY, rect.minY, rect.height) {
                    for x in cell(bounds.minX, rect.minX, rect.width)...cell(bounds.maxX, rect.minX, rect.width) { bins[y * Self.cells + x].append(index) }
                }
            }
        }
        for i in bins.indices {
            table[i] = SIMD2(UInt32(indices.count), UInt32(bins[i].count))
            indices.append(contentsOf: bins[i])
        }
    }
}
