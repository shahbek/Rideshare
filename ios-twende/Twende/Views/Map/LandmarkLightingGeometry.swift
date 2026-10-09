import SceneKit
import UIKit
import simd

/// Warm occupied windows and bounded real point-light fixtures consumed by the Metal site adapter.
enum LandmarkLightingGeometry {
    static let window = BuildingSurfaces.make("landmark.windowLight", color: "#FFD08A", roughness: 0.6)
    static let lamp = BuildingSurfaces.make("landmark.lamp", color: "#FFE3A6", roughness: 0.6)

    static func fixture(at point: SIMD3<Double>, radius: Double, intensity: Double, root: SCNNode) {
        let node = SCNNode()
        node.name = "landmarkPointLight"
        node.simdPosition = SIMD3(Float(point.x), Float(point.y), Float(point.z))
        let light = SCNLight()
        light.type = .omni
        light.color = UIColor(red: 1, green: 0.78, blue: 0.46, alpha: 1)
        light.intensity = CGFloat(intensity * 1000)
        light.attenuationEndDistance = CGFloat(radius)
        node.light = light
        root.addChildNode(node)
    }

    static func church(ring: [SIMD2<Double>], root: SCNNode) {
        var fixtures = BuildingMesh()
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], d = b - a
            guard simd_length(d) > 5 else { continue }
            let outward = simd_normalize(SIMD2(d.y, -d.x))
            let point = (a + b) * 0.5 + outward * 0.35
            LandmarkMesh.beam(&fixtures, from: SIMD3(point.x, point.y, 0.4),
                to: SIMD3(point.x, point.y, 0.75), radius: 0.22, sides: 8)
            fixture(at: SIMD3(point.x, point.y, 1.4), radius: 13, intensity: 1.6, root: root)
        }
        root.addChildNode(fixtures.node(name: "architecturalLighting", material: lamp))
    }
}
