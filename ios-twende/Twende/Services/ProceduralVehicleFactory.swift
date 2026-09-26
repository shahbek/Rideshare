import SceneKit
import SwiftUI
import UIKit
import simd

/// Original, locally modelled fleet. Continuous skins establish the silhouette; fitted mechanical
/// details use shared materials. Cached material batches keep the richer geometry out of frame updates.
enum ProceduralVehicleFactory {
    private static var prototypes: [RideTier: SCNNode] = [:]
    private static var shadowPrototypes: [RideTier: SCNNode] = [:]
    private static let graphite = VehicleGeometry.material(UIColor(TwendeColor.inkSecondary), metal: 0.38, roughness: 0.30)
    private static let pearl = VehicleGeometry.material(UIColor(red: 240 / 255, green: 240 / 255, blue: 234 / 255, alpha: 1), metal: 0.30, roughness: 0.25)
    private static let obsidian = VehicleGeometry.material(UIColor(white: 0.095, alpha: 1), metal: 0.48, roughness: 0.24)
    private static let champagne = VehicleGeometry.material(UIColor(red: 197 / 255, green: 170 / 255, blue: 118 / 255, alpha: 1), metal: 0.72, roughness: 0.28)
    private static let titanium = VehicleGeometry.material(UIColor(white: 0.59, alpha: 1), metal: 0.68, roughness: 0.30)
    private static let rubber = VehicleGeometry.material(UIColor(white: 0.065, alpha: 1), roughness: 0.84)
    private static let glass = VehicleGeometry.material(UIColor(white: 0.085, alpha: 1), metal: 0.42, roughness: 0.17)
    private static let alloy = VehicleGeometry.material(UIColor(TwendeColor.border), metal: 0.65, roughness: 0.27)
    private static let trim = VehicleGeometry.material(UIColor(TwendeColor.ink), metal: 0.25, roughness: 0.38)
    private static let leather = VehicleGeometry.material(UIColor(TwendeColor.ink), roughness: 0.72)
    private static let lamp: SCNMaterial = illuminated(.white, intensity: 2.8)
    private static let tailLamp: SCNMaterial = illuminated(UIColor(red: 1, green: 0.055, blue: 0.025, alpha: 1), intensity: 2.2)

    static func makeVehicle(for tier: RideTier) -> SCNNode {
        if let cached = prototypes[tier] { return cached.clone() }
        let node: SCNNode
        if let forma = FormaFleetLoader.vehicle(named: formaName(for: tier)) {
            node = forma
        } else {
            switch tier {
            case .economy: node = car(style: .hatchback)
            case .comfort: node = SedanVehicleFactory.makeVehicle()
            case .premium: node = car(style: .minivan)
            case .bajaji: node = bajaji()
            case .boda: node = motorcycle()
            }
        }
        // Flatten before scaling: SceneKit can discard transforms on geometry-less grouping nodes.
        let batched = node.flattenedClone()
        let (minimum, maximum) = node.boundingBox
        let scale: Float = 3.4 / max(maximum.z - minimum.z, 0.001)
        let position = SCNVector3(-(minimum.x + maximum.x) / 2 * scale, -minimum.y * scale, -(minimum.z + maximum.z) / 2 * scale)
        batched.scale = SCNVector3(scale, scale, scale)
        batched.position = position
        let root = SCNNode()
        root.name = "miniature-\(tier.rawValue)"
        root.addChildNode(batched)
        prototypes[tier] = root

        // Preserve readable CPU triangles; the optimized GPU geometry may no longer expose its data.
        node.scale = SCNVector3(scale, scale, scale)
        node.position = position
        let shadowRoot = SCNNode()
        shadowRoot.addChildNode(node)
        shadowPrototypes[tier] = shadowRoot
        return root.clone()
    }

    /// Owner-supplied Forma fleet vehicle for each ride tier.
    static func formaName(for tier: RideTier) -> String {
        switch tier {
        case .economy: "forma-hatchback"
        case .comfort: "forma-sedan"
        case .premium: "forma-mpv"
        case .bajaji: "forma-rickshaw"
        case .boda: "forma-scooter"
        }
    }

    static func shadowGeometry(for tier: RideTier) -> SCNNode {
        if let cached = shadowPrototypes[tier] { return cached.clone() }
        _ = makeVehicle(for: tier)
        return shadowPrototypes[tier]?.clone() ?? SCNNode()
    }

    private static func illuminated(_ color: UIColor, intensity: CGFloat) -> SCNMaterial {
        let material = VehicleGeometry.material(color, roughness: 0.25)
        material.emission.contents = color
        material.emission.intensity = intensity
        return material
    }

