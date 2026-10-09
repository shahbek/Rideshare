import Foundation

/// Shared street geometry and junction stations for surfaces, paint, landscaping and access ramps.
nonisolated struct DioramaStreetLayout: Sendable {
    struct Approach: Sendable {
        let roadID: UInt64
        let point: DV2
        let toward: DV2
        let width: Double
        let crossing: Bool
        let yields: Bool
    }
    let carriageway: DioramaStreetSurface
    let corridor: DioramaStreetSurface
    let approaches: [Approach]
    let junctions: [(point: DV2, radius: Double)]
    let paintStations: [UInt64: (offset: Double, direction: Double)]

    init(data: DioramaTileData, config: DioramaConfig) {
        let base = DioramaStreetSurface(data.roads.flatMap { DioramaStreetSurface.corridor($0, extra: 0, rect: data.rect) })
        let fillets = base.cornerFillets(obstacles: data.buildings.map(\.ring))
        carriageway = DioramaStreetSurface(base.polygons + fillets)
        let widened = data.roads.flatMap { DioramaStreetSurface.corridor($0, extra: $0.isPaved ? config.pavementWidth : 0.8, rect: data.rect) }
        let outer = DioramaStreetSurface(widened)
        corridor = DioramaStreetSurface(widened + outer.cornerFillets(obstacles: data.buildings.map(\.ring)))

        // Intersections include interior vertices and T joins, not only OSM way endpoints.
        var nodes: [DV2] = []
        let roads = data.roads.sorted { $0.id < $1.id }
        paintStations = DioramaRoadStations.build(roads)
        var segments: [(a: DV2, b: DV2, road: Int)] = []
        var segmentGrid = DioramaGrid(cell: 24)
        for i in roads.indices {
            for (a, b) in zip(roads[i].line, roads[i].line.dropFirst()) {
                segmentGrid.insert(segments.count, rect: DioramaRect.bounding([a, b]).expanded(by: 0.7))
                segments.append((a, b, i))
            }
        }
        for i in segments.indices {
            let a = segments[i].a, b = segments[i].b
            let bounds = DioramaRect.bounding([a, b]).expanded(by: 0.6)
            for j in segmentGrid.query(bounds).sorted() where j > i && segments[j].road != segments[i].road {
                let c = segments[j].a, d = segments[j].b
                guard bounds.intersects(DioramaRect.bounding([c, d])) else { continue }
                let ab = b - a, cd = d - c, cross = ab.cross(cd)
                var hit: DV2?
                if abs(cross) > 1e-8 {
                    let t = (c - a).cross(cd) / cross, u = (c - a).cross(ab) / cross
                    if t >= 0, t <= 1, u >= 0, u <= 1 { hit = a + ab * t }
                }
                if hit == nil {
                    for p in [a, b] where DioramaPolygon.distanceToSegment(p, c, d) < 0.6 { hit = p; break }
                    if hit == nil { for p in [c, d] where DioramaPolygon.distanceToSegment(p, a, b) < 0.6 { hit = p; break } }
                }
                if let hit, data.rect.expanded(by: -8).contains(hit), !nodes.contains(where: { $0.distance(to: hit) < 1.2 }) { nodes.append(hit) }
            }
        }
        var approaches: [Approach] = []
        var junctions: [(DV2, Double)] = []
        for node in nodes {
            var arms: [(road: DioramaRoadFeature, distance: Double, sign: Double)] = []
            for road in roads {
                var walked = 0.0
                var station: Double?
                for (a, b) in zip(road.line, road.line.dropFirst()) {
                    if DioramaPolygon.distanceToSegment(node, a, b) < 0.7 {
                        station = walked + a.distance(to: DioramaPolygon.closestPointOnSegment(node, a, b))
                        break
                    }
                    walked += a.distance(to: b)
                }
                guard let station else { continue }
                let length = DioramaPolygon.length(road.line)
                if station > 2 { arms.append((road, station, -1)) }
                if length - station > 2 { arms.append((road, station, 1)) }
            }
            // A split way with two arms is a continuation, not an intersection.
            guard arms.count >= 3 else { continue }
            let maxWidth = arms.map { $0.road.width }.max() ?? 6
            let back = maxWidth / 2 + 3.8
            junctions.append((node, back + 2))
            let hasFootpath = data.paths.contains { path in
                zip(path.line, path.line.dropFirst()).contains { DioramaPolygon.distanceToSegment(node, $0.0, $0.1) < 18 }
            }
            for arm in arms where arm.road.isPaved {
                let length = DioramaPolygon.length(arm.road.line)
                let distance = arm.distance + arm.sign * back
                guard distance > 1, distance < length - 1,
                      let s = DioramaPolygon.sample(arm.road.line, at: distance) else { continue }
                let toward = s.direction * -arm.sign
                guard !approaches.contains(where: { $0.point.distance(to: s.point) < 3 && $0.toward.dot(toward) > 0.8 }) else { continue }
                approaches.append(Approach(roadID: arm.road.id, point: s.point, toward: toward, width: arm.road.width,
                    crossing: hasFootpath && arm.road.width >= 6,
                    yields: arm.road.width < maxWidth && arm.road.width >= 5))
            }
        }
        self.approaches = approaches
        self.junctions = junctions
    }

    func paintIsClear(_ p: DV2) -> Bool {
        !junctions.contains { p.distance(to: $0.point) < $0.radius }
    }
}
