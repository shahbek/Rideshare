@_spi(Experimental) import MapboxMaps
import Metal
import QuartzCore
import simd

/// Draws one generated diorama tile through Mapbox's custom-layer hook, like the destination building
/// renderer: Mapbox supplies the projection matrix and depth buffer, we supply the triangles. Geometry
/// and the light grid are uploaded once; category visibility and the time-of-day lighting preset change
/// per frame without rebuilding anything.
///
/// Reflection/shadow targets are cached. Spatial batches outside the camera frustum never draw;
/// static content requires no display timer and opaque geometry skips alpha blending.
nonisolated final class DioramaRenderLayer: NSObject, CustomLayerHost {
    nonisolated struct Range: Sendable {
        let category: DioramaCategory
        let start: Int
        let count: Int
        var minimum: SIMD3<Float> = SIMD3(repeating: -.greatestFiniteMagnitude)
        var maximum: SIMD3<Float> = SIMD3(repeating: .greatestFiniteMagnitude)

        func intersects(_ matrix: simd_float4x4, mirrorHeight: Float? = nil) -> Bool {
            guard minimum.x > -.greatestFiniteMagnitude else { return true }
            var outside = [Bool](repeating: true, count: 6)
            for x in [minimum.x, maximum.x] { for y in [minimum.y, maximum.y] { for z in [minimum.z, maximum.z] {
                let height = mirrorHeight.map { 2 * $0 - z } ?? z
                let p = matrix * SIMD4(x, y, height, 1)
                // Near-camera boxes and non-finite projections cannot safely be CPU-rejected.
                guard p.x.isFinite, p.y.isFinite, p.w.isFinite, p.w > 0.00001 else { return true }
                // Mapbox owns depth-range mapping; only reject lateral/behind-camera planes.
                let planes = [p.x < -p.w, p.x > p.w, p.y < -p.w, p.y > p.w, p.w <= 0, false]
                for i in 0..<6 { outside[i] = outside[i] && planes[i] }
            } } }
            return !outside.contains(true)
        }
    }

    private let origin: CLLocationCoordinate2D
    private let vertices: [BuildingRenderVertex]
    private let indices: [UInt32]
    private let ranges: [Range]
    private let lightGrid: DioramaLightGrid
    private let waterHeight: Float
    /// Whether the water animates (false when Reduce Motion is on: waves then freeze mid-roll).
    private let animates: Bool
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var lightBuffer: MTLBuffer?
    private var lightTableBuffer: MTLBuffer?
    private var lightIndexBuffer: MTLBuffer?
    private var pipeline: MTLRenderPipelineState?
    private var reflectionPipeline: MTLRenderPipelineState?
    private var glowPipeline: MTLRenderPipelineState?
    private var reducedEffects: Bool = false
    private var reflectionMatrix: simd_float4x4?
    private var reflectionPreset: DioramaTimeOfDay?
    private var reflectionCategories: Set<DioramaCategory> = []
    private var depthState: MTLDepthStencilState?
    private var noWriteDepthState: MTLDepthStencilState?
    private var reflectionColor: MTLTexture?
    private var reflectionDepth: MTLTexture?
    private var blankReflection: MTLTexture?
    private var shadowMap: DioramaShadowMap?
    private let lock = NSLock()
    private var visible: Set<DioramaCategory>
    private var timeOfDay: DioramaTimeOfDay
    private var diagnosticText: String = "not started"

    /// Reflection renders at this fraction of the screen; ripples hide the softness.
    private let reflectionScale: Int = 4

    init(origin: CLLocationCoordinate2D, vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [Range], lightGrid: DioramaLightGrid, waterHeight: Double, visible: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay, animates: Bool) {
        self.origin = origin
        self.vertices = vertices
        self.indices = indices
        self.ranges = ranges
        self.lightGrid = lightGrid
        self.waterHeight = Float(waterHeight)
        self.visible = visible
        self.timeOfDay = timeOfDay
        self.animates = animates
        super.init()
    }

    var diagnostic: String {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticText
    }

    func setVisible(_ categories: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay) {
        lock.lock()
        visible = categories
        self.timeOfDay = timeOfDay
        lock.unlock()
    }

    func setReducedEffects(_ reduced: Bool) {
        lock.lock()
        reducedEffects = reduced
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
        func descriptor(color: MTLPixelFormat, depth: MTLPixelFormat, stencil: Bool, blended: Bool = false) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vertex
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = color
            d.colorAttachments[0].isBlendingEnabled = blended
            d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = depth
            if stencil { d.stencilAttachmentPixelFormat = depth }
            return d
        }
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        let noWrite = MTLDepthStencilDescriptor()
        noWrite.depthCompareFunction = .lessEqual
        noWrite.isDepthWriteEnabled = false
        do {
            pipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true))
            glowPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true, blended: true))
            reflectionPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor(color: .bgra8Unorm, depth: .depth32Float, stencil: false))
            shadowMap = DioramaShadowMap(device: metalDevice, library: library, vertices: vertices)
            depthState = metalDevice.makeDepthStencilState(descriptor: depth)
            noWriteDepthState = metalDevice.makeDepthStencilState(descriptor: noWrite)

            func upload<T>(_ items: [T], fallback: T) -> MTLBuffer? {
                // Metal rejects zero-length buffers, so always upload at least one slot.
                let data = items.isEmpty ? [fallback] : items
                return data.withUnsafeBufferPointer { pointer in
                    guard let address = pointer.baseAddress else { return nil }
                    return metalDevice.makeBuffer(bytes: address, length: data.count * MemoryLayout<T>.stride, options: .storageModeShared)
                }
            }
            lightBuffer = upload(lightGrid.lights, fallback: DioramaShaderLight(position: .zero, color: .zero))
            lightTableBuffer = upload(lightGrid.table, fallback: SIMD2<UInt32>(0, 0))
            lightIndexBuffer = upload(lightGrid.indices, fallback: UInt32(0))
            vertexBuffer = upload(vertices, fallback: vertices[0])
            indexBuffer = upload(indices, fallback: 0)

            let blank = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
            blank.usage = [.shaderRead]
            blankReflection = metalDevice.makeTexture(descriptor: blank)
            if let blankReflection {
                var zeros = [UInt8](repeating: 0, count: 4 * 4 * 4)
                zeros.withUnsafeMutableBytes { bytes in
                    if let base = bytes.baseAddress {
                        blankReflection.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: base, bytesPerRow: 16)
                    }
                }
            }
            setDiagnostic("ready vertices=\(vertices.count) triangles=\(indices.count / 3) lights=\(lightGrid.lights.count)")
        } catch {
            setDiagnostic("pipeline creation failed")
            print("[Diorama] render pipeline unavailable")
        }
    }

    private func ensureReflectionTargets(_ device: MTLDevice, width: Int, height: Int) {
        let w = max(width / reflectionScale, 8), h = max(height / reflectionScale, 8)
        if let reflectionColor, reflectionColor.width == w, reflectionColor.height == h { return }
        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        depth.usage = [.renderTarget]
        depth.storageMode = .private
        reflectionMatrix = nil
        reflectionColor = device.makeTexture(descriptor: color)
        reflectionDepth = device.makeTexture(descriptor: depth)
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let pipeline, let vertexBuffer, let indexBuffer, let lightBuffer, let lightTableBuffer, let lightIndexBuffer,
              let depthState, let noWriteDepthState,
              let texture = mtlRenderPassDescriptor.colorAttachments[0].texture,
              parameters.projectionMatrix.count == 16 else { return }
        lock.lock()
        let visible = self.visible
        let timeOfDay = self.timeOfDay
        let reducedEffects = self.reducedEffects
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
        // Vertex heights already include absolute DEM elevation and exaggeration.
        // Adding the origin elevation again would lift the sea and double-count the terrain.
        model[3, 2] = 0
        let transform = projection * model
        var matrix = simd_float4x4(columns: (
            SIMD4<Float>(transform.columns.0), SIMD4<Float>(transform.columns.1),
            SIMD4<Float>(transform.columns.2), SIMD4<Float>(transform.columns.3)
        ))
        let mainRanges = drawn.filter { $0.intersects(matrix) }
        guard !mainRanges.isEmpty else { return }
        let eyeH = simd_inverse(transform) * SIMD4<Double>(0, 0, 1, 0)
        guard abs(eyeH.w) > 0.00000001 else { return }
        let eye = SIMD3<Float>(Float(eyeH.x / eyeH.w), Float(eyeH.y / eyeH.w), Float(eyeH.z / eyeH.w))
        guard eye.x.isFinite, eye.y.isFinite, eye.z.isFinite else { return }

        var uniforms = DioramaLighting.uniforms(for: timeOfDay, eye: eye)
        uniforms.lightGrid = SIMD4<Float>(lightGrid.minX, lightGrid.minY, lightGrid.cellSize, Float(lightGrid.cells))
        // Wrapped so the float stays precise however long the map is open; 1.7 s into the cycle when frozen.
        uniforms.params.y = animates ? Float((CACurrentMediaTime() - startTime).truncatingRemainder(dividingBy: 3600)) : 1.7

        if let shadowMap, let shadowMatrix = shadowMap.update(command: mtlCommandBuffer, vertices: vertexBuffer, indices: indexBuffer, ranges: drawn,
            sun: SIMD3(uniforms.sunDirection.x, uniforms.sunDirection.y, uniforms.sunDirection.z), preset: timeOfDay) {
            uniforms.shadowMatrix = shadowMatrix
            uniforms.shadowParams = SIMD4(1, 1.0 / 2048.0, 0.00006, 0)
        }

        let wantsReflection = !reducedEffects && mainRanges.contains { $0.category == .water }
        var reflectionTexture: MTLTexture? = blankReflection
        if wantsReflection {
            ensureReflectionTargets(mtlCommandBuffer.device, width: texture.width, height: texture.height)
        }
        let reflectionDirty = reflectionMatrix != matrix || reflectionPreset != timeOfDay || reflectionCategories != visible
        if wantsReflection && !reflectionDirty { reflectionTexture = reflectionColor }

        // Reuse the static reflection until camera, lighting, visibility or target size changes.
        if wantsReflection, reflectionDirty, let reflectionPipeline {
            if let color = reflectionColor, let depth = reflectionDepth {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = color
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.depthAttachment.texture = depth
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .dontCare
                pass.depthAttachment.clearDepth = 1
                if let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                    var mirrored = uniforms
                    mirrored.params.w = 1
                    mirrored.water = SIMD4<Float>(waterHeight, 1, Float(color.width), Float(color.height))
                    encoder.label = "Zuri diorama reflection"
                    encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(color.width), height: Double(color.height), znear: 0, zfar: 1))
                    encoder.setRenderPipelineState(reflectionPipeline)
                    encoder.setCullMode(.none)
                    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                    encoder.setVertexBytes(&mirrored, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
                    encoder.setFragmentBytes(&mirrored, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
                    encoder.setFragmentBuffer(lightBuffer, offset: 0, index: 1)
                    encoder.setFragmentBuffer(lightTableBuffer, offset: 0, index: 2)
                    encoder.setFragmentBuffer(lightIndexBuffer, offset: 0, index: 3)
                    encoder.setFragmentTexture(blankReflection, index: 0)
                    encoder.setFragmentTexture(shadowMap?.texture, index: 1)
                    for range in drawn where range.category != .water && range.category != .ground && range.category != .propGlow && range.intersects(matrix, mirrorHeight: waterHeight) {
                        encoder.setDepthStencilState(range.category == .propGlow ? noWriteDepthState : depthState)
                        encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
                    }
                    encoder.endEncoding()
                    reflectionTexture = color
                    reflectionMatrix = matrix
                    reflectionPreset = timeOfDay
                    reflectionCategories = visible
                }
            }
        }

        // Pass 2: the real scene into Mapbox's frame.
        uniforms.water = SIMD4<Float>(waterHeight, 0, Float(texture.width), Float(texture.height))
        guard let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Zuri diorama"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: Double(parameters.depthRange.min), zfar: Double(parameters.depthRange.max)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(lightBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(lightTableBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(lightIndexBuffer, offset: 0, index: 3)
        encoder.setFragmentTexture(reflectionTexture, index: 0)
        encoder.setFragmentTexture(shadowMap?.texture, index: 1)
        for range in mainRanges {
            encoder.setRenderPipelineState(range.category == .propGlow ? (glowPipeline ?? pipeline) : pipeline)
            encoder.setDepthStencilState(range.category == .propGlow ? noWriteDepthState : depthState)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        encoder.endEncoding()
    }

    func renderingWillEnd() {
        pipeline = nil
        reflectionPipeline = nil
        glowPipeline = nil
        reflectionMatrix = nil
        reflectionPreset = nil
        reflectionCategories = []
        depthState = nil
        noWriteDepthState = nil
        vertexBuffer = nil
        indexBuffer = nil
        lightBuffer = nil
        lightTableBuffer = nil
        lightIndexBuffer = nil
        reflectionColor = nil
        reflectionDepth = nil
        blankReflection = nil
        shadowMap = nil
    }

    private func setDiagnostic(_ text: String) {
        lock.lock()
        diagnosticText = text
        lock.unlock()
    }
}
