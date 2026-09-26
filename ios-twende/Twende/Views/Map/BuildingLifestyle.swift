import SceneKit
import simd

/// Alternative domestic/roof treatments, fitted to existing footprints rather than replacing them.
enum BuildingLifestyle {
    static func hasTropicalRoof(_ morphology: BuildingMorphology) -> Bool {
        [.cottage, .villa].contains(morphology.family) && morphology.identity.variant(channel: 14, count: 3) != 0
    }

    static func plantedRoof(footprint: BuildingFootprint, eave: Double, identity: BuildingIdentity) -> SCNNode? {
        guard let site = footprint.domeSite, site.radius > 3.0 else { return nil }
        let root = SCNNode(); root.name = "plantedRoof"
        let half = min(7, site.radius * 0.62)
        let grass = identity.material("lawn")
        let border = identity.material("trim")
        let minX = site.centre.x - half, minY = site.centre.y - half
        for x in 0..<2 {
            for y in 0..<2 {
                let a = SIMD2(minX + Double(x) * (half + 0.24), minY + Double(y) * (half + 0.24))
                let size = half - 0.24
                let ring = [a, a + SIMD2(size, 0), a + SIMD2(size, size), a + SIMD2(0, size)]
                let bed = BuildingFootprint(rings: [BuildingContour.rounded(ring, tangentDistance: 0.25)])
                root.addChildNode(bed.deck(at: eave + 0.18, thickness: 0.22, material: border, name: "planterBorder"))
                let inner = [a + SIMD2(0.10, 0.10), a + SIMD2(size - 0.10, 0.10), a + SIMD2(size - 0.10, size - 0.10), a + SIMD2(0.10, size - 0.10)]
                root.addChildNode(BuildingFootprint(rings: [inner]).deck(at: eave + 0.40, thickness: 0.035, material: grass, name: "roofGrass"))
            }
        }
        return root
    }

    static func tropical(footprint: BuildingFootprint, eave: Double, base: Double, identity: BuildingIdentity) -> SCNNode? {
        guard let corners = footprint.rectangle else { return nil }
        let root = SCNNode(); root.name = "baliPavilion"
        let roof = BuildingRoof.make(footprint: footprint, eave: eave, style: .hip, trim: identity.material("trim"), softensEdges: true)
        roof.enumerateChildNodes { node, _ in
            if node.name == "continuousRoof" || node.name == "spanishBarrelTiles" {
                node.geometry?.materials = [identity.material("slate")]
            }
        }
        root.addChildNode(roof)
        var screens = BuildingMesh()
        let width = simd_distance(corners[0], corners[1])
        let tangent = simd_normalize(corners[1] - corners[0]), outward = SIMD2(tangent.y, -tangent.x)
        let top = eave - 0.15, bottom = max(base + 0.5, eave - 3.1)
        for i in 0..<min(22, max(6, Int(width / 0.7))) {
            let x = 0.35 + Double(i) * (width - 0.7) / Double(max(1, min(22, max(6, Int(width / 0.7))) - 1))
            let c = corners[0] + tangent * x + outward * 0.20
            let a = c - tangent * 0.035, b = c + tangent * 0.035
            screens.quad(SIMD3(a.x, a.y, bottom), SIMD3(b.x, b.y, bottom), SIMD3(b.x, b.y, top), SIMD3(a.x, a.y, top))
        }
        root.addChildNode(screens.node(name: "tropicalTimberScreen", material: identity.material("timber")))
        return root
    }

    static func sanFranciscoBays(footprint: BuildingFootprint, base: Double, eave: Double, identity: BuildingIdentity) -> SCNNode? {
        guard let corners = footprint.rectangle, eave - base >= 6 else { return nil }
        // Short frontage faces the street in the illustrative narrow-lot grammar.
        let start = corners[3], end = corners[0], tangent = simd_normalize(end - start)
        let normal = SIMD2(tangent.y, -tangent.x), width = simd_distance(start, end)
        guard width >= 4 else { return nil }
        let root = SCNNode(); root.name = "sanFranciscoBays"
        var cheeks = BuildingMesh(), glass = BuildingMesh(), trim = BuildingMesh()
        let count = min(2, max(1, Int(width / 4.5)))
        let floors = max(1, min(5, Int((eave - base) / 3.3) - 1))
        func p(_ x: Double, _ d: Double, _ z: Double) -> SIMD3<Double> {
            let xy = start + tangent * x + normal * d
            return SIMD3(xy.x, xy.y, z)
        }
        for bay in 0..<count {
            let centre = width * (Double(bay) + 0.5) / Double(count)
            let half = min(1.15, width / Double(count) * 0.33)
            for floor in 0..<floors {
                let low = base + Double(floor + 1) * (eave - base) / Double(floors + 1) + 0.08
                let high = min(eave - 0.22, low + 2.45)
                let outline = [(centre - half, 0.02), (centre - half * 0.70, 0.62), (centre + half * 0.70, 0.62), (centre + half, 0.02)]
                for edge in 0..<3 {
                    let a = outline[edge], b = outline[edge + 1]
                    cheeks.quad(p(a.0, a.1, low), p(b.0, b.1, low), p(b.0, b.1, high), p(a.0, a.1, high))
                    let c = (a.0 * 0.91 + b.0 * 0.09, a.1 * 0.91 + b.1 * 0.09)
                    let d = (b.0 * 0.91 + a.0 * 0.09, b.1 * 0.91 + a.1 * 0.09)
                    glass.quad(p(c.0, c.1 + 0.02, low + 0.20), p(d.0, d.1 + 0.02, low + 0.20), p(d.0, d.1 + 0.02, high - 0.18), p(c.0, c.1 + 0.02, high - 0.18))
                    trim.quad(p(a.0, a.1 + 0.04, high - 0.10), p(b.0, b.1 + 0.04, high - 0.10), p(b.0, b.1 + 0.04, high + 0.04), p(a.0, a.1 + 0.04, high + 0.04))
                }
                cheeks.quad(p(outline[0].0, outline[0].1, high), p(outline[1].0, outline[1].1, high), p(outline[2].0, outline[2].1, high), p(outline[3].0, outline[3].1, high), normal: SIMD3(0, 0, 1))
            }
        }
        root.addChildNode(cheeks.node(name: "projectingBayWalls", material: identity.material("trim")))
        root.addChildNode(glass.node(name: "bayWindowGlass", material: identity.material("curtainGlass")))
        root.addChildNode(trim.node(name: "bayWindowCornices", material: identity.material("trim")))
        return root
    }
}
