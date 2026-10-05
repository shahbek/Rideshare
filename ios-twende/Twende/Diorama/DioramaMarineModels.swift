import Foundation

/// Hulls are lofted ribs with open interiors, not extruded footprint prisms. +X is the bow.
/// Boats are illustrative anchored craft; positions are not live vessel locations.
nonisolated enum DioramaMarineModels {
    static func dhow() -> DioramaMesh {
        var m = DioramaMesh()
        hull(length: 8.8, beam: 2.55, depth: 1.15, freeboard: 0.72, color: .hullWood, mesh: &m)
        for x in stride(from: -3.5, through: 3.0, by: 0.55) {
            let width = hullWidth(t: (x + 4.4) / 8.8, beam: 2.55) * 0.82
            m.box(centre: DV2(x, 0), z0: 0.36, halfLength: 0.22, halfWidth: max(0.08, width), height: 0.065, .deckWood)
        }
        for x in [-2.4, -0.9, 1.2] {
            m.box(centre: DV2(x, 0), z0: 0.7, halfLength: 0.16, halfWidth: 0.95, height: 0.09, .doorWood)
        }
        m.tube(from: DV3(0.4, 0, 0.35), to: DV3(0.1, 0, 7.2), r0: 0.095, r1: 0.04, sides: 10, .trunk)
        let low = DV3(-3.6, 0, 2.0), peak = DV3(3.25, 0, 8.1), clew = DV3(2.6, 0, 1.2)
        m.tube(from: low, to: peak, r0: 0.06, r1: 0.035, sides: 8, .trunk)
        // Curved lateen sail: triangular barycentric tessellation, with genuine two-sided normals.
        let n = 12
        func point(_ i: Int, _ j: Int) -> DV3 {
            let u = Double(i) / Double(n), v = Double(j) / Double(n), w = 1 - u - v
            return low * w + peak * u + clew * v + DV3(0, 1.8 * u * v * w * 12, 0)
        }
        for i in 0..<n {
            for j in 0..<(n - i) {
                let a = point(i, j), b = point(i + 1, j), c = point(i, j + 1)
                m.triangle(a, b, c, .sailCream)
                m.triangle(c, b, a, .sailCream)
                if i + j < n - 1 {
                    let d = point(i + 1, j + 1)
                    m.triangle(b, d, c, .sailCream); m.triangle(c, d, b, .sailCream)
                }
            }
        }
        for (a, b) in [(DV3(0.1, 0, 7.1), DV3(-3.4, -0.7, 0.9)), (DV3(0.1, 0, 7.1), DV3(3.8, 0, 1.0)), (clew, DV3(-2.8, 0.75, 0.9))] {
            m.tube(from: a, to: b, r0: 0.018, r1: 0.018, sides: 4, .sailCream)
        }
        // Stern rudder, tiller and lashed foredeck cleats.
        m.box(centre: DV2(-4.4, 0), z0: -0.65, halfLength: 0.18, halfWidth: 0.055, height: 1.25, .doorWood)
        m.tube(from: DV3(-4.4, 0, 0.65), to: DV3(-2.8, 0.2, 0.85), r0: 0.045, r1: 0.035, sides: 6, .trunk)
        return m
    }

    static func canoe() -> DioramaMesh {
        var m = DioramaMesh()
        hull(length: 5.8, beam: 0.95, depth: 0.65, freeboard: 0.43, color: .hullWood, mesh: &m)
        for x in [-1.7, -0.4, 1.1] {
            m.box(centre: DV2(x, 0), z0: 0.27, halfLength: 0.14, halfWidth: 0.34, height: 0.07, .deckWood)
        }
        for s in [-1.0, 1.0] {
            var float = DioramaMesh()
            hull(length: 4.3, beam: 0.22, depth: 0.26, freeboard: 0.1, color: .whitewash, mesh: &float)
            m.append(float, DioramaTransform(translation: DV3(-0.2, s * 1.9, 0)))
            for x in [-1.35, 1.1] {
                m.tube(from: DV3(x, 0, 0.5), to: DV3(x - 0.25, s * 1.85, 0.27), r0: 0.055, r1: 0.04, sides: 7, .trunk)
                m.tube(from: DV3(x - 0.25, s * 1.85, 0.27), to: DV3(x - 0.25, s * 1.9, 0.05), r0: 0.035, r1: 0.035, sides: 6, .trunk)
                m.box(centre: DV2(x, s * 0.33), z0: 0.51, halfLength: 0.09, halfWidth: 0.09, height: 0.045, .sailCream)
            }
        }
        // Furled rig and paddle lie inside the open canoe.
        m.tube(from: DV3(0.5, 0, 0.2), to: DV3(0.1, 0, 4.2), r0: 0.05, r1: 0.025, sides: 8, .trunk)
        m.tube(from: DV3(-2.0, 0.1, 0.52), to: DV3(2.3, 0.1, 1.05), r0: 0.09, r1: 0.06, sides: 9, .sailCream)
        m.tube(from: DV3(-2, -0.2, 0.47), to: DV3(0.4, -0.2, 0.52), r0: 0.025, r1: 0.025, sides: 6, .doorWood)
        m.box(centre: DV2(-2.15, -0.2), z0: 0.45, halfLength: 0.3, halfWidth: 0.1, height: 0.035, .doorWood, bevel: 0.01)
        return m
    }

    static func yacht() -> DioramaMesh {
        var m = DioramaMesh()
        hull(length: 11.2, beam: 3.45, depth: 1.5, freeboard: 0.95, color: .carWhite, mesh: &m)
        // The deck leaves a cockpit opening aft; benches surround it rather than covering it.
        for i in 0..<28 {
            let t = (Double(i) + 0.5) / 28, x = -5.6 + t * 11.2
            let w = max(0.05, hullWidth(t: t, beam: 3.45) - 0.08)
            if x < -1.0 && x > -4.7 {
                for s in [-1.0, 1.0] {
                    m.box(centre: DV2(x, s * (w + 0.66) / 2), z0: 0.89, halfLength: 0.2, halfWidth: max(0.03, (w - 0.66) / 2), height: 0.09, .carWhite)
                }
            } else {
                m.box(centre: DV2(x, 0), z0: 0.89, halfLength: 0.2, halfWidth: w, height: 0.09, .carWhite)
            }
        }
        m.box(centre: DV2(-2.8, 0), z0: 0.3, halfLength: 1.75, halfWidth: 0.65, height: 0.08, .deckWood)
        for s in [-1.0, 1.0] {
            m.box(centre: DV2(-2.5, s * 0.7), z0: 0.55, halfLength: 1.35, halfWidth: 0.26, height: 0.18, .cream, bevel: 0.07)
        }
        m.box(centre: DV2(0.55, 0), z0: 0.95, halfLength: 1.9, halfWidth: 1.12, height: 0.52, .carWhite, bevel: 0.2)
        for s in [-1.0, 1.0] {
            for x in [-0.7, 0.2, 1.1, 1.9] {
                m.box(centre: DV2(x, s * 1.09), z0: 1.08, halfLength: 0.32, halfWidth: 0.045, height: 0.21, .glass, bevel: 0.04)
            }
            for x in stride(from: -4.5, through: 4.2, by: 1.1) {
                let y = s * (hullWidth(t: (x + 5.6) / 11.2, beam: 3.45) - 0.06)
                m.tube(from: DV3(x, y, 1), to: DV3(x, y, 1.62), r0: 0.02, r1: 0.02, sides: 5, .carSilver)
                let nextX = min(x + 1.1, 5.2), nextY = s * (hullWidth(t: (nextX + 5.6) / 11.2, beam: 3.45) - 0.06)
                for h in [1.3, 1.6] {
                    m.tube(from: DV3(x, y, h), to: DV3(nextX, nextY, h), r0: 0.012, r1: 0.012, sides: 4, .carSilver)
                }
            }
            for x in [-3.2, -0.8, 1.1] {
                let y = s * hullWidth(t: (x + 5.6) / 11.2, beam: 3.45)
                m.sphere(centre: DV3(x, y + s * 0.14, 0.55), radii: DV3(0.14, 0.14, 0.43), .solarNavy)
                m.tube(from: DV3(x, y, 1.6), to: DV3(x, y + s * 0.14, 0.9), r0: 0.015, r1: 0.015, sides: 4, .sailCream)
            }
        }
        let mast = DV3(0.8, 0, 13.5)
        m.tube(from: DV3(0.8, 0, 1), to: mast, r0: 0.095, r1: 0.045, sides: 10, .carSilver)
        m.tube(from: DV3(0.8, 0, 2.1), to: DV3(-3.4, 0, 2.1), r0: 0.08, r1: 0.06, sides: 8, .carSilver)
        m.tube(from: DV3(0.7, 0, 2.25), to: DV3(-3.4, 0, 2.25), r0: 0.15, r1: 0.11, sides: 10, .solarNavy)
        for foot in [DV3(5.35, 0, 1.1), DV3(-5, 0, 1.1), DV3(0.5, -1.4, 1.1), DV3(0.5, 1.4, 1.1)] {
            m.tube(from: mast, to: foot, r0: 0.012, r1: 0.012, sides: 4, .carSilver)
        }
        m.tube(from: DV3(0.8, -1.1, 7), to: DV3(0.8, 1.1, 7), r0: 0.035, r1: 0.035, sides: 6, .carSilver)
        // Cockpit bimini, tubular uprights, helm wheel and companionway.
        for x in [-4.2, -2.0] { for s in [-1.0, 1.0] {
            m.tube(from: DV3(x, s, 1), to: DV3(x, s, 2.45), r0: 0.025, r1: 0.025, sides: 5, .carSilver)
        } }
        m.box(centre: DV2(-3.1, 0), z0: 2.45, halfLength: 1.2, halfWidth: 1.08, height: 0.07, .solarNavy, bevel: 0.025)
        for i in 0..<24 {
            let a = Double(i) * .pi / 12, b = Double(i + 1) * .pi / 12
            m.tube(from: DV3(-3.9, cos(a) * 0.31, 1.14 + sin(a) * 0.31), to: DV3(-3.9, cos(b) * 0.31, 1.14 + sin(b) * 0.31), r0: 0.018, r1: 0.018, sides: 5, .carSilver)
        }
        m.box(centre: DV2(-1.3, 0), z0: 0.85, halfLength: 0.035, halfWidth: 0.4, height: 0.6, .glass)
        return m
    }

    private static func hullWidth(t: Double, beam: Double) -> Double {
        let u = max(0, min(1, t))
        return beam * 0.5 * max(0.025, pow(sin(.pi * (0.15 + 0.85 * u)), 0.72))
    }

    private static func hull(length: Double, beam: Double, depth: Double, freeboard: Double,
                             color: DioramaSwatch, mesh: inout DioramaMesh) {
        let stations = 32, sides = 12
        func point(_ i: Int, _ j: Int, inner: Bool = false) -> DV3 {
            let t = Double(i) / Double(stations), a = Double(j) * .pi / Double(sides)
            let w = max(0.01, hullWidth(t: t, beam: beam) - (inner ? 0.065 : 0))
            let shear = 0.22 * pow(abs(2 * t - 1), 3)
            return DV3((t - 0.5) * length, cos(a) * w, freeboard + shear - sin(a) * (depth - (inner ? 0.08 : 0)))
        }
        for i in 0..<stations {
            for j in 0..<sides {
                let a = point(i, j), b = point(i + 1, j), c = point(i + 1, j + 1), d = point(i, j + 1)
                mesh.quad(a, b, c, d, color)
                let ia = point(i, j, inner: true), ib = point(i + 1, j, inner: true)
                let ic = point(i + 1, j + 1, inner: true), id = point(i, j + 1, inner: true)
                mesh.quad(id, ic, ib, ia, color == .carWhite ? .carWhite : .deckWood)
            }
            for j in [0, sides] {
                let a = point(i, j), b = point(i + 1, j)
                mesh.tube(from: a, to: b, r0: 0.045, r1: 0.045, sides: 6, color == .carWhite ? .solarNavy : .doorWood)
                mesh.quad(a, b, point(i + 1, j, inner: true), point(i, j, inner: true), color)
            }
        }
        for i in [0, stations] {
            let normal = DV3(i == 0 ? -1 : 1, 0, 0)
            let c = DV3(point(i, 0).x, 0, point(i, 0).z)
            for j in 0..<sides {
                // Solid transom and stem, not just a thin rim around an open half-disc.
                mesh.triangle(c, point(i, j), point(i, j + 1), color, normal: normal)
                let inset = normal * -0.025
                mesh.triangle(c + inset, point(i, j + 1, inner: true) + inset, point(i, j, inner: true) + inset, color == .carWhite ? .carWhite : .deckWood, normal: normal * -1)
            }
        }
    }
}
