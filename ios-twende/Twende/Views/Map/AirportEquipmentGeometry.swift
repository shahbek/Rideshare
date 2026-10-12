import SceneKit
import simd

/// Small closed mechanical silhouettes: fork carriage, counterweight, wheels and open operator cage.
enum AirportEquipmentGeometry {
    static func forklift() -> SCNNode {
        var m = DioramaMesh()
        m.box(centre: DV2(-0.25, 0), z0: 0.38, halfLength: 1.35, halfWidth: 0.68, height: 0.65, .signYellow, bevel: 0.12, bottom: true)
        m.box(centre: DV2(-1.1, 0), z0: 1.0, halfLength: 0.5, halfWidth: 0.65, height: 0.6, .signYellow, bevel: 0.1, bottom: true)
        m.box(centre: DV2(-0.4, 0), z0: 1.02, halfLength: 0.32, halfWidth: 0.35, height: 0.18, .tyre)
        m.box(centre: DV2(-0.65, 0), z0: 1.15, halfLength: 0.12, halfWidth: 0.35, height: 0.52, .tyre)
        for x in [-0.9, 0.65] {
            for y in [-0.62, 0.62] {
                m.tube(from: DV3(x, y, 1.0), to: DV3(x, y, 2.6), r0: 0.045, r1: 0.045, sides: 6, .metalCharcoal)
            }
        }
        m.box(centre: DV2(-0.15, 0), z0: 2.58, halfLength: 0.85, halfWidth: 0.7, height: 0.1, .metalCharcoal, bottom: true)
        for y in [-0.47, 0.47] {
            m.box(centre: DV2(1.15, y), z0: 0.4, halfLength: 0.09, halfWidth: 0.075, height: 2.8, .metalCharcoal, bottom: true)
            m.box(centre: DV2(1.8, y), z0: 0.18, halfLength: 0.8, halfWidth: 0.10, height: 0.10, .metalCharcoal, bottom: true)
            m.box(centre: DV2(1.15, y), z0: 0.28, halfLength: 0.09, halfWidth: 0.10, height: 0.65, .metalCharcoal)
        }
        m.box(centre: DV2(1.2, 0), z0: 0.6, halfLength: 0.10, halfWidth: 0.6, height: 0.18, .metalCharcoal)
        wheels(&m, positions: [(0.8, 0.63, 0.43), (-1.15, 0.58, 0.32)])
        return AirportInstanceGeometry.colored(m)
    }

    static func tractor() -> SCNNode {
        var m = DioramaMesh()
        m.box(centre: .zero, z0: 0.35, halfLength: 1.6, halfWidth: 0.78, height: 0.52, .carWhite, bevel: 0.12, bottom: true)
        m.box(centre: DV2(0.72, 0), z0: 0.87, halfLength: 0.65, halfWidth: 0.73, height: 0.5, .carWhite, bevel: 0.1)
        for y in [-0.35, 0.35] {
            m.box(centre: DV2(-0.9, y), z0: 0.85, halfLength: 0.27, halfWidth: 0.24, height: 0.16, .tyre)
            m.box(centre: DV2(-1.1, y), z0: 1.0, halfLength: 0.1, halfWidth: 0.24, height: 0.45, .tyre)
        }
        m.tube(from: DV3(-0.35, 0.35, 0.9), to: DV3(-0.18, 0.35, 1.5), r0: 0.04, r1: 0.04, sides: 6, .metalCharcoal)
        m.box(centre: DV2(-1.85, 0), z0: 0.36, halfLength: 0.3, halfWidth: 0.07, height: 0.12, .metalCharcoal)
        wheels(&m, positions: [(1.0, 0.72, 0.34), (-1.0, 0.72, 0.34)])
        for cart in 0..<2 {
            let x = -3.6 - Double(cart) * 3.2
            m.box(centre: DV2(x, 0), z0: 0.42, halfLength: 1.25, halfWidth: 0.8, height: 0.18, .mastGrey, bottom: true)
            m.box(centre: DV2(x, 0), z0: 0.6, halfLength: 1.13, halfWidth: 0.7, height: 1.0, .carSilver, bevel: 0.1)
            m.tube(from: DV3(x + 1.25, 0, 0.45), to: DV3(x + 1.95, 0, 0.45), r0: 0.045, r1: 0.045, sides: 6, .metalCharcoal)
            wheels(&m, positions: [(x - 0.8, 0.7, 0.25), (x + 0.8, 0.7, 0.25)])
        }
        return AirportInstanceGeometry.colored(m)
    }

    private static func wheels(_ m: inout DioramaMesh, positions: [(Double, Double, Double)]) {
        for (x, y, r) in positions {
            for side in [-1.0, 1.0] {
                m.tube(from: DV3(x, side * y - 0.12, r), to: DV3(x, side * y + 0.12, r), r0: r, r1: r, sides: 10, .tyre)
            }
        }
    }
}
