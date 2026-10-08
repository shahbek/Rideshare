import Foundation
import Metal
import simd

/// Screen-space passes for the diorama, encoded on Mapbox's command buffer before its main pass:
/// a half-resolution G-buffer (position, normal, emissive), hemisphere ambient occlusion with a
/// separable blur, and a two-level bloom pyramid built from the emissive channel. The main pass
/// samples the occlusion texture; the bloom is added over the finished frame.
nonisolated final class DioramaPostProcess {
    private let device: MTLDevice
    private let gbufferPipeline: MTLRenderPipelineState
    private let gbufferInstancedPipeline: MTLRenderPipelineState
    private let emissivePipeline: MTLRenderPipelineState
    private let emissiveInstancedPipeline: MTLRenderPipelineState
    private let ssaoPipeline: MTLRenderPipelineState
    private let blurGrayPipeline: MTLRenderPipelineState
    private let blurColorPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let noDepthState: MTLDepthStencilState
    private let compositeDepthState: MTLDepthStencilState

    private var width = 0
    private var height = 0
    private var position: MTLTexture?
    private var normal: MTLTexture?
    private var emissive: MTLTexture?
    private var depth: MTLTexture?
    private var occlusionA: MTLTexture?
    private var occlusionB: MTLTexture?
    private var quarterA: MTLTexture?
    private var quarterB: MTLTexture?
    private var eighthA: MTLTexture?
    private var eighthB: MTLTexture?

    private(set) var occlusion: MTLTexture?
    private var cachedRevision: UInt64?
    private var cachedSettings: SIMD4<Float> = .zero
    private var cachedBloom: [MTLTexture] = []
    private var cachedSubmission: Submission?

    /// Track failure without retaining Mapbox's entire command buffer and its frame resources.
    private final class Submission: @unchecked Sendable {
        private let lock = NSLock()
        private var failed: Bool = false
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return !failed }
        func invalidate() { lock.lock(); failed = true; lock.unlock() }
    }

    init?(device: MTLDevice, library: MTLLibrary, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device
        guard let vertex = library.makeFunction(name: "dioramaVertex"),
              let instancedVertex = library.makeFunction(name: "dioramaInstancedVertex"),
              let gbuffer = library.makeFunction(name: "dioramaGBufferFragment"),
              let emissiveFragment = library.makeFunction(name: "dioramaEmissiveFragment"),
              let fullscreen = library.makeFunction(name: "dioramaFullscreenVertex"),
              let ssao = library.makeFunction(name: "dioramaSSAOFragment"),
              let blur = library.makeFunction(name: "dioramaBlurFragment"),
              let copy = library.makeFunction(name: "dioramaCopyFragment"),
              let composite = library.makeFunction(name: "dioramaBloomComposite") else { return nil }

        func geometry(_ vertexFunction: MTLFunction, _ fragment: MTLFunction, emissive: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.label = emissive ? "Diorama emissive prepass" : "Diorama G-buffer"
            d.vertexFunction = vertexFunction
            d.fragmentFunction = fragment
            for i in 0..<3 { d.colorAttachments[i].pixelFormat = .rgba16Float }
            d.depthAttachmentPixelFormat = .depth32Float
            if emissive {
                d.colorAttachments[0].writeMask = []
                d.colorAttachments[1].writeMask = []
                d.colorAttachments[2].isBlendingEnabled = true
                d.colorAttachments[2].sourceRGBBlendFactor = .one
                d.colorAttachments[2].destinationRGBBlendFactor = .one
                d.colorAttachments[2].sourceAlphaBlendFactor = .one
                d.colorAttachments[2].destinationAlphaBlendFactor = .one
            }
            return try? DioramaPipelineCache.shared.state(device: device, descriptor: d)
        }
        func screen(_ fragment: MTLFunction, format: MTLPixelFormat, label: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = fullscreen
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = format
            return try? DioramaPipelineCache.shared.state(device: device, descriptor: d)
        }
        guard let gbufferPipeline = geometry(vertex, gbuffer, emissive: false),
              let gbufferInstancedPipeline = geometry(instancedVertex, gbuffer, emissive: false),
              let emissivePipeline = geometry(vertex, emissiveFragment, emissive: true),
              let emissiveInstancedPipeline = geometry(instancedVertex, emissiveFragment, emissive: true),
              let ssaoPipeline = screen(ssao, format: .r8Unorm, label: "Diorama SSAO"),
              let blurGrayPipeline = screen(blur, format: .r8Unorm, label: "Diorama AO blur"),
              let blurColorPipeline = screen(blur, format: .rgba16Float, label: "Diorama bloom blur"),
              let copyPipeline = screen(copy, format: .rgba16Float, label: "Diorama bloom downsample") else { return nil }

        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.label = "Diorama bloom composite"
        compositeDescriptor.vertexFunction = fullscreen
        compositeDescriptor.fragmentFunction = composite
        compositeDescriptor.colorAttachments[0].pixelFormat = colorFormat
        compositeDescriptor.colorAttachments[0].isBlendingEnabled = true
        compositeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        compositeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        compositeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        compositeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        compositeDescriptor.depthAttachmentPixelFormat = depthFormat
        compositeDescriptor.stencilAttachmentPixelFormat = depthFormat
        guard let compositePipeline = try? DioramaPipelineCache.shared.state(device: device, descriptor: compositeDescriptor) else { return nil }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true
        let noDepth = MTLDepthStencilDescriptor()
        noDepth.depthCompareFunction = .lessEqual
        noDepth.isDepthWriteEnabled = false
        let always = MTLDepthStencilDescriptor()
        always.depthCompareFunction = .always
        always.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor),
              let noDepthState = device.makeDepthStencilState(descriptor: noDepth),
              let compositeDepthState = device.makeDepthStencilState(descriptor: always) else { return nil }

        self.gbufferPipeline = gbufferPipeline
        self.gbufferInstancedPipeline = gbufferInstancedPipeline
        self.emissivePipeline = emissivePipeline
        self.emissiveInstancedPipeline = emissiveInstancedPipeline
        self.ssaoPipeline = ssaoPipeline
        self.blurGrayPipeline = blurGrayPipeline
        self.blurColorPipeline = blurColorPipeline
        self.copyPipeline = copyPipeline
        self.compositePipeline = compositePipeline
        self.depthState = depthState
        self.noDepthState = noDepthState
        self.compositeDepthState = compositeDepthState
    }

    private func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int, label: String) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)
        t?.label = label
        return t
    }

    /// Preallocate off the render thread before registering the owning custom layer.
    func prepareSize(width: Int, height: Int) { resize(width: width, height: height) }

    private func resize(width w: Int, height h: Int) {
        guard w != width || h != height else { return }
        width = w; height = h
        cachedRevision = nil; cachedBloom = []; occlusion = nil
        let hw = max(w / 2, 1), hh = max(h / 2, 1)
        position = make(.rgba16Float, hw, hh, label: "Diorama G position")
        normal = make(.rgba16Float, hw, hh, label: "Diorama G normal")
        emissive = make(.rgba16Float, hw, hh, label: "Diorama G emissive")
        depth = make(.depth32Float, hw, hh, label: "Diorama G depth")
        occlusionA = make(.r8Unorm, hw, hh, label: "Diorama AO A")
        occlusionB = make(.r8Unorm, hw, hh, label: "Diorama AO B")
        quarterA = make(.rgba16Float, hw / 2, hh / 2, label: "Diorama bloom quarter A")
        quarterB = make(.rgba16Float, hw / 2, hh / 2, label: "Diorama bloom quarter B")
        eighthA = make(.rgba16Float, hw / 4, hh / 4, label: "Diorama bloom eighth A")
        eighthB = make(.rgba16Float, hw / 4, hh / 4, label: "Diorama bloom eighth B")
    }

    /// Encodes the prepass, occlusion and bloom. Returns the two bloom levels to composite.
    func encode(command: MTLCommandBuffer, targetWidth: Int, targetHeight: Int,
                vertices: MTLBuffer, indices: MTLBuffer, instances: MTLBuffer?,
                opaqueRanges: [DioramaRenderLayer.Range], emissiveRanges: [DioramaRenderLayer.Range],
                opaqueGroups: [DioramaDrawPlan.Instance], emissiveGroups: [DioramaDrawPlan.Instance],
                matrix: simd_float4x4, uniforms: DioramaShaderUniforms, eye: SIMD3<Float>,
                aoRadius: Float, aoStrength: Float, bloomStrength: Float, lodDistance: Float,
                revision: UInt64) -> [MTLTexture] {
        resize(width: targetWidth, height: targetHeight)
        // Revision includes the exact camera, categories, reveal boundary and instance LOD.
        // G-buffer/emission do not depend on water time or directional-shadow contents.
        let settings = SIMD4(aoRadius, aoStrength, bloomStrength, uniforms.params.x)
        if cachedRevision == revision, cachedSettings == settings,
           cachedSubmission?.isValid == true { return cachedBloom }
        cachedRevision = nil; cachedBloom = []; occlusion = nil
        guard let position, let normal, let emissive, let depth, let occlusionA, let occlusionB,
              let quarterA, let quarterB, let eighthA, let eighthB else { return [] }
        var matrix = matrix
        var uniforms = uniforms

        // 1. G-buffer and emissive prepass at half resolution.
        let pass = MTLRenderPassDescriptor()
        for (i, t) in [position, normal, emissive].enumerated() {
            pass.colorAttachments[i].texture = t
            pass.colorAttachments[i].loadAction = .clear
            pass.colorAttachments[i].storeAction = .store
            pass.colorAttachments[i].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let g = command.makeRenderCommandEncoder(descriptor: pass) else { return [] }
        g.label = "Diorama G-buffer"
        g.setFrontFacing(.counterClockwise)
        g.setVertexBuffer(vertices, offset: 0, index: 0)
        g.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        g.setVertexBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
        g.setFragmentBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
        var cullMode: MTLCullMode = .back
        g.setCullMode(.back)
        func cull(_ doubleSided: Bool) {
            let wanted: MTLCullMode = doubleSided ? .none : .back
            if wanted != cullMode { g.setCullMode(wanted); cullMode = wanted }
        }
        func drawGroup(_ group: DioramaDrawPlan.Instance) {
            let start = group.start
            let count = group.count
            cull(group.doubleSided)
            g.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: indices,
                                    indexBufferOffset: start * MemoryLayout<UInt32>.stride, instanceCount: group.instanceCount,
                                    baseVertex: 0, baseInstance: group.firstInstance)
        }
        g.setDepthStencilState(depthState)
        g.setRenderPipelineState(gbufferPipeline)
        for range in opaqueRanges {
            cull(range.doubleSided)
            g.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        if let instances, !opaqueGroups.isEmpty {
            g.setVertexBuffer(instances, offset: 0, index: 3)
            g.setRenderPipelineState(gbufferInstancedPipeline)
            for group in opaqueGroups { drawGroup(group) }
        }
        if bloomStrength > 0.001 {
            g.setDepthStencilState(noDepthState)
            cull(true)
            g.setRenderPipelineState(emissivePipeline)
            for range in emissiveRanges {
                g.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
            }
            if let instances, !emissiveGroups.isEmpty {
                g.setVertexBuffer(instances, offset: 0, index: 3)
                g.setRenderPipelineState(emissiveInstancedPipeline)
                for group in emissiveGroups { drawGroup(group) }
            }
        }
        g.endEncoding()

        var allPassesEncoded = true
        func screenPass(_ target: MTLTexture, pipeline: MTLRenderPipelineState, sources: [MTLTexture], post: DioramaPostUniforms, label: String) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let e = command.makeRenderCommandEncoder(descriptor: d) else { allPassesEncoded = false; return }
            e.label = label
            e.setRenderPipelineState(pipeline)
            var post = post
            e.setFragmentBytes(&post, length: MemoryLayout<DioramaPostUniforms>.stride, index: 0)
            for (i, s) in sources.enumerated() { e.setFragmentTexture(s, index: i) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        func post(for target: MTLTexture, blur: SIMD2<Float> = .zero) -> DioramaPostUniforms {
            DioramaPostUniforms(matrix: matrix, eye: SIMD4(eye, 1),
                                params: SIMD4(aoRadius, aoStrength, Float(target.width), Float(target.height)),
                                blur: SIMD4(blur.x, blur.y, bloomStrength, 0))
        }

        // 2. Ambient occlusion, then a horizontal and vertical blur.
        if aoStrength > 0.001 {
            screenPass(occlusionA, pipeline: ssaoPipeline, sources: [position, normal], post: post(for: occlusionA), label: "Diorama SSAO")
            screenPass(occlusionB, pipeline: blurGrayPipeline, sources: [occlusionA], post: post(for: occlusionB, blur: SIMD2(1, 0)), label: "Diorama AO blur H")
            screenPass(occlusionA, pipeline: blurGrayPipeline, sources: [occlusionB], post: post(for: occlusionA, blur: SIMD2(0, 1)), label: "Diorama AO blur V")
            occlusion = occlusionA
        } else {
            occlusion = nil
        }

        // 3. Bloom: downsample the emissive channel twice, blurring each level.
        func saveCache(_ bloom: [MTLTexture]) -> [MTLTexture] {
            guard allPassesEncoded else { occlusion = nil; return [] }
            let submission = Submission()
            cachedRevision = revision; cachedSettings = settings; cachedBloom = bloom; cachedSubmission = submission
            command.addCompletedHandler { finished in
                if finished.status != .completed { submission.invalidate() }
            }
            return bloom
        }
        guard bloomStrength > 0.001 else { return saveCache([]) }
        screenPass(quarterA, pipeline: copyPipeline, sources: [emissive], post: post(for: quarterA), label: "Diorama bloom down 1")
        screenPass(quarterB, pipeline: blurColorPipeline, sources: [quarterA], post: post(for: quarterB, blur: SIMD2(1, 0)), label: "Diorama bloom blur 1H")
        screenPass(quarterA, pipeline: blurColorPipeline, sources: [quarterB], post: post(for: quarterA, blur: SIMD2(0, 1)), label: "Diorama bloom blur 1V")
        screenPass(eighthA, pipeline: copyPipeline, sources: [quarterA], post: post(for: eighthA), label: "Diorama bloom down 2")
        screenPass(eighthB, pipeline: blurColorPipeline, sources: [eighthA], post: post(for: eighthB, blur: SIMD2(2.5, 0)), label: "Diorama bloom blur 2H")
        screenPass(eighthA, pipeline: blurColorPipeline, sources: [eighthB], post: post(for: eighthA, blur: SIMD2(0, 2.5)), label: "Diorama bloom blur 2V")
        return saveCache([quarterA, eighthA])
    }

    /// Adds the bloom levels over the finished frame inside Mapbox's own render pass.
    func composite(_ levels: [MTLTexture], into encoder: MTLRenderCommandEncoder, strength: Float) {
        guard !levels.isEmpty, strength > 0.001 else { return }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setDepthStencilState(compositeDepthState)
        encoder.setCullMode(.none)
        for (i, level) in levels.enumerated() {
            var post = DioramaPostUniforms(matrix: matrix_identity_float4x4, eye: .zero, params: .zero,
                                           blur: SIMD4(0, 0, strength * (i == 0 ? 0.6 : 0.9), 0))
            encoder.setFragmentBytes(&post, length: MemoryLayout<DioramaPostUniforms>.stride, index: 0)
            encoder.setFragmentTexture(level, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }
}
