import Foundation

/// Bounded demo pathfinding over mapped road vertices, never invented grid elbows.
nonisolated struct RoadGeometryGraph: Sendable {
    struct Line: Sendable { let points: [GeoPoint]; let level: String; let oneWay: Bool }
    struct Segment: Sendable { let a: Int; let b: Int; let oneWay: Bool; let length: Double }
    struct Edge: Sendable { let to: Int; let length: Double }
    struct Snap { let point: GeoPoint; let segment: Int; let fraction: Double }
    static let drivingClasses: Set<String> = ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link", "tertiary", "tertiary_link", "street", "street_limited", "residential", "unclassified", "service", "living_street"]
    private var points: [GeoPoint] = []
    private var edges: [[Edge]] = []
    private var segments: [Segment] = []

    init(lines: [Line]) {
        var ids: [String: Int] = [:]
        for line in lines {
            var previous: Int?
            for point in line.points where point.latitude.isFinite && point.longitude.isFinite {
                // About one metre tolerance joins shared vertices/tile boundaries, not geometric crossings.
                let key = "\(Int((point.latitude * 100_000).rounded())):\(Int((point.longitude * 100_000).rounded())):\(line.level)"
                let id: Int
                if let known = ids[key] { id = known }
                else { id = points.count; ids[key] = id; points.append(point); edges.append([]) }
                if let a = previous, a != id {
                    let length = points[a].distanceKm(to: points[id]) * 1_000
                    if length > 0.1, length.isFinite {
                        edges[a].append(Edge(to: id, length: length))
                        if !line.oneWay { edges[id].append(Edge(to: a, length: length)) }
                        segments.append(Segment(a: a, b: id, oneWay: line.oneWay, length: length))
                    }
                }
                previous = id
            }
        }
    }

    func nearest(_ point: GeoPoint, within metres: Double) -> Snap? {
        let north = 111_320.0, east = 111_320 * cos(point.latitude * .pi / 180)
        var best = metres
        var result: Snap?
        for (index, segment) in segments.enumerated() {
            let a = points[segment.a], b = points[segment.b]
            let ax = (a.longitude - point.longitude) * east, ay = (a.latitude - point.latitude) * north
            let dx = (b.longitude - a.longitude) * east, dy = (b.latitude - a.latitude) * north
            let squared = dx * dx + dy * dy
            guard squared > 0 else { continue }
            let t = min(1, max(0, -(ax * dx + ay * dy) / squared))
            let distance = hypot(ax + dx * t, ay + dy * t)
            if distance < best {
                best = distance
                result = Snap(point: a.interpolated(to: b, fraction: t), segment: index, fraction: t)
            }
        }
        return result
    }

    func path(from: GeoPoint, to: GeoPoint) -> [GeoPoint]? {
        guard let start = nearest(from, within: 150), let end = nearest(to, within: 150) else { return nil }
        let first = segments[start.segment], last = segments[end.segment]
        if start.segment == end.segment, !first.oneWay || end.fraction >= start.fraction {
            return [start.point, end.point]
        }
        let source = points.count, destination = source + 1
        var adjacency = edges + [[], []]
        adjacency[source].append(Edge(to: first.b, length: first.length * (1 - start.fraction)))
        if !first.oneWay { adjacency[source].append(Edge(to: first.a, length: first.length * start.fraction)) }
        adjacency[last.a].append(Edge(to: destination, length: last.length * end.fraction))
        if !last.oneWay { adjacency[last.b].append(Edge(to: destination, length: last.length * (1 - end.fraction))) }
        var distances = [Double](repeating: .infinity, count: adjacency.count)
        var parents = [Int](repeating: -1, count: adjacency.count)
        var heap = RoadRouteHeap()
        distances[source] = 0; heap.push(node: source, cost: 0)
        var visited: Int = 0
        while let item = heap.pop() {
            guard !Task.isCancelled else { return nil }
            if item.cost > distances[item.node] { continue }
            if item.node == destination { break }
            visited += 1
            guard visited <= 100_000 else { return nil }
            for edge in adjacency[item.node] {
                let cost = item.cost + edge.length
                if cost < distances[edge.to] {
                    distances[edge.to] = cost; parents[edge.to] = item.node
                    heap.push(node: edge.to, cost: cost)
                }
            }
        }
        guard distances[destination].isFinite else { return nil }
        var route: [GeoPoint] = [end.point]
        var current = parents[destination]
        while current >= 0, current != source {
            route.append(points[current]); current = parents[current]
        }
        guard current == source else { return nil }
        route.append(start.point)
        return route.reversed()
    }
}
