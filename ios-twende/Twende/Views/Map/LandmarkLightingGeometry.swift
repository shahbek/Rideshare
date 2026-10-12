import SceneKit
import UIKit
import simd

/// Warm occupied windows and bounded real point-light fixtures consumed by the Metal site adapter.
enum LandmarkLightingGeometry {
    static let window = BuildingSurfaces.make("landmark.windowLight", color: "#FFA333", roughness: 0.6)
    static let lamp = BuildingSurfaces.make("landmark.lamp", color: "#FFB04A", roughness: 0.6)

    /// A real light at the fixture's own position. Lanterns and lamp heads throw their light down;
    /// `upward` marks a ground floodlight that washes the wall or structure above it.
    static func fixture(at point: SIMD3<Double>, radius: Double, intensity: Double, root: SCNNode, upward: Bool = false) {
        let node = SCNNode()
        node.name = "landmarkPointLight"
        node.simdPosition = SIMD3(Float(point.x), Float(point.y), Float(point.z))
        let light = SCNLight()
        light.name = upward ? "uplight" : nil
        light.type = .omni
        light.color = UIColor(red: 1, green: 0.64, blue: 0.20, alpha: 1)
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
            LandmarkMesh.leanBeam(&fixtures, from: SIMD3(point.x, point.y, 0.4),
                to: SIMD3(point.x, point.y, 0.75), radius: 0.22)
            // The floodlight sits on its own housing and washes the wall above it.
            fixture(at: SIMD3(point.x, point.y, 0.8), radius: 13, intensity: 1.6, root: root, upward: true)
        }
        root.addChildNode(fixtures.node(name: "architecturalLighting", material: lamp))
    }
}
