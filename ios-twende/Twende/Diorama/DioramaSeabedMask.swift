import Metal
import simd

/// Identifies pixels where the native flat floor is visible, preserving nearer native objects.
/// Only those pixels may have their floor depth replaced by the lower diorama seabed.
nonisolated final class DioramaSeabedMask {
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private var texture: MTLTexture?

    init?(device: MTLDevice, library: MTLLibrary, depthFormat: MTLPixelFormat) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "dioramaVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "dioramaSeabedMask")
        descriptor.colorAttachments[0].pixelFormat = .r8Unorm
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.stencilAttachmentPixelFormat = depthFormat
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .lessEqual
        d.isDepthWriteEnabled = false
        guard let state = device.makeDepthStencilState(descriptor: d),
              let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
        depth = state
    }

    func draw(command: MTLCommandBuffer, native: MTLRenderPassDescriptor, vertices: MTLBuffer, indices: MTLBuffer,
              ranges: [DioramaRenderLayer.Range], matrix: simd_float4x4, uniforms: DioramaShaderUniforms, viewport: MTLViewport) -> MTLTexture? {
        guard let output = native.colorAttachments[0].texture, native.depthAttachment.texture != nil else { return nil }
        if texture?.width != output.width || texture?.height != output.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: output.width, height: output.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            texture = output.device.makeTexture(descriptor: d)
        }
        guard let texture else { return nil }
        let inverse = matrix.inverse
        guard inverse.columns.2.z.isFinite, abs(inverse.columns.2.z) > 0.000001 else { return nil }
        // Same screen x/y/w as the seabed, but depth at the ray's intersection with world z=0.
        var flatMatrix = matrix
        for column in 0..<4 {
            flatMatrix[column].z = -(inverse.columns.0.z * matrix[column].x + inverse.columns.1.z * matrix[column].y + inverse.columns.3.z * matrix[column].w) / inverse.columns.2.z
        }
        var constants = uniforms
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = native.depthAttachment.texture
        pass.depthAttachment.loadAction = .load
        pass.depthAttachment.storeAction = .store
        pass.stencilAttachment.texture = native.stencilAttachment.texture
        pass.stencilAttachment.loadAction = .load
        pass.stencilAttachment.storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Diorama native-floor visibility"
        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&flatMatrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setVertexBytes(&constants, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&constants, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
        for range in ranges where range.category == .ground {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        encoder.endEncoding()
        return texture
    }
}
