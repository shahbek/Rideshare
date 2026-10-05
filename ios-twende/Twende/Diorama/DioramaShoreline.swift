import Foundation

/// Extracts actual water/land interfaces, stitches clipped pieces, then records classification provenance.
nonisolated enum DioramaShoreline {
    nonisolated enum Kind: String, Codable, CaseIterable, Sendable { case beach, seawall, revetment, deck, natural }
    nonisolated enum Source: String, Sendable { case data, fallback, override }
    nonisolated struct Choice: Equatable, Sendable {
        let kind: Kind
        let source: Source
        let evidence: String
        let rocks: Bool
    }

    /// Water stays left of travel. Artificial tile edges and internal polygon boundaries are excluded.
    static func extract(_ water: [DioramaAreaFeature], rect: DioramaRect) -> [[DV2]] {
        var edges: [(DV2, DV2)] = []
        for feature in water {
            for (ringIndex, rawRing) in feature.rings.enumerated() {
                let ring = ringIndex == 0 ? DioramaPolygon.counterClockwise(rawRing) : Array(DioramaPolygon.counterClockwise(rawRing).reversed())
                for i in ring.indices {
                    if ringIndex == 0, i < feature.clipped.count, feature.clipped[i] { continue }
                    let a = ring[i], b = ring[(i + 1) % ring.count]
                    guard a.distance(to: b) > 0.001 else { continue }
                    // Probe on the land side; shared seams between adjacent water polygons are not coast.
                    let probe = (a + b) * 0.5 + (b - a).normalized.right * 0.02
                    guard !water.contains(where: { $0.id != feature.id && DioramaPolygon.contains(polygon: $0.rings, probe) }) else { continue }
                    for piece in DioramaPolygon.clip([a, b], to: rect) {
                        if let first = piece.first, let last = piece.last, first.distance(to: last) > 0.001 { edges.append((first, last)) }
                    }
                }
            }
        }
        return merge(edges)
    }

    /// Direction-preserving endpoint welding also joins coastline pieces split between adjacent tiles.
    static func merge(_ edges: [(DV2, DV2)], tolerance: Double = 0.05) -> [[DV2]] {
        var remaining = edges
        var chains: [[DV2]] = []
        while !remaining.isEmpty {
            let edge = remaining.removeFirst()
            var chain = [edge.0, edge.1]
            var changed = true
            while changed {
                changed = false
                if let last = chain.last, let i = remaining.firstIndex(where: { $0.0.distance(to: last) <= tolerance }) {
                    chain.append(remaining.remove(at: i).1); changed = true
                }
                if let first = chain.first, let i = remaining.firstIndex(where: { $0.1.distance(to: first) <= tolerance }) {
                    chain.insert(remaining.remove(at: i).0, at: 0); changed = true
                }
            }
            chains.append(chain)
        }
        return chains
    }

    /// Bounded miter at every shared station; the water-facing normal never flips at tile seams.
    static func frames(_ points: [DV2]) -> [DV2] {
        guard points.count >= 2 else { return [] }
        let closed = points[0].distance(to: points[points.count - 1]) < 0.05
        return points.indices.map { i in
            let before = i > 0 ? points[i] - points[i - 1] : (closed ? points[0] - points[points.count - 2] : points[1] - points[0])
            let after = i + 1 < points.count ? points[i + 1] - points[i] : (closed ? points[1] - points[0] : before)
            let a = before.normalized.left, b = after.normalized.left
            let normal = (a + b).normalized
            return normal * (1 / max(0.7, normal.dot(b)))
        }
    }

    static func classify(data: DioramaTileData, config: DioramaConfig, overrides: [DioramaShorelineOverrides.Entry]) -> [DioramaShorelineSegment] {
        var result: [DioramaShorelineSegment] = []
        for chain in extract(data.water, rect: data.rect) {
            let points = DioramaPolygon.densify(chain, maxStep: max(0.5, config.shorelineSampleSpacing))
            let normals = frames(points)
            guard points.count >= 2 else { continue }
            var start = 0
            var choice = choose(at: (points[0] + points[1]) * 0.5, data: data, config: config, overrides: overrides)
            func append(end: Int) {
                let p = Array(points[start...end]), n = Array(normals[start...end])
                let seed = UInt64(bitPattern: Int64((p[0].x * 100).rounded())) ^ UInt64(bitPattern: Int64((p[0].y * 100).rounded())) &* 613
                result.append(DioramaShorelineSegment(id: DioramaRandom.mix(seed), points: p, outward: n,
                    kind: choice.kind, source: choice.source, evidence: choice.evidence, hasRevetment: choice.rocks))
            }
            for i in 1..<(points.count - 1) {
                let next = choose(at: (points[i] + points[i + 1]) * 0.5, data: data, config: config, overrides: overrides)
                if next != choice { append(end: i); start = i; choice = next }
            }
            append(end: points.count - 1)
        }
        return result
    }

    static func choose(at p: DV2, data: DioramaTileData, config: DioramaConfig,
                       overrides: [DioramaShorelineOverrides.Entry]) -> Choice {
        func nearArea(_ area: DioramaAreaFeature, distance: Double) -> Bool {
            area.rings.first.map { DioramaPolygon.contains($0, p) || DioramaPolygon.distanceToRing($0, p) <= distance } ?? false
        }
        let deck = data.landuse.first { $0.kind == "terrace" && nearArea($0, distance: 6) }
        let pier = data.paths.first { ($0.kind == "pier" || $0.tags["man_made"] == "pier") && distance(p, line: $0.line) <= 2 }
        if let entry = overrides.first(where: { $0.contains(p, projection: data.projection) }) {
            if entry.preserveMappedDecks, deck != nil || pier != nil {
                return Choice(kind: .deck, source: .data, evidence: deck.map { "terrace \($0.id) over \(entry.id)" } ?? "pier \(pier?.sourceID ?? pier?.id ?? 0) over \(entry.id)", rocks: entry.revetment)
            }
            return Choice(kind: entry.type, source: .override, evidence: entry.id, rocks: entry.revetment)
        }
        if let deck { return Choice(kind: .deck, source: .data, evidence: "terrace \(deck.id)", rocks: true) }
        if let pier { return Choice(kind: .deck, source: .data, evidence: "pier \(pier.sourceID ?? pier.id)", rocks: true) }
        if let sand = data.landuse.first(where: { (["beach", "sand"].contains($0.kind) || $0.tags["natural"] == "beach" || $0.tags["surface"] == "sand") && nearArea($0, distance: 8) }) {
            return Choice(kind: .beach, source: .data, evidence: "sand/beach \(sand.id)", rocks: false)
        }
        if let structure = data.paths.first(where: { (["retaining_wall", "breakwater"].contains($0.kind) || $0.tags["barrier"] == "retaining_wall" || $0.tags["man_made"] == "breakwater") && distance(p, line: $0.line) < 4 }) {
            let kind: Kind = structure.kind == "breakwater" || structure.tags["man_made"] == "breakwater" ? .revetment : .seawall
            return Choice(kind: kind, source: .data, evidence: "structure \(structure.sourceID ?? structure.id)", rocks: true)
        }
        let reach = config.shorelineFallbackDistance
        let built = data.buildings.contains { DioramaPolygon.distanceToRing($0.ring, p) <= reach }
        let paved = data.landuse.contains { ["parking", "fuel", "paving", "promenade"].contains($0.kind) && nearArea($0, distance: reach) }
        let path = data.paths.contains { ["footway", "promenade"].contains($0.kind) && distance(p, line: $0.line) <= reach }
        let road = data.roads.contains { $0.isPaved && distance(p, line: $0.line) <= reach + $0.width / 2 }
        return built || paved || path || road
            ? Choice(kind: .seawall, source: .fallback, evidence: "paving/building within \(Int(reach)) m", rocks: true)
            : Choice(kind: .natural, source: .fallback, evidence: "no coastal structure or sand tag", rocks: true)
    }

    static func distance(_ p: DV2, line: [DV2]) -> Double {
        zip(line, line.dropFirst()).reduce(Double.infinity) { min($0, DioramaPolygon.distanceToSegment(p, $1.0, $1.1)) }
    }

    /// Reserve only the landward portion of beach/natural profiles, not a blanket sand stripe.
    static func landMasks(_ segments: [DioramaShorelineSegment], config: DioramaConfig) -> [[DV2]] {
        segments.filter { [.beach, .natural, .revetment].contains($0.kind) }.flatMap { segment in
            let width = segment.kind == .beach ? config.beachWidth * 0.65 : config.revetmentWidth * 0.5
            return (0..<(segment.points.count - 1)).map { i in
                let a = segment.points[i], b = segment.points[i + 1]
                return DioramaPolygon.counterClockwise([a, b, b - segment.outward[i + 1] * width, a - segment.outward[i] * width])
            }
        }
    }

    static func report(_ segments: [DioramaShorelineSegment]) -> [String] {
        var groups: [String: Double] = [:]
        for s in segments { groups["\(s.source.rawValue) · \(s.kind.rawValue) · \(s.evidence)", default: 0] += s.length }
        return groups.keys.sorted().map { "\(groups[$0, default: 0].rounded().formatted()) m · \($0)" }
    }
}
