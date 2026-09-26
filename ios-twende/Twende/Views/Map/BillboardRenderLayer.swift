@_spi(Experimental) import MapboxMaps
import AVFoundation
import CoreVideo
import Metal
import simd

/// Screen-face vertex: metric position plus texture coordinate (xy).
nonisolated struct BillboardVertex {
    let position: SIMD4<Float>
    let uv: SIMD4<Float>
}

/// Draws the two lit faces of a billboard with the current video frame, sharing Mapbox's projection
/// and depth buffer so the screen sits correctly among buildings and behind labels.
nonisolated final class BillboardRenderLayer: NSObject, CustomLayerHost {
    private let origin: CLLocationCoordinate2D
    private let output: AVPlayerItemVideoOutput
    private let vertices: [BillboardVertex]
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var buffer: MTLBuffer?
    private var textureCache: CVMetalTextureCache?
    private var frameTexture: CVMetalTexture?
    private var standby: MTLTexture?

    init(origin: CLLocationCoordinate2D, facingDegrees: Double, output: AVPlayerItemVideoOutput) {
        self.origin = origin
        self.output = output
        let d = BillboardDimensions.self
        let n = d.normal(facingDegrees: facingDegrees)
        let r = d.right(for: n)
        let offset = d.frameDepth / 2 + 0.04
        let bottom = d.screenBottom, top = d.screenBottom + d.screenHeight
        func face(centre: SIMD2<Double>, right: SIMD2<Double>) -> [BillboardVertex] {
            let half = right * (d.screenWidth / 2)
            func v(_ xy: SIMD2<Double>, _ z: Double, _ u: Float, _ w: Float) -> BillboardVertex {
                BillboardVertex(position: SIMD4(Float(xy.x), Float(xy.y), Float(z), 1), uv: SIMD4(u, w, 0, 0))
            }
            let bl = v(centre - half, bottom, 0, 1), br = v(centre + half, bottom, 1, 1)
            let tr = v(centre + half, top, 1, 0), tl = v(centre - half, top, 0, 0)
            return [bl, br, tr, bl, tr, tl]
        }
        // The back face runs right-to-left from its own viewer's side, so video never reads mirrored.
        vertices = face(centre: n * offset, right: r) + face(centre: -n * offset, right: -r)
        super.init()
    }

    func renderingWillStart(_ metalDevice: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        guard let library = BuildingShaderLibrary.library(for: metalDevice),
              let vertex = library.makeFunction(name: "billboardVertex"),
              let fragment = library.makeFunction(name: "billboardFragment"),
              let colorFormat = MTLPixelFormat(rawValue: colorPixelFormat),
              let depthFormat = MTLPixelFormat(rawValue: depthStencilPixelFormat) else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.stencilAttachmentPixelFormat = depthFormat
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        pipeline = try? metalDevice.makeRenderPipelineState(descriptor: descriptor)
        depthState = metalDevice.makeDepthStencilState(descriptor: depth)
        buffer = vertices.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.flatMap {
                metalDevice.makeBuffer(bytes: $0, length: vertices.count * MemoryLayout<BillboardVertex>.stride, options: .storageModeShared)
            }
        }
        CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &textureCache)
        // Dark red standby panel until the first video frame decodes.
        let standbyDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        standby = metalDevice.makeTexture(descriptor: standbyDescriptor)
        var pixel: [UInt8] = [20, 18, 110, 255]
        standby?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let pipeline, let depthState, let buffer,
              let target = mtlRenderPassDescriptor.colorAttachments[0].texture,
              parameters.projectionMatrix.count == 16 else { return }
        refreshFrame()

        var projection = matrix_identity_double4x4
        for column in 0..<4 {
            for row in 0..<4 { projection[column, row] = parameters.projectionMatrix[column * 4 + row].doubleValue }
        }
        let point = Projection.project(origin, zoomScale: CGFloat(pow(2, parameters.zoom)))
        let metresToPixels = 1 / Double(Projection.metersPerPoint(for: origin.latitude, zoom: CGFloat(parameters.zoom)))
        var model = matrix_identity_double4x4
        model[0, 0] = metresToPixels
        model[1, 1] = -metresToPixels
        model[3, 0] = point.x
        model[3, 1] = point.y
        model[3, 2] = parameters.elevationData?.getElevationFor(origin)?.doubleValue ?? 0
        let transform = projection * model
        var matrix = simd_float4x4(columns: (
            SIMD4<Float>(transform.columns.0), SIMD4<Float>(transform.columns.1),
            SIMD4<Float>(transform.columns.2), SIMD4<Float>(transform.columns.3)
        ))
        // Night map styles dim the panel slightly so it glows rather than blinds.
        var tint = SIMD4<Float>(1, 1, 1, 1)

        guard let texture = frameTexture.flatMap(CVMetalTextureGetTexture) ?? standby,
              let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Zuri billboard screen"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height),
                                        znear: Double(parameters.depthRange.min), zfar: Double(parameters.depthRange.max)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    /// Pulls the frame due now from the player and wraps it as a Metal texture without copying.
    private func refreshFrame() {
        guard let textureCache else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixels, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &texture
        )
        if let texture { frameTexture = texture }
    }

    func renderingWillEnd() {
        pipeline = nil
        depthState = nil
        buffer = nil
        frameTexture = nil
        standby = nil
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        textureCache = nil
    }
}
