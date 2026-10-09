import Foundation
import CoreGraphics
import ImageIO

/// Raw Terrain-RGB pixels used only during explicit preparation. No colour-managed decoding.
nonisolated struct DioramaElevationRaster: Sendable {
    let width: Int
    let height: Int
    private let bytes: Data
    private let stride: Int
    private let channels: Int
    private let red: Int
    private let green: Int
    private let blue: Int

    init?(data: Data) {
        if (try? JSONDecoder().decode([String: String].self, from: data)["message"]) == "Tile does not exist" {
            width = 256; height = 256; bytes = Data(); stride = 0; channels = 0
            red = 0; green = 0; blue = 0
            return
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerComponent == 8, [24, 32].contains(image.bitsPerPixel),
              image.width > 0, image.height > 0, image.width <= 1024, image.height <= 1024,
              let raw = image.dataProvider?.data,
              CFDataGetLength(raw) >= image.bytesPerRow * image.height else { return nil }
        width = image.width; height = image.height; stride = image.bytesPerRow
        bytes = raw as Data; channels = image.bitsPerPixel / 8
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let first = image.alphaInfo == .first || image.alphaInfo == .premultipliedFirst || image.alphaInfo == .noneSkipFirst
        red = channels == 3 ? 0 : little ? (first ? 2 : 3) : (first ? 1 : 0)
        green = channels == 3 ? 1 : little ? (first ? 1 : 2) : (first ? 2 : 1)
        blue = channels == 3 ? 2 : little ? (first ? 0 : 1) : (first ? 3 : 2)
    }

    func sample(x: Int, y: Int) -> Double {
        guard !bytes.isEmpty else { return 0 }
        let offset = min(max(y, 0), height - 1) * stride + min(max(x, 0), width - 1) * channels
        return -10_000 + Double(Int(bytes[offset + red]) * 65536 + Int(bytes[offset + green]) * 256 + Int(bytes[offset + blue])) * 0.1
    }
}
