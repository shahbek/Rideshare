import simd
import SceneKit

/// Direct triangle primitives for real-scale bridge beams/cables; avoids lazy SceneKit primitive baking.
enum LandmarkMesh {
    /// Closed footprint shell with the same six-segment rounded roof shoulder as Slipway.
    static func volume(_ ring: [SIMD2<Double>], bottom: Double, top: Double,
                       material: SCNMaterial, name: String) -> SCNNode {
        let radius = min(DioramaConfig.slipway.cornerRadius, max(0.08, (top - bottom) * 0.35))
        let softened = BuildingContour.rounded(ring, tangentDistance: radius, segments: 6)
        let outline = DioramaPolygon.counterClockwise(softened.map { DV2($0.x, $0.y) })
        let bevel = min(DioramaConfig.slipway.roofBevel, (top - bottom) * 0.35)
        var shell = DioramaMesh()
        let kit = DioramaBuildingKit(config: .slipway)
        for edge in outline.indices { kit.wall(outline, edge: edge, z0: bottom, z1: top - bevel, .whitewash, into: &shell) }
        if kit.roofEdge(outline, flags: Array(repeating: false, count: outline.count), z: top - bevel,
                        bevel: bevel, deck: .whitewash, into: &shell) == nil {
            for edge in outline.indices { kit.wall(outline, edge: edge, z0: top - bevel, z1: top, .whitewash, into: &shell) }
            shell.polygon(outline, z: top, .whitewash)
        }
        shell.polygon(outline, z: bottom, .whitewash, facingUp: false)
        var mesh = BuildingMesh(); mesh.append(shell)
        return mesh.node(name: name, material: material)
    }

    static func beam(_ mesh: inout BuildingMesh, from start: SIMD3<Double>, to end: SIMD3<Double>, radius: Double, sides: Int = 6) {
        let direction = end - start
        guard simd_length(direction) > 0.001, radius > 0, sides >= 3 else { return }
        let axis = simd_normalize(direction)
        let helper = abs(axis.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
        let u = simd_normalize(simd_cross(axis, helper)), v = simd_cross(axis, u)
        for i in 0..<sides {
            let a = Double(i) * 2 * .pi / Double(sides), b = Double(i + 1) * 2 * .pi / Double(sides)
            let n0 = u * cos(a) + v * sin(a), n1 = u * cos(b) + v * sin(b)
            let p = n0 * radius, q = n1 * radius
            mesh.smoothQuad(start + p, start + q, end + q, end + p, normals: [n0, n1, n1, n0])
            mesh.triangle(start, start + q, start + p, normal: -axis)
            mesh.triangle(end, end + p, end + q, normal: axis)
        }
    }
}
