import Foundation
import CoreGraphics
import CoreText

/// Small static architectural signs baked into the same Metal mesh, not floating map labels.
nonisolated enum DioramaLettering {
    static func line(_ text: String, centre: DV3, right: DV2, up: DV3, height: Double,
                     swatch: DioramaSwatch, mesh: inout DioramaMesh) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = max(1, Int(ceil(bounds.width)) + 4), rows = max(1, Int(ceil(bounds.height)) + 4)
        var pixels = [UInt8](repeating: 0, count: width * rows)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: rows,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.textPosition = CGPoint(x: 2 - bounds.minX, y: 2 - bounds.minY)
            CTLineDraw(line, context)
        }
        let scale = height / Double(rows), r = DV3(right, 0), normal = r.cross(up).normalized
        for y in 0..<rows {
            var x = 0
            while x < width {
                if pixels[y * width + x] < 100 { x += 1; continue }
                let start = x
                while x < width && pixels[y * width + x] >= 100 { x += 1 }
                let a = centre + r * ((Double(start) - Double(width) / 2) * scale) + up * (Double(y) * scale)
                let b = a + r * (Double(x - start) * scale)
                mesh.quad(a, b, b + up * scale, a + up * scale, swatch, normal: normal)
            }
        }
    }
}
