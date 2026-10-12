import SceneKit
import UIKit
import simd

/// Bounded authoring-time UV pigment sampling; existing procedural materials are untouched.
enum GeneratedLandmarkPigment {
    struct Sampler {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let coordinates: [SIMD2<Float>]

        func color(at index: Int) -> SIMD4<Float>? {
            guard coordinates.indices.contains(index), width > 0, height > 0 else { return nil }
            let uv = coordinates[index]
            guard uv.x.isFinite, uv.y.isFinite else { return nil }
            let x = min(Float(width - 1), max(0, uv.x * Float(width - 1)))
            let y = min(Float(height - 1), max(0, (1 - uv.y) * Float(height - 1)))
            let x0 = Int(x), y0 = Int(y), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
            func pixel(_ px: Int, _ py: Int) -> SIMD4<Float> {
                let offset = (py * width + px) * 4
                let alpha = Float(pixels[offset + 3]) / 255
                let divisor = max(alpha, 1 / 255)
                return SIMD4(Float(pixels[offset]) / 255 / divisor,
                             Float(pixels[offset + 1]) / 255 / divisor,
                             Float(pixels[offset + 2]) / 255 / divisor, alpha)
            }
            let tx = x - Float(x0), ty = y - Float(y0)
            return (pixel(x0, y0) * (1 - tx) + pixel(x1, y0) * tx) * (1 - ty)
                + (pixel(x0, y1) * (1 - tx) + pixel(x1, y1) * tx) * ty
        }
    }

    static func make(material: SCNMaterial?, geometry: SCNGeometry) -> Sampler? {
        guard material?.name?.hasPrefix("generated.landmark") == true,
              let source = geometry.sources(for: .texcoord).first,
              source.usesFloatComponents, source.componentsPerVector >= 2,
              [4, 8].contains(source.bytesPerComponent), source.vectorCount > 0,
              source.vectorCount <= 300_000 else { return nil }
        let contents = material?.diffuse.contents
        let image: CGImage?
        if let value = contents as? UIImage { image = value.cgImage }
        else if let url = contents as? URL, url.isFileURL { image = UIImage(contentsOfFile: url.path)?.cgImage }
        else { image = nil }
        guard let image else { return nil }
        let width = min(512, image.width), height = min(512, image.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let coordinates: [SIMD2<Float>]? = source.data.withUnsafeBytes { bytes in
            var result: [SIMD2<Float>] = []
            result.reserveCapacity(source.vectorCount)
            for index in 0..<source.vectorCount {
                let offset = source.dataOffset + index * source.dataStride
                guard offset >= 0, offset + 2 * source.bytesPerComponent <= bytes.count else { return nil }
                func value(_ component: Int) -> Float {
                    let start = offset + component * source.bytesPerComponent
                    return source.bytesPerComponent == 4
                        ? bytes.loadUnaligned(fromByteOffset: start, as: Float.self)
                        : Float(bytes.loadUnaligned(fromByteOffset: start, as: Double.self))
                }
                result.append(SIMD2(value(0), value(1)))
            }
            return result
        }
        guard let coordinates else { return nil }
        return Sampler(pixels: pixels, width: width, height: height, coordinates: coordinates)
    }
}