    private static func car(style: VehicleCoachwork.BodyStyle) -> SCNNode {
        let root = SCNNode()
        let isMinivan = style == .minivan
        let paint = isMinivan ? obsidian : (style == .sedan ? graphite : pearl)
        let skin = VehicleCoachwork(style: style)
        let front = skin.frontZ, rear = skin.rearZ
        let mirrorZ: Float = isMinivan ? -1.53 : -0.61
        let mirrorY: Float = isMinivan ? 1.30 : 1.025
        let mirrorX: Float = isMinivan ? 1.04 : 0.945
        root.addChildNode(skin.makeNode(paint: paint, glass: glass, trim: trim))
        for side in [Float(-1), 1] {
            for z in [-skin.wheelbase, skin.wheelbase] {
                wheel(root, at: SIMD3(side * skin.wheelTrack, skin.wheelRadius, z), radius: skin.wheelRadius, width: 0.235, openSpokes: false)
                // The arch lip follows the cut-out, meeting the shoulder rather than floating above it.
                let points: [SIMD3<Float>] = (0...36).map { step in
                    let a = Float(step) * .pi / 36
                    let z = z + cos(a) * (skin.archRadius + 0.003)
                    let width = VehicleGeometry.sample(skin.stations, at: z).y
                    return SIMD3(side * (width * 0.99 + 0.003), skin.wheelRadius + sin(a) * (skin.archRadius + 0.003), z)
                }
                VehicleGeometry.seam(root, points: points, radius: 0.011, material: paint)
            }
            carPanelLines(root, skin: skin, side: side)
            // Proper mirror with triangular mounting foot, painted shell, dark lower edge and glass face.
            VehicleGeometry.rod(root, from: skin.point(z: mirrorZ, contour: 4, side: side),
                                to: SIMD3(side * (mirrorX - 0.02), mirrorY - 0.02, mirrorZ), radius: 0.025, material: trim)
            VehicleGeometry.ellipsoid(root, size: SIMD3(0.125, 0.061, 0.09), at: SIMD3(side * mirrorX, mirrorY, mirrorZ), material: paint)
            VehicleGeometry.ellipsoid(root, size: SIMD3(0.104, 0.039, 0.012), at: SIMD3(side * mirrorX, mirrorY, mirrorZ + 0.086), material: alloy)
            VehicleGeometry.seam(root, points: [SIMD3(side * (mirrorX - 0.065), mirrorY - 0.02, mirrorZ - 0.066), SIMD3(side * (mirrorX + 0.065), mirrorY - 0.02, mirrorZ - 0.04)], radius: 0.006, material: lamp)
            let handles: [Float] = isMinivan ? [-0.65, -0.21] : [0.05, skin.isSedan ? 0.86 : 1.03]
            for z in handles {
                let position = skin.point(z: z, contour: 5.6, side: side, offset: 0.004)
                VehicleGeometry.box(root, SIMD3(0.015, 0.029, 0.16), at: position, material: trim, radius: 0.006)
                VehicleGeometry.box(root, SIMD3(0.018, 0.013, 0.12), at: position + SIMD3(side * 0.003, 0.003, 0), material: isMinivan ? champagne : alloy, radius: 0.004)
            }
        }
        // Broad continuous signatures wrap subtly around the nose and rear shoulders.
        lightBar(root, width: isMinivan ? 1.43 : 1.30, at: SIMD3(0, isMinivan ? 0.935 : 0.671, front - 0.008), front: true, wrap: 0.070)
        lightBar(root, width: isMinivan ? 1.47 : 1.30, at: SIMD3(0, isMinivan ? 1.00 : 0.725, rear + 0.006), front: false, wrap: 0.055)
        VehicleGeometry.box(root, SIMD3(1.00, 0.105, 0.07), at: SIMD3(0, 0.445, front + 0.015), material: trim, radius: 0.022)
        VehicleGeometry.box(root, SIMD3(0.72, 0.012, 0.04), at: SIMD3(0, 0.445, front - 0.034), material: isMinivan ? champagne : graphite, radius: 0.005)
        VehicleGeometry.box(root, SIMD3(1.12, 0.07, 0.055), at: SIMD3(0, 0.357, rear - 0.08), material: trim, radius: 0.024)
        for x: Float in [-0.37, 0, 0.37] {
            VehicleGeometry.box(root, SIMD3(0.025, 0.072, 0.16), at: SIMD3(x, 0.325, rear - 0.14), material: trim, radius: 0.008)
        }
        plateRecess(root, at: SIMD3(0, isMinivan ? 0.72 : 0.53, rear + 0.023), width: 0.34)
        // Fine bonnet breaks and the rear hatch perimeter sit directly on the coachwork.
        for side in [Float(-1), 1] {
            let bonnetLength: Float = isMinivan ? 0.35 : 0.86
            let bonnet = (0...24).map { i in skin.point(z: front + 0.19 + Float(i) * bonnetLength / 24, contour: 1.50, side: side) + SIMD3(0, 0.003, 0) }
            VehicleGeometry.seam(root, points: bonnet, radius: 0.004, material: trim)
        }
        let rearEdge = (0...32).map { i -> SIMD3<Float> in
            let u = Float(i) / 32 * 2 - 1
            return skin.point(z: rear - (isMinivan ? 0.12 : (skin.isSedan ? 0.40 : 0.16)), contour: abs(u) * 5, side: u < 0 ? -1 : 1) + SIMD3(0, 0.004, 0)
        }
        VehicleGeometry.seam(root, points: rearEdge, radius: 0.005, material: trim)
        if isMinivan {
            minivanDetails(root, skin: skin)
        } else if style == .hatchback {
            let spoiler = (0...24).map { i -> SIMD3<Float> in
                let u = Float(i) / 24 * 2 - 1
                return skin.point(z: 1.22, contour: abs(u) * 1.9, side: u < 0 ? -1 : 1) + SIMD3(0, 0.022, 0)
            }
            VehicleGeometry.seam(root, points: spoiler, radius: 0.025, material: paint)
        }
        return root
    }

