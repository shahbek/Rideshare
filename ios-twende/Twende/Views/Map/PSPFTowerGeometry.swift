import SceneKit
import simd

/// Two distinct mapped tower shells; crowns and gold feature bands mirror across the twin composition.
enum PSPFTowerGeometry {
    static func build(_ site: DarLandmarkSite, ring original: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        let ring = BuildingContour.rounded(original, tangentDistance: 2.0, segments: 6)
        let lowX = ring.map(\.x).min() ?? -20, highX = ring.map(\.x).max() ?? 20
        let width = highX - lowX
        let roof: Double = 140.5
        let mirror = site.id == "pspf-nw"
        var glass = BuildingMesh(), glassAlternate = BuildingMesh(), mullions = BuildingMesh(), gold = BuildingMesh(), ribs = BuildingMesh(), lattice = BuildingMesh(), fins = BuildingMesh()
        let normals = BuildingContour.outwardNormals(ring)
        for i in ring.indices {
            let j = (i + 1) % ring.count, a = ring[i], b = ring[j], delta = b - a
            let length = simd_length(delta), direction = simd_normalize(delta), outward = SIMD2(direction.y, -direction.x)
            let bays = max(1, Int(ceil(length / 2.4)))
            for bay in 0..<bays {
                let t0 = Double(bay) / Double(bays), t1 = Double(bay + 1) / Double(bays)
                let p = a + delta * t0, q = a + delta * t1
                let n0 = simd_normalize(normals[i] * (1 - t0) + normals[j] * t0)
                let n1 = simd_normalize(normals[i] * (1 - t1) + normals[j] * t1)
                let ns = [P.p(n0, 0), P.p(n1, 0), P.p(n1, 0), P.p(n0, 0)]
                for floor in 0..<35 {
                    let bottom = Double(floor) * roof / 35, top = Double(floor + 1) * roof / 35
                    if (bay + i) % 3 == 0 { glassAlternate.smoothQuad(P.p(p, bottom), P.p(q, bottom), P.p(q, top), P.p(p, top), normals: ns) }
                    else { glass.smoothQuad(P.p(p, bottom), P.p(q, bottom), P.p(q, top), P.p(p, top), normals: ns) }
                    let n = outward * 0.045
                    mullions.quad(P.p(p + n, top - 0.14), P.p(q + n, top - 0.14), P.p(q + n, top), P.p(p + n, top))
                    let fraction = ((p.x + q.x) / 2 - lowX) / width
                    let inGoldHalf = mirror ? fraction > 0.53 : fraction < 0.47
                    if floor < 24 && floor % 2 == 1 && inGoldHalf {
                        gold.quad(P.p(p + n * 2, top - 0.85), P.p(q + n * 2, top - 0.85), P.p(q + n * 2, top), P.p(p + n * 2, top))
                    }
                }
                let n = outward * 0.06, strip = direction * min(0.10, length * 0.15)
                mullions.quad(P.p(p + n, 0), P.p(p + strip + n, 0), P.p(p + strip + n, roof), P.p(p + n, roof))
                if bay % 2 == 0 {
                    let w = direction * min(0.33, length * 0.2)
                    ribs.quad(P.p(p + n * 2, 97), P.p(p + w + n * 2, 97), P.p(p + w + n * 2, roof), P.p(p + n * 2, roof))
                }
                let fraction = ((p.x + q.x) / 2 - lowX) / width
                if abs(fraction - (mirror ? 0.55 : 0.45)) < 0.045 {
                    gold.quad(P.p(p + n * 3, 0.2), P.p(q + n * 3, 0.2), P.p(q + n * 3, 98), P.p(p + n * 3, 98))
                }
            }
            let count = max(1, Int(ceil(length / 1.2)))
            func crownHeight(_ p: SIMD2<Double>) -> Double {
                let t = (p.x - lowX) / width
                return 143.4 + 8.3 * (mirror ? 1 - t : t)
            }
            for step in 0..<count {
                let p = a + delta * (Double(step) / Double(count)), q = a + delta * (Double(step + 1) / Double(count))
                P.beam(&lattice, P.p(p * 0.94, roof + 0.4), P.p(p * 0.94, crownHeight(p)), radius: 0.09)
                P.beam(&lattice, P.p(p * 0.94, crownHeight(p)), P.p(q * 0.94, crownHeight(q)), radius: 0.13)
                for z in stride(from: 142.0, through: 150.0, by: 1.6) where z < min(crownHeight(p), crownHeight(q)) {
                    P.beam(&lattice, P.p(p * 0.94, z), P.p(q * 0.94, z), radius: 0.07)
                }
            }
            // End fins rise above the open lattice rather than capping the crown with a solid box.
            if abs(outward.x) > 0.82 {
                fins.quad(P.p(a * 0.96, 137), P.p(b * 0.96, 137), P.p(b * 0.96, site.height), P.p(a * 0.96, site.height))
            }
        }
        root.addChildNode(glass.node(name: "curtainGlass", material: BuildingSurfaces.make("pspf.tealGlass", color: "#326A72", roughness: 0.4, metalness: 0.08)))
        root.addChildNode(glassAlternate.node(name: "curtainGlass", material: BuildingSurfaces.make("pspf.tealGlass", color: "#417E86", roughness: 0.4, metalness: 0.08)))
        root.addChildNode(mullions.node(name: "pspfMullions", material: P.silver))
        root.addChildNode(ribs.node(name: "pspfUpperRibs", material: P.silver))
        root.addChildNode(gold.node(name: "pspfAsymmetricGoldBands", material: P.gold))
        root.addChildNode(lattice.node(name: "pspfSlopingLatticeCrown", material: P.gold))
        root.addChildNode(fins.node(name: "pspfCrownEndFins", material: P.silver))
        P.volume(ring, bottom: roof, top: roof + 0.3, material: P.gold, name: "pspfClosedRoof", root: root)
        P.volume(ring, bottom: 0, top: 0.3, material: P.silver, name: "pspfFoundation", root: root)
    }
}
