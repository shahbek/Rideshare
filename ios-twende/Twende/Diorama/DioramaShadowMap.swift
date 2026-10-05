import Metal
import simd

/// Tile-local directional shadows, cached until the lighting preset or visible geometry changes.
/// The static tile costs one depth pass per change, not another scene render on every water frame.
nonisolated final class DioramaShadowMap {
    let texture: MTLTexture
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let corners: [SIMD3<Float>]
    private var cachedKey: String?
    private var matrix: simd_float4x4 = matrix_identity_float4x4

    init?(device: MTLDevice, library: MTLLibrary, vertices: [BuildingRenderVertex]) {
        guard let function = library.makeFunction(name: "dioramaShadowVertex") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Diorama directional shadow depth"
        descriptor.vertexFunction = function
        descriptor.depthAttachmentPixelFormat = .depth32Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depth = depth
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        target.usage = [.renderTarget, .shaderRead]
        target.storageMode = .private
        guard let texture = device.makeTexture(descriptor: target) else { return nil }
        self.texture = texture
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices where v.appearance.w < 3.5 {
            let p = SIMD3<Float>(v.position.x, v.position.y, v.position.z)
            low = simd_min(low, p); high = simd_max(high, p)
        }
        guard low.x.isFinite, high.x > low.x else { return nil }
        var corners: [SIMD3<Float>] = []
        for x in [low.x - 2, high.x + 2] {
            for y in [low.y - 2, high.y + 2] {
                for z in [low.z - 2, high.z + 2] { corners.append(SIMD3(x, y, z)) }
            }
        }
        self.corners = corners
    }

    /// Returns nil if encoding fails; callers disable sampling until a valid map exists.
    func update(command: MTLCommandBuffer, vertices: MTLBuffer, indices: MTLBuffer,
                ranges: [DioramaRenderLayer.Range], sun: SIMD3<Float>, preset: DioramaTimeOfDay) -> simd_float4x4? {
        let casters = ranges.filter { !$0.category.isEmissive && $0.category != .water }
        let key = preset.rawValue + casters.map { $0.category.rawValue }.sorted().joined(separator: "/")
        if cachedKey == key { return matrix }
        let forward = -simd_normalize(sun)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), sun))
        let up = simd_normalize(simd_cross(sun, right))
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in corners {
            let q = SIMD3(simd_dot(right, p), simd_dot(up, p), simd_dot(forward, p))
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let span = simd_max(hi - lo, SIMD3<Float>(repeating: 1))
        let x = right * (2 / span.x), y = up * (2 / span.y), z = forward / span.z
        var candidate = simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-(hi.x + lo.x) / span.x, -(hi.y + lo.y) / span.y, -lo.z / span.z, 1)
        ))
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Diorama cached sun shadows"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: 2048, height: 2048, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setDepthBias(0.4, slopeScale: 1.0, clamp: 0.001)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&candidate, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        for range in casters {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        encoder.endEncoding()
        matrix = candidate
        cachedKey = key
        return matrix
    }
}