    private static func carPanelLines(_ root: SCNNode, skin: VehicleCoachwork, side: Float) {
        // Sill trim, window seals and door cuts are surface-following, not raised decorative tubing.
        if skin.isMinivan {
            for contour: Float in [4.13, 7.95] {
                let strip = (0...60).map { i in
                    skin.point(z: -1.81 + Float(i) * 3.95 / 60, contour: contour, side: side, offset: 0.004)
                }
                VehicleGeometry.seam(root, points: strip, radius: 0.009, material: champagne)
            }
            for z: Float in [-1.72, -0.45, 1.34] {
                let cut = (0...30).map { i in skin.point(z: z, contour: 4.2 + Float(i) * 3.65 / 30, side: side, offset: 0.003) }
                VehicleGeometry.seam(root, points: cut, radius: 0.0045, material: trim)
            }
            // Sliding-door rail runs rearwards under the third-row quarter window.
            let track = (0...36).map { i in skin.point(z: 0.13 + Float(i) * 2.02 / 36, contour: 5.8, side: side, offset: 0.004) }
            VehicleGeometry.seam(root, points: track, radius: 0.009, material: graphite)
            return
        }
        let sill = (0...32).map { i in skin.point(z: -0.65 + Float(i) * 1.30 / 32, contour: 8.05, side: side, offset: 0.003) }
        VehicleGeometry.seam(root, points: sill, radius: 0.014, material: trim)
        let seal = (0...48).map { i in skin.point(z: -0.83 + Float(i) * 2.13 / 48, contour: 4.03, side: side, offset: 0.002) }
        VehicleGeometry.seam(root, points: seal, radius: 0.007, material: trim)
        for z: Float in [-0.79, 0.26, 1.27] {
            let points = (0...24).map { i in skin.point(z: z, contour: 4.2 + Float(i) * 3.65 / 24, side: side, offset: 0.003) }
            VehicleGeometry.seam(root, points: points, radius: 0.0045, material: trim)
        }
        let chargingDoor = [SIMD2<Float>(1.48, 5.7), SIMD2(1.65, 5.7), SIMD2(1.65, 6.4), SIMD2(1.48, 6.4), SIMD2(1.48, 5.7)]
        VehicleGeometry.seam(root, points: chargingDoor.map { skin.point(z: $0.x, contour: $0.y, side: side, offset: 0.003) }, radius: 0.0035, material: trim)
    }

