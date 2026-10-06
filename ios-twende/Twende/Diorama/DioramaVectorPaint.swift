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

    init(rings: [(ring: [DV2], color: SIMD4<Float>)] = [], rect: DioramaRect? = nil) {
        guard let rect else { return }
        var bins = [[UInt32]](repeating: [], count: Self.cells * Self.cells)
        func cell(_ value: Double, _ origin: Double, _ extent: Double) -> Int {
            min(Self.cells - 1, max(0, Int(floor((value - origin) / extent * Double(Self.cells)))))
        }
        for item in rings {
            let ring = DioramaPolygon.counterClockwise(item.ring)
            for (i, j, k) in DioramaPolygon.triangulate(ring) {
                let points = [ring[i], ring[j], ring[k]]
                func edge(_ a: DV2, _ b: DV2) -> SIMD4<Float> {
                    let inward = (b - a).normalized.left
                    return SIMD4(Float(inward.x), Float(inward.y), Float(-inward.dot(a)), 0)
                }
                let index = UInt32(triangles.count)
                triangles.append(.init(edge0: edge(points[0], points[1]), edge1: edge(points[1], points[2]), edge2: edge(points[2], points[0]), color: item.color))
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
