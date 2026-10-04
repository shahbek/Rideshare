@_spi(Experimental) import MapboxMaps
import Metal
import simd

/// Draws one generated diorama tile through Mapbox's custom-layer hook, like the destination building
/// renderer: Mapbox supplies the projection matrix and depth buffer, we supply the triangles. Geometry
/// and the point-light list are uploaded once; category visibility and the time-of-day lighting preset
/// change per frame without rebuilding anything.
nonisolated final class DioramaRenderLayer: NSObject, CustomLayerHost {
    nonisolated struct Range: Sendable {
        let category: DioramaCategory
        let start: Int
        let count: Int
    }

    private let origin: CLLocationCoordinate2D
    private let vertices: [BuildingRenderVertex]
    private let indices: [UInt32]
    private let ranges: [Range]
    private let lights: [DioramaShaderLight]
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var lightBuffer: MTLBuffer?
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var noWriteDepthState: MTLDepthStencilState?
    private let lock = NSLock()
    private var visible: Set<DioramaCategory>
    private var timeOfDay: DioramaTimeOfDay
    private var diagnosticText: String = "not started"

    init(origin: CLLocationCoordinate2D, vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [Range], lights: [DioramaLight], visible: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay) {
        self.origin = origin
        self.vertices = vertices
        self.indices = indices
        self.ranges = ranges
        self.lights = lights.prefix(DioramaShaderSource.maxLights).map {
            DioramaShaderLight(
                position: SIMD4<Float>(Float($0.position.x), Float($0.position.y), Float($0.position.z), Float($0.radius)),
                color: SIMD4<Float>($0.color, $0.intensity)
            )
        }
        self.visible = visible
        self.timeOfDay = timeOfDay
        super.init()
    }

    var diagnostic: String {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticText
    }

    /// Which categories draw; the glow categories additionally need a time of day that shows lights.
    func setVisible(_ categories: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay) {
        lock.lock()
        visible = categories
        self.timeOfDay = timeOfDay
        lock.unlock()
    }

    func renderingWillStart(_ metalDevice: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        guard !vertices.isEmpty, !indices.isEmpty,
              let library = DioramaShaderSource.library(for: metalDevice),
              let vertex = library.makeFunction(name: "dioramaVertex"),
              let fragment = library.makeFunction(name: "dioramaFragment"),
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
        let noWrite = MTLDepthStencilDescriptor()
        noWrite.depthCompareFunction = .lessEqual
        noWrite.isDepthWriteEnabled = false
        do {
            pipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            depthState = metalDevice.makeDepthStencilState(descriptor: depth)
            noWriteDepthState = metalDevice.makeDepthStencilState(descriptor: noWrite)
            // Metal rejects zero-length buffers, so always upload at least one (unused) light slot.
            let lightData = lights.isEmpty ? [DioramaShaderLight(position: .zero, color: .zero)] : lights
            lightBuffer = lightData.withUnsafeBufferPointer { pointer in
                guard let address = pointer.baseAddress else { return nil }
                return metalDevice.makeBuffer(bytes: address, length: lightData.count * MemoryLayout<DioramaShaderLight>.stride, options: .storageModeShared)
            }
            vertexBuffer = vertices.withUnsafeBufferPointer { pointer in
                guard let address = pointer.baseAddress else { return nil }
                return metalDevice.makeBuffer(bytes: address, length: vertices.count * MemoryLayout<BuildingRenderVertex>.stride, options: .storageModeShared)
            }
            indexBuffer = indices.withUnsafeBufferPointer { pointer in
                guard let address = pointer.baseAddress else { return nil }
                return metalDevice.makeBuffer(bytes: address, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
            }
            setDiagnostic("ready vertices=\(vertices.count) triangles=\(indices.count / 3) lights=\(lights.count)")
        } catch {
            setDiagnostic("pipeline creation failed")
            print("[Diorama] render pipeline unavailable")
        }
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let pipeline, let vertexBuffer, let indexBuffer, let lightBuffer, let depthState, let noWriteDepthState,
              let texture = mtlRenderPassDescriptor.colorAttachments[0].texture,
              parameters.projectionMatrix.count == 16 else { return }
        lock.lock()
        let visible = self.visible
        let timeOfDay = self.timeOfDay
        lock.unlock()
        let glowOn = timeOfDay.showsLights
        let drawn = ranges.filter { range in
            guard range.count > 0, visible.contains(range.category) else { return false }
            return range.category.isEmissive ? glowOn : true
        }
        guard !drawn.isEmpty else { return }

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
        let eyeH = simd_inverse(transform) * SIMD4<Double>(0, 0, 1, 0)
        guard abs(eyeH.w) > 0.00000001 else { return }
        let eye = SIMD3<Float>(Float(eyeH.x / eyeH.w), Float(eyeH.y / eyeH.w), Float(eyeH.z / eyeH.w))
        guard eye.x.isFinite, eye.y.isFinite, eye.z.isFinite else { return }
        var uniforms = DioramaLighting.uniforms(for: timeOfDay, eye: eye, lightCount: lights.count)
        guard let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Zuri diorama"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: Double(parameters.depthRange.min), zfar: Double(parameters.depthRange.max)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(lightBuffer, offset: 0, index: 1)
        // Opaque categories first (ranges are emitted in that order), then the translucent halos
        // without depth writes so they never punch holes in each other.
        for range in drawn {
            encoder.setDepthStencilState(range.category == .propGlow ? noWriteDepthState : depthState)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: range.count, indexType: .uint32,
                indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride
            )
        }
        encoder.endEncoding()
    }

    func renderingWillEnd() {
        pipeline = nil
        depthState = nil
        noWriteDepthState = nil
        vertexBuffer = nil
        indexBuffer = nil
        lightBuffer = nil
    }

    private func setDiagnostic(_ text: String) {
        lock.lock()
        diagnosticText = text
        lock.unlock()
    }
}
