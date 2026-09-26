import SceneKit
import CoreText
import UIKit

/// Actual triangulated raised lettering: avoids SCNText's lazy CPU geometry in the native Metal bake.
enum AirtelSignage {
    static func make(width: Double, material: SCNMaterial) -> SCNNode {
        let root = SCNNode()
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 100, nil)
        let text = Array("airtel".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: text.count)
        guard CTFontGetGlyphsForCharacters(font, text, &glyphs, text.count) else { return root }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let textWidth = advances.reduce(0) { $0 + $1.width }
        let scale = width / (textWidth + 105)
        var cursor: Double = -width / 2 + 100 * scale
        for (index, glyph) in glyphs.enumerated() {
            if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
                let rings = flatten(path).map { ring in ring.map { SIMD2($0.x * scale + cursor, $0.y * scale) } }
                root.addChildNode(BuildingFootprint(rings: rings).deck(at: 0, thickness: 0.13, material: material, name: "airtelLetter.\(index)"))
                if material.name == "airtel.signLight" { addHalo(rings, to: root) }
            }
            cursor += advances[index].width * scale
        }
        // Reference-shaped rising loop/swoosh, rendered as a closed enamel silhouette.
        let mark = UIBezierPath()
        mark.move(to: CGPoint(x: 4, y: 44))
        mark.addCurve(to: CGPoint(x: 72, y: 83), controlPoint1: CGPoint(x: 15, y: 73), controlPoint2: CGPoint(x: 50, y: 101))
        mark.addCurve(to: CGPoint(x: 76, y: 23), controlPoint1: CGPoint(x: 104, y: 58), controlPoint2: CGPoint(x: 97, y: 39))
        mark.addCurve(to: CGPoint(x: 20, y: 0), controlPoint1: CGPoint(x: 61, y: 5), controlPoint2: CGPoint(x: 29, y: -9))
        mark.addCurve(to: CGPoint(x: 42, y: 26), controlPoint1: CGPoint(x: 8, y: 7), controlPoint2: CGPoint(x: 31, y: 23))
        mark.addCurve(to: CGPoint(x: 68, y: 51), controlPoint1: CGPoint(x: 52, y: 27), controlPoint2: CGPoint(x: 70, y: 38))
        mark.addCurve(to: CGPoint(x: 29, y: 46), controlPoint1: CGPoint(x: 63, y: 66), controlPoint2: CGPoint(x: 43, y: 51))
        mark.addCurve(to: CGPoint(x: 4, y: 44), controlPoint1: CGPoint(x: 15, y: 34), controlPoint2: CGPoint(x: -1, y: 32))
        mark.close()
        let logoRings = flatten(mark.cgPath).map { ring in ring.map { SIMD2($0.x * scale - width / 2, $0.y * scale) } }
        root.addChildNode(BuildingFootprint(rings: logoRings).deck(at: 0, thickness: 0.16, material: material, name: "airtelSwoosh"))
        if material.name == "airtel.signLight" { addHalo(logoRings, to: root) }
        return root
    }

    private static func addHalo(_ rings: [[SIMD2<Double>]], to root: SCNNode) {
        let points = rings.flatMap { $0 }
        guard !points.isEmpty else { return }
        let centre = points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
        let material = BuildingSurfaces.make("airtel.signHalo", color: "#E22332", roughness: 1, metalness: 0)
        var halo = BuildingMesh()
        for ring in rings {
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let c = centre + (b - centre) * 1.16, d = centre + (a - centre) * 1.16
                halo.quad(SIMD3(a.x, a.y, 0.17), SIMD3(b.x, b.y, 0.17), SIMD3(c.x, c.y, 0.17), SIMD3(d.x, d.y, 0.17), normal: SIMD3(0, 0, 1))
            }
        }
        root.addChildNode(halo.node(name: "airtelSignHalo", material: material))
    }

    private static func flatten(_ path: CGPath) -> [[SIMD2<Double>]] {
        var rings: [[SIMD2<Double>]] = [], current: [SIMD2<Double>] = []
        func point(_ p: CGPoint) -> SIMD2<Double> { SIMD2(p.x, p.y) }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count >= 3 { rings.append(current) }
                current = [point(e.points[0])]
            case .addLineToPoint: current.append(point(e.points[0]))
            case .addQuadCurveToPoint:
                guard let a = current.last else { return }
                let b = point(e.points[0]), c = point(e.points[1])
                for step in 1...10 {
                    let t = Double(step) / 10, s = 1 - t
                    current.append(a * (s * s) + b * (2 * s * t) + c * (t * t))
                }
            case .addCurveToPoint:
                guard let a = current.last else { return }
                let b = point(e.points[0]), c = point(e.points[1]), d = point(e.points[2])
                for step in 1...12 {
                    let t = Double(step) / 12, s = 1 - t
                    current.append(a * (s * s * s) + b * (3 * s * s * t) + c * (3 * s * t * t) + d * (t * t * t))
                }
            case .closeSubpath:
                if current.count > 1, let first = current.first, let last = current.last, simd_distance(first, last) < 0.001 { current.removeLast() }
                if current.count >= 3 { rings.append(current) }
                current = []
            @unknown default: break
            }
        }
        if current.count >= 3 { rings.append(current) }
        return rings
    }
}
