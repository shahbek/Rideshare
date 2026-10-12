import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// Owns typography, projection and label collisions; no Mapbox symbol layer or glyph service.
///
/// Cost model: the Metal pipeline is compiled once per device and formats, and a title's plate is
/// rasterised once per process (shared by every tile and reload that shows it), on its first
/// visible frame rather than when the tile installs. Installing a tile with 400 labels therefore
/// costs nothing until the camera is close enough to read them.
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
    private struct PipelineKey: Hashable {
        let device: ObjectIdentifier
        let color: MTLPixelFormat
        let depth: MTLPixelFormat
    }
    private struct ImageKey: Hashable {
        let device: ObjectIdentifier
        let title: String
        let scale: Float
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pipelines: [PipelineKey: (MTLRenderPipelineState, MTLDepthStencilState)] = [:]
    nonisolated(unsafe) private static var sharedImages: [ImageKey: Image] = [:]
    nonisolated(unsafe) private static var sharedOrder: [ImageKey] = []
    /// Plates are about 100 KB each at 3×; 512 of them stay under 64 MB, well beyond one view's need.
    private static let sharedLimit = 512

    private let device: MTLDevice
    private let labels: [DioramaBuildingLabel]
    private let scale: Float
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState

    init?(device: MTLDevice, labels: [DioramaBuildingLabel], scale: Float, color: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device
        self.labels = labels.sorted { $0.isNamed != $1.isNamed ? $0.isNamed : $0.id < $1.id }
        self.scale = max(1, scale)
        guard let (pipeline, depth) = Self.pipeline(device: device, color: color, depthFormat: depthFormat) else {
            print("[Diorama] custom label pipeline unavailable")
            return nil
        }
        self.pipeline = pipeline
        self.depth = depth
    }

    private static func pipeline(device: MTLDevice, color: MTLPixelFormat, depthFormat: MTLPixelFormat) -> (MTLRenderPipelineState, MTLDepthStencilState)? {
        let key = PipelineKey(device: ObjectIdentifier(device), color: color, depth: depthFormat)
        lock.lock()
        defer { lock.unlock() }
        if let cached = pipelines[key] { return cached }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct LabelVertex { float4 position; float2 uv; };
        struct LabelOut { float4 position [[position]]; float2 uv; };
        vertex LabelOut labelVertex(uint id [[vertex_id]], const device LabelVertex *vertices [[buffer(0)]]) {
            LabelOut o; o.position = vertices[id].position; o.uv = vertices[id].uv; return o;
        }
        fragment float4 labelFragment(LabelOut in [[stage_in]], texture2d<float> image [[texture(0)]], constant float &coverage [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            if (in.uv.x < -1.5) return float4(coverage);
            if (in.uv.x < -0.5) return float4(0.20, 0.22, 0.24, 1.0) * coverage;
            float4 c = image.sample(s, in.uv);
            if (c.a < 0.01) discard_fragment();
            return c * coverage;
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
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .lessEqual
            d.isDepthWriteEnabled = false
            guard let state = device.makeDepthStencilState(descriptor: d) else { return nil }
            pipelines[key] = (pipeline, state)
            return (pipeline, state)
        } catch {
            return nil
        }
    }

    /// A title's plate, rasterised on first use and shared process-wide (bounded, oldest evicted).
    /// `allowRaster` false only returns an existing plate (frames spread new rasterisation).
    private func image(for title: String, allowRaster: Bool = true) -> Image? {
        let key = ImageKey(device: ObjectIdentifier(device), title: title, scale: scale)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let cached = Self.sharedImages[key] { return cached }
        guard allowRaster, let image = Self.raster(title, device: device, scale: scale) else { return nil }
        Self.sharedImages[key] = image
        Self.sharedOrder.append(key)
        if Self.sharedOrder.count > Self.sharedLimit {
            let evicted = Self.sharedOrder.removeFirst()
            Self.sharedImages[evicted] = nil
        }
        return image
    }

    /// Uses the same unique-title raster dimensions as allocation, without creating any textures.
    static func estimatedTextureBytes(titles: [String], scale: Float) -> Int {
        Set(titles).reduce(0) { total, title in
            let layout = textLayout(title, scale: max(1, scale))
            return total + layout.width * layout.height * 4
        }
    }

    private static func textLayout(_ title: String, scale: Float) -> (line: CTLine, width: Int, height: Int) {
        let font = CTFontCreateWithName("Figtree-SemiBold" as CFString, 13 * CGFloat(scale), nil)
        let ink = CGColor(gray: 0.133, alpha: 1)
        let text = NSAttributedString(string: String(title.prefix(64)), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
        ])
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let width = max(32, Int(ceil(textWidth + Double(scale) * 16)))
        let height = Int(32 * scale)
        return (line, width, height)
    }

    private static func raster(_ title: String, device: MTLDevice, scale: Float) -> Image? {
        let (line, width, height) = textLayout(title, scale: scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { return nil }
        let s = CGFloat(scale)
        let plate = CGRect(x: s, y: 4 * s, width: CGFloat(width) - 2 * s, height: 26 * s)
        context.setFillColor(CGColor(gray: 0.64, alpha: 1))
        context.addPath(CGPath(roundedRect: plate.offsetBy(dx: 0, dy: -2 * s), cornerWidth: 6 * s, cornerHeight: 6 * s, transform: nil)); context.fillPath()
        context.setFillColor(CGColor(gray: 0.99, alpha: 1))
        context.addPath(CGPath(roundedRect: plate, cornerWidth: 6 * s, cornerHeight: 6 * s, transform: nil)); context.fillPath()
        context.setLineJoin(.round)
        context.setTextDrawingMode(.stroke)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.98))
        context.setLineWidth(3.5 * s)
        context.textPosition = CGPoint(x: 8 * s, y: 12 * s)
        CTLineDraw(line, context)
        context.setTextDrawingMode(.fill)
        context.textPosition = CGPoint(x: 8 * s, y: 12 * s)
        CTLineDraw(line, context)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return Image(texture: texture, width: Float(width), height: Float(height))
    }

    func draw(encoder: MTLRenderCommandEncoder, matrix: simd_float4x4, width: Int, height: Int, zoom: Double, uniforms: DioramaShaderUniforms) -> Set<UInt64> {
        guard zoom >= 15.8 else { return [] }
        var accepted: Set<UInt64> = []
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setTriangleFillMode(.fill)
        var occupied: [CGRect] = []
        let w = Float(width), h = Float(height)
        // New plates are rasterised at most three per frame, so a camera move that reveals many
        // names never stalls one frame; the rest appear over the next few frames.
        var rastersLeft = 3
        for label in labels {
            // Labels are sorted named-first: once 18 are placed (or unnamed ones are not shown) stop.
            guard occupied.count < 18, label.isNamed || zoom >= 17.8 else { break }
            // Cheap projection and on-screen test first; reveal coverage and plates only for candidates.
            let roof = matrix * SIMD4(label.anchor, 1)
            let lift: Float = label.isNamed ? 5.5 : 3.5
            let p = matrix * SIMD4(label.anchor + SIMD3(0, 0, lift), 1)
            guard roof.w > 0.001, p.w > 0.001, p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  abs(p.x / p.w) < 1.1, abs(p.y / p.w) < 1.1 else { continue }
            let revealed = DioramaRevealStyle.sceneCoverage(label.anchor, reveal: uniforms.reveal,
                bounds: uniforms.tileBounds, edges: uniforms.focusEdges, state: uniforms.tileState, frame: uniforms.materialFrame)
                * DioramaRevealStyle.coverage(label.anchor, reveal: uniforms.lifecycleReveal, bounds: uniforms.tileBounds)
                * DioramaUnionShape.coverage(label.anchor, uniforms: uniforms)
            var coverage: Float = min(1, max(0, (revealed - 0.55) / 0.45))
            coverage = coverage * coverage * (3 - 2 * coverage)
            guard coverage > 0.001 else { continue }
            let cached = image(for: label.title, allowRaster: false)
            let made = cached ?? (rastersLeft > 0 ? image(for: label.title) : nil)
            if cached == nil, made != nil { rastersLeft -= 1 }
            guard let image = made else { continue }
            let x = (p.x / p.w + 1) * w * 0.5, y = (1 - p.y / p.w) * h * 0.5
            let rect = CGRect(x: CGFloat(x - image.width / 2), y: CGFloat(y - image.height), width: CGFloat(image.width), height: CGFloat(image.height))
            guard rect.minX >= 8 * CGFloat(scale), rect.maxX < CGFloat(width) - 8 * CGFloat(scale),
                  rect.minY > 8 * CGFloat(scale), rect.maxY < CGFloat(height),
                  !occupied.contains(where: { $0.intersects(rect.insetBy(dx: -6 * CGFloat(scale), dy: -4 * CGFloat(scale))) }) else { continue }
            occupied.append(rect)
            accepted.insert(label.id)
            encoder.setFragmentBytes(&coverage, length: MemoryLayout<Float>.stride, index: 0)
            encoder.setFragmentTexture(image.texture, index: 0)
            // Perspective-correct leader stem plus a solid 12-sided endpoint dot, in one draw.
            let delta = SIMD2((p.x / p.w - roof.x / roof.w) * w, (p.y / p.w - roof.y / roof.w) * h)
            let length = simd_length(delta)
            let normal = length > 0.01 ? SIMD2(-delta.y, delta.x) / length : SIMD2<Float>(1, 0)
            let thickness = 1.25 * scale
            func end(_ point: SIMD4<Float>, _ side: Float) -> Vertex {
                Vertex(position: SIMD4(point.x + normal.x * thickness * side / w * point.w, point.y + normal.y * thickness * side / h * point.w, point.z, point.w), uv: SIMD2(-1, 0))
            }
            func dotVertex(_ angle: Float, radius: Float) -> Vertex {
                Vertex(position: SIMD4(roof.x + cos(angle) * radius * 2 / w * roof.w,
                                       roof.y + sin(angle) * radius * 2 / h * roof.w, roof.z, roof.w), uv: SIMD2(-1, 0))
            }
            var marker = [end(roof, -1), end(roof, 1), end(p, 1), end(roof, -1), end(p, 1), end(p, -1)]
            for i in 0..<12 {
                marker += [dotVertex(0, radius: 0), dotVertex(Float(i) * .pi / 6, radius: 3 * scale),
                           dotVertex(Float(i + 1) * .pi / 6, radius: 3 * scale)]
            }
            marker.withUnsafeMutableBytes { bytes in
                if let base = bytes.baseAddress { encoder.setVertexBytes(base, length: bytes.count, index: 0) }
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: marker.count)
            func v(_ dx: Float, _ dy: Float, _ u: Float, _ t: Float) -> Vertex {
                Vertex(position: SIMD4(p.x + dx * 2 / w * p.w, p.y + dy * 2 / h * p.w, p.z, p.w), uv: SIMD2(u, t))
            }
            let a = v(-image.width / 2, 0, 0, 1), b = v(image.width / 2, 0, 1, 1)
            let c = v(image.width / 2, image.height, 1, 0), d = v(-image.width / 2, image.height, 0, 0)
            var vertices = [a, b, c, a, c, d]
            vertices.withUnsafeMutableBytes { bytes in
                if let base = bytes.baseAddress { encoder.setVertexBytes(base, length: bytes.count, index: 0) }
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        return accepted
    }
}
