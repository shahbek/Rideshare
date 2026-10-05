import Foundation

/// Photo reference: Slipway's red chute, yellow ladder/rails, blue tube frames and white pickets.
nonisolated enum DioramaPlaygroundModel {
    static func make() -> DioramaMesh {
        var m = DioramaMesh()
        func bar(_ a: DV3, _ b: DV3, _ color: DioramaSwatch, radius: Double = 0.04) {
            m.tube(from: a, to: b, r0: radius, r1: radius, sides: 8, color)
        }
        // Open elevated platform, four splayed legs, real climbable ladder with pitched stringers.
        let platform = DV2(0.2, -1.3), h = 1.9
        for x in [-0.45, 0.45] { for y in [-0.43, 0.43] {
            bar(DV3(platform + DV2(x * 1.8, y * 1.5), 0), DV3(platform + DV2(x, y), h), .signBlue, radius: 0.055)
        } }
        m.box(centre: platform, z0: h - 0.08, halfLength: 0.5, halfWidth: 0.48, height: 0.08, .signRed)
        for s in [-1.0, 1.0] {
            let low = DV3(platform + DV2(-2.0, s * 0.43), 0.08), high = DV3(platform + DV2(-0.5, s * 0.43), h)
            bar(low, high, .signYellow, radius: 0.045)
            bar(low + DV3(0, 0, 0.68), high + DV3(0, 0, 0.68), .signYellow, radius: 0.045)
            for t in [0.0, 1.0] { bar(low * (1 - t) + high * t, low * (1 - t) + high * t + DV3(0, 0, 0.68), .signYellow) }
            bar(DV3(platform + DV2(-0.5, s * 0.43), h + 0.68), DV3(platform + DV2(0.5, s * 0.43), h + 0.68), .signYellow)
            bar(DV3(platform + DV2(0.5, s * 0.43), h), DV3(platform + DV2(0.5, s * 0.43), h + 0.68), .signYellow)
        }
        for k in 0..<7 {
            let t = Double(k + 1) / 8
            m.box(centre: platform + DV2(-2 + 1.5 * t, 0), z0: 0.08 + (h - 0.08) * t, halfLength: 0.13, halfWidth: 0.43, height: 0.045, .signRed)
        }
        // Continuous moulded slide with rounded trough, high side cheeks and a horizontal run-out.
        func slide(_ t: Double, _ v: Double) -> DV3 {
            let smooth = t * t * (3 - 2 * t)
            let side = pow(abs(v), 5) * 0.19
            return DV3(platform.x + 0.5 + 3.6 * t, platform.y + v * 0.43, h - 1.74 * smooth + side)
        }
        for i in 0..<32 {
            for j in 0..<10 {
                let t = Double(i) / 32, u = Double(i + 1) / 32
                let v = Double(j) / 5 - 1, w = Double(j + 1) / 5 - 1
                let a = slide(t, v), b = slide(u, v), c = slide(u, w), d = slide(t, w)
                m.quad(a, b, c, d, .signRed)
                m.quad(d - DV3(0, 0, 0.045), c - DV3(0, 0, 0.045), b - DV3(0, 0, 0.045), a - DV3(0, 0, 0.045), .signRed)
            }
            for s in [-1.0, 1.0] { bar(slide(Double(i) / 32, s), slide(Double(i + 1) / 32, s), .signRed, radius: 0.035) }
        }
        for s in [-1.0, 1.0] {
            bar(DV3(2.3, platform.y + s * 0.45, 0), DV3(2.3, platform.y + s * 0.4, 0.94), .signBlue)
        }
        // Two swings: splayed A frames, crossbeam, independent chains and curved sling seats.
        for x in [-3.8, 0.2] {
            for s in [-1.0, 1.0] { bar(DV3(x, 1.9 + s * 0.95, 0), DV3(x, 1.9, 2.65), .signBlue, radius: 0.065) }
            bar(DV3(x, 1.28, 0.9), DV3(x, 2.52, 0.9), .signBlue)
        }
        bar(DV3(-3.8, 1.9, 2.65), DV3(0.2, 1.9, 2.65), .signYellow, radius: 0.075)
        for x in [-2.7, -0.9] {
            for s in [-1.0, 1.0] {
                bar(DV3(x + s * 0.25, 1.9, 2.62), DV3(x + s * 0.25, 2.0, 0.55), .metalCharcoal, radius: 0.018)
                m.cylinder(centre: DV2(x + s * 0.25, 1.9), z0: 2.62, z1: 2.73, r0: 0.085, r1: 0.085, sides: 8, .signRed)
            }
            for i in 0..<10 {
                let a = Double(i) / 10, b = Double(i + 1) / 10
                let za = 0.49 + 0.06 * pow(2 * a - 1, 2), zb = 0.49 + 0.06 * pow(2 * b - 1, 2)
                m.quad(DV3(x - 0.25 + a * 0.5, 1.8, za), DV3(x - 0.25 + b * 0.5, 1.8, zb), DV3(x - 0.25 + b * 0.5, 2.2, zb), DV3(x - 0.25 + a * 0.5, 2.2, za), .tyre, normal: .up)
            }
        }
        // Climbing arch and seesaw, separate from the slide's landing zone.
        for i in 0..<12 {
            let a = Double(i) * .pi / 12, b = Double(i + 1) * .pi / 12
            for s in [-1.0, 1.0] {
                bar(DV3(2.5 + cos(a), 2.4 + s * 0.4, sin(a) * 1.7), DV3(2.5 + cos(b), 2.4 + s * 0.4, sin(b) * 1.7), .signYellow)
            }
            bar(DV3(2.5 + cos(a), 2.0, sin(a) * 1.7), DV3(2.5 + cos(a), 2.8, sin(a) * 1.7), .signBlue, radius: 0.035)
        }
        m.cylinder(centre: DV2(-3, -2.8), z0: 0, z1: 0.55, r0: 0.17, r1: 0.17, sides: 10, .signBlue)
        bar(DV3(-4.2, -2.8, 0.4), DV3(-1.8, -2.8, 0.7), .signYellow, radius: 0.07)
        for s in [-1.0, 1.0] {
            let x = -3 + s * 1.1, z = 0.55 + s * 0.14
            m.box(centre: DV2(x, -2.8), z0: z, halfLength: 0.25, halfWidth: 0.23, height: 0.045, .signRed)
            bar(DV3(x - s * 0.3, -2.8, z), DV3(x - s * 0.3, -2.8, z + 0.35), .signBlue)
            bar(DV3(x - s * 0.3, -3, z + 0.35), DV3(x - s * 0.3, -2.6, z + 0.35), .signBlue)
        }
        // Pickets and two continuous rails. A 1.6 m entrance stays open on the south side.
        let corners = DioramaOrientedRect(centre: .zero, axis: DV2(1, 0), halfLength: 5.2, halfWidth: 4.0).corners
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4], d = (b - a).normalized
            let n = max(1, Int(a.distance(to: b) / 0.28))
            for k in 0..<n {
                let p = a + (b - a) * ((Double(k) + 0.5) / Double(n))
                if i == 0 && abs(p.x) < 0.8 { continue }
                m.box(centre: p, z0: 0, axis: d, halfLength: 0.055, halfWidth: 0.035, height: 0.95, .trimWhite)
                m.triangle(DV3(p - d * 0.055, 0.95), DV3(p + d * 0.055, 0.95), DV3(p, 1.05), .trimWhite, normal: DV3(d.right, 0))
                for z in [0.28, 0.7] {
                    m.box(centre: p, z0: z, axis: d, halfLength: a.distance(to: b) / Double(n) / 2 + 0.005, halfWidth: 0.04, height: 0.06, .trimWhite)
                }
            }
        }
        return m
    }
}
