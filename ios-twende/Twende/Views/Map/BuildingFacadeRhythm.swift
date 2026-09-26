import SceneKit
import simd

/// Tall-form ribs and pier strips stay on solid bay boundaries, never across glass or doors.
struct BuildingFacadeRhythm {
    private var ribs = BuildingMesh()
    private var count: Int = 0
    let limit: Int

    init(limit: Int) { self.limit = max(0, limit) }

    mutating func addRib(start: SIMD2<Double>, tangent: SIMD2<Double>, outward: SIMD2<Double>, position: Double, bottom: Double, top: Double, variant: Int) {
        guard count < limit, top - bottom > 3 else { return }
        let centre = start + tangent * position
        let halfWidth = 0.075 + Double(variant % 3) * 0.025
        let projection = 0.18 + Double(variant % 3) * 0.06
        let steps = 6
        func point(_ angle: Double, _ z: Double) -> SIMD3<Double> {
            let xy = centre + tangent * (cos(angle) * halfWidth) + outward * (sin(angle) * projection)
            return SIMD3(xy.x, xy.y, z)
        }
        func normal(_ angle: Double) -> SIMD3<Double> {
            let xy = tangent * (cos(angle) / halfWidth) + outward * (sin(angle) / projection)
            return simd_normalize(SIMD3(xy.x, xy.y, 0))
        }
        for step in 0..<steps {
            let a = Double(step) * .pi / Double(steps), b = Double(step + 1) * .pi / Double(steps)
            ribs.smoothQuad(point(a, bottom), point(b, bottom), point(b, top), point(a, top), normals: [normal(a), normal(b), normal(b), normal(a)])
            ribs.triangle(SIMD3(centre.x, centre.y, top), point(a, top), point(b, top), normal: SIMD3(0, 0, 1))
            ribs.triangle(SIMD3(centre.x, centre.y, bottom), point(b, bottom), point(a, bottom), normal: SIMD3(0, 0, -1))
        }
        count += 1
    }

    func addNode(to root: SCNNode, identity: BuildingIdentity) {
        if !ribs.positions.isEmpty { root.addChildNode(ribs.node(name: "verticalFacadeRibs", material: identity.material("trim"))) }
    }
}
