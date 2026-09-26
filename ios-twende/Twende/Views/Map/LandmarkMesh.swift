import simd

/// Direct triangle primitives for real-scale bridge beams/cables; avoids lazy SceneKit primitive baking.
enum LandmarkMesh {
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
