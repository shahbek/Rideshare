import Metal
import simd

/// Mesh-silhouette directional shadows on a sampled ground/water receiver. Separate from scenery caches.
/// A native SDK surface cannot receive our private shadow map; the depth-tested receiver supplies it.
nonisolated final class DioramaProjectedShadow {
    struct Field {
        let matrix: simd_float4x4
        let bounds: SIMD4<Float>
        let texture: MTLTexture
    }
    private struct Key: Equatable {
        let sun: SIMD3<Float>
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
        let vertices: ObjectIdentifier
        let indices: ObjectIdentifier
        let count: Int
    }
    private struct ReceiverUniforms {
        var light: simd_float4x4
        var params: SIMD4<Float>
    }
    private let texture: MTLTexture
    private let casterPipeline: MTLRenderPipelineState
    private let receiverPipeline: MTLRenderPipelineState
    private let casterDepth: MTLDepthStencilState
    private let receiverDepth: MTLDepthStencilState
    private let size: Int
    private var key: Key?
    private var field: Field?

    init?(device: MTLDevice, color: UInt, depth: UInt, size: Int) {
        guard let library = DioramaShaderSource.library(for: device) else { return nil }
        self.size = size
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "dioramaProjectedCasterVertex")
        d.depthAttachmentPixelFormat = .depth32Float
        guard let caster = try? DioramaPipelineCache.shared.state(device: device, descriptor: d) else { return nil }
        casterPipeline = caster
        d.vertexFunction = library.makeFunction(name: "dioramaProjectedReceiverVertex")
        d.fragmentFunction = library.makeFunction(name: "dioramaProjectedReceiverFragment")
        d.depthAttachmentPixelFormat = MTLPixelFormat(rawValue: depth) ?? .depth32Float_stencil8
        d.stencilAttachmentPixelFormat = d.depthAttachmentPixelFormat == .depth32Float_stencil8 ? .depth32Float_stencil8 : .invalid
        d.colorAttachments[0].pixelFormat = MTLPixelFormat(rawValue: color) ?? .bgra8Unorm
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let receiver = try? DioramaPipelineCache.shared.state(device: device, descriptor: d) else { return nil }
        receiverPipeline = receiver
        let state = MTLDepthStencilDescriptor()
        state.depthCompareFunction = .lessEqual; state.isDepthWriteEnabled = true
        guard let casting = device.makeDepthStencilState(descriptor: state) else { return nil }
        casterDepth = casting
        state.isDepthWriteEnabled = false
        guard let receiving = device.makeDepthStencilState(descriptor: state) else { return nil }
        receiverDepth = receiving
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        guard let texture = device.makeTexture(descriptor: td) else { return nil }
        self.texture = texture
    }

    /// XY projection includes the entire sun-directed silhouette, not an oval under the body.
    static func receiverBounds(minimum: SIMD3<Float>, maximum: SIMD3<Float>, sun: SIMD3<Float>) -> SIMD4<Float> {
        let ray = -SIMD2(sun.x, sun.y) / max(0.02, sun.z)
        let a = ray * max(0, minimum.z), b = ray * max(0, maximum.z)
        let low = SIMD2(minimum.x, minimum.y) + simd_min(.zero, simd_min(a, b)) - SIMD2(repeating: 0.8)
        let high = SIMD2(maximum.x, maximum.y) + simd_max(.zero, simd_max(a, b)) + SIMD2(repeating: 0.8)
        return SIMD4(low.x, low.y, high.x, high.y)
    }

    /// Immutable caster buffers are rendered only when the local light direction or fitted box changes.
    func encode(command: MTLCommandBuffer, vertices: MTLBuffer, indices: MTLBuffer, count: Int,
                minimum: SIMD3<Float>, maximum: SIMD3<Float>, sun: SIMD3<Float>,
                receiver: [SIMD4<Float>]) -> Field? {
        guard sun.z > 0.02 else { return nil }
        let bounds = Self.receiverBounds(minimum: minimum, maximum: maximum, sun: sun)
        var low = minimum, high = maximum
        for p in receiver { low = simd_min(low, SIMD3(p.x, p.y, p.z)); high = simd_max(high, SIMD3(p.x, p.y, p.z)) }
        let next = Key(sun: sun, minimum: low, maximum: high, vertices: ObjectIdentifier(vertices), indices: ObjectIdentifier(indices), count: count)
        if key == next { return field }
        let forward = -simd_normalize(sun)
        let helper = abs(sun.z) > 0.98 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
        let right = simd_normalize(simd_cross(helper, sun)), up = simd_normalize(simd_cross(sun, right))
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for x in [low.x, high.x] { for y in [low.y, high.y] { for z in [low.z - 1, high.z + 1] {
            let p = SIMD3(x, y, z), q = SIMD3(simd_dot(right, p), simd_dot(up, p), simd_dot(forward, p))
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        } } }
        let span = simd_max(hi - lo, SIMD3(repeating: 1))
        let x = right * (2 / span.x), y = up * (2 / span.y), z = forward / span.z
        var light = simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0), SIMD4(-(hi.x + lo.x) / span.x, -(hi.y + lo.y) / span.y, -lo.z / span.z, 1)))
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture; pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store; pass.depthAttachment.clearDepth = 1
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Cached actual-mesh ground shadow"
        encoder.setRenderPipelineState(casterPipeline); encoder.setDepthStencilState(casterDepth)
        encoder.setCullMode(.none)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(size), height: Double(size), znear: 0, zfar: 1))
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&light, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        encoder.endEncoding()
        let result = Field(matrix: light, bounds: bounds, texture: texture)
        key = next; field = result
        return result
    }

    /// The 5×5 receiver follows saved terrain (or SDK elevation); walls/vehicles occlude it via SDK depth.
    func receive(encoder: MTLRenderCommandEncoder, field: Field, points: [SIMD4<Float>],
                 matrix: simd_float4x4, opacity: Float) {
        guard points.count == 25 else { return }
        var matrix = matrix
        var uniforms = ReceiverUniforms(light: field.matrix, params: SIMD4(1 / Float(size), opacity, 0.0003, 0))
        encoder.setRenderPipelineState(receiverPipeline); encoder.setDepthStencilState(receiverDepth)
        encoder.setCullMode(.none)
        points.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { encoder.setVertexBytes(base, length: bytes.count, index: 0) }
        }
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReceiverUniforms>.stride, index: 0)
        encoder.setFragmentTexture(field.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 96)
    }

    static let source = """
    struct DioramaReceiverUniforms { float4x4 light; float4 params; };
    struct DioramaShadowReceiver { float4 position [[position]]; float3 local; };
    vertex float4 dioramaProjectedCasterVertex(uint id [[vertex_id]],
        const device DioramaInput *vertices [[buffer(0)]], constant float4x4 &light [[buffer(1)]]) {
        DioramaInput v = vertices[id];
        if (v.appearance.w > 3.5 || (v.appearance.w > 0.5 && v.appearance.w < 1.5)) return float4(2,2,2,1);
        return light * v.position;
    }
    vertex DioramaShadowReceiver dioramaProjectedReceiverVertex(uint id [[vertex_id]],
        constant float4 *points [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]]) {
        constexpr uint corners[6] = {0,1,6,0,6,5};
        uint cell = id / 6, index = (cell / 4) * 5 + cell % 4 + corners[id % 6];
        float3 p = points[index].xyz;
        return {matrix * float4(p,1), p};
    }
    fragment float4 dioramaProjectedReceiverFragment(DioramaShadowReceiver in [[stage_in]],
        constant DioramaReceiverUniforms &u [[buffer(0)]], depth2d<float> shadow [[texture(0)]]) {
        float4 clip = u.light * float4(in.local,1);
        float3 p = clip.xyz / clip.w;
        float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        if (any(uv < float2(0.005)) || any(uv > float2(0.995)) || p.z <= 0 || p.z >= 1) discard_fragment();
        constexpr sampler comparison(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less_equal);
        float2 dx = dfdx(uv), dy = dfdy(uv);
        float det = dx.x * dy.y - dx.y * dy.x;
        float2 gradient = abs(det) > 1e-10 ? float2(dy.y * dfdx(p.z) - dx.y * dfdy(p.z), dx.x * dfdy(p.z) - dy.x * dfdx(p.z)) / det : float2(0);
        float visible = 0;
        for (int y = -1; y <= 1; ++y) { for (int x = -1; x <= 1; ++x) {
            float2 offset = float2(x,y) * u.params.x * 1.25;
            visible += shadow.sample_compare(comparison, uv + offset, p.z + dot(gradient,offset) - u.params.z);
        } }
        float alpha = (1 - visible / 9) * u.params.y;
        if (alpha < 0.002) discard_fragment();
        return float4(0.08,0.09,0.10,alpha);
    }
    """
}
