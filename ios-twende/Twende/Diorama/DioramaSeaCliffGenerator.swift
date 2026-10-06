import Foundation

/// Sea Cliff's mapped envelope with photo-estimated room bays, roof pitches and lower restaurant wing.
/// Courtyard voids and the mapped swimming basin are never covered by the landmark shell.
nonisolated struct DioramaSeaCliffGenerator {
    let data: DioramaTileData
    let terrain: DioramaTerrain
    let config: DioramaConfig

    func build(_ feature: DioramaBuildingFeature, mesh: inout DioramaMesh, glow: inout DioramaMesh,
               detailed: Bool = true) -> DioramaBuilt {
        let base = terrain.buildingHeight(feature)
        let hole = DioramaSeaCliffSite.courtyard(data.projection)
        let holes = hole.count >= 3 ? [hole] : []
        let cut = data.projection.local(longitude: 39.28455, latitude: -6.7396).x
        let box = DioramaRect.bounding(feature.ring).expanded(by: 2)
        // The source combines several roof masses. This height split is a photo interpretation,
        // not a claim that OSM supplies building parts or three-storey height metadata.
        let zones: [(DioramaRect, Int)] = [
            (.init(minX: box.minX, minY: box.minY, maxX: cut, maxY: box.maxY), 3),
            (.init(minX: cut, minY: box.minY, maxX: box.maxX, maxY: box.maxY), 2)
        ]
        let old = mesh.baseZ, oldGlow = glow.baseZ
        defer { mesh.baseZ = old; glow.baseZ = oldGlow }
        terrain.foundation(feature.ring, top: base, swatch: .coralStone, into: &mesh)
        mesh.baseZ = base; glow.baseZ = base
        let kit = DioramaBuildingKit(config: config)
        for (bounds, floors) in zones {
            let raw = DioramaPolygon.clipPolygon(feature.ring, to: bounds)
            guard raw.count >= 3, DioramaPolygon.area(raw) > 2 else { continue }
            let ring = DioramaPolygon.counterClockwise(DioramaPolygon.clean(raw, flags: []).points)
            let pieces = DioramaGroundCutouts(polygons: holes).subtract(from: ring)
            let height = Double(floors) * 3.4
            for floor in 0...floors {
                let z = Double(floor) * 3.4
                for piece in pieces { mesh.extrude(piece, z0: z, z1: z + 0.16, .trimWhite) }
            }
            let boundaries = [ring] + holes.map { Array($0.reversed()) }
            for boundary in boundaries {
                for i in boundary.indices {
                    let a = boundary[i], b = boundary[(i + 1) % boundary.count]
                    let midpoint = (a + b) * 0.5
                    guard bounds.contains(midpoint) else { continue }
                    let dir = (b - a).normalized, out = dir.right, length = a.distance(to: b)
                    guard length > 0.12 else { continue }
                    // No fictitious windows on the split through the connected hotel volume.
                    let internalCut = abs(a.x - cut) < 0.01 && abs(b.x - cut) < 0.01
                    if internalCut {
                        if floors == 3 { mesh.wall(a, b, z0: 6.8, z1: height, .whitewash) }
                        continue
                    }
                    if !detailed || length < 2.2 {
                        mesh.wall(a, b, z0: 0.16, z1: height, .whitewash)
                        continue
                    }
                    let bays = max(1, Int(length / 3.6)), pitch = length / Double(bays)
                    for floor in 0..<floors {
                        let z = Double(floor) * 3.4 + 0.16
                        for bay in 0..<bays {
                            let l = a + dir * (Double(bay) * pitch), r = l + dir * pitch
                            let paneWidth = max(0.8, pitch - 0.6)
                            let lower = z + (floors == 2 && floor == 0 ? 0.25 : 0.65)
                            let upper = z + 2.75
                            mesh.wall(l, r, z0: z, z1: lower - 0.12, .whitewash)
                            mesh.wall(l, r, z0: upper + 0.13, z1: z + 3.24, .whitewash)
                            for edge in [l + dir * 0.14, r - dir * 0.14] {
                                mesh.box(centre: edge - out * 0.12, z0: z, axis: dir, halfLength: 0.14,
                                         halfWidth: 0.24, height: 3.24, .trimWhite, bevel: 0.04)
                            }
                            kit.window(a: l, dir: dir, out: out, u: pitch / 2, z0: lower, z1: upper,
                                       width: paneWidth, hasGrille: false, lit: (bay + floor) % 3 != 0, into: &mesh, glow: &glow)
                            if floors == 2 && floor > 0 {
                                let q = (l + r) * 0.5 + out * 0.22
                                mesh.box(centre: q, z0: z + 0.82, axis: dir, halfLength: pitch / 2,
                                         halfWidth: 0.055, height: 0.1, .trimWhite, bevel: 0.03)
                                for k in 0..<max(2, Int(pitch / 0.42)) {
                                    let p = l + dir * (0.22 + Double(k) * 0.42) + out * 0.22
                                    mesh.box(centre: p, z0: z + 0.1, axis: dir, halfLength: 0.025,
                                             halfWidth: 0.025, height: 0.72, .trimWhite)
                                }
                            }
                        }
                    }
                }
            }
            roof(ring, holes: holes, z: height, detailed: detailed, mesh: &mesh)
        }
        let oriented = DioramaPolygon.minimumAreaRectangle(feature.ring)
        return .init(feature: feature, kind: .apartments, floors: 3, height: 10.2, box: oriented,
            flatRoof: false, wallColor: .whitewash, entrance: oriented.centre - oriented.axis * oriented.halfLength,
            entranceOut: -oriented.axis)
    }

    /// A distance-to-eave hip surface on the real outline. Subdivision retains holes, valleys and
    /// separate wings; it never roofs the bounding rectangle or fans across a concavity.
    private func roof(_ ring: [DV2], holes: [[DV2]], z: Double, detailed: Bool, mesh: inout DioramaMesh) {
        let eave = DioramaPolygon.offset(ring, by: 0.55) ?? ring
        let roofHoles = holes.map { DioramaPolygon.offset($0, by: 0.25) ?? $0 }
        let pieces = DioramaGroundCutouts(polygons: roofHoles).subtract(from: eave)
        func height(_ p: DV2) -> Double {
            let inset = min(DioramaPolygon.distanceToRing(eave, p), roofHoles.map { DioramaPolygon.distanceToRing($0, p) }.min() ?? .infinity)
            return z + 0.24 + min(4.8, inset * 0.58)
        }
        func triangle(_ a: DV2, _ b: DV2, _ c: DV2, depth: Int, into mesh: inout DioramaMesh) {
            let span = max(a.distance(to: b), max(b.distance(to: c), c.distance(to: a)))
            if span > (detailed ? 1.8 : 4) && depth < 8 {
                let ab = (a + b) * 0.5, bc = (b + c) * 0.5, ca = (c + a) * 0.5
                triangle(a, ab, ca, depth: depth + 1, into: &mesh)
                triangle(ab, b, bc, depth: depth + 1, into: &mesh)
                triangle(ca, bc, c, depth: depth + 1, into: &mesh)
                triangle(ab, bc, ca, depth: depth + 1, into: &mesh)
            } else {
                mesh.triangle(DV3(a, height(a)), DV3(b, height(b)), DV3(c, height(c)), .seaCliffRoof)
            }
        }
        for piece in pieces {
            mesh.polygon(piece, z: z + 0.05, .seaCliffRoof, facingUp: false)
            for (a, b, c) in DioramaPolygon.triangulate(piece) { triangle(piece[a], piece[b], piece[c], depth: 0, into: &mesh) }
        }
        for i in eave.indices {
            let a = eave[i], b = eave[(i + 1) % eave.count]
            mesh.wall(a, b, z0: z - 0.08, z1: z + 0.24, .seaCliffRoof)
        }
    }
}
