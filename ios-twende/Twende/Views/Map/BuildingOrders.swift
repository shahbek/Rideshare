import SceneKit
import simd

/// Simplified classical orders, drawn as connected surfaces at map scale.
enum BuildingOrders {
    static func column(mesh: inout BuildingMesh, centre: SIMD2<Double>, tangent: SIMD2<Double>, outward: SIMD2<Double>, bottom: Double, top: Double, order: BuildingIdentity.Order) {
        let h = top - bottom
        guard h > 1 else { return }
        let r = min(0.30, h * (order == .doric ? 0.085 : 0.065))
        let flare = order == .corinthian ? 1.65 : order == .ionic ? 1.4 : 1.25
        let profile: [SIMD2<Double>] = [SIMD2(r * 1.22, bottom), SIMD2(r * 1.22, bottom + h * 0.06), SIMD2(r, bottom + h * 0.10), SIMD2(r * 0.86, top - h * 0.19), SIMD2(r * flare, top - h * 0.08), SIMD2(r * flare, top)]
        mesh.revolve(centre: centre, profile: profile, segments: 32)
        // Rounded base and neck mouldings, with slender raised flutes along the tapered shaft.
        for z in [bottom + h * 0.08, top - h * 0.18] {
            mesh.revolve(centre: centre, profile: [SIMD2(r, z - 0.045), SIMD2(r * 1.10, z), SIMD2(r, z + 0.045)], segments: 32)
        }
        for flute in 0..<12 {
            let angle = Double(flute) * .pi / 6
            let radial = SIMD2(cos(angle), sin(angle))
            let location = centre + radial * r * 0.94
            mesh.revolve(centre: location, profile: [SIMD2(0, bottom + h * 0.13), SIMD2(r * 0.065, bottom + h * 0.17), SIMD2(r * 0.045, top - h * 0.25), SIMD2(0, top - h * 0.20)], segments: 6)
        }
        if order == .ionic {
            // Paired scrolls in the facade plane, integrated into the capital.
            for side in [-1.0, 1.0] {
                let c = centre + tangent * side * r * 1.35
                let z = top - h * 0.075
                for i in 0..<20 {
                    let a = Double(i) * 2 * .pi / 20, b = Double(i + 1) * 2 * .pi / 20
                    func p(_ angle: Double, _ radius: Double) -> SIMD3<Double> {
                        let xy = c + tangent * (cos(angle) * radius) + outward * r * 0.7
                        return SIMD3(xy.x, xy.y, z + sin(angle) * radius)
                    }
                    mesh.quad(p(a, r * 0.62), p(b, r * 0.62), p(b, r * 0.30), p(a, r * 0.30))
                }
            }
        } else if order == .corinthian {
            // Eight smooth petal-shaped lobes, not noisy carved-leaf texture.
            for leaf in 0..<8 {
                let angle = Double(leaf) * .pi / 4
                let radial = SIMD2(cos(angle), sin(angle)), across = SIMD2(-radial.y, radial.x)
                let a = centre + radial * r * 0.85, b = centre + radial * r * 1.6
                let p = SIMD3(a.x, a.y, top - h * 0.20)
                let q = SIMD3(b.x, b.y, top - h * 0.04)
                mesh.triangle(p, SIMD3(b.x + across.x * r * 0.45, b.y + across.y * r * 0.45, top - h * 0.09), q)
                mesh.triangle(p, q, SIMD3(b.x - across.x * r * 0.45, b.y - across.y * r * 0.45, top - h * 0.09))
            }
        }
    }

    /// Fills the spandrel above a rectangular opening and adds a curved reveal at its actual depth.
    static func arch(wall: inout BuildingMesh, trim: inout BuildingMesh, reveal: inout BuildingMesh, start: SIMD2<Double>, tangent: SIMD2<Double>, normal: SIMD2<Double>, left: Double, right: Double, top: Double, bottom: Double, depth: Double) {
        let radius = (right - left) / 2, centre = (left + right) / 2
        let rise = min(radius, (top - bottom) * 0.38), spring = top - rise
        func p(_ x: Double, _ z: Double, _ offset: Double) -> SIMD3<Double> {
            let xy = start + tangent * x + normal * offset
            return SIMD3(xy.x, xy.y, z)
        }
        for i in 0..<20 {
            let a = Double(i) * .pi / 20, b = Double(i + 1) * .pi / 20
            let x0 = centre + radius * cos(a), x1 = centre + radius * cos(b)
            let z0 = spring + rise * sin(a), z1 = spring + rise * sin(b)
            wall.quad(p(x1, z1, 0), p(x0, z0, 0), p(x0, top, 0), p(x1, top, 0))
            reveal.quad(p(x0, z0, 0), p(x1, z1, 0), p(x1, z1, -depth + 0.015), p(x0, z0, -depth + 0.015))
            trim.quad(p(x0, z0, 0.06), p(x1, z1, 0.06), p(centre + (radius + 0.12) * cos(b), spring + (rise + 0.12) * sin(b), 0.06), p(centre + (radius + 0.12) * cos(a), spring + (rise + 0.12) * sin(a), 0.06))
        }
    }
}
