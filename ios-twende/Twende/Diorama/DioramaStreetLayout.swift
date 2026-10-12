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
    /// OSM ways that continue one another, joined into single polylines (marking runs use these).
    let chains: [DioramaRoadFeature]
    let approaches: [Approach]
    let junctions: [(point: DV2, radius: Double)]
    let paintStations: [UInt64: (offset: Double, direction: Double)]

    init(data: DioramaTileData, config: DioramaConfig) {
        let chains = DioramaStreetSurface.chained(data.roads)
        self.chains = chains

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

        // Surfaces: every chain is a plain strip that stops exactly at its OSM end (no square cap
        // poking through the far side of the road it joins); each junction is filled by one convex
        // patch through the arms' mouths, so asphalt, pavement and the kerbs that trace the union's
        // outline meet in straight, closed edges. Re-entrant corners then get their small fillets.
        let obstacles = data.buildings.map(\.ring)
        let joinNodes = nodes + Self.chainEnds(chains, near: data.rect)
        let base = DioramaStreetSurface(chains.flatMap { DioramaStreetSurface.corridor($0, extra: 0, rect: data.rect, caps: false) }
            + Self.junctionPatches(chains, nodes: joinNodes, extra: { _ in 0 }))
        carriageway = DioramaStreetSurface(base.polygons + base.cornerFillets(obstacles: obstacles))
        let pavement: (DioramaRoadFeature) -> Double = { $0.isPaved ? config.pavementWidth : 0.8 }
        let widened = chains.flatMap { DioramaStreetSurface.corridor($0, extra: pavement($0), rect: data.rect, caps: false) }
            + Self.junctionPatches(chains, nodes: joinNodes, extra: pavement)
        let outer = DioramaStreetSurface(widened)
        corridor = DioramaStreetSurface(widened + outer.cornerFillets(obstacles: obstacles))
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

    /// Chain ends that touch another chain (a way joining at an angle or with another width), so
    /// those joints get a patch too even when no segment crossing was found.
    private static func chainEnds(_ chains: [DioramaRoadFeature], near rect: DioramaRect) -> [DV2] {
        var result: [DV2] = []
        for chain in chains where chain.line.count >= 2 {
            for end in [chain.line[0], chain.line[chain.line.count - 1]] where rect.expanded(by: -2).contains(end) {
                let touches = chains.contains { other in
                    other.id != chain.id && zip(other.line, other.line.dropFirst()).contains { DioramaPolygon.distanceToSegment(end, $0.0, $0.1) < 0.7 }
                }
                if touches, !result.contains(where: { $0.distance(to: end) < 1.2 }) { result.append(end) }
            }
        }
        return result
    }

    /// One convex junction patch per node where two or more chains meet: the hull of every arm's
    /// mouth (its two edge points, a little past the widest crossing road) and the node. Nodes on a
    /// roundabout ring are skipped so the patch never cuts into the central island.
    static func junctionPatches(_ chains: [DioramaRoadFeature], nodes: [DV2], extra: (DioramaRoadFeature) -> Double) -> [[DV2]] {
        var patches: [[DV2]] = []
        var seen: [DV2] = []
        for node in nodes where !seen.contains(where: { $0.distance(to: node) < 1.2 }) {
            seen.append(node)
            var arms: [(chain: Int, station: Double, sign: Double, half: Double, length: Double)] = []
            var onRing = false
            for (index, chain) in chains.enumerated() where chain.line.count >= 2 {
                var walked = 0.0
                var station: Double?
                for (a, b) in zip(chain.line, chain.line.dropFirst()) {
                    if DioramaPolygon.distanceToSegment(node, a, b) < 0.7 {
                        station = walked + a.distance(to: DioramaPolygon.closestPointOnSegment(node, a, b))
                        break
                    }
                    walked += a.distance(to: b)
                }
                guard let station else { continue }
                if chain.line[0].distance(to: chain.line[chain.line.count - 1]) < 0.05 { onRing = true; break }
                let length = DioramaPolygon.length(chain.line)
                let half = chain.width / 2 + extra(chain)
                if station > 0.5 { arms.append((index, station, -1, half, length)) }
                if length - station > 0.5 { arms.append((index, station, 1, half, length)) }
            }
            guard !onRing, arms.count >= 2, Set(arms.map(\.chain)).count >= 2 else { continue }
            var corners: [DV2] = [node]
            for (k, arm) in arms.enumerated() {
                let crossing = arms.enumerated().filter { $0.offset != k && $0.element.chain != arm.chain }.map(\.element.half).max() ?? arm.half
                let room = arm.sign > 0 ? arm.length - arm.station : arm.station
                let reach = min(crossing + 0.4, room)
                guard let s = DioramaPolygon.sample(chains[arm.chain].line, at: arm.station + arm.sign * reach) else { continue }
                let side = s.direction.left * arm.half
                corners += [s.point + side, s.point - side]
            }
            let hull = Self.convexHull(corners)
            if hull.count >= 3 { patches.append(hull) }
        }
        return patches
    }

    /// Andrew's monotone chain, counter-clockwise.
    static func convexHull(_ points: [DV2]) -> [DV2] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return sorted }
        func turn(_ o: DV2, _ a: DV2, _ b: DV2) -> Double { (a - o).cross(b - o) }
        var lower: [DV2] = [], upper: [DV2] = []
        for p in sorted {
            while lower.count >= 2, turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 1e-9 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 1e-9 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    func paintIsClear(_ p: DV2) -> Bool {
        !junctions.contains { p.distance(to: $0.point) < $0.radius }
    }
}
