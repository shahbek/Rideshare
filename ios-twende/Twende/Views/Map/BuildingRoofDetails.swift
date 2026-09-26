import SceneKit
import simd

/// Bounded sculptural roof details; no grain or photographic texture.
enum BuildingRoofDetails {
    static func dome(centre: SIMD2<Double>, radius: Double, spring: Double, trim: SCNMaterial) -> SCNNode {
        let root = SCNNode()
        root.name = "domeDetails"
        var ribs = BuildingMesh()
        for rib in 0..<16 {
            let azimuth = Double(rib) * .pi / 8
            for step in 0..<24 {
                let a = Double(step) * .pi / 50, b = Double(step + 1) * .pi / 50
                func p(_ angle: Double, _ side: Double) -> SIMD3<Double> {
                    let r = radius * cos(angle) + 0.035
                    let theta = azimuth + side * 0.012
                    return SIMD3(centre.x + r * cos(theta), centre.y + r * sin(theta), spring + radius * 0.78 * sin(angle) + 0.045)
                }
                ribs.quad(p(a, -1), p(a, 1), p(b, 1), p(b, -1))
            }
        }
        ribs.revolve(centre: centre, profile: [SIMD2(radius + 0.05, spring - 0.08), SIMD2(radius + 0.13, spring), SIMD2(radius + 0.05, spring + 0.12)], segments: 64)
        let apex = spring + radius * 0.78
        let lantern = min(0.6, radius * 0.12)
        ribs.revolve(centre: centre, profile: [SIMD2(lantern, apex - 0.1), SIMD2(lantern, apex + 0.35), SIMD2(lantern * 1.15, apex + 0.42), SIMD2(lantern * 0.8, apex + 0.55), SIMD2(0, apex + 0.95)], segments: 32)
        root.addChildNode(ribs.node(name: "domeRibsAndLantern", material: trim))
        return root
    }

    /// Barrel tiles follow a bilinear roof plane, preserving the underlying closed roof.
    static func tiles(a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>, d: SIMD3<Double>) -> SCNNode {
        var mesh = BuildingMesh()
        let columns = min(32, max(2, Int(simd_length(b - a) / 0.5)))
        let rows = min(14, max(2, Int(simd_length(d - a) / 0.65)))
        var normal = simd_normalize(simd_cross(b - a, d - a))
        if normal.z < 0 { normal = -normal }
        func point(_ u: Double, _ v: Double, _ lift: Double) -> SIMD3<Double> {
            (a * (1 - u) + b * u) * (1 - v) + (d * (1 - u) + c * u) * v + normal * lift
        }
        for row in 0..<rows {
            let v0 = Double(row) / Double(rows), v1 = min(1, Double(row + 1) / Double(rows) + 0.015)
            for column in 0..<columns {
                for segment in 0..<6 {
                    let t0 = Double(segment) / 6, t1 = Double(segment + 1) / 6
                    let u0 = (Double(column) + 0.04 + t0 * 0.92) / Double(columns)
                    let u1 = (Double(column) + 0.04 + t1 * 0.92) / Double(columns)
                    let h0 = 0.025 + 0.10 * sin(t0 * .pi), h1 = 0.025 + 0.10 * sin(t1 * .pi)
                    mesh.quad(point(u0, v0, h0), point(u1, v0, h1), point(u1, v1, h1 + 0.035), point(u0, v1, h0 + 0.035))
                }
            }
        }
        return mesh.node(name: "spanishBarrelTiles", material: BuildingSurfaces.make("glazed terracotta", color: "#AD583D", roughness: 0.58))
    }
}
