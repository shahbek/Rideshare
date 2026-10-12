import SceneKit
import UIKit
import simd

/// Scene construction markers consumed as spatially binned GPU instances, not baked copies.
enum AirportInstanceGeometry {
    static let prefix = "airportInstance."

    static func place(_ prototype: SCNNode, id: String, at point: SIMD3<Double>, angle: Double = 0, scale: Double = 1, root: SCNNode) {
        let node = prototype.clone()
        node.name = prefix + id
        node.simdPosition = SIMD3(Float(point.x), Float(point.y), Float(point.z))
        node.simdEulerAngles = SIMD3(0, 0, Float(angle))
        node.simdScale = SIMD3(repeating: Float(scale))
        root.addChildNode(node)
    }

    static func colored(_ source: DioramaMesh) -> SCNNode {
        let node = SCNNode()
        let swatches = Dictionary(grouping: source.indices) { DioramaAtlas.lookup(source.uvs[Int($0)])?.swatch ?? .whitewash }
        for swatch in swatches.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let ids = swatches[swatch] else { continue }
            var mesh = BuildingMesh()
            for i in stride(from: 0, to: max(0, ids.count - 2), by: 3) {
                let vertices = [Int(ids[i]), Int(ids[i + 1]), Int(ids[i + 2])]
                mesh.smoothTriangle(vertices.map { let p = source.positions[$0]; return SIMD3(p.x, p.y, p.z) }, normals: vertices.map { let n = source.normals[$0]; return SIMD3(n.x, n.y, n.z) })
            }
            let c = DioramaAtlas.color(swatch, dark: false, config: .slipway)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            let wood = swatch == .palmTrunk || swatch == .trunk || swatch == .coconut
            let foliage = swatch == .leafDark || swatch == .leafOlive || swatch == .leafBright || swatch == .leafMid || swatch == .leafLight
            material.name = wood ? "landmark.trunk" : foliage ? "landmark.foliage" : "airport.propPigment"
            material.roughness.contents = 0.85
            material.isDoubleSided = foliage
            node.addChildNode(mesh.node(name: "airportPrototypePigment", material: material))
        }
        return node
    }
}
