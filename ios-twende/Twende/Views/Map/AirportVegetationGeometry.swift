import SceneKit
import UIKit

/// Reuses the app's established ringed-trunk, arching-frond palm recipe, including leaflets and coconuts.
enum AirportVegetationGeometry {
    static func palm(at point: DV2, base: Double, height: Double, maximumRadius: Double, cache: inout [UInt64: (node: SCNNode, radius: Double)], root: SCNNode) {
        let seed = UInt64(bitPattern: Int64((point.x * 11 + point.y * 13).rounded()))
        let variant = seed % 3 + 1
        if let cached = cache[variant] {
            let scale = min(height / 8.1, max(0.1, maximumRadius - 0.15) / max(0.1, cached.radius))
            AirportInstanceGeometry.place(cached.node, id: "existingPalm\(variant)", at: SIMD3(point.x, point.y, base), angle: Double(seed % 628) / 100, scale: scale, root: root)
            return
        }
        let prototype = DioramaPropLibrary.makePalm(seed: variant, lean: 0.28)
        let crownRadius = prototype.positions.map { hypot($0.x, $0.y) }.max() ?? 1
        let scale = min(height / 8.1, max(0.1, maximumRadius - 0.15) / max(0.1, crownRadius))
        let placed = prototype
        let swatches = Dictionary(grouping: placed.indices) { DioramaAtlas.lookup(placed.uvs[Int($0)])?.swatch ?? .trunk }
        let node = SCNNode()
        for swatch in swatches.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let ids = swatches[swatch] else { continue }
            var mesh = BuildingMesh()
            for triangle in stride(from: 0, to: max(0, ids.count - 2), by: 3) {
                let vertices = [Int(ids[triangle]), Int(ids[triangle + 1]), Int(ids[triangle + 2])]
                mesh.smoothTriangle(vertices.map { i in
                    let p = placed.positions[i]
                    return SIMD3(p.x, p.y, p.z)
                }, normals: vertices.map { i in
                    let n = placed.normals[i]
                    return SIMD3(n.x, n.y, n.z)
                })
            }
            let c = DioramaAtlas.color(swatch, dark: false, config: .slipway)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            let wood = swatch == .palmTrunk || swatch == .trunk || swatch == .coconut
            material.name = wood ? "landmark.trunk" : "landmark.foliage"
            material.roughness.contents = 1.0
            material.isDoubleSided = !wood
            node.addChildNode(mesh.node(name: wood ? "airportPalmRingedTrunkAndCoconuts" : "airportPalmCurvedFrondsAndLeaflets", material: material))
        }
        cache[variant] = (node, crownRadius)
        AirportInstanceGeometry.place(node, id: "existingPalm\(variant)", at: SIMD3(point.x, point.y, base), angle: Double(seed % 628) / 100, scale: scale, root: root)
    }
}
