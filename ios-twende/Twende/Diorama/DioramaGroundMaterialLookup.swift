import Foundation
import Metal
import simd

/// CPU view of a saved tile's ground finish, matching the shader: the raster material code, overridden
/// by any analytic finish layer that was painted after that pixel (compact packages, see
/// `DioramaGroundPainter`). Used by read-time planting and estate walls so trees and walls never land on
/// roads or paving whose exact edges live in the vector layers rather than the raster.
nonisolated struct DioramaGroundMaterialLookup {
    private let rect: DioramaRect
    private let side: Int
    /// Level-0 alpha resampled to at most 1024², row 0 = north (same as the texture).
    private let alpha: [UInt8]
    private let paint: UnsafePointer<DioramaPaintTriangle>
    private let paintCount: Int
    private let table: UnsafePointer<SIMD2<UInt32>>
    private let tableCount: Int
    private let indices: UnsafePointer<UInt32>
    private let indexCount: Int
    private let hasFinishes: Bool

    init(texture: MTLTexture, rect: DioramaRect, paint: MTLBuffer, paintCount: Int, table: MTLBuffer, tableCount: Int,
         indices: MTLBuffer, indexCount: Int) {
        self.rect = rect
        let side = max(1, min(1024, texture.width))
        self.side = side
        var alpha = [UInt8](repeating: 0, count: side * side)
        var row = [UInt8](repeating: 0, count: texture.width * 4)
        for y in 0..<side {
            let sy = min(texture.height - 1, y * texture.height / side)
            row.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, sy, texture.width, 1), mipmapLevel: 0)
            }
            for x in 0..<side { alpha[y * side + x] = row[min(texture.width - 1, x * texture.width / side) * 4 + 3] }
        }
        self.alpha = alpha
        self.paint = UnsafePointer(paint.contents().assumingMemoryBound(to: DioramaPaintTriangle.self))
        self.paintCount = paintCount
        self.table = UnsafePointer(table.contents().assumingMemoryBound(to: SIMD2<UInt32>.self))
        self.tableCount = tableCount
        self.indices = UnsafePointer(indices.contents().assumingMemoryBound(to: UInt32.self))
        self.indexCount = indexCount
        let triangles = UnsafeBufferPointer(start: self.paint, count: paintCount)
        hasFinishes = tableCount == DioramaVectorPaint.cells * DioramaVectorPaint.cells
            && triangles.contains { $0.color.w < DioramaGroundPainter.hybridThreshold }
    }

    /// Material code (`DioramaGroundPainter.Material`) at a local point, or nil outside the tile.
    func code(_ p: DV2) -> Int? {
        let u = (p.x - rect.minX) / rect.width, v = (p.y - rect.minY) / rect.height
        guard u >= 0, v >= 0, u < 1, v < 1 else { return nil }
        let x = min(side - 1, Int(u * Double(side))), y = min(side - 1, Int((1 - v) * Double(side)))
        let byte = Int(alpha[y * side + x])
        var code = byte / 32
        guard hasFinishes else { return code }
        let epoch = Float(byte & 31)
        let cells = DioramaVectorPaint.cells
        let cx = min(cells - 1, Int(u * Double(cells))), cy = min(cells - 1, Int(v * Double(cells)))
        let entry = table[cy * cells + cx]
        let q = SIMD3<Float>(Float(p.x), Float(p.y), 1)
        let start = Int(entry.x), end = min(indexCount, start + Int(entry.y))
        guard start < end else { return code }
        for k in start..<end {
            let i = Int(indices[k])
            guard i < paintCount else { continue }
            let t = paint[i]
            guard t.color.w < DioramaGroundPainter.hybridThreshold, t.edge1.w >= epoch - 0.5 else { continue }
            func inside(_ e: SIMD4<Float>) -> Bool { simd_dot(SIMD3(e.x, e.y, e.z), q) >= 0 }
            if inside(t.edge0) && inside(t.edge1) && inside(t.edge2) {
                code = Int(-t.color.w - DioramaGroundPainter.hybridBase)
            }
        }
        return code
    }
}
