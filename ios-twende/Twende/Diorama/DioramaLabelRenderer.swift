import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// Owns typography, projection and label collisions; no Mapbox symbol layer or glyph service.
nonisolated final class DioramaLabelRenderer {
    private struct Vertex {
        var position: SIMD4<Float>
        var uv: SIMD2<Float>
    }
    private struct Image {
        let texture: MTLTexture
        let width: Float
        let height: Float
    }
    private let labels: [DioramaBuildingLabel]
    private let scale: Float
    private var images: [String: Image] = [:]
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState

    init?(device: MTLDevice, labels: [DioramaBuildingLabel], scale: Float, color: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.labels = labels.sorted { $0.isNamed != $1.isNamed ? $0.isNamed : $0.id < $1.id }
        self.scale = max(1, scale)
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct LabelVertex { float4 position; float2 uv; };
        struct LabelOut { float4 position [[position]]; float2 uv; };
        vertex LabelOut labelVertex(uint id [[vertex_id]], const device LabelVertex *vertices [[buffer(0)]]) {
            LabelOut o; o.position = vertices[id].position; o.uv = vertices[id].uv; return o;
        }
        fragment float4 labelFragment(LabelOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 c = image.sample(s, in.uv);
            if (c.a < 0.01) discard_fragment();
            return c;
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "labelVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "labelFragment")
            descriptor.colorAttachments[0].pixelFormat = color
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            descriptor.depthAttachmentPixelFormat = depthFormat
            descriptor.stencilAttachmentPixelFormat = depthFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .lessEqual
            d.isDepthWriteEnabled = false
            guard let state = device.makeDepthStencilState(descriptor: d) else { return nil }
            depth = state
            for title in Set(labels.map(\.title)) {
                images[title] = Self.raster(title, device: device, scale: self.scale)
            }
        } catch {
            print("[Diorama] custom label pipeline unavailable")
            return nil
        }
    }

    private static func raster(_ title: String, device: MTLDevice, scale: Float) -> Image? {
        let font = CTFontCreateWithName("Figtree-SemiBold" as CFString, 12 * CGFloat(scale), nil)
        let ink = CGColor(gray: 0.133, alpha: 1)
        let text = NSAttributedString(string: String(title.prefix(64)), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
        ])
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let width = max(32, Int(ceil(textWidth + Double(scale) * 16)))
        let height = Int(46 * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { return nil }
        let s = CGFloat(scale), mid = CGFloat(width) / 2
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(3 * s)
        context.move(to: CGPoint(x: mid, y: 4 * s)); context.addLine(to: CGPoint(x: mid, y: 23 * s)); context.strokePath()
        context.setStrokeColor(CGColor(gray: 0.42, alpha: 0.8))
        context.setLineWidth(s)
        context.move(to: CGPoint(x: mid, y: 4 * s)); context.addLine(to: CGPoint(x: mid, y: 23 * s)); context.strokePath()
        context.setFillColor(ink)
        context.fillEllipse(in: CGRect(x: mid - 2 * s, y: 2 * s, width: 4 * s, height: 4 * s))
        context.setLineJoin(.round)
        context.setTextDrawingMode(.stroke)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.98))
        context.setLineWidth(3.5 * s)
        context.textPosition = CGPoint(x: 8 * s, y: 27 * s)
        CTLineDraw(line, context)
        context.setTextDrawingMode(.fill)
        context.textPosition = CGPoint(x: 8 * s, y: 27 * s)
        CTLineDraw(line, context)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return Image(texture: texture, width: Float(width), height: Float(height))
    }

    func draw(encoder: MTLRenderCommandEncoder, matrix: simd_float4x4, width: Int, height: Int, zoom: Double, reveal: SIMD4<Float>) {
        guard zoom >= 15.8 else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setTriangleFillMode(.fill)
        var occupied: [CGRect] = []
        let w = Float(width), h = Float(height)
        for label in labels {
            guard label.isNamed || zoom >= 17.8, occupied.count < 18, let image = images[label.title] else { continue }
            if reveal.w > 0.5, max(abs(label.anchor.x - reveal.x), abs(label.anchor.y - reveal.y)) + 3 > reveal.z { continue }
            let p = matrix * SIMD4(label.anchor, 1)
            guard p.w > 0.001, p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            let x = (p.x / p.w + 1) * w * 0.5, y = (1 - p.y / p.w) * h * 0.5
            let rect = CGRect(x: CGFloat(x - image.width / 2), y: CGFloat(y - image.height), width: CGFloat(image.width), height: CGFloat(image.height))
            guard rect.minX >= 8 * CGFloat(scale), rect.maxX < CGFloat(width) - 8 * CGFloat(scale),
                  rect.minY > 8 * CGFloat(scale), rect.maxY < CGFloat(height),
                  !occupied.contains(where: { $0.intersects(rect.insetBy(dx: -6 * CGFloat(scale), dy: -4 * CGFloat(scale))) }) else { continue }
            occupied.append(rect)
            func v(_ dx: Float, _ dy: Float, _ u: Float, _ t: Float) -> Vertex {
                Vertex(position: SIMD4(p.x + dx * 2 / w * p.w, p.y + dy * 2 / h * p.w, p.z, p.w), uv: SIMD2(u, t))
            }
            let a = v(-image.width / 2, 0, 0, 1), b = v(image.width / 2, 0, 1, 1)
            let c = v(image.width / 2, image.height, 1, 0), d = v(-image.width / 2, image.height, 0, 0)
            var vertices = [a, b, c, a, c, d]
            vertices.withUnsafeMutableBytes { bytes in
                if let base = bytes.baseAddress { encoder.setVertexBytes(base, length: bytes.count, index: 0) }
            }
            encoder.setFragmentTexture(image.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }
}
