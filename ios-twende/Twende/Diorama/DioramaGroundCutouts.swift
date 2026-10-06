import Foundation

/// Removes occupied ground from landscape overlays. Boolean subtraction happens once on the CPU,
/// not by drawing competing lawn/road faces and hoping their depth values win.
nonisolated struct DioramaGroundCutouts: Sendable {
    private let masks: [(ring: [DV2], bounds: DioramaRect)]
    private let bins: [SIMD2<Int>: [Int]]
    private let broadMasks: [Int]
    private static let binSize = 32.0

    private static func index(_ masks: [(ring: [DV2], bounds: DioramaRect)]) -> ([SIMD2<Int>: [Int]], [Int]) {
        var bins: [SIMD2<Int>: [Int]] = [:]
        var broad: [Int] = []
        for (i, mask) in masks.enumerated() {
            let b = mask.bounds
            guard b.minX.isFinite, b.maxX.isFinite, b.minY.isFinite, b.maxY.isFinite,
                  abs(b.minX) < 1e7, abs(b.maxX) < 1e7, abs(b.minY) < 1e7, abs(b.maxY) < 1e7 else { broad.append(i); continue }
            let x0 = Int(floor(b.minX / binSize)), x1 = Int(floor(b.maxX / binSize))
            let y0 = Int(floor(b.minY / binSize)), y1 = Int(floor(b.maxY / binSize))
            guard x1 >= x0, y1 >= y0, (x1 - x0 + 1) * (y1 - y0 + 1) <= 256 else { broad.append(i); continue }
            for y in y0...y1 { for x in x0...x1 { bins[SIMD2(x, y), default: []].append(i) } }
        }
        return (bins, broad)
    }

    private func candidates(_ bounds: DioramaRect) -> [(ring: [DV2], bounds: DioramaRect)] {
        guard bounds.minX.isFinite, bounds.maxX.isFinite, bounds.minY.isFinite, bounds.maxY.isFinite,
              abs(bounds.minX) < 1e7, abs(bounds.maxX) < 1e7, abs(bounds.minY) < 1e7, abs(bounds.maxY) < 1e7 else {
            return masks.filter { $0.bounds.intersects(bounds) }
        }
        let x0 = Int(floor(bounds.minX / Self.binSize)), x1 = Int(floor(bounds.maxX / Self.binSize))
        let y0 = Int(floor(bounds.minY / Self.binSize)), y1 = Int(floor(bounds.maxY / Self.binSize))
        guard x1 >= x0, y1 >= y0, (x1 - x0 + 1) * (y1 - y0 + 1) <= 256 else {
            return masks.filter { $0.bounds.intersects(bounds) }
        }
        var ids = Set(broadMasks)
        for y in y0...y1 { for x in x0...x1 { ids.formUnion(bins[SIMD2(x, y)] ?? []) } }
        // Sorting source indices is essential: subtraction order is part of the byte-identity contract.
        return ids.sorted().compactMap { masks[$0].bounds.intersects(bounds) ? masks[$0] : nil }
    }

    init(data: DioramaTileData, pavementWidth: Double, streetPolygons: [[DV2]]? = nil, additionalMasks: [[DV2]] = [], excludedAreaIDs: Set<UInt64> = []) {
        var polygons: [[DV2]] = data.buildings.flatMap(\.footprints) + additionalMasks
            + data.shorelineLandMasks
        polygons += data.landuse.filter { ["pool", "pitch", "parking", "fuel", "terrace"].contains($0.kind) && !excludedAreaIDs.contains($0.id) }.compactMap { area in
            guard let ring = area.rings.first else { return nil }
            // Reserve the whole coping/deck, not only the water opening.
            return area.kind == "pool" ? (DioramaPolygon.offset(ring, by: area.sport == "private" ? 1.1 : 2.2) ?? ring) : ring
        }
        var convex: [[DV2]] = []
        for polygon in polygons {
            let ring = DioramaPolygon.counterClockwise(polygon)
            for (a, b, c) in DioramaPolygon.triangulate(ring) { convex.append([ring[a], ring[b], ring[c]]) }
        }
        if let streetPolygons {
            convex += streetPolygons
        } else { for road in data.roads {
            let half = road.width / 2 + (road.isPaved ? pavementWidth : 1.0)
            for (a, b) in zip(road.line, road.line.dropFirst()) {
                let n = (b - a).normalized.left * half
                convex.append(DioramaPolygon.counterClockwise([a - n, b - n, b + n, a + n]))
            }
        }
        }
        masks = convex.map { ($0, DioramaRect.bounding($0)) }
        (bins, broadMasks) = Self.index(masks)
    }

    /// Geometry-only subtraction for base land, coastline bands and disjoint path joins.
    init(polygons: [[DV2]]) {
        masks = polygons.flatMap { polygon in
            let ring = DioramaPolygon.counterClockwise(polygon)
            return DioramaPolygon.triangulate(ring).map { t in
                let triangle = [ring[t.0], ring[t.1], ring[t.2]]
                return (ring: triangle, bounds: DioramaRect.bounding(triangle))
            }
        }
        (bins, broadMasks) = Self.index(masks)
    }

    /// Returns convex pieces outside all occupied footprints, preserving real outline intersections.
    func subtract(from ring: [DV2]) -> [[DV2]] {
        let audit = DioramaGenerationAudit.current
        let start = audit == nil ? 0 : DioramaGenerationAudit.now
        defer { audit?.operation("cutout.subtract", since: start) }
        let bounds = DioramaRect.bounding(ring)
        let optimized = audit?.usesCachedCutoutBounds ?? true
        let relevant = optimized ? candidates(bounds) : masks.filter { $0.bounds.intersects(bounds) }
        let ccw = DioramaPolygon.counterClockwise(ring)
        let initial = DioramaPolygon.triangulate(ccw).map { [ccw[$0.0], ccw[$0.1], ccw[$0.2]] }
        if audit?.usesCachedCutoutBounds ?? true {
            return subtractWithCachedBounds(initial, masks: relevant)
        }
        var pieces = initial
        for mask in relevant {
            pieces = pieces.flatMap { piece in
                guard DioramaRect.bounding(piece).intersects(mask.bounds) else { return [piece] }
                return Self.subtractConvex(mask.ring, from: piece)
            }
            if pieces.isEmpty { break }
        }
        return pieces
    }

    /// Keep mask order, piece order, clipping arithmetic and area thresholds unchanged.
    /// Carry bounds with surviving pieces instead of recomputing them for every later mask.
    private func subtractWithCachedBounds(_ initial: [[DV2]], masks: [(ring: [DV2], bounds: DioramaRect)]) -> [[DV2]] {
        var pieces = initial.map { (ring: $0, bounds: DioramaRect.bounding($0)) }
        for mask in masks {
            var next: [(ring: [DV2], bounds: DioramaRect)] = []
            next.reserveCapacity(pieces.count)
            for piece in pieces {
                if !piece.bounds.intersects(mask.bounds) {
                    next.append(piece)
                } else {
                    for ring in Self.subtractConvex(mask.ring, from: piece.ring) {
                        next.append((ring, DioramaRect.bounding(ring)))
                    }
                }
            }
            pieces = next
            if pieces.isEmpty { break }
        }
        return pieces.map(\.ring)
    }

    static func subtractConvex(_ mask: [DV2], from polygon: [DV2]) -> [[DV2]] {
        var remainder = polygon
        var outside: [[DV2]] = []
        // Each edge peels off an exterior piece. Only the still-inside remainder meets the next edge;
        // this keeps the output disjoint even where many road and building masks overlap.
        for i in mask.indices {
            guard remainder.count >= 3 else { break }
            let a = mask[i], b = mask[(i + 1) % mask.count]
            let outer = halfPlane(remainder, a: a, b: b, inside: false)
            if outer.count >= 3, DioramaPolygon.area(outer) > 0.0001 { outside.append(outer) }
            remainder = halfPlane(remainder, a: a, b: b, inside: true)
        }
        return outside
    }

    static func halfPlane(_ ring: [DV2], a: DV2, b: DV2, inside: Bool) -> [DV2] {
        guard let last = ring.last else { return [] }
        let edge = b - a
        let sign = inside ? 1.0 : -1.0
        func distance(_ p: DV2) -> Double { edge.cross(p - a) * sign }
        var result: [DV2] = []
        var previous = last
        var dp = distance(previous)
        for current in ring {
            let dc = distance(current)
            if (dc >= 0) != (dp >= 0) {
                result.append(previous + (current - previous) * (dp / (dp - dc)))
            }
            if dc >= 0 { result.append(current) }
            previous = current
            dp = dc
        }
        return result
    }
}
