import SceneKit
import UIKit
import simd

/// Reference-led Comfort sedan. All details are attached to the same coachwork surface;
/// the hatchback, minivan and two-wheelers retain their existing geometry and finishes.
enum SedanVehicleFactory {
    private static let paint = finish("sedan-white-paint", white: 0.94, metal: 0.18, roughness: 0.24)
    private static let glass = finish("sedan-smoked-glass", white: 0.070, metal: 0.30, roughness: 0.20)
    private static let black = finish("sedan-black-trim", white: 0.035, metal: 0.10, roughness: 0.34)
    private static let rubber = finish("sedan-tyre", white: 0.055, metal: 0, roughness: 0.86)
    private static let silver = finish("sedan-disc-silver", white: 0.82, metal: 0.48, roughness: 0.30)
    private static let hub = finish("sedan-hub-silver", white: 0.65, metal: 0.42, roughness: 0.32)
    private static let gap = finish("sedan-panel-gap", white: 0.39, metal: 0, roughness: 0.60)
    private static let headlight: SCNMaterial = {
        let material = finish("sedan-white-led", white: 1, metal: 0, roughness: 0.25)
        material.emission.contents = UIColor.white
        material.emission.intensity = 2.8
        return material
    }()
    private static let taillight: SCNMaterial = {
        let material = VehicleGeometry.material(UIColor(red: 1, green: 0.055, blue: 0.025, alpha: 1), roughness: 0.25)
        material.name = "sedan-rear-led"
        material.emission.contents = material.diffuse.contents
        material.emission.intensity = 2.2
        return material
    }()

    static func makeVehicle() -> SCNNode {
        let root = SCNNode()
        root.name = "reference-sedan"
        let skin = VehicleCoachwork(style: .sedan)
        root.addChildNode(skin.makeNode(paint: paint, glass: glass, trim: black))
        glazing(root, skin: skin)
        for side: Float in [-1, 1] {
            for z in [-skin.wheelbase, skin.wheelbase] {
                discWheel(root, at: SIMD3(side * skin.wheelTrack, skin.wheelRadius, z), radius: skin.wheelRadius)
                // A broad painted arch return, not a dark floating fender or oversized chrome ring.
                VehicleGeometry.panel(root, columns: 4, rows: 48, material: paint) { u, v in
                    let angle = v * .pi
                    let radius = skin.archRadius + 0.006 + u * 0.022
                    let longitudinal = z + cos(angle) * radius
                    let width = VehicleGeometry.sample(skin.stations, at: longitudinal).y
                    return SIMD3(side * (width * 0.993 + 0.004), skin.wheelRadius + sin(angle) * radius, longitudinal)
                }.name = "sedan-arch-return"
            }
            sideDetails(root, skin: skin, side: side)
        }
        frontDetails(root, skin: skin)
        rearDetails(root, skin: skin)
        return root
    }

    private static func finish(_ name: String, white: CGFloat, metal: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let material = VehicleGeometry.material(UIColor(white: white, alpha: 1), metal: metal, roughness: roughness)
        material.name = name
        return material
    }

    /// Offset normal to the skin, not world-up: side glass and windscreen remain equally flush.
    private static func flushPoint(_ skin: VehicleCoachwork, z: Float, contour: Float, side: Float, lift: Float = 0.006) -> SIMD3<Float> {
        let point = skin.point(z: z, contour: contour, side: side)
        let along = skin.point(z: z + 0.002, contour: contour, side: side) - skin.point(z: z - 0.002, contour: contour, side: side)
        let across = skin.point(z: z, contour: min(9.99, contour + 0.002), side: side)
            - skin.point(z: z, contour: max(0, contour - 0.002), side: side)
        let cross = simd_cross(along, across) * side
        let normal = simd_length_squared(cross) > 0.0000000000000001 ? simd_normalize(cross) : SIMD3<Float>(0, 1, 0)
        return point + normal * lift
    }

