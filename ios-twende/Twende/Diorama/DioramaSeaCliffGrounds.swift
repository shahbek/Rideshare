import Foundation

/// Photo-led garden furniture and shallow terracotta terraces, constrained to the mapped hotel site.
/// Cliff profile and individual plant positions are illustrative, not survey measurements.
nonisolated struct DioramaSeaCliffGrounds {
    static let cliffEvidence = "Sea Cliff photo-led coral cliff"
    let data: DioramaTileData
    let terrain: DioramaTerrain
    let config: DioramaConfig
    let library: DioramaPropLibrary
    let painter: DioramaGroundPainter

    func generate(ground: inout DioramaMesh, props: inout DioramaMesh, vegetation: inout DioramaMesh,
                  glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        guard let grounds = data.landuse.first(where: { $0.id == DioramaSeaCliffSite.siteID })?.rings.first else { return }
        let plan = DioramaSeaCliffSite.plan(data.projection)
        let buildings = data.buildings.flatMap(\.footprints)
        let basins = data.landuse.filter { $0.kind == "pool" }.compactMap { $0.rings.first }
        let blocked = buildings + basins.map { DioramaPolygon.offset($0, by: 2.3) ?? $0 } + data.water.compactMap { $0.rings.first }
        let cutouts = DioramaGroundCutouts(polygons: blocked)
        let gardens = cutouts.subtract(from: grounds)
        painter.fillPieces(gardens, .lawn)
        let deck = DioramaStreetSurface([grounds]).intersection(plan.restaurantDeck)
        painter.fillPieces(deck, .tileClay)
        let lawn = DioramaStreetSurface(gardens).intersection(plan.lawn)
        painter.fillPieces(lawn, .grass)
        func clear(_ p: DV2, margin: Double = 0) -> Bool {
            DioramaPolygon.contains(grounds, p) && !blocked.contains { ring in
                DioramaPolygon.contains(ring, p) || (margin > 0 && DioramaPolygon.distanceToRing(ring, p) < margin)
            }
        }
        var placed: [DV2] = []
        func plant(_ p: DV2, palm: Bool, index: Int) {
            guard clear(p, margin: 1.5), !placed.contains(where: { $0.distance(to: p) < 4.2 }) else { return }
            placed.append(p)
            let size = palm ? 1.05 : 1.1
            vegetation.instance(palm ? library.palms[index % library.palms.count] : library.trees[index % 4],
                .init(rotation: Double(index) * 1.73, scale: DV3(size, size, size), translation: DV3(p, terrain.height(p))))
        }
        // Deliberate clusters between the bedroom wing and pavilion; leave the photographed lawn open.
        for (index, uv) in [DV2(-34, 19), DV2(-25, 16), DV2(-17, 22), DV2(-12, 13), DV2(0, 15),
                            DV2(12, 17), DV2(21, 13), DV2(35, 17), DV2(-25, 34), DV2(20, 40)].enumerated() {
            plant(plan.point(uv.x, uv.y), palm: index % 3 == 0, index: index)
        }
        if let pool = data.landuse.first(where: { $0.id == DioramaSeaCliffSite.poolID })?.rings.first {
            let box = DioramaPolygon.minimumAreaRectangle(pool)
            for k in -2...2 {
                plant(box.centre + box.axis * Double(k * 4) + box.across * (box.halfWidth + 5), palm: true, index: k + 2)
            }
        }
        for segment in data.shorelines where segment.evidence == Self.cliffEvidence && segment.points.count >= 2 {
            // Joined shore frames create one continuous staircase ribbon, not overlapping boxes.
            for i in 0..<(segment.points.count - 1) {
                let a = segment.points[i], b = segment.points[i + 1]
                let na = segment.outward[i], nb = segment.outward[i + 1]
                let topA = terrain.height(a - na * 1.2), topB = terrain.height(b - nb * 1.2)
                let bottom = terrain.waterLevel - 0.7
                let heightsA = [bottom, bottom + (topA - bottom) * 0.3, bottom + (topA - bottom) * 0.72, topA]
                let heightsB = [bottom, bottom + (topB - bottom) * 0.3, bottom + (topB - bottom) * 0.72, topB]
                let offsets = [2.1, 0.5, 0.85, -1.2]
                for band in 0..<3 {
                    let color: DioramaSwatch = band == 0 ? .dampStone : band == 1 ? .rockWarm : .coralStone
                    ground.quad(DV3(a + na * offsets[band], heightsA[band]), DV3(b + nb * offsets[band], heightsB[band]),
                        DV3(b + nb * offsets[band + 1], heightsB[band + 1]), DV3(a + na * offsets[band + 1], heightsA[band + 1]),
                        color, normal: DV3((na + nb).normalized, 0.25))
                }
                for step in 0..<3 {
                    let inner = 4.8 + Double(step) * 0.62, outer = inner - 0.62
                    let p = a - na * outer, q = b - nb * outer, r = b - nb * inner, s = a - na * inner
                    guard [p, q, r, s].allSatisfy({ clear($0) }) else { continue }
                    let rise = Double(step + 1) * 0.16
                    let za = max(terrain.height(p), terrain.height(s)) + rise
                    let zb = max(terrain.height(q), terrain.height(r)) + rise
                    ground.quad(DV3(p, za), DV3(q, zb), DV3(r, zb), DV3(s, za), .tileClay, normal: .up)
                    ground.quad(DV3(p, za - 0.16), DV3(q, zb - 0.16), DV3(q, zb), DV3(p, za), .capTerracotta, normal: DV3((na + nb).normalized, 0))
                }
            }
            let length = DioramaPolygon.length(segment.points)
            for distance in stride(from: 5.0, to: length, by: 13) {
                guard let sample = DioramaPolygon.sample(segment.points, at: distance) else { continue }
                let inward = -sample.direction.left
                let p = sample.point + inward * 6.9
                guard clear(p, margin: 0.5) else { continue }
                let z = terrain.height(p)
                props.cylinder(centre: p, z0: z, z1: z + 2.8, r0: 0.065, r1: 0.045, sides: 10, .trimWhite)
                props.sphere(centre: DV3(p, z + 2.85), radii: DV3(0.2, 0.2, 0.24), .poolCoping, detail: 1)
                glow.sphere(centre: DV3(p, z + 2.85), radii: DV3(0.18, 0.18, 0.22), .lampGlow, detail: 1)
                if lights.count < config.maxLights {
                    lights.append(.init(position: DV3(p, z + 2.85), color: SIMD3(1, 0.83, 0.57), radius: 7, intensity: 0.7))
                }
            }
        }
        // Ocean restaurant: terrace furniture and the white switchback stair seen at the left.
        let base = plan.footprints.map { terrain.foundationHeight($0) }.max() ?? 0
        let deckPieces = cutouts.subtract(from: plan.restaurantDeck)
        for piece in deckPieces.flatMap({ DioramaStreetSurface([grounds]).intersection($0) }) {
            terrain.foundation(piece, top: base, swatch: .coralStone, into: &props)
            props.extrude(piece, z0: base - 0.24, z1: base, .coralStone, top: .tileClay)
        }
        for u in stride(from: -59.0, through: -35, by: 6) {
            let p = plan.point(u, 53)
            guard DioramaPolygon.contains(grounds, p), !data.water.contains(where: { DioramaPolygon.contains(polygon: $0.rings, p) }) else { continue }
            props.instance(library.parasol[0], .init(scale: DV3(0.8, 0.8, 0.8), translation: DV3(p, max(base, terrain.height(p)))))
        }
        let stair = plan.point(-28, 44)
        for flight in 0..<2 {
            let direction = flight == 0 ? plan.seaward : -plan.seaward
            let start = stair + plan.axis * (Double(flight) * 2.5) + (flight == 0 ? .zero : plan.seaward * 4.2)
            let z = base + Double(flight) * 1.65
            for step in 0..<10 {
                let p = start + direction * (Double(step) * 0.42)
                props.box(centre: p, z0: z + Double(step) * 0.165, axis: plan.axis,
                    halfLength: 1.1, halfWidth: 0.23, height: 0.165, .poolCoping, bevel: 0.02)
            }
            for side in [-1.0, 1.0] {
                let p = start + plan.axis * (side * 1.07)
                props.tube(from: DV3(p, z + 0.95), to: DV3(p + direction * 4.2, z + 2.6),
                    r0: 0.045, r1: 0.045, sides: 8, .trimWhite)
            }
            let landing = start + direction * 4.2
            props.box(centre: landing, z0: z + 1.5, axis: plan.axis, halfLength: 2.4, halfWidth: 0.7,
                height: 0.18, .poolCoping, bevel: 0.04)
        }
    }
}