    /// Chauffeur-style details fitted to the taller shell, never a sedan stretched on one axis.
    private static func minivanDetails(_ root: SCNNode, skin: VehicleCoachwork) {
        let front = skin.frontZ, rear = skin.rearZ
        // Recessed grille, thin champagne blades and a discreet central badge.
        VehicleGeometry.box(root, SIMD3(1.16, 0.34, 0.03), at: SIMD3(0, 0.70, front - 0.016), material: glass, radius: 0.035)
        for x: Float in [-0.49, -0.35, -0.21, -0.07, 0.07, 0.21, 0.35, 0.49] {
            VehicleGeometry.box(root, SIMD3(0.018, 0.26, 0.018), at: SIMD3(x, 0.70, front - 0.038), material: champagne, radius: 0.006)
        }
        VehicleGeometry.box(root, SIMD3(0.085, 0.037, 0.016), at: SIMD3(0, 1.015, front - 0.010), material: champagne, radius: 0.010)
        // Upright rear glazing on the tailgate, with a soft curve matching the rear shoulders.
        VehicleGeometry.panel(root, material: glass) { u, v in
            let x = u * 2 - 1
            return SIMD3(x * (0.69 - v * 0.035), 1.115 + v * 0.50, rear + 0.008 - 0.034 * pow(abs(x), 4))
        }
        VehicleGeometry.seam(root, points: [SIMD3(-0.18, 1.14, rear + 0.019), SIMD3(0.27, 1.14, rear + 0.019)], radius: 0.010, material: trim)
        for side in [Float(-1), 1] {
            let rail = (0...48).map { i in
                skin.point(z: -0.95 + Float(i) * 2.98 / 48, contour: 1.94, side: side) + SIMD3(0, 0.009, 0)
            }
            VehicleGeometry.seam(root, points: rail, radius: 0.012, material: champagne)
            // Slim rear pillars tie into the full-width rear light signature.
            let tail = [SIMD3(side * 0.744, 1.62, rear - 0.009), SIMD3(side * 0.756, 1.05, rear - 0.018)]
            VehicleGeometry.seam(root, points: tail, radius: 0.031, material: glass)
            VehicleGeometry.seam(root, points: tail.map { $0 + SIMD3(0, 0, 0.024) }, radius: 0.011, material: tailLamp)
        }
        let spoiler = (0...32).map { i -> SIMD3<Float> in
            let u = Float(i) / 32 * 2 - 1
            return skin.point(z: 2.19, contour: abs(u) * 1.92, side: u < 0 ? -1 : 1) + SIMD3(0, 0.015, 0.012)
        }
        VehicleGeometry.seam(root, points: spoiler, radius: 0.024, material: obsidian)
    }

