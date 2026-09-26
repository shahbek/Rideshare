@_spi(Experimental) import MapboxMaps
import SceneKit
import Metal
import simd

/// Uses Mapbox's Metal projection/depth directly. SceneKit only builds geometry; no second camera or depth conversion.
nonisolated final class BuildingRenderLayer: NSObject, CustomLayerHost {
    private let origin: CLLocationCoordinate2D
    private let vertices: [BuildingRenderVertex]
    private var buffer: MTLBuffer?
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var glowPipeline: MTLRenderPipelineState?
    private var glowDepthState: MTLDepthStencilState?
    private let opaqueVertexCount: Int
    private let diagnosticLock = NSLock()
    private var renderDiagnostic: String = "not started"

    var diagnostic: String {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        return renderDiagnostic
    }

    @MainActor
    init(origin: CLLocationCoordinate2D, scene: SCNScene) {
        self.origin = origin
        let baked = BuildingRenderGeometry.vertices(from: scene)
        let opaque = baked.filter { $0.appearance.w != 3 }
        opaqueVertexCount = opaque.count
        vertices = opaque + baked.filter { $0.appearance.w == 3 }
        super.init()
    }

    func renderingWillStart(_ metalDevice: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        guard !vertices.isEmpty, let library = BuildingShaderLibrary.library(for: metalDevice),
              let vertex = library.makeFunction(name: "buildingMapVertex"),
              let fragment = library.makeFunction(name: "buildingMapFragment"),
              let colorFormat = MTLPixelFormat(rawValue: colorPixelFormat),
              let depthFormat = MTLPixelFormat(rawValue: depthStencilPixelFormat) else {
            setDiagnostic("missing geometry or shader resources")
            return
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.stencilAttachmentPixelFormat = depthFormat
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        do {
            pipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            depthState = metalDevice.makeDepthStencilState(descriptor: depth)
            if opaqueVertexCount < vertices.count {
                // Only the landmark halo uses additive light; opaque structures retain shared depth.
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
                glowPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
                depth.isDepthWriteEnabled = false
                glowDepthState = metalDevice.makeDepthStencilState(descriptor: depth)
            }
            buffer = vertices.withUnsafeBufferPointer { pointer in
                guard let address = pointer.baseAddress else { return nil }
                return metalDevice.makeBuffer(bytes: address, length: vertices.count * MemoryLayout<BuildingRenderVertex>.stride, options: .storageModeShared)
            }
            setDiagnostic("ready vertices=\(vertices.count)")
        } catch {
            setDiagnostic("pipeline creation failed")
            print("[BuildingRenderLayer] Map geometry pipeline unavailable")
        }
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let pipeline, let buffer, let depthState,
              let texture = mtlRenderPassDescriptor.colorAttachments[0].texture,
              parameters.projectionMatrix.count == 16 else { return }
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
        // Multiply global coordinates in double precision before narrowing to a local GPU transform.
        let transform = projection * model
        var matrix = simd_float4x4(columns: (
            SIMD4<Float>(transform.columns.0), SIMD4<Float>(transform.columns.1),
            SIMD4<Float>(transform.columns.2), SIMD4<Float>(transform.columns.3)
        ))
        let eyeH = simd_inverse(transform) * SIMD4<Double>(0, 0, 1, 0)
        guard abs(eyeH.w) > 0.00000001 else { return }
        var eyeAndDetail = SIMD4<Float>(Float(eyeH.x / eyeH.w), Float(eyeH.y / eyeH.w), Float(eyeH.z / eyeH.w), Float(0.65 + 0.35 * max(0, min(1, parameters.zoom - 15.5))))
        guard let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Twende restrained architecture"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: Double(parameters.depthRange.min), zfar: Double(parameters.depthRange.max)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setFragmentBytes(&eyeAndDetail, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: opaqueVertexCount)
        if let glowPipeline, let glowDepthState, opaqueVertexCount < vertices.count {
            encoder.setRenderPipelineState(glowPipeline)
            encoder.setDepthStencilState(glowDepthState)
            encoder.drawPrimitives(type: .triangle, vertexStart: opaqueVertexCount, vertexCount: vertices.count - opaqueVertexCount)
        }
        encoder.endEncoding()
    }

    func renderingWillEnd() {
        pipeline = nil
        buffer = nil
        depthState = nil
        glowPipeline = nil
        glowDepthState = nil
    }

    private func setDiagnostic(_ text: String) {
        diagnosticLock.lock()
        renderDiagnostic = text
        diagnosticLock.unlock()
    }
}
