import SceneKit
import simd

/// One continuous coachbuilt skin. Glazing shares the body's vertices and normals rather than
/// sitting on top as a separate volume. The minivan has its own long, upright passenger compartment.
struct VehicleCoachwork {
    enum BodyStyle { case hatchback, sedan, minivan }

    let style: BodyStyle
    var isMinivan: Bool { style == .minivan }
    var isSedan: Bool { style == .sedan }
    let stations: [SIMD4<Float>]

    init(style: BodyStyle) {
        self.style = style
        // Longitudinal position, shoulder half-width, belt height, crown height.
        if style == .minivan {
            stations = [
                SIMD4(-2.40, 0.73, 0.93, 1.00), SIMD4(-2.25, 0.87, 1.00, 1.09),
                SIMD4(-1.95, 0.91, 1.05, 1.18), SIMD4(-1.70, 0.92, 1.07, 1.44),
                SIMD4(-1.18, 0.92, 1.08, 1.87), SIMD4(-0.78, 0.93, 1.09, 1.96),
                SIMD4(0.10, 0.94, 1.10, 1.99), SIMD4(1.12, 0.94, 1.10, 1.99),
                SIMD4(1.85, 0.93, 1.09, 1.97), SIMD4(2.22, 0.89, 1.06, 1.87),
                SIMD4(2.40, 0.79, 1.00, 1.73)
            ]
        } else if style == .sedan {
            // User's sedan.png: upright rounded nose, short bonnet, generous arched cabin and short boot.
            stations = [
                SIMD4(-2.10, 0.785, 0.945, 0.985), SIMD4(-1.96, 0.865, 0.990, 1.030),
                SIMD4(-1.35, 0.895, 1.015, 1.055), SIMD4(-1.04, 0.865, 1.025, 1.080),
                SIMD4(-0.72, 0.855, 1.030, 1.330), SIMD4(-0.37, 0.850, 1.035, 1.560),
                SIMD4(0.15, 0.850, 1.040, 1.615), SIMD4(0.67, 0.860, 1.040, 1.600),
                SIMD4(1.00, 0.880, 1.035, 1.500), SIMD4(1.42, 0.895, 1.030, 1.235),
                SIMD4(1.70, 0.885, 1.015, 1.105), SIMD4(1.96, 0.850, 0.975, 1.045),
                SIMD4(2.08, 0.760, 0.910, 0.985)
            ]
        } else {
            // Compact five-door hatch: short bonnet, arched roof and a steep rear liftgate, no boot deck.
            stations = [
                SIMD4(-1.94, 0.66, 0.67, 0.71), SIMD4(-1.80, 0.79, 0.75, 0.79),
                SIMD4(-1.35, 0.86, 0.81, 0.85), SIMD4(-0.94, 0.83, 0.83, 0.88),
                SIMD4(-0.68, 0.82, 0.85, 1.12), SIMD4(-0.30, 0.81, 0.86, 1.44),
                SIMD4(0.15, 0.81, 0.87, 1.51), SIMD4(0.80, 0.83, 0.88, 1.50),
                SIMD4(1.26, 0.86, 0.88, 1.44), SIMD4(1.63, 0.85, 0.86, 1.29),
                SIMD4(1.82, 0.80, 0.81, 1.07), SIMD4(1.92, 0.68, 0.73, 0.90)
            ]
        }
    }

    var frontZ: Float { stations.first?.x ?? -1.94 }
    var rearZ: Float { stations.last?.x ?? 1.92 }
    var wheelbase: Float { isMinivan ? 1.51 : (isSedan ? 1.30 : 1.12) }
    var wheelRadius: Float { isMinivan ? 0.38 : (isSedan ? 0.44 : 0.34) }
    var archRadius: Float { wheelRadius + (isSedan ? 0.048 : 0.062) }
    var wheelTrack: Float { isMinivan ? 0.85 : (isSedan ? 0.785 : 0.78) }

