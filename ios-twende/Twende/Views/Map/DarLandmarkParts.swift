import SceneKit
import simd

/// Small explicit-mesh construction vocabulary shared only by the researched city landmarks.
enum DarLandmarkParts {
    static let plaster = BuildingSurfaces.make("landmark.plaster", color: "#FAF9F4", roughness: 0.85, metalness: 0)
    static let trim = BuildingSurfaces.make("landmark.limestone", color: "#D9CDB7", roughness: 0.8, metalness: 0)
    static let clay = BuildingSurfaces.make("landmark.clay", color: "#AD583D", roughness: 0.82, metalness: 0)
    static let slate = BuildingSurfaces.make("landmark.slate", color: "#4C504F", roughness: 0.8, metalness: 0)
    static let dark = BuildingSurfaces.make("landmark.recess", color: "#30494E", roughness: 0.6, metalness: 0)
    static let silver = BuildingSurfaces.make("landmark.silver", color: "#BFCBCB", roughness: 0.48, metalness: 0.25)
    static let gold = BuildingSurfaces.make("landmark.pspfAnodised", color: "#D4B15B", roughness: 0.48, metalness: 0.35)

    static func p(_ xy: SIMD2<Double>, _ z: Double) -> SIMD3<Double> { SIMD3(xy.x, xy.y, z) }

    static func rectangle(x: Double, y: Double, width: Double, depth: Double) -> [SIMD2<Double>] {
        [SIMD2(x - width / 2, y - depth / 2), SIMD2(x + width / 2, y - depth / 2), SIMD2(x + width / 2, y + depth / 2), SIMD2(x - width / 2, y + depth / 2)]
    }

    static func volume(_ ring: [SIMD2<Double>], bottom: Double, top: Double, material: SCNMaterial, name: String, root: SCNNode) {
        root.addChildNode(BuildingFootprint(rings: [ring]).deck(at: bottom, thickness: top - bottom, material: material, name: name))
    }

    static func beam(_ mesh: inout BuildingMesh, _ a: SIMD3<Double>, _ b: SIMD3<Double>, radius: Double = 0.12) {
        LandmarkMesh.beam(&mesh, from: a, to: b, radius: radius, sides: 6)
    }

    static func gable(_ ring: [SIMD2<Double>], eave: Double, ridge: Double, root: SCNNode, name: String) {
        guard ring.count == 4 else { return }
        let front = (ring[0] + ring[1]) / 2, back = (ring[2] + ring[3]) / 2
        var roof = BuildingMesh(), ends = BuildingMesh(), courses = BuildingMesh()
        roof.quad(p(ring[0], eave), p(front, ridge), p(back, ridge), p(ring[3], eave))
        roof.quad(p(front, ridge), p(ring[1], eave), p(ring[2], eave), p(back, ridge))
        ends.triangle(p(ring[0], eave), p(ring[1], eave), p(front, ridge))
        ends.triangle(p(ring[2], eave), p(ring[3], eave), p(back, ridge))
        for step in 1..<16 {
            let t = Double(step) / 16
            for side in [0, 1] {
                let edgeFront = ring[side], edgeBack = ring[side == 0 ? 3 : 2]
                let z = eave + (ridge - eave) * t + 0.025
                beam(&courses, p(edgeFront + (front - edgeFront) * t, z), p(edgeBack + (back - edgeBack) * t, z), radius: 0.028)
            }
        }
        root.addChildNode(roof.node(name: name, material: clay))
        root.addChildNode(ends.node(name: "gableMasonry", material: plaster))
        root.addChildNode(courses.node(name: "roofTileCourses", material: clay))
    }

    static func pyramid(_ ring: [SIMD2<Double>], base: Double, top: Double, material: SCNMaterial, root: SCNNode, name: String) {
        let centre = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
        var mesh = BuildingMesh()
        for i in ring.indices { mesh.triangle(p(ring[i], base), p(ring[(i + 1) % ring.count], base), p(centre, top)) }
        root.addChildNode(mesh.node(name: name, material: material))
    }

    /// Front-facing right/up/outward plane; proper rotation keeps lettering and asymmetric motifs unmirrored.
    static func faceNode(at centre: SIMD2<Double>, outward: SIMD2<Double>, height: Double) -> SCNNode {
        let right = SIMD2(-outward.y, outward.x)
        let node = SCNNode()
        node.simdTransform = simd_float4x4(columns: (
            SIMD4(Float(right.x), Float(right.y), 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(Float(outward.x), Float(outward.y), 0, 0), SIMD4(Float(centre.x), Float(centre.y), Float(height), 1)
        ))
        return node
    }

    static func arch(width: Double, height: Double, root: SCNNode, name: String) {
        let half = width / 2, spring = height * 0.6
        var ring = [SIMD2(-half, 0), SIMD2(half, 0), SIMD2(half, spring)]
        for i in 1...16 {
            let t = Double(i) / 16
            let x = half * (1 - 2 * t)
            let z = spring + (height - spring) * (1 - pow(abs(2 * t - 1), 1.4))
            ring.append(SIMD2(x, z))
        }
        root.addChildNode(BuildingFootprint(rings: [ring]).deck(at: 0.03, thickness: 0.035, material: dark, name: name))
        var border = BuildingMesh()
        for i in 2..<(ring.count - 1) { beam(&border, p(ring[i], 0.09), p(ring[i + 1], 0.09), radius: 0.12) }
        for x in [-half, half] { beam(&border, SIMD3(x, 0, 0.09), SIMD3(x, spring, 0.09), radius: 0.13) }
        root.addChildNode(border.node(name: "pointedArchSurround", material: trim))
    }

    static func disc(radius: Double, root: SCNNode, name: String, clock: Bool) {
        var face = BuildingMesh(), rim = BuildingMesh(), details = BuildingMesh()
        for i in 0..<48 {
            let a = Double(i) * .pi / 24, b = Double(i + 1) * .pi / 24
            let p = SIMD3(cos(a) * radius, sin(a) * radius, 0.06), q = SIMD3(cos(b) * radius, sin(b) * radius, 0.06)
            face.triangle(SIMD3(0, 0, 0.06), p, q)
            beam(&rim, p, q, radius: 0.10)
        }
        for i in 0..<12 {
            let angle = Double(i) * .pi / 6
            let a = SIMD3(cos(angle) * radius * (clock ? 0.77 : 0.28), sin(angle) * radius * (clock ? 0.77 : 0.28), 0.12)
            let b = SIMD3(cos(angle) * radius * 0.94, sin(angle) * radius * 0.94, 0.12)
            beam(&details, a, b, radius: clock ? 0.04 : 0.065)
        }
        if clock {
            beam(&details, SIMD3(0, 0, 0.13), SIMD3(0, radius * 0.66, 0.13), radius: 0.055)
            beam(&details, SIMD3(0, 0, 0.13), SIMD3(radius * 0.45, -radius * 0.2, 0.13), radius: 0.055)
        }
        root.addChildNode(face.node(name: name, material: dark))
        root.addChildNode(rim.node(name: "stoneRoundel", material: trim))
        root.addChildNode(details.node(name: clock ? "clockHands" : "roseTracery", material: plaster))
    }
}
