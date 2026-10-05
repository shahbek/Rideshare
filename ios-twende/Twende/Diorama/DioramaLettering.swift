import Foundation
import CoreGraphics
import CoreText

/// Architectural lettering in a right/up/outward frame, baked into the static Metal mesh.
nonisolated enum DioramaLettering {
    static func line(_ text: String, centre: DV3, up: DV3, facing: DV3, height: Double,
                     swatch: DioramaSwatch, mesh: inout DioramaMesh) {
        let normal = facing.normalized
        let r = up.cross(normal).normalized
        let u = normal.cross(r).normalized
        guard r.length > 0.5, height > 0 else { return }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let path = CGMutablePath()
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for i in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                path.addPath(glyph, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
        let bounds = path.boundingBoxOfPath
        guard !bounds.isNull, bounds.height > 0 else { return }
        let contours = flattened(path)
        let scale = height / bounds.height
        // Glyph paths are explicitly y-up. No bitmap row order or image flip can mirror the letters.
        // Even/odd spans preserve the counters in A, D, O and P rather than filling their holes.
        let step = bounds.height / 64
        for y in stride(from: bounds.minY, to: bounds.maxY, by: step) {
            let sample = y + step / 2
            var crossings: [Double] = []
            for contour in contours {
                for i in contour.indices {
                    let a = contour[i], b = contour[(i + 1) % contour.count]
                    if (a.y > sample) != (b.y > sample) {
                        crossings.append(a.x + (sample - a.y) * (b.x - a.x) / (b.y - a.y))
                    }
                }
            }
            crossings.sort()
            for i in stride(from: 0, to: crossings.count - 1, by: 2) {
                let a = centre + r * ((crossings[i] - bounds.midX) * scale) + u * ((y - bounds.minY) * scale)
                let b = a + r * ((crossings[i + 1] - crossings[i]) * scale)
                mesh.quad(a, b, b + u * (step * scale), a + u * (step * scale), swatch, normal: normal)
            }
        }
    }

    private static func flattened(_ path: CGPath) -> [[DV2]] {
        var contours: [[DV2]] = []
        var current: [DV2] = []
        func point(_ p: CGPoint) -> DV2 { DV2(p.x, p.y) }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count >= 3 { contours.append(current) }
                current = [point(e.points[0])]
            case .addLineToPoint:
                current.append(point(e.points[0]))
            case .addQuadCurveToPoint:
                guard let start = current.last else { return }
                let control = point(e.points[0]), end = point(e.points[1])
                for i in 1...12 {
                    let t = Double(i) / 12, s = 1 - t
                    current.append(start * (s * s) + control * (2 * s * t) + end * (t * t))
                }
            case .addCurveToPoint:
                guard let start = current.last else { return }
                let c1 = point(e.points[0]), c2 = point(e.points[1]), end = point(e.points[2])
                for i in 1...16 {
                    let t = Double(i) / 16, s = 1 - t
                    current.append(start * (s * s * s) + c1 * (3 * s * s * t) + c2 * (3 * s * t * t) + end * (t * t * t))
                }
            case .closeSubpath:
                if current.count >= 3 { contours.append(current) }
                current = []
            @unknown default: break
            }
        }
        if current.count >= 3 { contours.append(current) }
        return contours
    }
}
