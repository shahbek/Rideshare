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
        self.labels = labels.filter { !$0.title.isEmpty }.sorted { $0.isNamed != $1.isNamed ? $0.isNamed : $0.id < $1.id }
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
            for label in self.labels {
                let key = (label.roadDirection == nil ? "place:" : "road:") + label.title
                if images[key] == nil { images[key] = Self.raster(label.title, stem: label.roadDirection == nil, device: device, scale: self.scale) }
            }
        } catch {
            print("[Diorama] custom label pipeline unavailable")
            return nil
        }
    }

    private static func raster(_ title: String, stem: Bool, device: MTLDevice, scale: Float) -> Image? {
        let font = CTFontCreateWithName("Figtree-SemiBold" as CFString, 12 * CGFloat(scale), nil)
        let ink = CGColor(gray: 0.133, alpha: 1)
        let text = NSAttributedString(string: String(title.prefix(64)), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
        ])
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let width = max(32, Int(ceil(textWidth + Double(scale) * 16)))
        let height = Int((stem ? 46 : 24) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { return nil }
        let s = CGFloat(scale), mid = CGFloat(width) / 2
        if stem {
            context.setStrokeColor(ink)
            context.setLineWidth(s)
            context.move(to: CGPoint(x: mid, y: 4 * s)); context.addLine(to: CGPoint(x: mid, y: 23 * s)); context.strokePath()
            context.setFillColor(ink)
            context.fillEllipse(in: CGRect(x: mid - 2 * s, y: 2 * s, width: 4 * s, height: 4 * s))
        }
        context.setLineJoin(.round)
        context.setTextDrawingMode(.stroke)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.98))
        context.setLineWidth(3.5 * s)
        context.textPosition = CGPoint(x: 8 * s, y: (stem ? 27 : 6) * s)
        CTLineDraw(line, context)
        context.setTextDrawingMode(.fill)
        context.textPosition = CGPoint(x: 8 * s, y: (stem ? 27 : 6) * s)
        CTLineDraw(line, context)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return Image(texture: texture, width: Float(width), height: Float(height))
    }

    func draw(encoder: MTLRenderCommandEncoder, matrix: simd_float4x4, width: Int, height: Int, zoom: Double, reveal: SIMD4<Float>) {
        guard zoom >= 15.5 else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setTriangleFillMode(.fill)
        var occupied: [CGRect] = []
        let w = Float(width), h = Float(height)
        for label in labels {
            let key = (label.roadDirection == nil ? "place:" : "road:") + label.title
            guard occupied.count < 32, let image = images[key] else { continue }
            if reveal.w > 0.5, max(abs(label.anchor.x - reveal.x), abs(label.anchor.y - reveal.y)) + 3 > reveal.z { continue }
            let p = matrix * SIMD4(label.anchor, 1)
            guard p.w > 0.001, p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            let x = (p.x / p.w + 1) * w * 0.5, y = (1 - p.y / p.w) * h * 0.5
            var angle: Float = 0
            let isRoad = label.roadDirection != nil
            if let direction = label.roadDirection {
                let q = matrix * SIMD4(label.anchor + SIMD3(direction.x * 8, direction.y * 8, 0), 1)
                guard q.w > 0.001 else { continue }
                angle = atan2((q.y / q.w - p.y / p.w) * h, (q.x / q.w - p.x / p.w) * w)
                if angle > .pi / 2 { angle -= .pi }
                if angle < -.pi / 2 { angle += .pi }
            }
            let cw = abs(cos(angle)) * image.width + abs(sin(angle)) * image.height
            let ch = abs(sin(angle)) * image.width + abs(cos(angle)) * image.height
            let rect = CGRect(x: CGFloat(x - cw / 2), y: CGFloat(y - (isRoad ? ch / 2 : ch)), width: CGFloat(cw), height: CGFloat(ch))
            guard rect.minX >= 8 * CGFloat(scale), rect.maxX < CGFloat(width) - 8 * CGFloat(scale),
                  rect.minY > 8 * CGFloat(scale), rect.maxY < CGFloat(height),
                  !occupied.contains(where: { $0.intersects(rect.insetBy(dx: -6 * CGFloat(scale), dy: -4 * CGFloat(scale))) }) else { continue }
            occupied.append(rect)
            func v(_ dx: Float, _ dy: Float, _ u: Float, _ t: Float) -> Vertex {
                let yy = dy - (isRoad ? image.height / 2 : 0)
                let rx = dx * cos(angle) - yy * sin(angle), ry = dx * sin(angle) + yy * cos(angle)
                return Vertex(position: SIMD4(p.x + rx * 2 / w * p.w, p.y + ry * 2 / h * p.w, p.z, p.w), uv: SIMD2(u, t))
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