    private static func bajaji() -> SCNNode {
        let root = SCNNode()
        let paint = champagne
        // Low continuous sill tub leaves real open footwells; the nose and rear quarters grow out of it.
        root.addChildNode(VehicleGeometry.loft([
            SIMD4(-1.23, 0.27, 0.47, 0.06), SIMD4(-0.55, 0.55, 0.49, 0.12),
            SIMD4(0.40, 0.67, 0.50, 0.13), SIMD4(1.13, 0.65, 0.52, 0.14),
            SIMD4(1.30, 0.53, 0.55, 0.13)
        ], material: paint, roundness: 0.48))
        root.addChildNode(VehicleGeometry.loft([
            SIMD4(-1.33, 0.24, 0.83, 0.09), SIMD4(-1.14, 0.40, 0.86, 0.17),
            SIMD4(-0.77, 0.53, 0.86, 0.20), SIMD4(-0.46, 0.54, 0.73, 0.19)
        ], material: paint, roundness: 0.55))
        root.addChildNode(VehicleGeometry.loft([
            SIMD4(0.95, 0.59, 1.12, 0.41), SIMD4(1.13, 0.63, 1.10, 0.44),
            SIMD4(1.27, 0.56, 1.04, 0.38)
        ], material: paint, roundness: 0.4))
        VehicleGeometry.box(root, SIMD3(0.91, 0.26, 0.024), at: SIMD3(0, 1.32, 1.269), material: glass, radius: 0.055)
        VehicleGeometry.box(root, SIMD3(1.14, 0.035, 1.25), at: SIMD3(0, 0.63, 0.25), material: rubber, radius: 0.014)
        seat(root, at: SIMD3(0, 0.82, 0.64), width: 1.03, depth: 0.43, backHeight: 0.34)
        seat(root, at: SIMD3(0, 0.82, -0.18), width: 0.44, depth: 0.38, backHeight: 0.25)
        for x: Float in [-0.28, 0.28] {
            VehicleGeometry.box(root, SIMD3(0.28, 0.16, 0.10), at: SIMD3(x, 1.24, 0.79), material: leather, radius: 0.04)
        }
        // Curved single-pane windscreen and its precisely matching weather seal.
        func windshield(_ u: Float, _ v: Float) -> SIMD3<Float> {
            let x = (u * 2 - 1) * (0.51 - v * 0.045)
            return SIMD3(x, 1.025 + v * 0.565, -0.80 + v * 0.24 - 0.055 * (1 - pow(u * 2 - 1, 2)))
        }
        VehicleGeometry.panel(root, material: glass, surface: windshield)
        let bottom = (0...24).map { windshield(Float($0) / 24, 0) }
        VehicleGeometry.seam(root, points: bottom, radius: 0.025, material: obsidian)
        for side in [Float(-1), 1] {
            let edge = (0...20).map { windshield(side < 0 ? 0 : 1, Float($0) / 20) }
            VehicleGeometry.seam(root, points: edge, radius: 0.032, material: paint)
            wheel(root, at: SIMD3(side * 0.66, 0.30, 0.79), radius: 0.30, width: 0.21, openSpokes: false)
            fender(root, at: SIMD3(side * 0.64, 0.30, 0.79), radius: 0.355, width: 0.28, material: paint)
            VehicleGeometry.rod(root, from: SIMD3(side * 0.57, 0.85, 0.98), to: SIMD3(side * 0.58, 1.63, 0.95), radius: 0.039, material: paint)
            VehicleGeometry.box(root, SIMD3(0.18, 0.048, 0.67), at: SIMD3(side * 0.65, 0.46, -0.08), material: trim, radius: 0.02)
            for z: Float in [-0.29, -0.17, -0.05, 0.07] {
                VehicleGeometry.box(root, SIMD3(0.13, 0.007, 0.018), at: SIMD3(side * 0.65, 0.489, z), material: alloy, radius: 0.003)
            }
            VehicleGeometry.rod(root, from: SIMD3(side * 0.52, 1.19, -0.72), to: SIMD3(side * 0.73, 1.28, -0.71), radius: 0.016, material: trim)
            mirror(root, at: SIMD3(side * 0.74, 1.30, -0.69), size: 0.095)
            VehicleGeometry.seam(root, points: [SIMD3(side * 0.57, 1.48, 0.49), SIMD3(side * 0.57, 1.42, 0.49), SIMD3(side * 0.57, 1.42, 0.79), SIMD3(side * 0.57, 1.48, 0.79)], radius: 0.012, material: trim)
        }
        root.addChildNode(VehicleGeometry.loft([
            SIMD4(-0.72, 0.46, 1.63, 0.032), SIMD4(-0.42, 0.62, 1.68, 0.06),
            SIMD4(0.72, 0.66, 1.69, 0.06), SIMD4(1.22, 0.53, 1.62, 0.035)
        ], material: obsidian, roundness: 0.52))
        for side in [Float(-1), 1] {
            let canopyEdge = [SIMD3(side * 0.47, 1.625, -0.69), SIMD3(side * 0.62, 1.64, -0.39), SIMD3(side * 0.65, 1.65, 0.72), SIMD3(side * 0.53, 1.61, 1.18)]
            VehicleGeometry.seam(root, points: canopyEdge, radius: 0.012, material: trim)
        }
        VehicleGeometry.box(root, SIMD3(0.75, 0.075, 0.20), at: SIMD3(0, 1.035, -0.59), material: trim, radius: 0.03)
        VehicleGeometry.box(root, SIMD3(0.19, 0.06, 0.09), at: SIMD3(0, 1.10, -0.60), material: glass, radius: 0.018)
        VehicleGeometry.seam(root, points: [SIMD3(-0.27, 1.08, -0.34), SIMD3(-0.18, 1.13, -0.46), SIMD3(0.18, 1.13, -0.46), SIMD3(0.27, 1.08, -0.34)], radius: 0.023, material: trim)
        VehicleGeometry.seam(root, points: [windshield(0.51, 0.09) - SIMD3(0, 0, 0.009), windshield(0.75, 0.46) - SIMD3(0, 0, 0.009)], radius: 0.009, material: trim)
        wheel(root, at: SIMD3(0, 0.30, -1.09), radius: 0.30, width: 0.23, openSpokes: true)
        fender(root, at: SIMD3(0, 0.30, -1.09), radius: 0.35, width: 0.30, material: obsidian)
        for side in [Float(-1), 1] {
            VehicleGeometry.rod(root, from: SIMD3(side * 0.13, 0.31, -1.09), to: SIMD3(side * 0.13, 0.88, -0.85), radius: 0.026, material: alloy)
        }
        lightBar(root, width: 0.47, at: SIMD3(0, 0.86, -1.34), front: true, wrap: 0.018)
        lightBar(root, width: 0.95, at: SIMD3(0, 0.85, 1.292), front: false, wrap: 0.045)
        plateRecess(root, at: SIMD3(0, 0.68, 1.319), width: 0.26)
        return root
    }

