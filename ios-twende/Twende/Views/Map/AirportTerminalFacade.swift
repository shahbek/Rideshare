import SceneKit
import simd

/// T3's continuous rising side shell and the landside curtain wall wrapping beneath it.
enum AirportTerminalFacade {
    static func add(ring: [SIMD2<Double>], heights: [Double], mapped: [SIMD2<Double>], spineFront: Double, boardingRoots: [SIMD2<Double>], root: SCNNode) {
        guard ring.count == heights.count, mapped.count > 5 else { return }
        let frontA = mapped[2], frontB = mapped[5]
        let alongFront = simd_normalize(frontB - frontA)
        var frontOut = SIMD2(-alongFront.y, alongFront.x)
        let centre = mapped.reduce(SIMD2<Double>.zero, +) / Double(mapped.count)
        if simd_dot(frontOut, centre - frontA) > 0 { frontOut = -frontOut }
        let entrances = [0.30, 0.72].map { frontA + (frontB - frontA) * $0 }
        var walls = BuildingMesh(), sideShell = BuildingMesh(), panes = BuildingMesh(), frames = BuildingMesh(), louvres = BuildingMesh()
        let frontY = max(frontA.y, frontB.y)
        func shellBottom(_ p: SIMD2<Double>) -> Double {
            let t = min(1, max(0, (p.y - spineFront) / max(1, frontY - spineFront)))
            return 0.55 + 13.65 * pow(t, 2.8)
        }
        for i in ring.indices {
            let j = (i + 1) % ring.count, a = ring[i], b = ring[j], delta = b - a
            let length = simd_length(delta)
            guard length > 0.001 else { continue }
            let normal = SIMD2(delta.y, -delta.x) / length
            let mid = (a + b) / 2
            let front = simd_dot(normal, frontOut) > 0.7 && mid.y > spineFront + 45
            let side = abs(normal.x) > 0.65 && mid.y > spineFront + 2
            var stops: [Double] = [0, 1]
            let bays = max(1, Int(ceil(length / (side ? 2.0 : 5.2))))
            for bay in 1..<bays { stops.append(Double(bay) / Double(bays)) }
            if front {
                let ds = simd_dot(delta, alongFront)
                if abs(ds) > 0.001 {
                    for entry in entrances {
                        for offset in [-2.75, 2.75] {
                            let t = (simd_dot(entry - a, alongFront) + offset) / ds
                            if t > 0, t < 1 { stops.append(t) }
                        }
                    }
                }
            }
            let along = delta / length
            let gates = boardingRoots.filter { abs(simd_dot($0 - a, normal)) < 0.4 }
            if !front && !side {
                for gate in gates {
                    for offset in [-1.85, 1.85] {
                        let t = (simd_dot(gate - a, along) + offset) / length
                        if t > 0, t < 1 { stops.append(t) }
                    }
                }
            }
            stops.sort()
            for (t, u) in zip(stops, stops.dropFirst()) where u - t > 0.00001 {
                let p = a + delta * t, q = a + delta * u
                let za = heights[i] + (heights[j] - heights[i]) * t
                let zb = heights[i] + (heights[j] - heights[i]) * u
                if front {
                    let door = entrances.contains { abs(simd_dot((p + q) / 2 - $0, alongFront)) < 2.75 }
                    let bottom = door ? 4.45 : 0.32
                    pane(&panes, p, q, low: bottom, highA: za, highB: zb, normal: normal)
                } else if side {
                    let lowA = min(za - 0.35, shellBottom(p)), lowB = min(zb - 0.35, shellBottom(q))
                    risingShell(&sideShell, p, q, bottomA: lowA, bottomB: lowB, topA: za, topB: zb, normal: normal)
                    pane(&panes, p - normal * 0.275, q - normal * 0.275, low: 0.32, highA: lowA, highB: lowB, normal: normal)
                    LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(p - normal * 0.12, lowA), to: DarLandmarkParts.p(q - normal * 0.12, lowB), radius: 0.11, sides: 6)
                    if lowA > 3 && Int(t * Double(bays)) % 3 == 0 {
                        LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(p - normal * 0.12, 0.32), to: DarLandmarkParts.p(p - normal * 0.12, lowA), radius: 0.12, sides: 6)
                    }
                    for z in [5.7, 10.8] where z < min(lowA, lowB) {
                        LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(p - normal * 0.12, z), to: DarLandmarkParts.p(q - normal * 0.12, z), radius: 0.10, sides: 6)
                    }
                } else {
                    // Two readable airside storeys, solid spandrels and an opaque upper wall beneath the roof.
                    wall(&walls, p, q, low: 0.32, highA: 1.3, highB: 1.3, normal: normal)
                    let gate = gates.contains { abs(simd_dot((p + q) / 2 - $0, along)) < 1.85 }
                    wall(&walls, p, q, low: 4.9, highA: gate ? 5.7 : 6.3, highB: gate ? 5.7 : 6.3, normal: normal)
                    wall(&walls, p, q, low: 10.8, highA: za, highB: zb, normal: normal)
                    pane(&panes, p - normal * 0.15, q - normal * 0.15, low: 1.3, highA: 4.9, highB: 4.9, normal: normal)
                    pane(&panes, p - normal * 0.15, q - normal * 0.15, low: gate ? 8.93 : 6.3, highA: 10.8, highB: 10.8, normal: normal)
                }
                let crossesDoor = front && entrances.contains { abs(simd_dot(p - $0, alongFront)) < 2.70 }
                let crossesGate = !front && gates.contains { abs(simd_dot(p - $0, along)) < 1.8 }
                if !side && !crossesDoor && !crossesGate && simd_distance(p, q) > 1.2 {
                    LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(p - normal * 0.08, 0.32), to: DarLandmarkParts.p(p - normal * 0.08, za), radius: 0.16, sides: 8)
                }
            }
            if !side {
                for z in [0.45, 5.7, 10.8] where z < min(heights[i], heights[j]) {
                    // Door openings remain genuinely open below the entrance lintel.
                    if front && z < 4.45 { continue }
                    LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(a - normal * 0.08, z), to: DarLandmarkParts.p(b - normal * 0.08, z), radius: 0.12, sides: 8)
                }
                LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(a - normal * 0.08, heights[i]), to: DarLandmarkParts.p(b - normal * 0.08, heights[j]), radius: 0.14, sides: 8)
            }
        }
        root.addChildNode(sideShell.node(name: "terminal3ContinuousSideRoofShell", material: DarLandmarkParts.plaster))
        root.addChildNode(walls.node(name: "terminal3SolidCreamSideWallsAndSpandrels", material: DarLandmarkParts.plaster))
        root.addChildNode(louvres.node(name: "terminal3OpaqueServiceLouvreBand", material: DarLandmarkParts.dark))
        root.addChildNode(panes.node(name: "terminal3ZonedClearGlazing", material: AirportArchitectureParts.clearGlass()))
        root.addChildNode(frames.node(name: "terminal3AlignedFacadeMullions", material: DarLandmarkParts.silver))
        for (index, entrance) in entrances.enumerated() {
            revolvingEntrance(at: entrance - frontOut * 0.25, outward: frontOut, title: index == 0 ? "ARRIVALS" : "DEPARTURES", root: root)
        }
    }

    private static func risingShell(_ mesh: inout BuildingMesh, _ a: SIMD2<Double>, _ b: SIMD2<Double>, bottomA: Double, bottomB: Double, topA: Double, topB: Double, normal: SIMD2<Double>) {
        let p = a - normal * 0.55, q = b - normal * 0.55
        mesh.quad(DarLandmarkParts.p(a, bottomA + 0.14), DarLandmarkParts.p(b, bottomB + 0.14), DarLandmarkParts.p(b, topB), DarLandmarkParts.p(a, topA))
        mesh.quad(DarLandmarkParts.p(q, bottomB + 0.14), DarLandmarkParts.p(p, bottomA + 0.14), DarLandmarkParts.p(p, topA), DarLandmarkParts.p(q, topB))
        for step in 0..<6 {
            let angleA = Double(step) * Double.pi / 6, angleB = Double(step + 1) * Double.pi / 6
            func sample(_ xy: SIMD2<Double>, _ z: Double, _ angle: Double) -> (SIMD3<Double>, SIMD3<Double>) {
                let point = xy - normal * (0.275 * (1 - cos(angle)))
                let n = simd_normalize(SIMD3(normal.x * cos(angle) / 0.275, normal.y * cos(angle) / 0.275, -sin(angle) / 0.14))
                return (DarLandmarkParts.p(point, z + 0.14 * (1 - sin(angle))), n)
            }
            let pa = sample(a, bottomA, angleA), pb = sample(b, bottomB, angleA), pc = sample(b, bottomB, angleB), pd = sample(a, bottomA, angleB)
            mesh.smoothQuad(pa.0, pb.0, pc.0, pd.0, normals: [pa.1, pb.1, pc.1, pd.1])
        }
        mesh.quad(DarLandmarkParts.p(a, topA), DarLandmarkParts.p(b, topB), DarLandmarkParts.p(q, topB), DarLandmarkParts.p(p, topA))
    }

    private static func pane(_ mesh: inout BuildingMesh, _ a: SIMD2<Double>, _ b: SIMD2<Double>, low: Double, highA: Double, highB: Double, normal: SIMD2<Double>) {
        guard min(highA, highB) > low else { return }
        mesh.quad(DarLandmarkParts.p(a, low), DarLandmarkParts.p(b, low), DarLandmarkParts.p(b, highB), DarLandmarkParts.p(a, highA), normal: SIMD3(normal.x, normal.y, 0))
    }

    /// A closed inward-thickened panel, including reveals around the real facade openings.
    private static func wall(_ mesh: inout BuildingMesh, _ a: SIMD2<Double>, _ b: SIMD2<Double>, low: Double, highA: Double, highB: Double, normal: SIMD2<Double>) {
        guard min(highA, highB) > low else { return }
        let p = a - normal * 0.55, q = b - normal * 0.55
        let al = DarLandmarkParts.p(a, low), bl = DarLandmarkParts.p(b, low)
        let ah = DarLandmarkParts.p(a, highA), bh = DarLandmarkParts.p(b, highB)
        let pl = DarLandmarkParts.p(p, low), ql = DarLandmarkParts.p(q, low)
        let ph = DarLandmarkParts.p(p, highA), qh = DarLandmarkParts.p(q, highB)
        mesh.quad(al, bl, bh, ah)
        mesh.quad(ql, pl, ph, qh)
        mesh.quad(pl, al, ah, ph)
        mesh.quad(bl, ql, qh, bh)
        mesh.quad(ah, bh, qh, ph)
        mesh.quad(pl, ql, bl, al)
    }

    private static func revolvingEntrance(at centre: SIMD2<Double>, outward: SIMD2<Double>, title: String, root: SCNNode) {
        let radius = 2.6, facingAngle = atan2(outward.y, outward.x)
        var panes = BuildingMesh(), metal = BuildingMesh(), roof = BuildingMesh()
        for arc in 0..<48 {
            let a = Double(arc) * 2 * Double.pi / 48, b = Double(arc + 1) * 2 * Double.pi / 48
            let relative = atan2(sin((a + b) / 2 - facingAngle), cos((a + b) / 2 - facingAngle))
            // Open passage at both sides of the drum; do not draw a glass cylinder across the doors.
            guard abs(relative) > 0.62, abs(relative) < Double.pi - 0.62 else { continue }
            let p = centre + SIMD2(cos(a), sin(a)) * radius, q = centre + SIMD2(cos(b), sin(b)) * radius
            pane(&panes, p, q, low: 0.32, highA: 4.25, highB: 4.25, normal: SIMD2(cos((a + b) / 2), sin((a + b) / 2)))
            for z in [0.4, 4.22] { LandmarkMesh.beam(&metal, from: DarLandmarkParts.p(p, z), to: DarLandmarkParts.p(q, z), radius: 0.08, sides: 6) }
            if arc % 6 == 0 { LandmarkMesh.beam(&metal, from: DarLandmarkParts.p(p, 0.32), to: DarLandmarkParts.p(p, 4.25), radius: 0.09, sides: 8) }
        }
        LandmarkMesh.beam(&metal, from: DarLandmarkParts.p(centre, 0.32), to: DarLandmarkParts.p(centre, 4.4), radius: 0.20, sides: 12)
        for wing in 0..<3 {
            let angle = facingAngle + Double(wing) * 2 * Double.pi / 3 + 0.3
            let tip = centre + SIMD2(cos(angle), sin(angle)) * 2.35
            pane(&panes, centre, tip, low: 0.45, highA: 4.12, highB: 4.12, normal: SIMD2(sin(angle), -cos(angle)))
            pane(&panes, tip, centre, low: 0.45, highA: 4.12, highB: 4.12, normal: SIMD2(-sin(angle), cos(angle)))
            LandmarkMesh.beam(&metal, from: DarLandmarkParts.p(tip, 0.45), to: DarLandmarkParts.p(tip, 4.12), radius: 0.075, sides: 8)
            for z in [0.45, 4.12] { LandmarkMesh.beam(&metal, from: DarLandmarkParts.p(centre, z), to: DarLandmarkParts.p(tip, z), radius: 0.07, sides: 8) }
        }
        roof.revolve(centre: centre, profile: [SIMD2(0, 4.38), SIMD2(2.55, 4.38), SIMD2(2.72, 4.49), SIMD2(2.55, 4.65), SIMD2(0, 4.65)], segments: 48)
        root.addChildNode(panes.node(name: "terminal3CircularEntranceGlass", material: AirportArchitectureParts.clearGlass(alpha: 0.09)))
        root.addChildNode(metal.node(name: "terminal3RevolvingDoorColumnAndWings", material: DarLandmarkParts.silver))
        root.addChildNode(roof.node(name: "terminal3CircularDoorDrumCap", material: DarLandmarkParts.plaster))
        AirportArchitectureParts.name(title, centre: DarLandmarkParts.p(centre + outward * 2.65, 4.95), facing: outward, height: 0.6, root: root, material: AirportArchitectureParts.signBlue, maximumWidth: 5.1)
    }
}
