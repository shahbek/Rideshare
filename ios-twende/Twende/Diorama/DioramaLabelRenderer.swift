import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// Owns typography, projection and label collisions; no Mapbox symbol layer or glyph service.
///
/// Cost model (2026-10-12 label pass):
///  - Name plates are rasterised once per process into ONE shared atlas texture (2048², shelf
///    packed), at most three new plates per frame, so revealing a district never stalls a frame.
///  - Every visible label of a tile (plate, leader stem, endpoint dot) is written into one small
///    ring buffer and drawn with a single draw call; the dot is a quad shaded round in the fragment.
///  - While the camera and reveal are unchanged, the previous frame's buffer and placements are
///    reused untouched: no projection, collision test or vertex writes at rest.
///  - Labels only appear from zoom 16.3, and a frame-wide budget shared by all tiles shows a few
///    (4 at street level up to 12 fully zoomed in). Labels placed last frame keep priority, so
///    names do not swap places or flicker while panning.
nonisolated final class DioramaLabelRenderer {
    private struct Vertex {
        var position: SIMD4<Float>
        /// xy: atlas uv (plates) or unit-disc position (dot); z: coverage; w: 0 plate, 1 stem, 2 dot.
        var uv: SIMD4<Float>
    }
    private struct PipelineKey: Hashable {
        let device: ObjectIdentifier
        let color: MTLPixelFormat
        let depth: MTLPixelFormat
    }
    private struct Plate {
        let uv: SIMD4<Float>
        let width: Float
        let height: Float
    }
    /// Process-wide plate atlas per device and display scale.
    private final class Atlas {
        static let size = 2048
        let texture: MTLTexture
        var plates: [String: Plate] = [:]
        var cursor = SIMD2<Int>(0, 0)
        var rowHeight = 0
        var generation = 0
        init(texture: MTLTexture) { self.texture = texture }
    }
    private struct AtlasKey: Hashable {
        let device: ObjectIdentifier
        let scale: Float
    }
    /// Placements of the current frame across every tile's renderer (keyed by the command buffer).
    private struct FrameSlots {
        var frame: ObjectIdentifier?
        var rects: [CGRect] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pipelines: [PipelineKey: (MTLRenderPipelineState, MTLDepthStencilState)] = [:]
    nonisolated(unsafe) private static var atlases: [AtlasKey: Atlas] = [:]
    nonisolated(unsafe) private static var slots = FrameSlots()
    private static let verticesPerLabel = 18
    private static let ringLength = 3

    private let device: MTLDevice
    private let labels: [DioramaBuildingLabel]
    private let byID: [UInt64: Int]
    private let scale: Float
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private var ring: [MTLBuffer] = []
    private var ringIndex = 0
    // Previous frame, reused verbatim while nothing that affects placement has changed.
    private var lastKey: [SIMD4<Float>] = []
    private var lastOrder: [UInt64] = []
    private var lastRects: [CGRect] = []
    private var lastVertexCount = 0
    private var lastBuffer: MTLBuffer?
    private var lastGeneration = -1
    private var lastComplete = false

    init?(device: MTLDevice, labels: [DioramaBuildingLabel], scale: Float, color: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device
        let sorted = labels.sorted { $0.isNamed != $1.isNamed ? $0.isNamed : $0.id < $1.id }
        self.labels = sorted
        var index: [UInt64: Int] = [:]
        for (i, label) in sorted.enumerated() where index[label.id] == nil { index[label.id] = i }
        byID = index
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
        struct LabelVertex { float4 position; float4 uv; };
        struct LabelOut { float4 position [[position]]; float4 uv; };
        vertex LabelOut labelVertex(uint id [[vertex_id]], const device LabelVertex *vertices [[buffer(0)]]) {
            LabelOut o; o.position = vertices[id].position; o.uv = vertices[id].uv; return o;
        }
        fragment float4 labelFragment(LabelOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float coverage = in.uv.z;
            float4 ink = float4(0.20, 0.22, 0.24, 1.0);
            if (in.uv.w > 1.5) {
                float r = length(in.uv.xy);
                float a = 1.0 - smoothstep(1.0 - max(fwidth(r), 0.02) * 1.5, 1.0, r);
                if (a <= 0.0) discard_fragment();
                return ink * (a * coverage);
            }
            if (in.uv.w > 0.5) return ink * coverage;
            float4 c = atlas.sample(s, in.uv.xy);
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

    /// Plates live in one shared 16 MB atlas, not per tile; tiles add nothing to the label budget.
    static func estimatedTextureBytes(titles: [String], scale: Float) -> Int { 0 }

    private static func textLayout(_ title: String, scale: Float) -> (line: CTLine, width: Int, height: Int) {
        let font = CTFontCreateWithName("Figtree-SemiBold" as CFString, 13 * CGFloat(scale), nil)
        let ink = CGColor(gray: 0.133, alpha: 1)
        let text = NSAttributedString(string: String(title.prefix(64)), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
        ])
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let width = min(Atlas.size - 4, max(32, Int(ceil(textWidth + Double(scale) * 16))))
        let height = Int(32 * scale)
        return (line, width, height)
    }

    private static func atlas(device: MTLDevice, scale: Float) -> Atlas? {
        let key = AtlasKey(device: ObjectIdentifier(device), scale: scale)
        if let atlas = atlases[key] { return atlas }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Atlas.size, height: Atlas.size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let atlas = Atlas(texture: texture)
        atlases[key] = atlas
        return atlas
    }

    /// A title's plate in the shared atlas, rasterised on first use (only when `allowRaster`).
    /// When the atlas is full it is recycled: every plate is redrawn on demand over a few frames.
    private static func plate(_ title: String, atlas: Atlas, scale: Float, allowRaster: Bool) -> Plate? {
        if let plate = atlas.plates[title] { return plate }
        guard allowRaster else { return nil }
        let (line, width, height) = textLayout(title, scale: scale)
        let padding = 2
        if atlas.cursor.x + width + padding > Atlas.size {
            atlas.cursor = SIMD2(0, atlas.cursor.y + atlas.rowHeight + padding)
            atlas.rowHeight = 0
        }
        if atlas.cursor.y + height > Atlas.size {
            atlas.plates.removeAll()
            atlas.cursor = .zero
            atlas.rowHeight = 0
            atlas.generation += 1
        }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { return nil }
        let s = CGFloat(scale)
        let shape = CGRect(x: s, y: 4 * s, width: CGFloat(width) - 2 * s, height: 26 * s)
        context.setFillColor(CGColor(gray: 0.64, alpha: 1))
        context.addPath(CGPath(roundedRect: shape.offsetBy(dx: 0, dy: -2 * s), cornerWidth: 6 * s, cornerHeight: 6 * s, transform: nil)); context.fillPath()
        context.setFillColor(CGColor(gray: 0.99, alpha: 1))
        context.addPath(CGPath(roundedRect: shape, cornerWidth: 6 * s, cornerHeight: 6 * s, transform: nil)); context.fillPath()
        context.setLineJoin(.round)
        context.setTextDrawingMode(.stroke)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.98))
        context.setLineWidth(3.5 * s)
        context.textPosition = CGPoint(x: 8 * s, y: 12 * s)
        CTLineDraw(line, context)
        context.setTextDrawingMode(.fill)
        context.textPosition = CGPoint(x: 8 * s, y: 12 * s)
        CTLineDraw(line, context)
        let origin = atlas.cursor
        atlas.texture.replace(region: MTLRegionMake2D(origin.x, origin.y, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        atlas.cursor.x += width + padding
        atlas.rowHeight = max(atlas.rowHeight, height)
        let size = Float(Atlas.size)
        let plate = Plate(uv: SIMD4(Float(origin.x) / size, Float(origin.y) / size,
                                    Float(origin.x + width) / size, Float(origin.y + height) / size),
                          width: Float(width), height: Float(height))
        atlas.plates[title] = plate
        return plate
    }

    /// Labels a frame may show across every tile: a few at street level, more fully zoomed in.
    private static func budget(zoom: Double) -> Int {
        zoom < 16.8 ? 4 : zoom < 17.5 ? 6 : zoom < 18.3 ? 9 : 12
    }

    func draw(encoder: MTLRenderCommandEncoder, frame: ObjectIdentifier, matrix: simd_float4x4, width: Int, height: Int,
              zoom: Double, uniforms: DioramaShaderUniforms) -> Set<UInt64> {
        guard zoom >= 16.3, !labels.isEmpty else { return [] }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if Self.slots.frame != frame { Self.slots = FrameSlots(frame: frame) }
        guard let atlas = Self.atlas(device: device, scale: scale) else { return [] }
        let budget = Self.budget(zoom: zoom)
        let key: [SIMD4<Float>] = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3,
            SIMD4(Float(width), Float(height), Float(zoom), 0), uniforms.reveal, uniforms.lifecycleReveal,
            uniforms.tileBounds, uniforms.focusEdges, uniforms.tileState, uniforms.unionState]

        // At rest: the previous placements and vertices are still exact.
        if lastComplete, key == lastKey, lastGeneration == atlas.generation, let buffer = lastBuffer,
           Self.slots.rects.count + lastRects.count <= budget,
           !lastRects.contains(where: { rect in Self.slots.rects.contains { $0.intersects(rect) } }) {
            Self.slots.rects += lastRects
            if lastVertexCount > 0 { submit(encoder, buffer: buffer, atlas: atlas, count: lastVertexCount) }
            return Set(lastOrder)
        }

        if ring.isEmpty {
            for _ in 0..<Self.ringLength {
                guard let buffer = device.makeBuffer(length: 16 * Self.verticesPerLabel * MemoryLayout<Vertex>.stride,
                                                     options: .storageModeShared) else { return [] }
                ring.append(buffer)
            }
        }
        ringIndex = (ringIndex + 1) % ring.count
        let buffer = ring[ringIndex]
        let out = buffer.contents().bindMemory(to: Vertex.self, capacity: 16 * Self.verticesPerLabel)
        var written = 0
        let w = Float(width), h = Float(height)
        let margin = 8 * CGFloat(scale)
        var rastersLeft = 3
        var complete = true
        var order: [UInt64] = []
        var rects: [CGRect] = []

        // Labels shown last frame first (stable while panning), then the rest in fixed order.
        var candidates: [Int] = lastOrder.compactMap { byID[$0] }
        let previous = Set(candidates)
        candidates += labels.indices.filter { !previous.contains($0) }

        for index in candidates {
            guard Self.slots.rects.count < budget, order.count < 16 else { break }
            let label = labels[index]
            guard label.isNamed || zoom >= 18.3 else { continue }
            // Cheap projection and on-screen test first; reveal coverage and plates only for candidates.
            let roof = matrix * SIMD4(label.anchor, 1)
            let lift: Float = label.isNamed ? 5.5 : 3.5
            let p = matrix * SIMD4(label.anchor + SIMD3(0, 0, lift), 1)
            guard roof.w > 0.001, p.w > 0.001, p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  abs(p.x / p.w) < 1.05, abs(p.y / p.w) < 1.05 else { continue }
            let revealed = DioramaRevealStyle.sceneCoverage(label.anchor, reveal: uniforms.reveal,
                bounds: uniforms.tileBounds, edges: uniforms.focusEdges, state: uniforms.tileState, frame: uniforms.materialFrame)
                * DioramaRevealStyle.coverage(label.anchor, reveal: uniforms.lifecycleReveal, bounds: uniforms.tileBounds)
                * DioramaUnionShape.coverage(label.anchor, uniforms: uniforms)
            var coverage: Float = min(1, max(0, (revealed - 0.55) / 0.45))
            coverage = coverage * coverage * (3 - 2 * coverage)
            guard coverage > 0.001 else { continue }
            if coverage < 0.999 { complete = false }
            let cached = Self.plate(label.title, atlas: atlas, scale: scale, allowRaster: false)
            let made = cached ?? (rastersLeft > 0 ? Self.plate(label.title, atlas: atlas, scale: scale, allowRaster: true) : nil)
            if cached == nil { if made != nil { rastersLeft -= 1 } else { complete = false } }
            guard let plate = made else { continue }
            let x = (p.x / p.w + 1) * w * 0.5, y = (1 - p.y / p.w) * h * 0.5
            let rect = CGRect(x: CGFloat(x - plate.width / 2), y: CGFloat(y - plate.height), width: CGFloat(plate.width), height: CGFloat(plate.height))
            let padded = rect.insetBy(dx: -6 * CGFloat(scale), dy: -4 * CGFloat(scale))
            guard rect.minX >= margin, rect.maxX < CGFloat(width) - margin, rect.minY > margin, rect.maxY < CGFloat(height),
                  !Self.slots.rects.contains(where: { $0.intersects(padded) }) else { continue }
            Self.slots.rects.append(padded)
            rects.append(padded)
            order.append(label.id)

            // Leader stem (perspective correct: each end keeps its own depth) and a round endpoint dot.
            let delta = SIMD2((p.x / p.w - roof.x / roof.w) * w, (p.y / p.w - roof.y / roof.w) * h)
            let length = simd_length(delta)
            let normal = length > 0.01 ? SIMD2(-delta.y, delta.x) / length : SIMD2<Float>(1, 0)
            let thickness = 1.25 * scale, dot = 3 * scale
            func end(_ point: SIMD4<Float>, _ side: Float) -> Vertex {
                Vertex(position: SIMD4(point.x + normal.x * thickness * side / w * point.w, point.y + normal.y * thickness * side / h * point.w, point.z, point.w),
                       uv: SIMD4(0, 0, coverage, 1))
            }
            func disc(_ dx: Float, _ dy: Float) -> Vertex {
                Vertex(position: SIMD4(roof.x + dx * dot * 2 / w * roof.w, roof.y + dy * dot * 2 / h * roof.w, roof.z, roof.w),
                       uv: SIMD4(dx, dy, coverage, 2))
            }
            func corner(_ dx: Float, _ dy: Float, _ u: Float, _ v: Float) -> Vertex {
                Vertex(position: SIMD4(p.x + dx * 2 / w * p.w, p.y + dy * 2 / h * p.w, p.z, p.w), uv: SIMD4(u, v, coverage, 0))
            }
            let a = corner(-plate.width / 2, 0, plate.uv.x, plate.uv.w), b = corner(plate.width / 2, 0, plate.uv.z, plate.uv.w)
            let c = corner(plate.width / 2, plate.height, plate.uv.z, plate.uv.y), d = corner(-plate.width / 2, plate.height, plate.uv.x, plate.uv.y)
            let quad: [Vertex] = [end(roof, -1), end(roof, 1), end(p, 1), end(roof, -1), end(p, 1), end(p, -1),
                                  disc(-1, -1), disc(1, -1), disc(1, 1), disc(-1, -1), disc(1, 1), disc(-1, 1),
                                  a, b, c, a, c, d]
            for v in quad { out[written] = v; written += 1 }
        }
        lastKey = key
        lastOrder = order
        lastRects = rects
        lastVertexCount = written
        lastBuffer = buffer
        lastGeneration = atlas.generation
        lastComplete = complete
        if written > 0 { submit(encoder, buffer: buffer, atlas: atlas, count: written) }
        return Set(order)
    }

    private func submit(_ encoder: MTLRenderCommandEncoder, buffer: MTLBuffer, atlas: Atlas, count: Int) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setTriangleFillMode(.fill)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
    }
}
