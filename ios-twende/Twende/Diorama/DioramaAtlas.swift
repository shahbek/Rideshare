import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Palette texture: one 8px cell per swatch, plus a darker copy of each used as fake ambient occlusion
/// on the lowest band of walls. Every vertex UV points at the centre of a cell; the sampler uses
/// nearest filtering so neighbouring cells never bleed.
nonisolated enum DioramaAtlas {
    static let columns = 16
    static let cellPixels = 8
    static var rows: Int { (DioramaSwatch.allCases.count * 2 + columns - 1) / columns }

    private static func cell(_ swatch: DioramaSwatch, dark: Bool) -> Int {
        swatch.rawValue * 2 + (dark ? 1 : 0)
    }

    static func uv(_ swatch: DioramaSwatch, dark: Bool) -> SIMD2<Float> {
        let index = cell(swatch, dark: dark)
        let cx = Double(index % columns) + 0.5
        let cy = Double(index / columns) + 0.5
        return SIMD2<Float>(Float(cx / Double(columns)), Float(cy / Double(rows)))
    }

    /// Inverse of `uv`: which swatch (and whether its darker AO copy) a vertex points at.
    static func lookup(_ uv: SIMD2<Float>) -> (swatch: DioramaSwatch, dark: Bool)? {
        let cx = Int((Double(uv.x) * Double(columns)).rounded(.down))
        let cy = Int((Double(uv.y) * Double(rows)).rounded(.down))
        let index = cy * columns + cx
        guard let swatch = DioramaSwatch(rawValue: index / 2) else { return nil }
        return (swatch, index % 2 == 1)
    }

    /// Linear RGB of a swatch cell as the renderer sees it.
    static func color(_ swatch: DioramaSwatch, dark: Bool, config: DioramaConfig) -> SIMD4<Float> {
        let rgb = config.palette[swatch] ?? 0xFF00FF
        let factor = Float(dark ? config.aoDarkening : 1)
        return SIMD4<Float>(
            Float((rgb >> 16) & 0xFF) / 255 * factor,
            Float((rgb >> 8) & 0xFF) / 255 * factor,
            Float(rgb & 0xFF) / 255 * factor,
            1
        )
    }

    /// Encodes the atlas as PNG (debug export).
    static func png(config: DioramaConfig) -> Data? {
        let width = columns * cellPixels
        let height = rows * cellPixels
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for swatch in DioramaSwatch.allCases {
            let rgb = config.palette[swatch] ?? 0xFF00FF
            for dark in [false, true] {
                let index = cell(swatch, dark: dark)
                let factor = dark ? config.aoDarkening : 1
                let r = UInt8(min(Double((rgb >> 16) & 0xFF) * factor, 255))
                let g = UInt8(min(Double((rgb >> 8) & 0xFF) * factor, 255))
                let b = UInt8(min(Double(rgb & 0xFF) * factor, 255))
                let x0 = (index % columns) * cellPixels
                let y0 = (index / columns) * cellPixels
                for y in y0..<(y0 + cellPixels) {
                    for x in x0..<(x0 + cellPixels) {
                        let o = (y * width + x) * 4
                        pixels[o] = r; pixels[o + 1] = g; pixels[o + 2] = b; pixels[o + 3] = 255
                    }
                }
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
