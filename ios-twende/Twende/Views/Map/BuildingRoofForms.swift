import SceneKit
import simd

/// Closed roof silhouettes, kept inside a validated rectangular footprint above the native envelope.
enum BuildingRoofForms {
    static func mansard(corners: [SIMD2<Double>], eave: Double, trim: SCNMaterial, variant: Int) -> SCNNode {
        let root = SCNNode()
        guard corners.count == 4 else { return root }
        let a = corners[0], b = corners[1], d = corners[3]
        let length = simd_distance(a, b), width = simd_distance(a, d)
        let u = (b - a) / length, v = (d - a) / width
        let inset = min(2.5, width * 0.20), rise = min(4.1, width * (0.20 + Double(variant % 3) * 0.015))
        let bottom = eave + 0.18
        func p(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
            let xy = a + u * x + v * y
            return SIMD3(xy.x, xy.y, bottom + z)
        }
        let upper = [p(inset, inset, rise), p(length - inset, inset, rise), p(length - inset, width - inset, rise), p(inset, width - inset, rise)]
        let lower = [p(0, 0, 0), p(length, 0, 0), p(length, width, 0), p(0, width, 0)]
        var roof = BuildingMesh(), cheeks = BuildingMesh(), glass = BuildingMesh(), dormerRoof = BuildingMesh()
        for i in 0..<4 { let j = (i + 1) % 4; roof.quad(lower[i], lower[j], upper[j], upper[i]) }
        roof.quad(upper[0], upper[1], upper[2], upper[3], normal: SIMD3(0, 0, 1))
        let count = min(4, max(1, Int(length / 7)))
        if rise > 1.8 && length > 8 {
            for side in 0..<2 {
                for index in 0..<count {
                    let centre = length * (Double(index) + 0.5) / Double(count)
                    let halfWidth = min(0.70, length / Double(count) * 0.16)
                    let front = side == 0 ? inset * 0.42 : width - inset * 0.42
                    let back = side == 0 ? inset * 1.12 : width - inset * 1.12
                    let sill = rise * 0.42 + 0.04, head = rise + 0.25, ridge = head + 0.48
                    let l = centre - halfWidth, r = centre + halfWidth
                    cheeks.quad(p(l, front, sill), p(l, back, sill), p(l, back, head), p(l, front, head))
                    cheeks.quad(p(r, back, sill), p(r, front, sill), p(r, front, head), p(r, back, head))
                    cheeks.quad(p(l, front, sill), p(r, front, sill), p(r, front, head), p(l, front, head))
                    let offset = side == 0 ? -0.018 : 0.018
                    glass.quad(p(l + 0.11, front + offset, sill + 0.12), p(r - 0.11, front + offset, sill + 0.12), p(r - 0.11, front + offset, head - 0.10), p(l + 0.11, front + offset, head - 0.10))
                    cheeks.triangle(p(l, front, head), p(r, front, head), p(centre, front, ridge))
                    cheeks.triangle(p(r, back, head), p(l, back, head), p(centre, back, ridge))
                    dormerRoof.quad(p(l - 0.06, front - offset * 3, head), p(centre, front - offset * 3, ridge), p(centre, back, ridge), p(l - 0.06, back, head))
                    dormerRoof.quad(p(centre, front - offset * 3, ridge), p(r + 0.06, front - offset * 3, head), p(r + 0.06, back, head), p(centre, back, ridge))
                }
            }
        }
        root.addChildNode(roof.node(name: "mansardRoof", material: BuildingSurfaces.slate))
        if !cheeks.positions.isEmpty {
            root.addChildNode(cheeks.node(name: "dormerCheeks", material: trim))
            root.addChildNode(glass.node(name: "dormerGlass", material: BuildingSurfaces.glass))
            root.addChildNode(dormerRoof.node(name: "dormerCaps", material: BuildingSurfaces.slate))
        }
        return root
    }

    static func sawtooth(corners: [SIMD2<Double>], eave: Double, trim: SCNMaterial, variant: Int) -> SCNNode {
        let root = SCNNode()
        guard corners.count == 4 else { return root }
        let a = corners[0], b = corners[1], d = corners[3]
        let length = simd_distance(a, b), width = simd_distance(a, d)
        let u = (b - a) / length, v = (d - a) / width
        let count = min(8, max(2, Int(length / (7 + Double(variant % 3)))))
        let step = length / Double(count), rise = min(3.6, step * 0.35)
        func p(_ x: Double, _ y: Double, _ height: Double) -> SIMD3<Double> {
            let xy = a + u * x + v * y
            return SIMD3(xy.x, xy.y, eave + 0.18 + height)
        }
        var slopes = BuildingMesh(), clerestories = BuildingMesh(), ends = BuildingMesh(), bars = BuildingMesh()
        for tooth in 0..<count {
            let x0 = Double(tooth) * step, x1 = x0 + step * 0.77, x2 = x0 + step
            slopes.quad(p(x0, 0, 0), p(x1, 0, rise), p(x1, width, rise), p(x0, width, 0))
            clerestories.quad(p(x1, 0, rise), p(x2, 0, 0), p(x2, width, 0), p(x1, width, rise))
            for y in [0.0, width] { ends.triangle(p(x0, y, 0), p(x1, y, rise), p(x2, y, 0)) }
            let divisions = min(16, max(2, Int(width / 2.5)))
            for mullion in 0...divisions {
                let y = width * Double(mullion) / Double(divisions)
                let lowY = max(0, y - 0.035), highY = min(width, y + 0.035)
                bars.quad(p(x1, lowY, rise + 0.025), p(x2, lowY, 0.025), p(x2, highY, 0.025), p(x1, highY, rise + 0.025))
            }
        }
        root.addChildNode(slopes.node(name: "sawtoothRoof", material: BuildingSurfaces.zinc))
        root.addChildNode(clerestories.node(name: "clerestoryGlass", material: BuildingSurfaces.glass))
        root.addChildNode(ends.node(name: "sawtoothEnds", material: trim))
        root.addChildNode(bars.node(name: "clerestoryMullions", material: trim))
        return root
    }
}