    private static func motorcycle() -> SCNNode {
        let root = SCNNode()
        let paint = titanium
        for z: Float in [-1.02, 1.02] {
            wheel(root, at: SIMD3(0, 0.36, z), radius: 0.36, width: 0.24, openSpokes: true)
        }
        // Sculpted monocoque tapers from tank shoulders into the saddle's undertray and tail.
        root.addChildNode(VehicleGeometry.loft([
            SIMD4(-0.69, 0.13, 1.00, 0.09), SIMD4(-0.40, 0.31, 1.085, 0.19),
            SIMD4(-0.03, 0.29, 1.055, 0.16), SIMD4(0.28, 0.22, 1.005, 0.08),
            SIMD4(0.75, 0.235, 1.07, 0.065), SIMD4(1.12, 0.14, 1.095, 0.046)
        ], material: paint, roundness: 0.65))
        root.addChildNode(VehicleGeometry.loft([
            SIMD4(-0.47, 0.16, 0.73, 0.16), SIMD4(-0.29, 0.25, 0.73, 0.23),
            SIMD4(0.18, 0.24, 0.70, 0.20), SIMD4(0.34, 0.16, 0.71, 0.13)
        ], material: graphite, roundness: 0.43))
        root.addChildNode(VehicleGeometry.loft([
            SIMD4(0.04, 0.18, 1.09, 0.032), SIMD4(0.32, 0.25, 1.11, 0.044),
            SIMD4(0.66, 0.24, 1.17, 0.048), SIMD4(0.95, 0.18, 1.16, 0.027)
        ], material: leather, roundness: 0.55))
        // Inset knee panels, machined battery fins, swingarms, real fork sliders and rear coilovers.
        for side in [Float(-1), 1] {
            VehicleGeometry.ellipsoid(root, size: SIMD3(0.012, 0.105, 0.20), at: SIMD3(side * 0.291, 1.055, -0.23), material: obsidian)
            VehicleGeometry.rod(root, from: SIMD3(side * 0.18, 0.48, 0.17), to: SIMD3(side * 0.16, 0.36, 1.02), radius: 0.061, material: trim)
            VehicleGeometry.rod(root, from: SIMD3(side * 0.135, 0.36, -1.02), to: SIMD3(side * 0.135, 0.80, -0.84), radius: 0.041, material: trim)
            VehicleGeometry.rod(root, from: SIMD3(side * 0.135, 0.78, -0.85), to: SIMD3(side * 0.135, 1.22, -0.67), radius: 0.026, material: alloy)
            spring(root, from: SIMD3(side * 0.18, 0.46, 0.78), to: SIMD3(side * 0.18, 0.94, 0.44))
            for y: Float in [0.60, 0.67, 0.74, 0.81] {
                VehicleGeometry.box(root, SIMD3(0.022, 0.013, 0.37), at: SIMD3(side * 0.245, y, -0.045), material: trim, radius: 0.005)
            }
            VehicleGeometry.rod(root, from: SIMD3(side * 0.16, 0.57, 0.20), to: SIMD3(side * 0.36, 0.57, 0.20), radius: 0.024, material: trim)
            VehicleGeometry.box(root, SIMD3(0.115, 0.036, 0.075), at: SIMD3(side * 0.34, 0.57, 0.20), material: rubber, radius: 0.012)
            VehicleGeometry.rod(root, from: SIMD3(side * 0.30, 1.30, -0.61), to: SIMD3(side * 0.42, 1.49, -0.59), radius: 0.012, material: trim)
            mirror(root, at: SIMD3(side * 0.43, 1.50, -0.575), size: 0.074)
            VehicleGeometry.rod(root, from: SIMD3(side * 0.28, 1.305, -0.62), to: SIMD3(side * 0.49, 1.29, -0.53), radius: 0.032, material: rubber)
            VehicleGeometry.rod(root, from: SIMD3(side * 0.28, 1.29, -0.67), to: SIMD3(side * 0.46, 1.275, -0.61), radius: 0.010, material: alloy)
            VehicleGeometry.seam(root, points: [SIMD3(side * 0.19, 1.18, 0.63), SIMD3(side * 0.21, 1.21, 0.72), SIMD3(side * 0.16, 1.20, 0.94)], radius: 0.014, material: trim)
        }
        VehicleGeometry.seam(root, points: [SIMD3(-0.30, 1.30, -0.62), SIMD3(-0.15, 1.26, -0.69), SIMD3(0.15, 1.26, -0.69), SIMD3(0.30, 1.30, -0.62)], radius: 0.023, material: alloy)
        let display = VehicleGeometry.box(root, SIMD3(0.17, 0.027, 0.12), at: SIMD3(0, 1.31, -0.71), material: glass, radius: 0.018)
        display.eulerAngles.x = -0.28
        root.addChildNode(VehicleGeometry.loft([
            SIMD4(-0.96, 0.19, 1.17, 0.07), SIMD4(-0.81, 0.24, 1.18, 0.12),
            SIMD4(-0.66, 0.17, 1.18, 0.09)
        ], material: paint, roundness: 0.5))
        lightBar(root, width: 0.36, at: SIMD3(0, 1.185, -0.969), front: true, wrap: 0.015)
        lightBar(root, width: 0.25, at: SIMD3(0, 1.095, 1.137), front: false, wrap: 0.012)
        fender(root, at: SIMD3(0, 0.36, -1.02), radius: 0.411, width: 0.29, material: paint)
        fender(root, at: SIMD3(0, 0.36, 1.02), radius: 0.402, width: 0.26, material: trim)
        // Saddle piping is small and low-contrast; it reads as upholstery rather than extra body pieces.
        for side in [Float(-1), 1] {
            VehicleGeometry.seam(root, points: [SIMD3(side * 0.19, 1.12, 0.11), SIMD3(side * 0.25, 1.145, 0.33), SIMD3(side * 0.23, 1.20, 0.67), SIMD3(side * 0.16, 1.18, 0.93)], radius: 0.004, material: graphite)
        }
        return root
    }

