import Foundation

/// Spatial index over road centrelines for "nearest road" and "does this cross a road" questions.
nonisolated struct DioramaRoadIndex: Sendable {
    nonisolated struct Segment: Sendable {
        let a: DV2
        let b: DV2
        let road: Int
    }

    let roads: [DioramaRoadFeature]
    /// Pavement width added to paved carriageways for occupancy tests.
    let pavementWidth: Double
    private(set) var segments: [Segment] = []
    private var grid = DioramaGrid(cell: 40)

    init(roads: [DioramaRoadFeature], pavementWidth: Double = 0) {
        self.roads = roads
        self.pavementWidth = pavementWidth
        for (r, road) in roads.enumerated() {
            for i in 0..<max(road.line.count - 1, 0) {
                let seg = Segment(a: road.line[i], b: road.line[i + 1], road: r)
                segments.append(seg)
                grid.insert(segments.count - 1, rect: DioramaRect.bounding([seg.a, seg.b]).expanded(by: road.width / 2 + pavementWidth + 1))
            }
        }
    }

    /// Full corridor half-width: carriageway plus pavement (paved) or a sandy shoulder (unpaved).
    func corridorHalfWidth(_ road: DioramaRoadFeature) -> Double {
        road.width / 2 + (road.isPaved ? pavementWidth : 0.8)
    }

    /// True when `p` lies on the carriageway of a road other than `excluding`.
    func isOnCarriageway(_ p: DV2, margin: Double = 0, excluding: UInt64? = nil) -> Bool {
        let box = DioramaRect(minX: p.x - 10, minY: p.y - 10, maxX: p.x + 10, maxY: p.y + 10)
        for index in grid.query(box) {
            let seg = segments[index]
            let road = roads[seg.road]
            if let excluding, road.id == excluding { continue }
            if DioramaPolygon.distanceToSegment(p, seg.a, seg.b) < road.width / 2 + margin { return true }
        }
        return false
    }

    /// Closest point on any road within `radius`, with the road's heading there.
    func nearest(to p: DV2, within radius: Double) -> (point: DV2, direction: DV2, road: DioramaRoadFeature, distance: Double)? {
        var best: (DV2, DV2, DioramaRoadFeature, Double)? = nil
        let query = DioramaRect(minX: p.x - radius, minY: p.y - radius, maxX: p.x + radius, maxY: p.y + radius)
        for index in grid.query(query) {
            let seg = segments[index]
            let q = DioramaPolygon.closestPointOnSegment(p, seg.a, seg.b)
            let d = p.distance(to: q)
            if d < radius, d < (best?.3 ?? .infinity) {
                best = (q, (seg.b - seg.a).normalized, roads[seg.road], d)
            }
        }
        return best
    }

    /// True when a segment comes within `clearance` of a carriageway edge.
    func blocks(_ a: DV2, _ b: DV2, clearance: Double) -> Bool {
        let box = DioramaRect.bounding([a, b]).expanded(by: clearance + 8)
        for index in grid.query(box) {
            let seg = segments[index]
            let limit = roads[seg.road].width / 2 + clearance
            if DioramaPolygon.segmentsIntersect(a, b, seg.a, seg.b) { return true }
            if DioramaPolygon.distanceToSegment(seg.a, a, b) < limit || DioramaPolygon.distanceToSegment(seg.b, a, b) < limit { return true }
            if DioramaPolygon.distanceToSegment(a, seg.a, seg.b) < limit || DioramaPolygon.distanceToSegment(b, seg.a, seg.b) < limit { return true }
        }
        return false
    }

    func isOnRoad(_ p: DV2, margin: Double = 0) -> Bool {
        let box = DioramaRect(minX: p.x - 10, minY: p.y - 10, maxX: p.x + 10, maxY: p.y + 10)
        for index in grid.query(box) {
            let seg = segments[index]
            if DioramaPolygon.distanceToSegment(p, seg.a, seg.b) < corridorHalfWidth(roads[seg.road]) + margin { return true }
        }
        return false
    }
}
