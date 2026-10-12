import SceneKit
import simd

/// Illustrative unbranded A320-class aircraft: 37.6m fuselage, 35.8m span, supported gear.
enum AirportAircraftGeometry {
    static func make() -> SCNNode {
        let root = SCNNode()
        var body = BuildingMesh(), windows = BuildingMesh(), metal = BuildingMesh(), tyres = BuildingMesh()
        let profile: [(Double, Double)] = [(-18.8, 0), (-17.5, 0.48), (-14, 1.35), (-10, 1.9), (11.5, 1.95), (15, 1.7), (17.5, 0.95), (18.8, 0)]
        for row in 0..<(profile.count - 1) {
            func sample(_ i: Int, _ j: Int) -> (SIMD3<Double>, SIMD3<Double>) {
                let a = Double(j) * 2 * Double.pi / 24, p = profile[i]
                let before = profile[max(0, i - 1)], after = profile[min(profile.count - 1, i + 1)]
                let dx = after.0 - before.0, dr = after.1 - before.1
                return (SIMD3(p.0, cos(a) * p.1, 3.6 + sin(a) * p.1), simd_normalize(SIMD3(-dr, cos(a) * dx, sin(a) * dx)))
            }
            for j in 0..<24 {
                let a = sample(row, j), b = sample(row, j + 1), c = sample(row + 1, j + 1), d = sample(row + 1, j)
                body.smoothQuad(a.0, b.0, c.0, d.0, normals: [a.1, b.1, c.1, d.1])
            }
        }
        func foil(_ ring: [SIMD2<Double>], z: Double, thickness: Double) {
            let wound = DioramaPolygon.counterClockwise(ring.map { DV2($0.x, $0.y) })
            for (a, b, c) in DioramaPolygon.triangulate(wound) {
                body.triangle(SIMD3(wound[a].x, wound[a].y, z + thickness), SIMD3(wound[b].x, wound[b].y, z + thickness), SIMD3(wound[c].x, wound[c].y, z + thickness))
                body.triangle(SIMD3(wound[c].x, wound[c].y, z), SIMD3(wound[b].x, wound[b].y, z), SIMD3(wound[a].x, wound[a].y, z))
            }
            for i in wound.indices {
                let a = wound[i], b = wound[(i + 1) % wound.count]
                body.quad(SIMD3(a.x, a.y, z), SIMD3(b.x, b.y, z), SIMD3(b.x, b.y, z + thickness), SIMD3(a.x, a.y, z + thickness))
            }
        }
        for side in [-1.0, 1.0] {
            foil([SIMD2(3.5, side * 1.6), SIMD2(-6.3, side * 17.9), SIMD2(-9.3, side * 17.9), SIMD2(-5.8, side * 1.6)], z: 3.0, thickness: 0.28)
            foil([SIMD2(-11.8, side * 1.0), SIMD2(-17.4, side * 6.2), SIMD2(-18.5, side * 6.2), SIMD2(-16.8, side * 1.0)], z: 4.0, thickness: 0.18)
            body.quad(SIMD3(-6.3, side * 17.9, 3.25), SIMD3(-9.3, side * 17.9, 3.25), SIMD3(-8.9, side * 17.9, 4.75), SIMD3(-7.0, side * 17.9, 5.4))
            body.quad(SIMD3(-7.0, side * 17.9, 5.4), SIMD3(-8.9, side * 17.9, 4.75), SIMD3(-9.3, side * 17.9, 3.25), SIMD3(-6.3, side * 17.9, 3.25))
            // Nacelles and a dark recessed intake; the wing carries each pylon.
            var engine = BuildingMesh()
            engine.revolve(centre: .zero, profile: [SIMD2(0.78, -2.0), SIMD2(1.03, -1.5), SIMD2(1.04, 0.9), SIMD2(0.83, 1.35)], segments: 16)
            let nacelle = engine.node(name: "aircraftEngineNacelle", material: DarLandmarkParts.plaster)
            nacelle.simdTransform = simd_float4x4(columns: (SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(1, 0, 0, 0), SIMD4(0.4, Float(side * 5.3), 2.1, 1)))
            root.addChildNode(nacelle)
            LandmarkMesh.beam(&windows, from: SIMD3(1.48, side * 5.3, 2.1), to: SIMD3(1.54, side * 5.3, 2.1), radius: 0.82, sides: 16)
            AirportArchitectureParts.box(&metal, centre: SIMD2(-0.5, side * 5.3), width: 2.0, depth: 0.28, bottom: 2.5, top: 3.4)
            for x in stride(from: -11.5, through: 12, by: 0.92) {
                windows.quad(SIMD3(x - 0.17, side * 1.88, 4.0), SIMD3(x + 0.17, side * 1.88, 4.0), SIMD3(x + 0.17, side * 1.82, 4.35), SIMD3(x - 0.17, side * 1.82, 4.35), normal: SIMD3(0, side, 0))
            }
        }
        // Thick closed vertical stabilizer, not a single paper triangle.
        let fin = [SIMD3(-17.5, -0.12, 4.4), SIMD3(-10.5, -0.12, 4.4), SIMD3(-15.5, -0.12, 11.8), SIMD3(-18.0, -0.12, 11.8)]
        body.quad(fin[3], fin[2], fin[1], fin[0])
        let other = fin.map { $0 + SIMD3(0, 0.24, 0) }
        body.quad(other[0], other[1], other[2], other[3])
        for i in fin.indices { let j = (i + 1) % fin.count; body.quad(fin[i], fin[j], other[j], other[i]) }
        for (x, y, r) in [(13.5, 0.0, 0.38), (-2.0, -2.6, 0.54), (-2.0, 2.6, 0.54)] {
            LandmarkMesh.beam(&metal, from: SIMD3(x, y, r), to: SIMD3(x, y, 2.1), radius: 0.11, sides: 8)
            for offset in [-0.16, 0.16] {
                LandmarkMesh.beam(&tyres, from: SIMD3(x, y + offset - 0.1, r), to: SIMD3(x, y + offset + 0.1, r), radius: r, sides: 12)
            }
        }
        root.addChildNode(body.node(name: "aircraftClosedFuselageWingsTail", material: DarLandmarkParts.plaster))
        root.addChildNode(windows.node(name: "aircraftWindowsAndIntake", material: DarLandmarkParts.dark))
        root.addChildNode(metal.node(name: "aircraftGearAndPylons", material: DarLandmarkParts.silver))
        root.addChildNode(tyres.node(name: "aircraftTyres", material: DarLandmarkParts.dark))
        return root
    }
}
