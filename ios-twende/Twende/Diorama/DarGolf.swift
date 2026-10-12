import Foundation

/// Bundled OpenStreetMap golf geography for Dar es Salaam (Gymkhana Club and TPDF Lugalo).
/// Mapped greens, bunkers, water hazards and hole lines come straight from OSM. Fairways are not
/// mapped as areas there, so they are painted as mown corridors along each mapped hole line
/// (illustrative width), and tees as small mown boxes at each hole's start.
nonisolated struct DarGolf: Decodable, Sendable {
    nonisolated struct Course: Decodable, Sendable {
        let id: String
        let osm: String
        let name: String
        /// Outer ring first, inner rings after. [longitude, latitude].
        let rings: [[[Double]]]
    }
    nonisolated struct Feature: Decodable, Sendable {
        let osm: String
        /// `green`, `bunker`, `water`, `tee`, `fairway`, `rough`.
        let kind: String
        let ring: [[Double]]
    }
    nonisolated struct Hole: Decodable, Sendable {
        let osm: String
        let ref: String?
        let par: Int?
        let line: [[Double]]
    }
    let courses: [Course]
    let features: [Feature]
    let holes: [Hole]

    static let bundled: DarGolf? = {
        guard let url = Bundle.main.url(forResource: "dar_golf", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let golf = try? JSONDecoder().decode(DarGolf.self, from: bytes) else {
            print("[DarGolf] bundled golf geography unavailable")
            return nil
        }
        return golf
    }()

    /// Every z16 tile touched by a course outline.
    static let tiles: [DioramaTileID] = {
        guard let golf = bundled else { return [] }
        var result: Set<DioramaTileID> = []
        for course in golf.courses {
            guard let outer = course.rings.first else { continue }
            let addresses = outer.compactMap { p in p.count >= 2 ? DioramaTileID(latitude: p[1], longitude: p[0], zoom: 16) : nil }
            guard let minX = addresses.map(\.x).min(), let maxX = addresses.map(\.x).max(),
                  let minY = addresses.map(\.y).min(), let maxY = addresses.map(\.y).max() else { continue }
            for y in minY...maxY { for x in minX...maxX { result.insert(.init(z: 16, x: x, y: y)) } }
        }
        return result.sorted { $0.key < $1.key }
    }()

    /// Golf land use for one tile, in paint order: course turf, hole corridors, tees, greens, bunkers.
    /// Water hazards are left to the mapped water layer.
    static func areas(projection: DioramaProjection, rect: DioramaRect) -> [DioramaAreaFeature] {
        guard let golf = bundled else { return [] }
        let reach = rect.expanded(by: 60)
        func local(_ ring: [[Double]]) -> [DV2] {
            ring.compactMap { $0.count >= 2 ? projection.local(longitude: $0[0], latitude: $0[1]) : nil }
        }
        func closed(_ ring: [DV2]) -> [DV2] {
            guard let first = ring.first, let last = ring.last, first.distance(to: last) < 0.01 else { return ring }
            return Array(ring.dropLast())
        }
        var result: [DioramaAreaFeature] = []
        func add(_ rings: [[DV2]], kind: String, id: String, tags: [String: String] = [:]) {
            guard let outer = rings.first, outer.count >= 2, DioramaRect.bounding(outer).intersects(reach) else { return }
            result.append(DioramaAreaFeature(id: DioramaRandom.hash("golf:\(id)"), rings: rings,
                clipped: Array(repeating: false, count: outer.count), kind: kind, tags: tags))
        }
        for course in golf.courses {
            let rings = course.rings.map { closed(local($0)) }.filter { $0.count >= 3 }
            guard let outer = rings.first else { continue }
            add([DioramaPolygon.counterClockwise(outer)] + rings.dropFirst().map { $0 },
                kind: "golfCourse", id: course.osm, tags: ["name": course.name])
        }
        for hole in golf.holes {
            let line = local(hole.line)
            guard line.count >= 2 else { continue }
            let start = line[0], direction = (line[1] - line[0]).normalized
            let side = DV2(-direction.y, direction.x)
            // Tee box: 12 x 7 m, a few metres in front of the mapped hole start.
            let tee = start + direction * 4
            add([[tee - direction * 6 - side * 3.5, tee + direction * 6 - side * 3.5,
                  tee + direction * 6 + side * 3.5, tee - direction * 6 + side * 3.5]],
                kind: "golf_tee", id: "\(hole.osm):tee")
            // Par 3s play over rough to the green; longer holes get a mown corridor.
            guard (hole.par ?? 4) >= 4 else { continue }
            let corridor = trimmed(line, from: 22)
            guard corridor.count >= 2 else { continue }
            for (index, piece) in capsule(corridor, halfWidth: 15).enumerated() {
                add([piece], kind: "golf_fairway", id: "\(hole.osm):fairway:\(index)")
            }
        }
        for kind in ["fairway", "rough", "tee", "green", "bunker"] {
            for feature in golf.features where feature.kind == kind {
                let ring = closed(local(feature.ring))
                guard ring.count >= 3 else { continue }
                add([DioramaPolygon.counterClockwise(ring)], kind: "golf_\(kind)", id: feature.osm)
            }
        }
        return result
    }

    static let kinds: Set<String> = ["golfCourse", "golf_fairway", "golf_rough", "golf_tee", "golf_green", "golf_bunker"]
    /// Golf surfaces nothing is planted on (the course outline itself keeps its trees).
    static let playingKinds: Set<String> = ["golf_fairway", "golf_tee", "golf_green", "golf_bunker"]

    private static func trimmed(_ line: [DV2], from distance: Double) -> [DV2] {
        var remaining = distance
        for i in 0..<(line.count - 1) {
            let length = line[i].distance(to: line[i + 1])
            if remaining < length {
                return [line[i] + (line[i + 1] - line[i]) * (remaining / length)] + line[(i + 1)...]
            }
            remaining -= length
        }
        return []
    }

    /// A rounded corridor as overlapping convex pieces: one rectangle per segment, one disc per vertex.
    private static func capsule(_ line: [DV2], halfWidth: Double) -> [[DV2]] {
        var pieces: [[DV2]] = []
        for (a, b) in zip(line, line.dropFirst()) where a.distance(to: b) > 0.5 {
            let d = (b - a).normalized, n = DV2(-d.y, d.x) * halfWidth
            pieces.append([a - n, b - n, b + n, a + n])
        }
        for p in line {
            pieces.append((0..<20).map { i in
                let angle = Double(i) * .pi / 10
                return p + DV2(cos(angle), sin(angle)) * halfWidth
            })
        }
        return pieces
    }
}