    /// Half-perimeter: 0 is the roof centre, 2 the roof rail, 4 the window sill, 10 the underfloor.
    func point(z: Float, contour: Float, side: Float = 1, offset: Float = 0) -> SIMD3<Float> {
        let section = VehicleGeometry.sample(stations, at: z)
        let width = section.y, belt = section.z, crown = section.w
        let rise = min(1, max(0, (crown - belt) / 0.30))
        let roofWidth = width * (0.85 - (isMinivan ? 0.065 : (isSedan ? 0.105 : 0.17)) * rise)
        let controls: [SIMD2<Float>] = [
            SIMD2(0, crown), SIMD2(roofWidth * 0.64, crown - 0.009),
            SIMD2(roofWidth, crown - 0.035),
            SIMD2(roofWidth + (width - roofWidth) * 0.48, belt + (crown - belt) * 0.48),
            SIMD2(width * 0.94, belt + 0.028), SIMD2(width * 0.985, belt),
            SIMD2(width, belt - 0.075), SIMD2(width * 0.988, isSedan ? 0.60 : 0.53),
            SIMD2(width * 0.94, isSedan ? 0.30 : 0.34),
            SIMD2(width * 0.76, isSedan ? 0.27 : 0.30), SIMD2(0, isSedan ? 0.27 : 0.30)
        ]
        let segment = min(9, max(0, Int(contour)))
        let t = min(1, max(0, contour - Float(segment)))
        let p0 = controls[max(0, segment - 1)], p1 = controls[segment]
        let p2 = controls[segment + 1], p3 = controls[min(10, segment + 2)]
        let p = VehicleGeometry.cubic(p0, p1, p2, p3, t: t)
        var y = p.y
        let distance = min(abs(z - wheelbase), abs(z + wheelbase))
        if contour > 5, distance < archRadius {
            let opening = wheelRadius + sqrt(archRadius * archRadius - distance * distance)
            let sideWeight = min(1, max(0, (p.x / width - 0.72) / 0.17))
            y += max(0, opening - y) * sideWeight
        }
        let corner = pow(min(1, p.x / max(width, 0.001)), 4)
        let nose = max(0, 1 - (z - frontZ) / 0.22) * 0.08
        let tail = max(0, 1 - (rearZ - z) / 0.22) * 0.06
        return SIMD3(side * (p.x + offset), y, z + corner * (nose - tail))
    }

    func makeNode(paint: SCNMaterial, glass: SCNMaterial, trim: SCNMaterial) -> SCNNode {
        let rows = 120
        let sides = 100
        var positions: [SIMD3<Float>] = []
        var groups = [[Int32]](repeating: [], count: 3)
        for row in 0...rows {
            let z = frontZ + (rearZ - frontZ) * Float(row) / Float(rows)
            for column in 0..<sides {
                let perimeter = Float(column) * 20 / Float(sides)
                positions.append(point(z: z, contour: perimeter <= 10 ? perimeter : 20 - perimeter,
                                       side: perimeter <= 10 ? 1 : -1))
            }
        }
        for row in 0..<rows {
            let z = frontZ + (rearZ - frontZ) * (Float(row) + 0.5) / Float(rows)
            for column in 0..<sides {
                let perimeter = (Float(column) + 0.5) * 20 / Float(sides)
                let contour = perimeter <= 10 ? perimeter : 20 - perimeter
                let index = materialIndex(z: z, contour: contour)
                let a = Int32(row * sides + column)
                let b = Int32(row * sides + (column + 1) % sides)
                let c = a + Int32(sides), d = b + Int32(sides)
                groups[index].append(contentsOf: [a, c, b, b, c, d])
            }
        }
        for row in [0, rows] {
            let centre = Int32(positions.count)
            let z = row == 0 ? frontZ : rearZ
            positions.append(SIMD3(0, 0.53, z))
            let first = Int32(positions.count)
            positions.append(contentsOf: positions[(row * sides)..<((row + 1) * sides)])
            for column in 0..<sides {
                let a = first + Int32(column), b = first + Int32((column + 1) % sides)
                groups[0].append(contentsOf: row == 0 ? [centre, a, b] : [centre, b, a])
            }
        }
        let node = VehicleGeometry.mesh(positions, groups: groups, materials: [paint, glass, trim])
        node.name = "continuous-\(style)-coachwork"
        return node
    }

    private func materialIndex(z: Float, contour: Float) -> Int {
        if contour > 8.1 { return 2 }
        // Sedan glass uses precisely bounded conformal panels, avoiding staircase edges in the side windows.
        if isSedan { return 0 }
        if isMinivan {
            if contour < 1.77 {
                if z > -1.92 && z < -1.17 { return 1 }
                // Two panoramic roof lights separated by a structural crossmember.
                if z > -0.94 && z < 0.10 { return 1 }
                if z > 0.27 && z < 1.87 { return 1 }
            }
            if contour > 2.25 && contour < 3.95 {
                let fraction = (contour - 2.25) / 1.70
                let front = -1.13 - 0.62 * fraction
                let rear = 2.06 + 0.09 * fraction
                if z > front && z < rear {
                    if abs(z + 0.45) < 0.055 || abs(z - 1.17) < 0.045 { return 2 }
                    return 1
                }
            }
        } else {
            if contour < 1.75 {
                if z > -0.87 && z < -0.34 { return 1 }
                if z > -0.19 && z < (isSedan ? 0.49 : 1.07) { return 1 }
                if z > (isSedan ? 0.65 : 1.31) && z < (isSedan ? 1.38 : 1.81) { return 1 }
            }
            if contour > 2.25 && contour < 3.95 {
                let fraction = (contour - 2.25) / 1.70
                let front = -0.29 - 0.54 * fraction
                let rear = isSedan ? 0.65 + 0.62 * fraction : 1.17 + 0.24 * fraction
                if z > front && z < rear {
                    if abs(z - 0.26) < 0.042 { return 2 }
                    return 1
                }
            }
        }
        return 0
    }
}
