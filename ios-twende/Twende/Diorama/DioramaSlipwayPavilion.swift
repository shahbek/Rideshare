import Foundation

/// Pale-roof western gallery and its northern return, identified separately in the mapped data.
/// Photo-led authored rounded plans use OSM only for placement, scale and the northern height.
nonisolated struct DioramaSlipwayPavilion {
    static let buildingID: UInt64 = 180_607_949
    /// The white pale-roof arcade block north of Hotel Slipway.
    static let arcadeBlockID: UInt64 = 142_262_992
    static let buildingIDs: Set<UInt64> = [buildingID, arcadeBlockID]
    let data: DioramaTileData
    let terrain: DioramaTerrain

    func build(_ f: DioramaBuildingFeature, mesh: inout DioramaMesh) -> DioramaBuilt {
        let base = terrain.buildingHeight(f)
        let floors = f.id == Self.buildingID ? 2 : 4
        let height = f.id == Self.buildingID ? 6.35 : (f.height ?? 12.8)
        let storey = height / Double(floors), eave = base + height
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        let architecture = DioramaHotelGenerator(terrain: terrain)
        mesh.extrude(f.ring, z0: base - 0.25, z1: base + 0.16, .coralStone, top: .paving)
        for floor in 1..<floors {
            let deck = base + Double(floor) * storey
            mesh.extrude(f.ring, z0: deck - 0.18, z1: deck, .trimWhite, top: .paving)
            mesh.polygon(f.ring, z: deck - 0.18, .cream, facingUp: false)
        }
        for i in f.ring.indices where !f.clipped[i] {
            let a = f.ring[i], b = f.ring[(i + 1) % f.ring.count]
            let dir = (b - a).normalized, out = dir.right
            let count = max(1, Int(a.distance(to: b) / 4.8)), bay = a.distance(to: b) / Double(count)
            guard bay > 1.2 else {
                mesh.mouldedWall(f.ring, edge: i, z0: base + 0.16, z1: eave, .whitewash)
                continue
            }
            for floor in 0..<floors {
                let deck = base + Double(floor) * storey + 0.16
                let ceiling = base + Double(floor + 1) * storey
                for k in 0..<count {
                    let p = a + dir * (Double(k) * bay), q = p + dir * bay
                    let backA = p + dir * 0.25 - out * 0.9, backB = q - dir * 0.25 - out * 0.9
                    mesh.box(centre: p + dir * 0.18 - out * 0.12, z0: deck, axis: dir,
                             halfLength: 0.18, halfWidth: 0.12, height: 1.75, .whitewash)
                    if DioramaPolygon.contains(f.ring, backA), DioramaPolygon.contains(f.ring, backB) {
                        mesh.wall(backA, backB, z0: deck, z1: ceiling - 0.12, .glass)
                        mesh.box(centre: (backA + backB) * 0.5, z0: deck, axis: dir,
                                 halfLength: 0.04, halfWidth: 0.05, height: ceiling - deck - 0.12, .doorWood)
                    }
                    architecture.archedSpandrel(a: p, dir: dir, out: out, width: bay,
                        spring: deck + 1.75, rise: min(0.9, storey - 2.05), top: ceiling,
                        color: .whitewash, mesh: &mesh)
                    if floor > 0 {
                        mesh.box(centre: (p + q) * 0.5 - out * 0.14, z0: deck + 0.9, axis: dir,
                                 halfLength: bay / 2, halfWidth: 0.06, height: 0.07, .trimWhite)
                        for t in stride(from: 0.55, to: bay - 0.3, by: 0.55) {
                            mesh.box(centre: p + dir * t - out * 0.14, z0: deck, axis: dir,
                                     halfLength: 0.025, halfWidth: 0.04, height: 0.9, .trimWhite)
                        }
                    }
                }
            }
        }
        mesh.polygon(f.ring, z: eave, .cream, facingUp: false)
        if f.id == Self.buildingID {
            rooftopPool(f.ring, box: box, eave: eave, mesh: &mesh)
        } else {
            architecture.pitchedGalleryRoof(f.ring, box: box, z: eave + 0.1, mesh: &mesh, infillDepth: 0.1)
        }
        let target = data.landuse.first(where: { $0.id == DioramaHotelGrounds.courtyardID })?.rings.first.map { DioramaPolygon.centroid($0) } ?? box.centre + box.across * 10
        let entrance = f.ring.indices.map { DioramaPolygon.closestPointOnSegment(target, f.ring[$0], f.ring[($0 + 1) % f.ring.count]) }.min { $0.distance(to: target) < $1.distance(to: target) } ?? box.centre
        return DioramaBuilt(feature: f, kind: .commercial, floors: floors, height: height, box: box,
                            flatRoof: f.id == Self.buildingID, wallColor: .whitewash, entrance: entrance, entranceOut: (target - entrance).normalized)
    }

    /// Photo-led roof terrace: maroon square-tile deck, white parapet and a sunken rooftop pool.
    /// Pool size is an estimate; no mapped pool exists for this roof.
    private func rooftopPool(_ ring: [DV2], box: DioramaOrientedRect, eave: Double, mesh: inout DioramaMesh) {
        let deck = eave + 0.18
        mesh.extrude(ring, z0: eave, z1: deck, .trimWhite)
        let pool = DioramaOrientedRect(centre: box.centre, axis: box.axis,
                                       halfLength: min(box.halfLength * 0.55, 6), halfWidth: min(box.halfWidth * 0.45, 3.2))
        let coping = pool.expanded(by: 0.35)
        let usable = coping.corners.allSatisfy { DioramaPolygon.contains(ring, $0) && DioramaPolygon.distanceToRing(ring, $0) > 0.6 }
        let ccw = DioramaPolygon.counterClockwise(ring)
        let deckPieces = usable ? DioramaGroundCutouts.subtractConvex(coping.corners, from: ccw) : [ccw]
        for piece in deckPieces where piece.count >= 3 {
            let p = DioramaPolygon.counterClockwise(piece)
            for t in DioramaPolygon.triangulate(p) {
                mesh.triangle(DV3(p[t.0], deck), DV3(p[t.1], deck), DV3(p[t.2], deck), .tileClay, normal: .up)
            }
        }
        if let inner = DioramaPolygon.offset(ring, by: -0.22) {
            for i in ring.indices {
                let j = (i + 1) % ring.count
                mesh.quad(DV3(ring[i], deck + 1.0), DV3(ring[j], deck + 1.0), DV3(inner[j], deck + 1.0), DV3(inner[i], deck + 1.0), .trimWhite, normal: .up)
                mesh.wall(inner[j], inner[i], z0: deck, z1: deck + 1.0, .whitewash)
            }
            mesh.extrude(ring, z0: deck, z1: deck + 1.0, .whitewash)
        }
        guard usable else { return }
        let c = coping.corners, w = pool.corners
        for i in 0..<4 {
            let j = (i + 1) % 4
            mesh.quad(DV3(c[i], deck + 0.06), DV3(c[j], deck + 0.06), DV3(w[j], deck + 0.06), DV3(w[i], deck + 0.06), .poolCoping, normal: .up)
            mesh.wall(c[i], c[j], z0: deck, z1: deck + 0.06, .poolCoping)
            mesh.wall(w[j], w[i], z0: deck - 1.2, z1: deck + 0.06, .poolBlue)
        }
        mesh.polygon(w, z: deck - 1.2, .poolBlue)
        mesh.polygon(w, z: deck - 0.12, .poolBlue, attribute: -1)
        for t in stride(from: -pool.halfLength + 1, through: pool.halfLength - 1, by: 1.6) {
            let p = pool.centre + pool.axis * t + pool.across * (coping.halfWidth + 1.1)
            guard DioramaPolygon.contains(ring, p), DioramaPolygon.distanceToRing(ring, p) > 0.7 else { continue }
            mesh.box(centre: p, z0: deck, axis: pool.across, halfLength: 0.95, halfWidth: 0.32, height: 0.32, .cream, bevel: 0.05)
        }
    }
}
