import Foundation

/// Photo-led western pavilion: shops below an arched lounge, with a terracotta pool terrace.
/// Pool plan comes from the bundled map; deck elevation and stair dimensions are inferred from photos.
nonisolated struct DioramaSlipwayPavilion {
    static let buildingID: UInt64 = 180_607_949
    let data: DioramaTileData
    let terrain: DioramaTerrain

    static func pool(in data: DioramaTileData) -> DioramaAreaFeature? {
        guard let building = data.buildings.first(where: { $0.id == buildingID }) else { return nil }
        return data.landuse.filter { area in
            guard area.kind == "pool", area.sport != "private", let ring = area.rings.first else { return false }
            return DioramaPolygon.distanceToRing(building.ring, DioramaPolygon.centroid(ring)) < 35
        }.min { a, b in
            let pa = DioramaPolygon.centroid(a.rings[0]), pb = DioramaPolygon.centroid(b.rings[0])
            return DioramaPolygon.distanceToRing(building.ring, pa) < DioramaPolygon.distanceToRing(building.ring, pb)
        }
    }

    func build(_ f: DioramaBuildingFeature, mesh: inout DioramaMesh) -> DioramaBuilt {
        let base = terrain.foundationHeight(f.ring), deck = base + 3.2, eave = deck + 3.15
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        let architecture = DioramaHotelGenerator(terrain: terrain)
        mesh.extrude(f.ring, z0: base - 0.5, z1: base + 0.16, .coralStone, top: .tileClay)
        mesh.extrude(f.ring, z0: deck - 0.22, z1: deck, .trimWhite, top: .tileClay)
        mesh.polygon(f.ring, z: deck - 0.22, .cream, facingUp: false)
        for i in f.ring.indices where !f.clipped[i] {
            let a = f.ring[i], b = f.ring[(i + 1) % f.ring.count], dir = (b - a).normalized, out = dir.right
            let count = max(1, Int(a.distance(to: b) / 4.8)), bay = a.distance(to: b) / Double(count)
            for k in 0..<count {
                let p = a + dir * (Double(k) * bay), q = p + dir * bay
                mesh.box(centre: p + dir * 0.18 - out * 0.18, z0: base + 0.16, axis: dir, halfLength: 0.18, halfWidth: 0.18, height: eave - base - 0.16, .whitewash)
                let backA = p + dir * 0.35 - out * 0.65, backB = q - dir * 0.35 - out * 0.65
                if DioramaPolygon.contains(f.ring, backA), DioramaPolygon.contains(f.ring, backB) {
                    mesh.wall(backA, backB, z0: base + 0.22, z1: deck - 0.35, .glass)
                    mesh.box(centre: (backA + backB) * 0.5, z0: base + 0.22, axis: dir, halfLength: 0.045, halfWidth: 0.06, height: 2.5, .doorWood)
                }
                architecture.archedSpandrel(a: p, dir: dir, out: out, width: bay, spring: deck + 1.7, rise: 1.05, top: eave, color: .whitewash, mesh: &mesh)
                mesh.box(centre: (p + q) * 0.5 - out * 0.12, z0: deck + 0.15, axis: dir, halfLength: bay / 2, halfWidth: 0.10, height: 0.55, .whitewash)
                for t in stride(from: 0.5, to: bay - 0.2, by: 0.36) {
                    mesh.box(centre: p + dir * t - out * 0.12, z0: deck + 0.7, axis: dir, halfLength: 0.035, halfWidth: 0.05, height: 0.3, .doorWood)
                }
                mesh.box(centre: (p + q) * 0.5 - out * 0.12, z0: deck + 1.0, axis: dir, halfLength: bay / 2, halfWidth: 0.12, height: 0.08, .carvedWood)
            }
        }
        architecture.pitchedGalleryRoof(f.ring, box: box, z: eave + 0.18, mesh: &mesh, infillDepth: 0.18)
        if let pool = Self.pool(in: data), let poolRing = pool.rings.first {
            terrace(poolRing: poolRing, building: f, deck: deck, base: base, mesh: &mesh)
        }
        let target = data.landuse.first(where: { $0.id == DioramaHotelGrounds.courtyardID })?.rings.first.map { DioramaPolygon.centroid($0) } ?? box.centre + box.across * 10
        let entrance = f.ring.indices.map { DioramaPolygon.closestPointOnSegment(target, f.ring[$0], f.ring[($0 + 1) % f.ring.count]) }.min { $0.distance(to: target) < $1.distance(to: target) } ?? box.centre
        return DioramaBuilt(feature: f, kind: .commercial, floors: 2, height: eave - base, box: box, flatRoof: false, wallColor: .whitewash, entrance: entrance, entranceOut: (target - entrance).normalized)
    }

    private func terrace(poolRing: [DV2], building: DioramaBuildingFeature, deck: Double, base: Double, mesh: inout DioramaMesh) {
        guard let coping = DioramaPolygon.offset(poolRing, by: 0.38),
              let outline = DioramaPolygon.offset(poolRing, by: 2.7) else { return }
        // Restrict the inferred terrace to free site space; never let the roof deck pierce neighbours.
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: 1.7, additionalMasks: data.water.compactMap { $0.rings.first }, excludedAreaIDs: Set(data.landuse.filter { $0.kind == "terrace" }.map(\.id)))
        for piece in cutouts.subtract(from: outline) {
            var deckPieces = [piece]
            for t in DioramaPolygon.triangulate(coping) {
                let mask = [coping[t.0], coping[t.1], coping[t.2]]
                deckPieces = deckPieces.flatMap { DioramaGroundCutouts.subtractConvex(mask, from: $0) }
            }
            for part in deckPieces {
                mesh.extrude(part, z0: deck - 0.22, z1: deck, .cream, top: .tileClay)
                mesh.polygon(part, z: deck - 0.22, .cream, facingUp: false)
            }
        }
        // The pool has a recessed water plane and an annular coping, never stacked solid lids.
        mesh.extrude(poolRing, z0: base, z1: deck - 0.22, .whitewash)
        mesh.polygon(poolRing, z: deck - 0.2, .poolBlue)
        let poolBox = DioramaPolygon.minimumAreaRectangle(poolRing)
        for side in [-1.0, 1.0] {
            for t in stride(from: -poolBox.halfLength + 1.5, to: poolBox.halfLength - 1, by: 2.6) {
                let p = poolBox.centre + poolBox.axis * t + poolBox.across * (side * (poolBox.halfWidth + 1.4))
                let lounger = DioramaOrientedRect(centre: p, axis: poolBox.across, halfLength: 0.95, halfWidth: 0.34)
                guard lounger.corners.allSatisfy({ point in
                    DioramaPolygon.contains(outline, point) && !data.buildings.contains(where: { DioramaPolygon.contains($0.ring, point) })
                }) else { continue }
                guard !data.buildings.contains(where: { DioramaPolygon.contains($0.ring, p) || DioramaPolygon.distanceToRing($0.ring, p) < 1.0 }) else { continue }
                mesh.box(centre: p, z0: deck + 0.2, axis: poolBox.across, halfLength: 0.93, halfWidth: 0.34, height: 0.12, .doorWood)
                mesh.box(centre: p, z0: deck + 0.32, axis: poolBox.across, halfLength: 0.89, halfWidth: 0.31, height: 0.1, .sailCream)
            }
        }
        for i in poolRing.indices {
            let j = (i + 1) % poolRing.count
            mesh.quad(DV3(poolRing[i], deck), DV3(poolRing[j], deck), DV3(coping[j], deck), DV3(coping[i], deck), .poolCoping, normal: .up)
            mesh.wall(poolRing[j], poolRing[i], z0: deck - 0.2, z1: deck, .poolCoping)
        }
        let target = data.landuse.first(where: { $0.id == DioramaHotelGrounds.courtyardID })?.rings.first.map { DioramaPolygon.centroid($0) } ?? DioramaPolygon.centroid(outline) + DV2(10, 0)
        let rise = deck - (base + 0.07), steps = max(1, Int(ceil(rise / 0.17))), run = Double(steps) * 0.3
        let roads = DioramaRoadIndex(roads: data.roads, pavementWidth: 1.7)
        let candidates = outline.indices.sorted { i, j in
            ((outline[i] + outline[(i + 1) % outline.count]) * 0.5).distance(to: target) < ((outline[j] + outline[(j + 1) % outline.count]) * 0.5).distance(to: target)
        }
        let stairEdge = candidates.first { i in
            let a = outline[i], b = outline[(i + 1) % outline.count], axis = (b - a).normalized
            guard a.distance(to: b) > 3.2 else { return false }
            let start = (a + b) * 0.5
            // Check the interior too, not just corners: narrow obstacles can cross the stair run.
            for t in stride(from: 0.0, through: run, by: 0.3) {
                for s in [-1.4, 0, 1.4] {
                    let p = start + axis.right * t + axis * s
                    if !data.rect.contains(p) || roads.isOnRoad(p, margin: 0.2) ||
                        data.buildings.contains(where: { DioramaPolygon.contains($0.ring, p) }) ||
                        data.water.contains(where: { DioramaPolygon.contains(polygon: $0.rings, p) }) { return false }
                }
            }
            return true
        }
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count], dir = (b - a).normalized
            let length = a.distance(to: b), count = max(1, Int(ceil(length / 2.4)))
            for k in 0..<count {
                let p = a + dir * (length * (Double(k) + 0.5) / Double(count))
                guard !data.buildings.contains(where: { DioramaPolygon.contains($0.ring, p) }) else { continue }
                mesh.box(centre: p, z0: base, axis: dir, halfLength: 0.15, halfWidth: 0.15, height: deck - base, .whitewash)
                if i != stairEdge || abs((p - (a + b) * 0.5).dot(dir)) > 1.6 {
                    mesh.box(centre: p, z0: deck, axis: dir, halfLength: length / Double(count) / 2, halfWidth: 0.13, height: 0.82, .whitewash)
                    mesh.box(centre: p, z0: deck + 0.82, axis: dir, halfLength: length / Double(count) / 2, halfWidth: 0.17, height: 0.09, .cream)
                }
            }
        }
        if let stairEdge {
            let a = outline[stairEdge], b = outline[(stairEdge + 1) % outline.count]
            let axis = (b - a).normalized, outward = axis.right, landing = (a + b) * 0.5
            for k in 0..<steps {
                let p = landing + outward * ((Double(k) + 0.5) * 0.3), h = deck - Double(k) * rise / Double(steps)
                mesh.box(centre: p, z0: base + 0.07, axis: axis, halfLength: 1.4, halfWidth: 0.15, height: h - base - 0.07, .tileClay)
            }
            for s in [-1.0, 0.0, 1.0] {
                let side = axis * (s * 1.3)
                mesh.tube(from: DV3(landing + side, deck + 0.95), to: DV3(landing + side + outward * run, base + 1.02), r0: 0.045, r1: 0.045, sides: 6, .carSilver)
                for k in stride(from: 0, through: steps, by: 3) {
                    let p = landing + side + outward * (Double(k) * 0.3), z = deck - Double(k) * rise / Double(steps)
                    mesh.tube(from: DV3(p, z), to: DV3(p, z + 0.95), r0: 0.035, r1: 0.035, sides: 5, .carSilver)
                }
            }
        }
        #if DEBUG
        print("[Diorama] Slipway elevated pool terrace: stair=\(stairEdge != nil), pool vertices=\(poolRing.count)")
        #endif
    }
}