    private static func seat(_ root: SCNNode, at position: SIMD3<Float>, width: Float, depth: Float, backHeight: Float) {
        VehicleGeometry.box(root, SIMD3(width, 0.11, depth), at: position, material: leather, radius: 0.045)
        let back = VehicleGeometry.box(root, SIMD3(width * 0.96, backHeight, 0.115), at: position + SIMD3(0, backHeight / 2 + 0.025, depth * 0.42), material: leather, radius: 0.045)
        back.eulerAngles.x = 0.10
        for x: Float in [-0.27, 0, 0.27] where abs(x) < width / 2 - 0.05 {
            VehicleGeometry.seam(root, points: [position + SIMD3(x, 0.057, -depth * 0.30), position + SIMD3(x, 0.057, depth * 0.29)], radius: 0.003, material: graphite)
        }
    }

    private static func mirror(_ root: SCNNode, at position: SIMD3<Float>, size: Float) {
        VehicleGeometry.ellipsoid(root, size: SIMD3(size, size * 0.65, size * 0.33), at: position, material: trim)
        VehicleGeometry.ellipsoid(root, size: SIMD3(size * 0.86, size * 0.52, 0.009), at: position + SIMD3(0, 0, size * 0.30), material: alloy)
    }

    private static func spring(_ root: SCNNode, from: SIMD3<Float>, to: SIMD3<Float>) {
        VehicleGeometry.rod(root, from: from, to: to, radius: 0.022, material: alloy)
        let tangent = simd_normalize(to - from)
        let u = simd_normalize(simd_cross(tangent, SIMD3<Float>(1, 0, 0)))
        let v = simd_cross(tangent, u)
        let points: [SIMD3<Float>] = (0...64).map { i in
            let t = Float(i) / 64
            let angle = t * 2 * .pi * 5
            return from + (to - from) * (0.12 + t * 0.76) + 0.046 * (u * cos(angle) + v * sin(angle))
        }
        VehicleGeometry.seam(root, points: points, radius: 0.011, material: trim)
    }

    private static func fender(_ root: SCNNode, at centre: SIMD3<Float>, radius: Float, width: Float, material: SCNMaterial) {
        VehicleGeometry.panel(root, columns: 10, rows: 36, material: material) { u, v in
            let a = 0.12 + v * (Float.pi - 0.24)
            let x = (u - 0.5) * width
            let crown = radius + 0.018 * (1 - pow(u * 2 - 1, 2))
            return centre + SIMD3(x, sin(a) * crown, cos(a) * crown)
        }
        for side in [Float(-1), 1] {
            let edge = (0...36).map { i -> SIMD3<Float> in
                let a = 0.12 + Float(i) / 36 * (Float.pi - 0.24)
                return centre + SIMD3(side * width / 2, sin(a) * radius, cos(a) * radius)
            }
            VehicleGeometry.seam(root, points: edge, radius: 0.009, material: material)
        }
    }

    /// Conformal lens and recessed surround, with separate end projectors rather than a thick light box.
    private static func lightBar(_ root: SCNNode, width: Float, at position: SIMD3<Float>, front: Bool, wrap: Float) {
        let direction: Float = front ? -1 : 1
        let bezel = (0...32).map { i -> SIMD3<Float> in
            let u = Float(i) / 32 * 2 - 1
            return position + SIMD3(u * width / 2, -0.009 * u * u, -direction * wrap * pow(abs(u), 4))
        }
        VehicleGeometry.seam(root, points: bezel, radius: 0.041, material: glass)
        VehicleGeometry.seam(root, points: bezel.map { $0 + SIMD3(0, 0.004, direction * 0.030) }, radius: 0.014, material: front ? lamp : tailLamp)
        for side in [Float(-1), 1] {
            let tip = position + SIMD3(side * width * 0.445, -0.005, direction * (0.034 - wrap * 0.63))
            VehicleGeometry.ellipsoid(root, size: SIMD3(0.044, 0.020, 0.016), at: tip, material: front ? lamp : tailLamp)
        }
    }