    private static func glazing(_ root: SCNNode, skin: VehicleCoachwork) {
        // Shaped panes follow the roof and pillars; they never become an extra cabin-sized black block.
        for (name, lower, upper, width) in [
            ("windscreen", Float(-1.025), Float(-0.39), Float(1.87)),
            ("panoramic-roof", Float(-0.34), Float(0.96), Float(1.77)),
            ("rear-glass", Float(1.055), Float(1.66), Float(1.78))
        ] {
            let surface: (Float, Float) -> SIMD3<Float> = { u, v in
                let across = u * 2 - 1
                let edgeCurve = 0.045 * across * across
                let z = lower + edgeCurve + v * (upper - lower - 2 * edgeCurve)
                return flushPoint(skin, z: z, contour: abs(across) * width, side: across < 0 ? -1 : 1)
            }
            glazedPanel(root, name: "sedan-\(name)", surface: surface)
        }
        for side: Float in [-1, 1] {
            // The narrow black B-pillar splits two large windows, with a small rear quarter-light.
            for section in 0..<3 {
                let surface: (Float, Float) -> SIMD3<Float> = { u, v in
                    let contour = 2.17 + v * 1.79
                    let front = -0.39 - 0.615 * v
                    let rear = 0.99 + 0.57 * v
                    let pillar = 0.285 - 0.065 * v
                    let quarter = 0.92 + 0.20 * v
                    let start: Float = section == 0 ? front : (section == 1 ? pillar + 0.042 : quarter + 0.023)
                    let end: Float = section == 0 ? pillar - 0.042 : (section == 1 ? quarter - 0.023 : rear)
                    return flushPoint(skin, z: start + (end - start) * u, contour: contour, side: side)
                }
                glazedPanel(root, name: "sedan-side-window-\(section)", surface: surface)
            }
            for (start, width) in [(Float(0.285), Float(0.084)), (Float(0.92), Float(0.046))] {
                VehicleGeometry.panel(root, columns: 2, rows: 20, material: black) { u, v in
                    let slope: Float = start < 0.5 ? -0.065 : 0.20
                    let z = start + slope * v + (u - 0.5) * width
                    return flushPoint(skin, z: z, contour: 2.17 + v * 1.79, side: side, lift: 0.008)
                }.name = "sedan-window-pillar"
            }
        }
    }

    private static func glazedPanel(_ root: SCNNode, name: String, surface: (Float, Float) -> SIMD3<Float>) {
        VehicleGeometry.panel(root, columns: 32, rows: 28, material: glass, surface: surface).name = name
        var outline: [SIMD3<Float>] = []
        for i in 0...32 { outline.append(surface(Float(i) / 32, 0)) }
        for i in 1...28 { outline.append(surface(1, Float(i) / 28)) }
        for i in (0..<32).reversed() { outline.append(surface(Float(i) / 32, 1)) }
        for i in (0..<28).reversed() { outline.append(surface(0, Float(i) / 28)) }
        VehicleGeometry.seam(root, points: outline, radius: 0.007, material: black)
    }

    private static func sideDetails(_ root: SCNNode, skin: VehicleCoachwork, side: Float) {
        // Small black pull handles, with no contrasting metal insert.
        for z: Float in [0.095, 1.04] {
            let point = flushPoint(skin, z: z, contour: 5.78, side: side, lift: 0.008)
            VehicleGeometry.box(root, SIMD3(0.022, 0.042, 0.135), at: point, material: black, radius: 0.010).name = "sedan-black-handle"
        }
        // Low satin-black mirror shell mounted at the base of the A-pillar.
        let mount = flushPoint(skin, z: -0.94, contour: 4.00, side: side)
        VehicleGeometry.rod(root, from: mount, to: SIMD3(side * 0.94, 1.087, -0.89), radius: 0.027, material: black)
        let mirror = VehicleGeometry.box(root, SIMD3(0.23, 0.12, 0.19), at: SIMD3(side * 0.983, 1.12, -0.89), material: black, radius: 0.048)
        mirror.name = "sedan-black-mirror"
        VehicleGeometry.ellipsoid(root, size: SIMD3(0.086, 0.041, 0.009), at: SIMD3(side * 0.983, 1.125, -0.790), material: glass)

        // Fine, low-contrast door gaps descend from the actual window divisions.
        for (topZ, bottomZ) in [(Float(-1.00), Float(-0.80)), (Float(0.22), Float(0.18)), (Float(1.51), Float(1.05))] {
            let cut = (0...36).map { i -> SIMD3<Float> in
                let t = Float(i) / 36
                let z = topZ + (bottomZ - topZ) * t * t
                return flushPoint(skin, z: z, contour: 4.07 + t * 3.91, side: side, lift: 0.003)
            }
            VehicleGeometry.seam(root, points: cut, radius: 0.003, material: gap)
        }
        let sill = (0...48).map { i in
            flushPoint(skin, z: -0.80 + Float(i) / 48 * 1.59, contour: 8.03, side: side, lift: 0.005)
        }
        VehicleGeometry.seam(root, points: sill, radius: 0.012, material: black)
        let bonnet = (0...32).map { i in
            flushPoint(skin, z: skin.frontZ + 0.15 + Float(i) / 32 * 0.94, contour: 1.94, side: side, lift: 0.003)
        }
        VehicleGeometry.seam(root, points: bonnet, radius: 0.0025, material: gap)
    }

