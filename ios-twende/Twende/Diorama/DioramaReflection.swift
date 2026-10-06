import Metal
import simd

/// Cached quarter-resolution planar scene reflection. Wave distortion runs in the main water pass.
nonisolated final class DioramaReflection {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let instancedPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var color: MTLTexture?
    private var depth: MTLTexture?
    private var lastMatrix: simd_float4x4?
    private var lastReveal: SIMD4<Float> = .zero
    private var lastSignature: String = ""

    init?(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        func descriptor(_ instanced: Bool) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: instanced ? "dioramaInstancedVertex" : "dioramaVertex")
            d.fragmentFunction = library.makeFunction(name: "dioramaFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            return d
        }
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor(false))
            instancedPipeline = try device.makeRenderPipelineState(descriptor: descriptor(true))
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .lessEqual; d.isDepthWriteEnabled = true
            guard let state = device.makeDepthStencilState(descriptor: d) else { return nil }
            depthState = state
        } catch { print("[Diorama] reflection pipeline unavailable"); return nil }
    }

    func encode(command: MTLCommandBuffer, width: Int, height: Int, depthRange: (Double, Double),
                matrix: simd_float4x4, uniforms: DioramaShaderUniforms, signature: String,
                vertices: MTLBuffer, indices: MTLBuffer, instances: MTLBuffer?,
                fragmentBuffers: [MTLBuffer], textures: [MTLTexture?],
                ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup]) -> MTLTexture? {
        let w = max(1, min(768, width / 4)), h = max(1, min(768, height / 4))
        if color?.width != w || color?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            color = device.makeTexture(descriptor: d)
            d.pixelFormat = .depth32Float; d.usage = .renderTarget
            depth = device.makeTexture(descriptor: d)
            lastMatrix = nil
        }
        guard let color, let depth else { return nil }
        if lastMatrix == matrix, lastReveal == uniforms.reveal, lastSignature == signature { return color }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let e = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var m = matrix, u = uniforms
        u.params.w = 1; u.water.y = 0; u.post.x = 0
        e.label = "Diorama cached water reflection"
        e.setViewport(.init(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: depthRange.0, zfar: depthRange.1))
        e.setFrontFacing(.clockwise)
        e.setDepthStencilState(depthState)
        e.setVertexBuffer(vertices, offset: 0, index: 0)
        e.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        e.setVertexBytes(&u, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
        e.setFragmentBytes(&u, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
        for (i, buffer) in fragmentBuffers.enumerated() { e.setFragmentBuffer(buffer, offset: 0, index: i + 1) }
        for (i, texture) in textures.enumerated() { e.setFragmentTexture(texture, index: i) }
        e.setRenderPipelineState(pipeline)
        let reflectedRanges = DioramaDrawPlan.ranges(ranges.filter {
            $0.category != .water && $0.category != .propGlow && $0.category != .shorelineDebug
                && $0.intersects(matrix, mirrorHeight: uniforms.water.x)
        })
        for range in reflectedRanges {
            e.setCullMode(range.doubleSided ? .none : .back)
            e.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: range.start * 4)
        }
        if let instances {
            e.setVertexBuffer(instances, offset: 0, index: 3); e.setRenderPipelineState(instancedPipeline)
            let reflectedGroups = groups.filter { group in
                group.category != .propGlow && DioramaRenderLayer.Range(category: group.category, start: 0, count: 0,
                    minimum: group.minimum, maximum: group.maximum).intersects(matrix, mirrorHeight: uniforms.water.x)
            }
            for group in DioramaDrawPlan.instances(reflectedGroups) {
                e.setCullMode(group.doubleSided ? .none : .back)
                e.drawIndexedPrimitives(type: .triangle, indexCount: group.count, indexType: .uint32, indexBuffer: indices,
                    indexBufferOffset: group.start * 4, instanceCount: group.instanceCount, baseVertex: 0, baseInstance: group.firstInstance)
            }
        }
        e.endEncoding()
        lastMatrix = matrix; lastReveal = uniforms.reveal; lastSignature = signature
        return color
    }
}
