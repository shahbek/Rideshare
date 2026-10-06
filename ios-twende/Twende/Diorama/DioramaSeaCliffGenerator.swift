import Foundation

/// Sculpted aerial-reference composition, not an extrusion of the mapped building polygon.
nonisolated struct DioramaSeaCliffGenerator {
    let data: DioramaTileData
    let terrain: DioramaTerrain
    let config: DioramaConfig

    func build(_ feature: DioramaBuildingFeature, mesh: inout DioramaMesh, glow: inout DioramaMesh,
               detailed: Bool = true) -> DioramaBuilt {
        let plan = DioramaSeaCliffSite.plan(data.projection)
        let base = plan.footprints.map { terrain.foundationHeight($0) }.max() ?? terrain.buildingHeight(feature)
        let old = mesh.baseZ, oldGlow = glow.baseZ
        defer { mesh.baseZ = old; glow.baseZ = oldGlow }
        for mass in plan.masses {
            terrain.foundation(mass.box.corners, top: base, swatch: .coralStone, into: &mesh)
            mesh.baseZ = base; glow.baseZ = base
            buildMass(mass, detailed: detailed, mesh: &mesh, glow: &glow)
            mesh.baseZ = old; glow.baseZ = oldGlow
        }
        return .init(feature: feature, kind: .apartments, floors: 3, height: 10.2,
            box: DioramaPolygon.minimumAreaRectangle(feature.ring), flatRoof: false, wallColor: .whitewash,
            entrance: plan.point(0, -7), entranceOut: -plan.seaward)
    }

    private func buildMass(_ mass: DioramaSeaCliffPlan.Mass, detailed: Bool, mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let ring = mass.box.corners
        let pitch = mass.eave / Double(mass.floors)
        let kit = DioramaBuildingKit(config: config)
        for floor in 0...mass.floors {
            let z = Double(floor) * pitch
            mesh.extrude(ring, z0: z, z1: z + 0.18, mass.pavilion ? .doorWood : .trimWhite,
                top: mass.pavilion ? .doorWood : .trimWhite)
            mesh.polygon(ring, z: z, .trimWhite, facingUp: false)
        }
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let dir = (b - a).normalized, out = dir.right, length = a.distance(to: b)
            let count = max(1, Int(length / (mass.pavilion ? 3.5 : 3.7)))
            let bay = length / Double(count)
            for floor in 0..<mass.floors {
                let z = Double(floor) * pitch + 0.18
                let open = mass.openGround && floor == 0
                if !detailed && !open { mesh.wall(a, b, z0: z, z1: z + pitch - 0.18, .whitewash); continue }
                for k in 0..<count {
                    let l = a + dir * (Double(k) * bay), r = l + dir * bay
                    let recess = mass.openGround ? 1.2 : 0.25
                    for p in [l + dir * 0.14, r - dir * 0.14] {
                        mesh.box(centre: p - out * 0.17, z0: z, axis: dir, halfLength: 0.14, halfWidth: 0.2,
                            height: pitch - 0.18, mass.pavilion ? .doorWood : .trimWhite, bevel: 0.055)
                    }
                    mesh.box(centre: (l + r) * 0.5 - out * 0.18, z0: z + pitch - 0.53, axis: dir,
                        halfLength: bay / 2, halfWidth: 0.21, height: 0.35, mass.pavilion ? .doorWood : .trimWhite, bevel: 0.04)
                    if !open {
                        let backL = l - out * recess, backR = r - out * recess
                        mesh.wall(backL, backR, z0: z, z1: z + 0.62, .whitewash)
                        mesh.wall(backL, backR, z0: z + pitch - 0.75, z1: z + pitch - 0.18, .whitewash)
                        kit.window(a: backL, dir: dir, out: out, u: bay / 2, z0: z + 0.72, z1: z + pitch - 0.85,
                            width: bay - 0.65, hasGrille: false, lit: (floor + k) % 3 != 0, into: &mesh, glow: &glow)
                    }
                    if mass.openGround && !mass.pavilion && floor > 0 {
                        for h in [0.15, 0.92] {
                            mesh.box(centre: (l + r) * 0.5, z0: z + h, axis: dir, halfLength: bay / 2,
                                halfWidth: 0.045, height: 0.08, .trimWhite, bevel: 0.025)
                        }
                        for n in 1..<max(2, Int(bay / 0.4)) {
                            let p = l + dir * (Double(n) * 0.4)
                            mesh.box(centre: p, z0: z + 0.23, axis: dir, halfLength: 0.024, halfWidth: 0.024, height: 0.69, .trimWhite)
                        }
                    }
                }
            }
        }
        hipRoof(mass.box, z: mass.eave + 0.24, rise: mass.roofRise, detailed: detailed, mesh: &mesh)
    }

    /// Four continuous roof planes with one long ridge, deep eaves and low-relief tile courses.
    private func hipRoof(_ box: DioramaOrientedRect, z: Double, rise: Double, detailed: Bool, mesh: inout DioramaMesh) {
        let aligned = box.halfLength >= box.halfWidth ? box : DioramaOrientedRect(centre: box.centre,
            axis: box.across, halfLength: box.halfWidth, halfWidth: box.halfLength)
        let eave = aligned.expanded(by: 0.9)
        let a = eave.axis, b = eave.across
        let L = eave.halfLength, W = eave.halfWidth
        let ridge = max(0, L - W * 0.9)
        let c = eave.centre
        let p0 = c - a * L - b * W, p1 = c + a * L - b * W
        let p2 = c + a * L + b * W, p3 = c - a * L + b * W
        let r0 = c - a * ridge, r1 = c + a * ridge
        mesh.quad(DV3(p0, z), DV3(p1, z), DV3(r1, z + rise), DV3(r0, z + rise), .seaCliffRoof)
        mesh.quad(DV3(p2, z), DV3(p3, z), DV3(r0, z + rise), DV3(r1, z + rise), .seaCliffRoof)
        mesh.triangle(DV3(p1, z), DV3(p2, z), DV3(r1, z + rise), .seaCliffRoof)
        mesh.triangle(DV3(p3, z), DV3(p0, z), DV3(r0, z + rise), .seaCliffRoof)
        mesh.extrude(eave.corners, z0: z - 0.26, z1: z, .seaCliffRoof, top: nil)
        mesh.polygon(eave.corners, z: z - 0.26, .trimWhite, facingUp: false)
        mesh.tube(from: DV3(r0, z + rise), to: DV3(r1, z + rise), r0: 0.11, r1: 0.11, sides: 10, .seaCliffRoof)
        guard detailed else { return }
        let courses = max(4, Int(W / 0.48))
        for row in 1..<courses {
            let t = Double(row) / Double(courses)
            let half = L + (ridge - L) * t
            for side in [-1.0, 1.0] {
                let centre = c + b * (side * W * (1 - t))
                mesh.tube(from: DV3(centre - a * half, z + rise * t + 0.015),
                    to: DV3(centre + a * half, z + rise * t + 0.015), r0: 0.025, r1: 0.025, sides: 4, .seaCliffRoof)
            }
        }
    }
}
