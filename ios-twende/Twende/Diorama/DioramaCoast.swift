import Foundation

/// The one authoritative coastline: the mapped water edge, split into classified shore segments.
/// Answers "how far is the sea, and what kind of shore is nearest" and "is this point in the water"
/// for the terrain, which eases beaches down to the water and builds the seabed from shore distance.
nonisolated struct DioramaCoast: Sendable {
    nonisolated struct Edge: Sendable {
        let a: DV2
        let b: DV2
        let kind: DioramaShoreline.Kind
    }

    nonisolated struct Nearest: Sendable {
        let distance: Double
        let kind: DioramaShoreline.Kind
    }

    private let edges: [Edge]
    private var grid = DioramaGrid(cell: 24)
    private let water: [(rings: [[DV2]], bounds: DioramaRect)]

    init(data: DioramaTileData) {
        var edges: [Edge] = []
        for segment in data.shorelines {
            for (a, b) in zip(segment.points, segment.points.dropFirst()) where a.distance(to: b) > 0.001 {
                edges.append(Edge(a: a, b: b, kind: segment.kind))
            }
        }
        self.edges = edges
        for i in edges.indices { grid.insert(i, rect: DioramaRect.bounding([edges[i].a, edges[i].b])) }
        water = data.water.compactMap { area in
            guard let outer = area.rings.first, outer.count >= 3 else { return nil }
            return (area.rings, DioramaRect.bounding(outer))
        }
    }

    var isEmpty: Bool { edges.isEmpty }

    /// Nearest classified shore within `reach` metres, or nil when the coast is further away.
    func nearest(_ p: DV2, within reach: Double) -> Nearest? {
        var best: Nearest?
        for i in grid.query(DioramaRect(minX: p.x - reach, minY: p.y - reach, maxX: p.x + reach, maxY: p.y + reach)) {
            let edge = edges[i]
            let d = DioramaPolygon.distanceToSegment(p, edge.a, edge.b)
            if d <= reach, best.map({ d < $0.distance }) ?? true { best = Nearest(distance: d, kind: edge.kind) }
        }
        return best
    }

    /// Inside the mapped water polygon (holes excluded).
    func isWater(_ p: DV2) -> Bool {
        water.contains { $0.bounds.contains(p) && DioramaPolygon.contains(polygon: $0.rings, p) }
    }
}

extension DioramaShoreline.Kind {
    /// Soft shores where the land itself runs down into the sea. Walls and decks keep their quay height.
    var easesToWater: Bool {
        switch self {
        case .beach, .natural, .revetment: true
        case .seawall, .deck: false
        }
    }
}
