import SceneKit
import simd

/// Two distinct mapped tower shells; crowns and gold feature bands mirror across the twin composition.
enum PSPFTowerGeometry {
    static func build(_ site: DarLandmarkSite, ring original: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let ring = H.ccw(BuildingContour.rounded(original, tangentDistance: 2.0, segments: 3))
        let lowX = ring.map(\.x).min() ?? -20, highX = ring.map(\.x).max() ?? 20
        let width = highX - lowX
        let roof: Double = 140.5
        let mirror = site.id == "pspf-nw"
        // Approved two-tint teal glazing with lit occupied floors; bay columns are merged quads.
        // The deep floor bands and mullions are open ledges and fins on the original lines.
        var glass = BuildingMesh(), glassAlternate = BuildingMesh(), lit = BuildingMesh()
        H.glazing(ring, bottom: 0, top: roof, rows: 18, bayWidth: 5.2, pattern: { i, bay, floor, _ in
            if (bay + floor * 3 + i) % 7 == 1 { return .lit }
            return (bay + i) % 3 == 0 ? .alternate : .pane
        }, panes: &glass, alternate: &glassAlternate, lit: &lit)
        root.addChildNode(glass.node(name: "curtainGlass", material: BuildingSurfaces.make("pspf.tealGlass", color: "#326A72", roughness: 0.4, metalness: 0.08)))
        root.addChildNode(glassAlternate.node(name: "curtainGlass", material: BuildingSurfaces.make("pspf.tealGlass", color: "#417E86", roughness: 0.4, metalness: 0.08)))
        root.addChildNode(lit.node(name: "occupiedTowerWindows", material: LandmarkLightingGeometry.window))
        var mullions = BuildingMesh(), gold = BuildingMesh(), ribs = BuildingMesh(), lattice = BuildingMesh(), fins = BuildingMesh()
        for floor in 1...18 { H.ledge(&mullions, ring: ring, z: Double(floor) * roof / 18 - 0.28, height: 0.56, reach: 0.5) }
        for i in ring.indices {
            let j = (i + 1) % ring.count, a = ring[i], b = ring[j], delta = b - a
            let length = simd_length(delta)
            guard length > 0.01 else { continue }
            let direction = delta / length, outward = SIMD2(direction.y, -direction.x)
            let bays = max(1, Int(ceil(length / 5.2)))
            for bay in 0..<bays {
                let t0 = Double(bay) / Double(bays), t1 = Double(bay + 1) / Double(bays)
                let p = a + delta * t0, q = a + delta * t1
                let n = outward * 0.045
                let fraction = ((p.x + q.x) / 2 - lowX) / width
                let inGoldHalf = mirror ? fraction > 0.53 : fraction < 0.47
                for floor in 0..<12 where floor % 2 == 1 && inGoldHalf {
                    let top = Double(floor + 1) * roof / 18
                    gold.quad(P.p(p + n * 12, top - 0.85), P.p(q + n * 12, top - 0.85), P.p(q + n * 12, top), P.p(p + n * 12, top))
                }
                if length > 1.2 { H.fin(&mullions, at: p, outward: outward, bottom: 0, top: roof, width: 0.5, depth: 0.42) }
                if bay % 2 == 0, length > 1.2 {
                    H.fin(&ribs, at: p, outward: outward, bottom: 97, top: roof, width: 0.7, depth: 0.8)
                }
                if abs(fraction - (mirror ? 0.55 : 0.45)) < 0.045 {
                    gold.quad(P.p(p + n * 13, 0.2), P.p(q + n * 13, 0.2), P.p(q + n * 13, 98), P.p(p + n * 13, 98))
                }
            }
            let count = max(1, Int(ceil(length / 4.0)))
            func crownHeight(_ p: SIMD2<Double>) -> Double {
                let t = (p.x - lowX) / width
                return 143.4 + 8.3 * (mirror ? 1 - t : t)
            }
            for step in 0..<count {
                let p = a + delta * (Double(step) / Double(count)), q = a + delta * (Double(step + 1) / Double(count))
                P.beam(&lattice, P.p(p * 0.94, roof + 0.4), P.p(p * 0.94, crownHeight(p)), radius: 0.30)
                P.beam(&lattice, P.p(p * 0.94, crownHeight(p)), P.p(q * 0.94, crownHeight(q)), radius: 0.34)
                for z in stride(from: 142.0, through: 150.0, by: 3.5) where z < min(crownHeight(p), crownHeight(q)) {
                    P.beam(&lattice, P.p(p * 0.94, z), P.p(q * 0.94, z), radius: 0.24)
                }
            }
            // End fins rise above the open lattice rather than capping the crown with a solid box.
            if abs(outward.x) > 0.82 {
                fins.quad(P.p(a * 0.96, 137), P.p(b * 0.96, 137), P.p(b * 0.96, site.height), P.p(a * 0.96, site.height))
            }
        }
        root.addChildNode(mullions.node(name: "pspfMullions", material: P.silver))
        root.addChildNode(ribs.node(name: "pspfUpperRibs", material: P.silver))
        root.addChildNode(gold.node(name: "pspfAsymmetricGoldBands", material: P.gold))
        root.addChildNode(lattice.node(name: "pspfSlopingLatticeCrown", material: P.gold))
        root.addChildNode(fins.node(name: "pspfCrownEndFins", material: P.silver))
        P.volume(ring, bottom: roof, top: roof + 0.3, material: P.gold, name: "pspfClosedRoof", root: root)
        P.volume(ring, bottom: 0, top: 0.3, material: P.silver, name: "pspfFoundation", root: root)
    }
}