    private static func frontDetails(_ root: SCNNode, skin: VehicleCoachwork) {
        fascia(root, skin: skin, name: "sedan-black-front-band", width: 1.51, height: 0.142, y: 0.863, radius: 0.060, lift: 0.010, material: black)
        for side: Float in [-1, 1] {
            fascia(root, skin: skin, name: "sedan-headlight", width: 0.365, height: 0.032, x: side * 0.515, y: 0.862, radius: 0.015, lift: 0.022, material: headlight)
        }
        fascia(root, skin: skin, name: "sedan-centre-badge", width: 0.060, height: 0.012, y: 0.858, radius: 0.005, lift: 0.022, material: silver)
        // A single low intake leaves the broad white bumper uninterrupted, as in the supplied image.
        fascia(root, skin: skin, name: "sedan-lower-intake", width: 1.33, height: 0.125, y: 0.405, radius: 0.054, lift: 0.013, material: black)
    }

    /// Rounded panels curve around the actual nose rather than intersecting it as rectangular boxes.
    private static func fascia(_ root: SCNNode, skin: VehicleCoachwork, name: String, width: Float, height: Float,
                               x: Float = 0, y: Float, radius: Float, lift: Float, material: SCNMaterial) {
        VehicleGeometry.panel(root, columns: 40, rows: 24, material: material) { u, v in
            let vertical = (v - 0.5) * height
            let cornerY = max(0, abs(vertical) - (height / 2 - radius))
            let halfWidth = width / 2 - radius + sqrt(max(0, radius * radius - cornerY * cornerY))
            let lateral = x + (u * 2 - 1) * halfWidth
            let wrap = 0.08 * pow(abs(lateral) / 0.785, 4)
            return SIMD3(lateral, y + vertical, skin.frontZ + wrap - lift)
        }.name = name
    }

    private static func rearDetails(_ root: SCNNode, skin: VehicleCoachwork) {
        let bezel = (0...48).map { i -> SIMD3<Float> in
            let u = Float(i) / 48 * 2 - 1
            return SIMD3(u * 0.67, 0.838, skin.rearZ - 0.06 * pow(abs(u), 4) + 0.004)
        }
        VehicleGeometry.seam(root, points: bezel, radius: 0.030, material: black)
        VehicleGeometry.seam(root, points: bezel.map { $0 + SIMD3(0, 0, 0.023) }, radius: 0.012, material: taillight)
        VehicleGeometry.box(root, SIMD3(0.37, 0.115, 0.012), at: SIMD3(0, 0.62, skin.rearZ + 0.008), material: black, radius: 0.005)
        VehicleGeometry.box(root, SIMD3(0.30, 0.072, 0.014), at: SIMD3(0, 0.62, skin.rearZ + 0.016), material: silver, radius: 0.004)
        let boot = (0...40).map { i -> SIMD3<Float> in
            let u = Float(i) / 40 * 2 - 1
            return flushPoint(skin, z: 1.77, contour: abs(u) * 4.10, side: u < 0 ? -1 : 1, lift: 0.003)
        }
        VehicleGeometry.seam(root, points: boot, radius: 0.003, material: gap)
    }

    /// Solid spun-aluminium aero discs with a tiny inset cap, not the shared turbine-spoke wheels.
    private static func discWheel(_ root: SCNNode, at centre: SIMD3<Float>, radius: Float) {
        let width: Float = 0.24
        let tyre: [SIMD2<Float>] = [
            SIMD2(-width * 0.46, radius * 0.69), SIMD2(-width * 0.52, radius * 0.80),
            SIMD2(-width * 0.46, radius * 0.94), SIMD2(-width * 0.28, radius * 0.995),
            SIMD2(0, radius), SIMD2(width * 0.28, radius * 0.995),
            SIMD2(width * 0.46, radius * 0.94), SIMD2(width * 0.52, radius * 0.80),
            SIMD2(width * 0.46, radius * 0.69), SIMD2(-width * 0.46, radius * 0.69)
        ]
        VehicleGeometry.revolve(root, profile: tyre, at: centre, material: rubber).name = "sedan-tyre"
        for side: Float in [-1, 1] {
            // Closed cover profile: rolled outer edge, very shallow dish, then a recessed central cap.
            let profile: [SIMD2<Float>] = [
                SIMD2(0.126, 0), SIMD2(0.126, radius * 0.19),
                SIMD2(0.138, radius * 0.23), SIMD2(0.137, radius * 0.53),
                SIMD2(0.130, radius * 0.69), SIMD2(0.119, radius * 0.746),
                SIMD2(0.101, radius * 0.754), SIMD2(0.094, radius * 0.71), SIMD2(0.094, 0)
            ]
            let mirrored = profile.map { SIMD2($0.x * side, $0.y) }
            VehicleGeometry.revolve(root, profile: side > 0 ? Array(mirrored.reversed()) : mirrored, at: centre, material: silver).name = "sedan-aero-disc"
            VehicleGeometry.ellipsoid(root, size: SIMD3(0.006, radius * 0.184, radius * 0.184), at: centre + SIMD3(side * 0.128, 0, 0), material: hub).name = "sedan-inset-hub"
        }
    }
}
