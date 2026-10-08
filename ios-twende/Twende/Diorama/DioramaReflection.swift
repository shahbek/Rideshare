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
    private var lastLifecycle: SIMD4<Float> = .zero
    private var lastEdges: SIMD4<Float> = .zero
    private var lastTileState: SIMD4<Float> = .zero
    private var lastSignature: String = ""
    private var lastUnion: SIMD4<Float> = .zero
    private var lastFocusEdges: SIMD4<Float> = .zero

    init?(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        func descriptor(_ instanced: Bool) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: instanced ? "dioramaInstancedVertex" : "dioramaVertex")
            d.fragmentFunction = library.makeFunction(name: "dioramaFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = .depth32Float
            return d
        }
        do {
            pipeline = try DioramaPipelineCache.shared.state(device: device, descriptor: descriptor(false))
            instancedPipeline = try DioramaPipelineCache.shared.state(device: device, descriptor: descriptor(true))
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .lessEqual; d.isDepthWriteEnabled = true
            guard let state = device.makeDepthStencilState(descriptor: d) else { return nil }
            depthState = state
        } catch { print("[Diorama] reflection pipeline unavailable"); return nil }
    }

    /// Preallocate before the host enters Mapbox's render loop.
    func prepareSize(width: Int, height: Int) {
        let w = max(1, min(768, width / 4)), h = max(1, min(768, height / 4))
        guard color?.width != w || color?.height != h else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        color = device.makeTexture(descriptor: d)
        d.pixelFormat = .depth32Float; d.usage = .renderTarget
        depth = device.makeTexture(descriptor: d)
        lastMatrix = nil
    }

    func encode(command: MTLCommandBuffer, width: Int, height: Int, depthRange: (Double, Double),
                matrix: simd_float4x4, uniforms: DioramaShaderUniforms, signature: String,
                vertices: MTLBuffer, indices: MTLBuffer, instances: MTLBuffer?,
                fragmentBuffers: [MTLBuffer], textures: [MTLTexture?],
                ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup],
                lod: DioramaLODSelector? = nil, timing: DioramaPassTimer.Frame? = nil) -> MTLTexture? {
        let w = max(1, min(768, width / 4)), h = max(1, min(768, height / 4))
        prepareSize(width: width, height: height)
        guard let color, let depth else { return nil }
        if lastMatrix == matrix, lastReveal == uniforms.reveal, lastLifecycle == uniforms.lifecycleReveal,
           lastEdges == uniforms.tileEdges, lastTileState == uniforms.tileState, lastSignature == signature,
           lastUnion == uniforms.unionState, lastFocusEdges == uniforms.focusEdges { return color }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        timing?.attach(pass, "Reflection")
        guard let e = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var m = matrix, u = uniforms
        u.params.w = 1; u.water.y = 0; u.post.x = 0
        e.label = "Diorama cached water reflection"
        e.setViewport(.init(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1))
        e.setFrontFacing(.clockwise)
        e.setDepthStencilState(depthState)
        e.setVertexBuffer(vertices, offset: 0, index: 0)
        e.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        e.setVertexBytes(&u, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
        e.setFragmentBytes(&u, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
        for (i, buffer) in fragmentBuffers.enumerated() { e.setFragmentBuffer(buffer, offset: 0, index: i + 1) }
        for (i, texture) in textures.enumerated() { e.setFragmentTexture(texture, index: i) }
        e.setRenderPipelineState(pipeline)
        let lodIndices = lod?.table.indexBuffer ?? indices
        let reflectedRanges = DioramaDrawPlan.ranges(DioramaDrawPlan.levels(ranges.filter {
            $0.category != .water && $0.category != .propGlow && $0.category != .shorelineDebug
                && $0.maximum.z >= uniforms.water.x - 0.05 && $0.intersectsReveal(uniforms.reveal)
                && $0.intersects(matrix, mirrorHeight: uniforms.water.x)
        }, selector: lod))
        timing?.count("Reflection", triangles: reflectedRanges.reduce(0) { $0 + $1.count / 3 })
        for range in reflectedRanges {
            e.setCullMode(range.doubleSided ? .none : .back)
            e.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: range.usesLODBuffer ? lodIndices : indices, indexBufferOffset: range.start * 4)
        }
        if let instances {
            e.setVertexBuffer(instances, offset: 0, index: 3); e.setRenderPipelineState(instancedPipeline)
            let reflectedGroups = groups.filter { group in
                let bounds = DioramaRenderLayer.Range(category: group.category, start: 0, count: 0,
                    minimum: group.minimum, maximum: group.maximum)
                return group.category != .propGlow && group.maximum.z >= uniforms.water.x - 0.05
                    && bounds.intersectsReveal(uniforms.reveal) && bounds.intersects(matrix, mirrorHeight: uniforms.water.x)
            }
            let reflectedDraws = DioramaDrawPlan.instances(reflectedGroups, selector: lod)
            timing?.count("Reflection", triangles: reflectedDraws.reduce(0) { $0 + $1.count / 3 * $1.instanceCount })
            for group in reflectedDraws {
                e.setCullMode(group.doubleSided ? .none : .back)
                e.drawIndexedPrimitives(type: .triangle, indexCount: group.count, indexType: .uint32, indexBuffer: group.usesLODBuffer ? lodIndices : indices,
                    indexBufferOffset: group.start * 4, instanceCount: group.instanceCount, baseVertex: 0, baseInstance: group.firstInstance)
            }
        }
        e.endEncoding()
        lastMatrix = matrix; lastReveal = uniforms.reveal; lastSignature = signature
        lastLifecycle = uniforms.lifecycleReveal; lastEdges = uniforms.tileEdges; lastTileState = uniforms.tileState
        lastUnion = uniforms.unionState; lastFocusEdges = uniforms.focusEdges
        return color
    }
}