    private static func plateRecess(_ root: SCNNode, at position: SIMD3<Float>, width: Float) {
        VehicleGeometry.box(root, SIMD3(width + 0.045, 0.11, 0.016), at: position, material: trim, radius: 0.014)
        VehicleGeometry.box(root, SIMD3(width, 0.072, 0.019), at: position + SIMD3(0, 0, 0.009), material: alloy, radius: 0.006)
        for x: Float in [-0.27, 0.27] {
            VehicleGeometry.box(root, SIMD3(width * 0.29, 0.022, 0.006), at: position + SIMD3(x * width, 0, 0.022), material: trim, radius: 0.002)
        }
    }

    /// Lathed tyre/bead, chamfered rim, brake rotor, caliper, turbine spokes and hub hardware.
    private static func wheel(_ root: SCNNode, at position: SIMD3<Float>, radius: Float, width: Float, openSpokes: Bool) {
        let profile: [SIMD2<Float>] = [
            SIMD2(-width * 0.49, radius * 0.66), SIMD2(-width * 0.54, radius * 0.77),
            SIMD2(-width * 0.47, radius * 0.92), SIMD2(-width * 0.30, radius * 0.988),
            SIMD2(0, radius), SIMD2(width * 0.30, radius * 0.988),
            SIMD2(width * 0.47, radius * 0.92), SIMD2(width * 0.54, radius * 0.77),
            SIMD2(width * 0.49, radius * 0.66), SIMD2(-width * 0.49, radius * 0.66)
        ]
        VehicleGeometry.revolve(root, profile: profile, at: position, material: rubber)
        for side in [Float(-1), 1] {
            let x = side * width * 0.51
            let rim: [SIMD2<Float>] = [
                SIMD2(x - 0.012, radius * 0.58), SIMD2(x - 0.015, radius * 0.67),
                SIMD2(x + 0.007, radius * 0.70), SIMD2(x + 0.016, radius * 0.65),
                SIMD2(x + 0.016, radius * 0.59), SIMD2(x - 0.012, radius * 0.58)
            ]
            VehicleGeometry.revolve(root, profile: rim, at: position, material: alloy)
            let discPosition = position + SIMD3(side * width * 0.35, 0, 0)
            let disc = SCNCylinder(radius: CGFloat(radius * 0.53), height: 0.013)
            disc.radialSegmentCount = 32
            disc.materials = [graphite]
            let brake = SCNNode(geometry: disc)
            brake.eulerAngles.z = .pi / 2
            brake.simdPosition = discPosition
            root.addChildNode(brake)
            VehicleGeometry.box(root, SIMD3(0.040, radius * 0.36, radius * 0.18), at: discPosition + SIMD3(side * 0.015, radius * 0.13, radius * 0.39), material: trim, radius: 0.012)
            let face = position + SIMD3(x + side * 0.014, 0, 0)
            let spokeCount = openSpokes ? 6 : 5
            for i in 0..<spokeCount {
                let angle = Float(i) * 2 * .pi / Float(spokeCount)
                let inner = face + SIMD3(0, cos(angle) * radius * 0.17, sin(angle) * radius * 0.17)
                let outerAngle = angle + (openSpokes ? 0.12 : 0.32)
                let outer = face + SIMD3(0, cos(outerAngle) * radius * 0.64, sin(outerAngle) * radius * 0.64)
                let spoke = VehicleGeometry.box(root, SIMD3(0.022, simd_length(outer - inner), radius * (openSpokes ? 0.09 : 0.25)), at: (inner + outer) / 2, material: alloy, radius: 0.006)
                spoke.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(outer - inner))
                let bolt = face + SIMD3(side * 0.015, cos(angle) * radius * 0.18, sin(angle) * radius * 0.18)
                VehicleGeometry.ellipsoid(root, size: SIMD3(0.009, 0.009, 0.009), at: bolt, material: trim)
            }
            VehicleGeometry.ellipsoid(root, size: SIMD3(0.024, radius * 0.135, radius * 0.135), at: face, material: alloy)
            // One recessed sidewall bead, kept below the painted body's detail contrast.
            let bead = (0...40).map { i -> SIMD3<Float> in
                let a = Float(i) * 2 * .pi / 40
                return position + SIMD3(side * width * 0.535, cos(a) * radius * 0.79, sin(a) * radius * 0.79)
            }
            VehicleGeometry.seam(root, points: bead, radius: 0.004, material: trim)
        }
    }
}
