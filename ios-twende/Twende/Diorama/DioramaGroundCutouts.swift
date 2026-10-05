import Foundation

/// Removes occupied ground from landscape overlays. Boolean subtraction happens once on the CPU,
/// not by drawing competing lawn/road faces and hoping their depth values win.
nonisolated struct DioramaGroundCutouts: Sendable {
    private let masks: [(ring: [DV2], bounds: DioramaRect)]

    init(data: DioramaTileData, pavementWidth: Double) {
        var polygons: [[DV2]] = data.buildings.map(\.ring)
        polygons += data.landuse.filter { ["pool", "pitch", "parking", "fuel", "terrace"].contains($0.kind) }.compactMap { $0.rings.first }
        var convex: [[DV2]] = []
        for polygon in polygons {
            let ring = DioramaPolygon.counterClockwise(polygon)
            for (a, b, c) in DioramaPolygon.triangulate(ring) { convex.append([ring[a], ring[b], ring[c]]) }
        }
        for road in data.roads {
            let half = road.width / 2 + (road.isPaved ? pavementWidth : 1.0)
            for (a, b) in zip(road.line, road.line.dropFirst()) {
                let n = (b - a).normalized.left * half
                convex.append(DioramaPolygon.counterClockwise([a - n, b - n, b + n, a + n]))
            }
        }
        masks = convex.map { ($0, DioramaRect.bounding($0)) }
    }

    /// Returns convex pieces outside all occupied footprints, preserving real outline intersections.
    func subtract(from ring: [DV2]) -> [[DV2]] {
        let bounds = DioramaRect.bounding(ring)
        let relevant = masks.filter { $0.bounds.intersects(bounds) }
        let ccw = DioramaPolygon.counterClockwise(ring)
        var pieces = DioramaPolygon.triangulate(ccw).map { [ccw[$0.0], ccw[$0.1], ccw[$0.2]] }
        for mask in relevant {
            pieces = pieces.flatMap { piece in
                guard DioramaRect.bounding(piece).intersects(mask.bounds) else { return [piece] }
                return Self.subtractConvex(mask.ring, from: piece)
            }
            if pieces.isEmpty { break }
        }
        return pieces
    }

    private static func subtractConvex(_ mask: [DV2], from polygon: [DV2]) -> [[DV2]] {
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

    private static func halfPlane(_ ring: [DV2], a: DV2, b: DV2, inside: Bool) -> [DV2] {
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
