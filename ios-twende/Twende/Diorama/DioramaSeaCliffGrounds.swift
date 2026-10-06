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
        let buildings = data.buildings.flatMap(\.footprints)
        let basins = data.landuse.filter { $0.kind == "pool" }.compactMap { $0.rings.first }
        let blocked = buildings + basins.map { DioramaPolygon.offset($0, by: 2.3) ?? $0 } + data.water.compactMap { $0.rings.first }
        let cutouts = DioramaGroundCutouts(polygons: blocked)
        let gardens = cutouts.subtract(from: grounds)
        painter.fillPieces(gardens, .lawn)
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
        // Keep the broad centre lawn empty; cluster planting along built edges and around the pool.
        if let hotel = data.buildings.first(where: { $0.id == DioramaSeaCliffSite.buildingID }) {
            for i in hotel.ring.indices {
                let a = hotel.ring[i], b = hotel.ring[(i + 1) % hotel.ring.count]
                guard a.distance(to: b) > 8 else { continue }
                let out = (b - a).normalized.right
                for k in 0..<max(1, Int(a.distance(to: b) / 10)) {
                    let p = a + (b - a) * ((Double(k) + 0.5) / Double(max(1, Int(a.distance(to: b) / 10)))) + out * 4
                    plant(p, palm: i % 3 == 0, index: i + k)
                }
            }
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
        // Low tropical garden pavilion visible in the aerial, fitted only in clear owned ground.
        let centre = data.projection.local(longitude: 39.28468, latitude: -6.73950)
        let pavilion = DioramaOrientedRect(centre: centre, axis: DV2(0.9, -0.43).normalized, halfLength: 8, halfWidth: 4.5)
        if pavilion.expanded(by: 1).corners.allSatisfy({ clear($0) }),
           !blocked.contains(where: { DioramaMapboxData.overlaps($0, pavilion.expanded(by: 1).corners) }) {
            let base = terrain.foundationHeight(pavilion.corners)
            terrain.foundation(pavilion.corners, top: base, swatch: .coralStone, into: &props)
            props.extrude(pavilion.corners, z0: base, z1: base + 0.2, .doorWood)
            for side in [-1.0, 1.0] {
                for k in -2...2 {
                    let p = centre + pavilion.axis * Double(k * 4) + pavilion.across * (side * 4.3)
                    props.box(centre: p, z0: base + 0.2, axis: pavilion.axis, halfLength: 0.14, halfWidth: 0.14,
                              height: 2.7, .doorWood, bevel: 0.04)
                }
            }
            _ = DioramaRoofBuilder.hip(pavilion.corners, flags: [false, false, false, false], z: base + 3,
                pitch: 0.57, overhang: 0.7, maxRise: 2.8, color: .seaCliffRoof, fascia: .doorWood, into: &props)
        }
    }
}
