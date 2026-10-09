import Foundation
import simd

/// Uniform 8 m grid of painted-ground triangles for constant-time height queries.
/// Saved low-detail tiles store their ground as one tile-wide range, so without this every vehicle,
/// shadow receiver and route sample linearly scanned tens of thousands of triangles per query.
/// Read-only after construction; holds index offsets only (no copied geometry).
nonisolated struct DioramaGroundIndex: Sendable {
    let minX: Float
    let minY: Float
    let cell: Float
    let columns: Int
    let rows: Int
    /// CSR layout: triangles of cell c are `triangles[offsets[c]..<offsets[c + 1]]`.
    let offsets: [UInt32]
    /// First index-buffer offset of each referenced triangle.
    let triangles: [UInt32]
    var bytes: Int { offsets.count * 4 + triangles.count * 4 }

    init?(rect: DioramaRect, ranges: [DioramaRenderLayer.Range], cell: Float = 8,
          index: (Int) -> UInt32, position: (Int) -> SIMD4<Float>, isGround: (Int) -> Bool) {
        let width = Float(rect.width), height = Float(rect.height)
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        minX = Float(rect.minX); minY = Float(rect.minY); self.cell = cell
        columns = max(1, Int(ceil(width / cell))); rows = max(1, Int(ceil(height / cell)))
        let columns = columns, rows = rows, minX = minX, minY = minY
        func span(_ start: Int) -> (Int, Int, Int, Int)? {
            let ia = Int(index(start)), ib = Int(index(start + 1)), ic = Int(index(start + 2))
            guard isGround(ia), isGround(ib), isGround(ic) else { return nil }
            let a = position(ia), b = position(ib), c = position(ic)
            let lo = simd_min(simd_min(SIMD2(a.x, a.y), SIMD2(b.x, b.y)), SIMD2(c.x, c.y))
            let hi = simd_max(simd_max(SIMD2(a.x, a.y), SIMD2(b.x, b.y)), SIMD2(c.x, c.y))
            guard lo.x.isFinite, lo.y.isFinite, hi.x.isFinite, hi.y.isFinite else { return nil }
            let c0 = max(0, Int(floor((lo.x - minX) / cell))), c1 = min(columns - 1, Int(floor((hi.x - minX) / cell)))
            let r0 = max(0, Int(floor((lo.y - minY) / cell))), r1 = min(rows - 1, Int(floor((hi.y - minY) / cell)))
            return c0 <= c1 && r0 <= r1 ? (c0, c1, r0, r1) : nil
        }
        var counts = [UInt32](repeating: 0, count: columns * rows + 1)
        let groundRanges = ranges.filter { $0.category == .ground && $0.count >= 3 }
        for range in groundRanges {
            for start in stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                guard let s = span(start) else { continue }
                for r in s.2...s.3 { for c in s.0...s.1 { counts[r * columns + c + 1] += 1 } }
            }
        }
        for i in 1..<counts.count { counts[i] += counts[i - 1] }
        var cursor = counts
        var list = [UInt32](repeating: 0, count: Int(counts[counts.count - 1]))
        for range in groundRanges {
            for start in stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                guard let s = span(start) else { continue }
                for r in s.2...s.3 {
                    for c in s.0...s.1 {
                        let slot = r * columns + c
                        list[Int(cursor[slot])] = UInt32(start); cursor[slot] += 1
                    }
                }
            }
        }
        offsets = counts; triangles = list
    }

    /// Triangle start offsets that may contain `p`; empty outside the indexed rectangle.
    func candidates(_ p: SIMD2<Float>) -> ArraySlice<UInt32> {
        let c = Int(floor((p.x - minX) / cell)), r = Int(floor((p.y - minY) / cell))
        guard c >= 0, c < columns, r >= 0, r < rows else { return [] }
        let slot = r * columns + c
        return triangles[Int(offsets[slot])..<Int(offsets[slot + 1])]
    }
}
