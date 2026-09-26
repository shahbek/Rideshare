import SceneKit
import simd

/// Reference-inspired curtain-wall tower: broad glass ribbons, rounded corners and a ribbed crown.
/// The taper starts ABOVE the native height envelope, so it cannot expose the underlying map model.
enum BuildingGlassTower {
    static func make(footprint: BuildingFootprint, base: Double, roof: Double, identity: BuildingIdentity) -> SCNNode {
        let root = SCNNode()
        root.name = "modernGlassTower"
        let softened = BuildingContour.softened(footprint)
        var glass = BuildingMesh(), bands = BuildingMesh(), crown = BuildingMesh(), ribs = BuildingMesh()
        let height = roof - base
        let floors = max(3, min(32, Int(min(32, height / 4.8))))
        let storey = height / Double(floors)
        let trim = BuildingSurfaces.make("tower white aluminium", color: "#F5F8FA", roughness: 0.55)
        for ring in softened.rings {
            let normals = BuildingContour.outwardNormals(ring)
            for i in ring.indices {
                let j = (i + 1) % ring.count
                let a = ring[i], b = ring[j]
                let n0 = SIMD3(normals[i].x, normals[i].y, 0.0), n1 = SIMD3(normals[j].x, normals[j].y, 0.0)
                glass.smoothQuad(SIMD3(a.x, a.y, base), SIMD3(b.x, b.y, base), SIMD3(b.x, b.y, roof), SIMD3(a.x, a.y, roof), normals: [n0, n1, n1, n0])
            }
        }
        for floor in 0...floors {
            let z = base + Double(floor) * storey
            bands.perimeter(rings: softened.rings, bottom: max(base, z - 0.18), top: z + 0.10, projection: 0.13, profileSegments: 4)
        }
        root.addChildNode(softened.deck(at: roof, thickness: 0.18, material: trim))
        if let ring = softened.rings.first, softened.rings.count == 1, isConvex(ring) {
            let centre = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
            let normals = BuildingContour.outwardNormals(ring)
            let crownHeight = min(14, max(4, height * 0.14))
            func p(_ index: Int, _ t: Double) -> SIMD3<Double> {
                let scale = 1 - 0.45 * t * t
                let xy = centre + (ring[index] - centre) * scale
                return SIMD3(xy.x, xy.y, roof + 0.18 + crownHeight * t)
            }
            for level in 0..<12 {
                let t0 = Double(level) / 12, t1 = Double(level + 1) / 12
                for i in ring.indices {
                    let j = (i + 1) % ring.count
                    func normal(_ index: Int, _ t: Double) -> SIMD3<Double> {
                        simd_normalize(SIMD3(normals[index].x, normals[index].y, simd_distance(ring[index], centre) * 0.9 * t / crownHeight))
                    }
                    crown.smoothQuad(p(i, t0), p(j, t0), p(j, t1), p(i, t1), normals: [normal(i, t0), normal(j, t0), normal(j, t1), normal(i, t1)])
                }
            }
            for i in ring.indices {
                let j = (i + 1) % ring.count
                crown.triangle(SIMD3(centre.x, centre.y, roof + 0.18 + crownHeight), p(i, 1), p(j, 1), normal: SIMD3(0, 0, 1))
            }
            let spacing = max(1, ring.count / 16)
            for i in stride(from: 0, to: ring.count, by: spacing) {
                let n = normals[i], tangent = SIMD2(-n.y, n.x)
                for level in 0..<12 {
                    let a = p(i, Double(level) / 12) + SIMD3(n.x * 0.04, n.y * 0.04, 0)
                    let b = p(i, Double(level + 1) / 12) + SIMD3(n.x * 0.04, n.y * 0.04, 0)
                    let offset = SIMD3(tangent.x * 0.08, tangent.y * 0.08, 0)
                    ribs.quad(a - offset, a + offset, b + offset, b - offset)
                }
            }
        }
        root.addChildNode(glass.node(name: "curtainGlass", material: identity.material("curtainGlass")))
        root.addChildNode(bands.node(name: "towerFloorRibbons", material: trim))
        if !crown.positions.isEmpty { root.addChildNode(crown.node(name: "sculptedTowerCrown", material: identity.material("metal"))) }
        if !ribs.positions.isEmpty { root.addChildNode(ribs.node(name: "towerCrownFins", material: trim)) }
        return root
    }

    private static func isConvex(_ ring: [SIMD2<Double>]) -> Bool {
        guard ring.count >= 3 else { return false }
        return ring.indices.allSatisfy { i in
            let a = ring[(i + 1) % ring.count] - ring[i]
            let b = ring[(i + 2) % ring.count] - ring[(i + 1) % ring.count]
            return a.x * b.y - a.y * b.x >= -0.00001
        }
    }
}
