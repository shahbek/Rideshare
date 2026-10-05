import Foundation

/// Pale-roof western gallery and its northern return, identified separately in the mapped data.
/// Roof/façade details are photo-led; mapped plans and the northern block's height remain intact.
nonisolated struct DioramaSlipwayPavilion {
    static let buildingID: UInt64 = 180_607_949
    static let buildingIDs: Set<UInt64> = [buildingID, 142_262_992]
    let data: DioramaTileData
    let terrain: DioramaTerrain

    func build(_ f: DioramaBuildingFeature, mesh: inout DioramaMesh) -> DioramaBuilt {
        let base = terrain.foundationHeight(f.ring)
        let floors = f.id == Self.buildingID ? 2 : 4
        let height = f.id == Self.buildingID ? 6.35 : (f.height ?? 12.8)
        let storey = height / Double(floors), eave = base + height
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        let architecture = DioramaHotelGenerator(terrain: terrain)
        mesh.extrude(f.ring, z0: base - 0.5, z1: base + 0.16, .coralStone, top: .paving)
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
                mesh.wall(a, b, z0: base + 0.16, z1: eave, .whitewash)
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
        architecture.pitchedGalleryRoof(f.ring, box: box, z: eave + 0.1, mesh: &mesh, infillDepth: 0.1)
        mesh.polygon(f.ring, z: eave, .cream, facingUp: false)
        let target = data.landuse.first(where: { $0.id == DioramaHotelGrounds.courtyardID })?.rings.first.map { DioramaPolygon.centroid($0) } ?? box.centre + box.across * 10
        let entrance = f.ring.indices.map { DioramaPolygon.closestPointOnSegment(target, f.ring[$0], f.ring[($0 + 1) % f.ring.count]) }.min { $0.distance(to: target) < $1.distance(to: target) } ?? box.centre
        return DioramaBuilt(feature: f, kind: .commercial, floors: floors, height: height, box: box,
                            flatRoof: false, wallColor: .whitewash, entrance: entrance, entranceOut: (target - entrance).normalized)
    }
}
