import Foundation

/// Photo-led pale-roofed western arcade. Pools retain their own mapped plans in the amenity
/// generator; proximity alone must not turn a neighbouring pool into this building's roof deck.
nonisolated struct DioramaSlipwayPavilion {
    static let buildingID: UInt64 = 180_607_949
    let data: DioramaTileData
    let terrain: DioramaTerrain

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
            guard bay > 0.8 else {
                mesh.wall(a, b, z0: base + 0.16, z1: eave, .whitewash)
                continue
            }
            for k in 0..<count {
                let p = a + dir * (Double(k) * bay), q = p + dir * bay
                // Posts stop at the arch spring; the spandrel owns the masonry above it.
                mesh.box(centre: p + dir * 0.18 - out * 0.18, z0: base + 0.16, axis: dir, halfLength: 0.18, halfWidth: 0.18, height: deck + 1.7 - base - 0.16, .whitewash)
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
        architecture.pitchedGalleryRoof(f.ring, box: box, z: eave + 0.18, mesh: &mesh, infillDepth: 0.08)
        let target = data.landuse.first(where: { $0.id == DioramaHotelGrounds.courtyardID })?.rings.first.map { DioramaPolygon.centroid($0) } ?? box.centre + box.across * 10
        let entrance = f.ring.indices.map { DioramaPolygon.closestPointOnSegment(target, f.ring[$0], f.ring[($0 + 1) % f.ring.count]) }.min { $0.distance(to: target) < $1.distance(to: target) } ?? box.centre
        return DioramaBuilt(feature: f, kind: .commercial, floors: 2, height: eave - base, box: box, flatRoof: false, wallColor: .whitewash, entrance: entrance, entranceOut: (target - entrance).normalized)
    }
}
