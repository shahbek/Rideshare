import SceneKit
import UIKit
import simd

/// Small photo-inspired site furnishings, not invented city-wide terrain or surveyed landscaping.
@MainActor enum DioramaLandmarkEnvironment {
    static func add(to scene: SCNScene, ring: [SIMD2<Double>], airtel: Bool) {
        let outline = DioramaPolygon.counterClockwise(ring.map { DV2($0.x, $0.y) })
        guard let outer = DioramaPolygon.offset(outline, by: 1.2), outer.count >= 3 else { return }
        let outerRing = outer.map { SIMD2($0.x, $0.y) }
        let innerRing = outline.reversed().map { SIMD2($0.x, $0.y) }
        let apron = BuildingFootprint(rings: [outerRing, innerRing]).deck(at: 0, thickness: 0.18,
            material: BuildingSurfaces.make("landmark.sitePaving", color: "#C9C2B6", roughness: 0.9), name: "landmarkSitePaving")
        scene.rootNode.addChildNode(apron)
        // Airtel's inspected frontage has palms; keep the entrance and the carriageway clear.
        guard airtel else { return }
        let edge = AirtelBuildingSite.frontEdge(ring)
        let a = ring[edge], b = ring[(edge + 1) % ring.count], direction = simd_normalize(b - a)
        let outward = SIMD2(direction.y, -direction.x)
        for t in [0.16, 0.34, 0.83] {
            let p = a + (b - a) * t + outward * 0.65
            let planter = DarLandmarkParts.rectangle(x: p.x, y: p.y, width: 1.1, depth: 1.1)
            scene.rootNode.addChildNode(LandmarkMesh.volume(planter, bottom: 0.18, top: 0.55,
                material: DarLandmarkParts.trim, name: "airtelFrontPlanter"))
            let palm = DioramaPropLibrary.makePalm(seed: UInt64(t * 100), lean: 0.3, light: true)
            var placed = DioramaMesh()
            placed.append(palm, DioramaTransform(scale: DV3(0.7, 0.7, 0.8), translation: DV3(p.x, p.y, 0.56)))
            // Convert the existing atlas swatches into explicit materials for the site adapter.
            let packed = DioramaMeshPacking.vertices(placed, category: .vegetation, config: .slipway)
            let node = SCNNode(); node.name = "landmarkSiteVegetation"
            let swatches = Dictionary(grouping: placed.indices, by: { DioramaAtlas.lookup(placed.uvs[Int($0)])?.swatch ?? .trunk })
            for swatch in swatches.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let ids = swatches[swatch] else { continue }
                var mesh = BuildingMesh()
                for tri in stride(from: 0, to: ids.count - 2, by: 3) {
                    let vs = [packed[Int(ids[tri])], packed[Int(ids[tri + 1])], packed[Int(ids[tri + 2])]]
                    mesh.smoothTriangle(vs.map { SIMD3(Double($0.position.x), Double($0.position.y), Double($0.position.z)) },
                        normals: vs.map { SIMD3(Double($0.normal.x), Double($0.normal.y), Double($0.normal.z)) })
                }
                let c = DioramaAtlas.color(swatch, dark: false, config: .slipway)
                let material = SCNMaterial(); material.diffuse.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
                material.name = swatch == .palmTrunk || swatch == .trunk ? "landmark.trunk" : "landmark.foliage"
                node.addChildNode(mesh.node(name: "sitePalm", material: material))
            }
            scene.rootNode.addChildNode(node)
        }
    }
}
