import CoreText
import SceneKit
import simd

/// Closed individually extruded glyphs, including counters; never lazy SCNText/SCNShape geometry.
enum AirportDimensionalSign {
    static func add(_ title: String, centre: SIMD3<Double>, facing: SIMD2<Double>, height: Double,
                    maximumWidth: Double?, depth: Double, material: SCNMaterial, root: SCNNode) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let text = NSAttributedString(string: title, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(text)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        var glyphPaths: [(CGPath, CGPoint)] = []
        let full = CGMutablePath()
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), points = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &points)
            for i in 0..<count {
                guard let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                glyphPaths.append((path, points[i]))
                full.addPath(path, transform: CGAffineTransform(translationX: points[i].x, y: points[i].y))
            }
        }
        let bounds = full.boundingBoxOfPath
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(height / bounds.height, (maximumWidth ?? .greatestFiniteMagnitude) / bounds.width)
        let outward = simd_normalize(facing), right = SIMD2(-outward.y, outward.x)
        let sign = SCNNode()
        sign.name = "airportDimensionalBlueRoofLetters"
        sign.simdTransform = simd_float4x4(columns: (
            SIMD4(Float(right.x), Float(right.y), 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(Float(outward.x), Float(outward.y), 0, 0), SIMD4(Float(centre.x), Float(centre.y), Float(centre.z), 1)))
        for (path, position) in glyphPaths {
            // Per-glyph scanline levels keep closed A/O/P holes without multiplying all letters' bands.
            let rings = DioramaLettering.flattened(path).map { contour in
                contour.map { SIMD2(($0.x + position.x - bounds.midX) * scale, ($0.y + position.y - bounds.minY) * scale) }
            }
            let glyph = BuildingFootprint(rings: rings).deck(at: -depth, thickness: depth, material: material, name: "airportSolidLetter")
            sign.addChildNode(glyph)
        }
        root.addChildNode(sign)
    }
}
