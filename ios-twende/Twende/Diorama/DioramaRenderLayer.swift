@_spi(Experimental) import MapboxMaps
import Metal
import QuartzCore
import simd

/// Draws one generated diorama tile through Mapbox's custom-layer hook, like the destination building
/// renderer: Mapbox supplies the projection matrix and depth buffer, we supply the triangles. Geometry
/// and the light grid are uploaded once; category visibility and the time-of-day lighting preset change
/// per frame without rebuilding anything.
///
/// Directional shadows are cached. Spatial batches outside the camera frustum never draw;
/// only water/halos blend. There is no planar reflection pass.
nonisolated final class DioramaRenderLayer: NSObject, CustomLayerHost {
    nonisolated struct Range: Codable, Sendable {
        let category: DioramaCategory
        let start: Int
        let count: Int
        var minimum: SIMD3<Float> = SIMD3(repeating: -.greatestFiniteMagnitude)
        var maximum: SIMD3<Float> = SIMD3(repeating: .greatestFiniteMagnitude)
        /// Thin open surfaces (fronds, sails, canopies, sprites) drawn without back-face culling.
        var doubleSided: Bool = false

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

    private let labels: [DioramaBuildingLabel]
    private let displayScale: Float
    private var labelRenderer: DioramaLabelRenderer?
    private let origin: CLLocationCoordinate2D
    private let vertices: [BuildingRenderVertex]
    private let indices: [UInt32]
    private let ranges: [Range]
    private let groups: [DioramaInstanceGroup]
    private let instances: [DioramaInstanceData]
    private var instanceBuffer: MTLBuffer?
    private var instancedPipeline: MTLRenderPipelineState?
    private var instancedGlowPipeline: MTLRenderPipelineState?
    private let lightGrid: DioramaLightGrid
    private let waterHeight: Float
    private let groundImage: DioramaGroundImage?
    private let groundRect: DioramaRect
    private var groundTexture: MTLTexture?
    /// Whether the water animates (false when Reduce Motion is on: waves then freeze mid-roll).
    private let animates: Bool
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var lightBuffer: MTLBuffer?
    private var lightTableBuffer: MTLBuffer?
    private var lightIndexBuffer: MTLBuffer?
    private var pipeline: MTLRenderPipelineState?
    private var glowPipeline: MTLRenderPipelineState?
    private var waterPipeline: MTLRenderPipelineState?
    private var wireframe: Bool = false
    private let shorelineSettings: SIMD4<Float>
    private let waterDeepTint: SIMD4<Float>
    private let waterShallowTint: SIMD4<Float>
    private var reducedEffects: Bool = false
    private var depthState: MTLDepthStencilState?
    private var noWriteDepthState: MTLDepthStencilState?
    private var blankReflection: MTLTexture?
    private var shadowMap: DioramaShadowMap?
    private var postProcess: DioramaPostProcess?
    private let postSettings: (ao: Float, aoRadius: Float, bloom: Float, grade: Float, haze: Float)
    private let lock = NSLock()
    private var visible: Set<DioramaCategory>
    private var timeOfDay: DioramaTimeOfDay
    private var diagnosticText: String = "not started"
    private var reveal: SIMD4<Float> = .zero
    private var labelsReady: Bool = false

    var hasCustomLabels: Bool {
        lock.lock(); defer { lock.unlock() }
        return labelsReady
    }

    func setReveal(_ value: SIMD4<Float>) {
        lock.lock(); reveal = value; lock.unlock()
    }

    init(origin: CLLocationCoordinate2D, vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [Range], groups: [DioramaInstanceGroup] = [], instances: [DioramaInstanceData] = [], lightGrid: DioramaLightGrid, waterHeight: Double, groundImage: DioramaGroundImage?, groundRect: DioramaRect, visible: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay, animates: Bool, config: DioramaConfig = .slipway, labels: [DioramaBuildingLabel] = [], displayScale: Float = 3) {
        self.origin = origin
        self.labels = labels
        self.displayScale = displayScale
        self.vertices = vertices
        self.indices = indices
        self.ranges = ranges
        self.groups = groups
        self.instances = instances
        self.lightGrid = lightGrid
        self.waterHeight = Float(waterHeight)
        self.groundImage = groundImage
        self.groundRect = groundRect
        self.visible = visible
        self.timeOfDay = timeOfDay
        self.animates = animates
        shorelineSettings = SIMD4(Float(config.shallowWaterDistance), Float(config.foamWidth), 0, 0)
        func tint(_ hex: String) -> SIMD4<Float> {
            let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0x17707A
            return SIMD4(Float((rgb >> 16) & 255) / 255, Float((rgb >> 8) & 255) / 255, Float(rgb & 255) / 255, 1)
        }
        waterDeepTint = tint(config.waterDeepColor)
        waterShallowTint = tint(config.waterShallowColor)
        postSettings = (config.ambientOcclusionStrength, config.ambientOcclusionRadius, config.bloomStrength, config.gradeStrength, config.hazeDensity)
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

    func setWireframe(_ enabled: Bool) {
        lock.lock(); wireframe = enabled; lock.unlock()
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
              let instancedVertex = library.makeFunction(name: "dioramaInstancedVertex"),
              let fragment = library.makeFunction(name: "dioramaFragment"),
              let colorFormat = MTLPixelFormat(rawValue: colorPixelFormat),
              let depthFormat = MTLPixelFormat(rawValue: depthStencilPixelFormat) else {
            setDiagnostic("missing geometry or shader resources")
            return
        }
        func descriptor(color: MTLPixelFormat, depth: MTLPixelFormat, stencil: Bool, blended: Bool = false, instanced: Bool = false) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = instanced ? instancedVertex : vertex
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
            waterPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true, blended: true))
            glowPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true, blended: true))
            instancedPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true, instanced: true))
            instancedGlowPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true, blended: true, instanced: true))
            shadowMap = DioramaShadowMap(device: metalDevice, library: library, vertices: vertices, instances: instances)
            postProcess = DioramaPostProcess(device: metalDevice, library: library, colorFormat: colorFormat, depthFormat: depthFormat)
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
            instanceBuffer = upload(instances, fallback: .identity)

            if let groundImage {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: groundImage.size, height: groundImage.size, mipmapped: true)
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .shared
                if let texture = metalDevice.makeTexture(descriptor: descriptor) {
                    groundImage.rgba.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            texture.replace(region: MTLRegionMake2D(0, 0, groundImage.size, groundImage.size), mipmapLevel: 0, withBytes: base, bytesPerRow: groundImage.size * 4)
                        }
                    }
                    if let queue = metalDevice.makeCommandQueue(), let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() {
                        blit.generateMipmaps(for: texture)
                        blit.endEncoding()
                        command.commit()
                    }
                    groundTexture = texture
                }
            }

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
            labelRenderer = DioramaLabelRenderer(device: metalDevice, labels: labels, scale: displayScale, color: colorFormat, depthFormat: depthFormat)
            lock.lock(); labelsReady = labelRenderer != nil; lock.unlock()
            setDiagnostic("ready vertices=\(vertices.count) triangles=\(indices.count / 3) instances=\(instances.count) lights=\(lightGrid.lights.count)")
        } catch {
            setDiagnostic("pipeline creation failed")
            print("[Diorama] render pipeline unavailable")
        }
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
        let wireframe = self.wireframe
        let reveal = self.reveal
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
        // Vertex heights use Mapbox's absolute elevations, with no extra scene lift or scaling.
        // Adding the origin elevation again would lift the sea and double-count the terrain.
        model[3, 2] = 0
        let transform = projection * model
        var matrix = simd_float4x4(columns: (
            SIMD4<Float>(transform.columns.0), SIMD4<Float>(transform.columns.1),
            SIMD4<Float>(transform.columns.2), SIMD4<Float>(transform.columns.3)
        ))
        let mainRanges = drawn.filter { $0.intersects(matrix) }
        let drawnGroups = groups.filter { group in
            guard !group.instances.isEmpty, visible.contains(group.category) else { return false }
            if group.category.isEmissive, !glowOn { return false }
            return Range(category: group.category, start: 0, count: 0, minimum: group.minimum, maximum: group.maximum).intersects(matrix)
        }
        guard !mainRanges.isEmpty || !drawnGroups.isEmpty else { return }
        let eyeH = simd_inverse(transform) * SIMD4<Double>(0, 0, 1, 0)
        guard abs(eyeH.w) > 0.00000001 else { return }
        let eye = SIMD3<Float>(Float(eyeH.x / eyeH.w), Float(eyeH.y / eyeH.w), Float(eyeH.z / eyeH.w))
        guard eye.x.isFinite, eye.y.isFinite, eye.z.isFinite else { return }

        var uniforms = DioramaLighting.uniforms(for: timeOfDay, eye: eye)
        uniforms.reveal = reveal
        uniforms.shoreline = shorelineSettings
        uniforms.shoreline.z = reducedEffects ? 1 : 0
        uniforms.waterDeep = waterDeepTint
        uniforms.waterShallow = waterShallowTint
        uniforms.groundImage = SIMD4<Float>(Float(groundRect.minX), Float(groundRect.minY), Float(1 / max(groundRect.width, 1)), Float(1 / max(groundRect.height, 1)))
        uniforms.lightGrid = SIMD4<Float>(lightGrid.minX, lightGrid.minY, lightGrid.cellSize, Float(lightGrid.cells))
        // Wrapped so the float stays precise however long the map is open; 1.7 s into the cycle when frozen.
        uniforms.params.y = animates && !reducedEffects ? Float((CACurrentMediaTime() - startTime).truncatingRemainder(dividingBy: 3600)) : 1.7

        // Shadows are fitted to what the camera can see: the union of the visible batches, so the
        // 2048 texels cover a street when zoomed in and the whole tile only when zoomed out.
        var viewLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var viewHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for range in mainRanges where range.minimum.x > -.greatestFiniteMagnitude {
            viewLow = simd_min(viewLow, range.minimum); viewHigh = simd_max(viewHigh, range.maximum)
        }
        for group in drawnGroups {
            viewLow = simd_min(viewLow, group.minimum); viewHigh = simd_max(viewHigh, group.maximum)
        }
        let castingGroups = groups.filter { !$0.instances.isEmpty && visible.contains($0.category) && !$0.category.isEmissive }
        if reveal.w < 0.5, let shadowMap, let shadowMatrix = shadowMap.update(command: mtlCommandBuffer, vertices: vertexBuffer, indices: indexBuffer, instances: instanceBuffer,
            ranges: drawn, groups: castingGroups, focus: viewLow.x.isFinite && viewHigh.x > viewLow.x ? (viewLow, viewHigh) : nil,
            sun: SIMD3(uniforms.sunDirection.x, uniforms.sunDirection.y, uniforms.sunDirection.z), preset: timeOfDay) {
            uniforms.shadowMatrix = shadowMatrix
            uniforms.shadowParams = SIMD4(1, 1.0 / 2048.0, 0.00006, 0)
        }

        // Only the real scene: no literal planar reflections or additional water render target.
        uniforms.water = SIMD4<Float>(waterHeight, 0, Float(texture.width), Float(texture.height))

        // Screen-space passes first: occlusion the main pass samples, bloom added at the end.
        // Reduced effects (Low Power, thermal) drop them entirely; geometry is unchanged.
        let effectsOn = !reducedEffects && !wireframe
        let aoStrength: Float = effectsOn ? postSettings.ao : 0
        let bloomStrength: Float = effectsOn && glowOn ? postSettings.bloom : 0
        uniforms.post = SIMD4<Float>(aoStrength, bloomStrength, postSettings.grade, postSettings.haze)
        let lodDistance: Float = 140
        var bloomLevels: [MTLTexture] = []
        if let postProcess, aoStrength > 0 || bloomStrength > 0 {
            bloomLevels = postProcess.encode(
                command: mtlCommandBuffer, targetWidth: texture.width, targetHeight: texture.height,
                vertices: vertexBuffer, indices: indexBuffer, instances: instanceBuffer,
                opaqueRanges: mainRanges.filter { $0.category != .water && $0.category != .propGlow && !$0.category.isEmissive },
                emissiveRanges: mainRanges.filter { $0.category.isEmissive },
                opaqueGroups: drawnGroups.filter { !$0.category.isEmissive },
                emissiveGroups: drawnGroups.filter { $0.category.isEmissive },
                matrix: matrix, uniforms: uniforms, eye: eye,
                aoRadius: postSettings.aoRadius, aoStrength: aoStrength, bloomStrength: bloomStrength, lodDistance: lodDistance)
        }
        if aoStrength > 0, postProcess?.occlusion == nil { uniforms.post.x = 0 }

        guard let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Zuri diorama"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: Double(parameters.depthRange.min), zfar: Double(parameters.depthRange.max)))
        encoder.setRenderPipelineState(pipeline)
        // Geometric winding is counter-clockwise seen from outside; closed meshes cull their backs.
        // Thin double-sided pieces (fronds, sails, canopies) carry appearance.x = 0 and are drawn
        // in a second pass with culling off.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setTriangleFillMode(wireframe ? .lines : .fill)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(lightBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(lightTableBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(lightIndexBuffer, offset: 0, index: 3)
        encoder.setFragmentTexture(blankReflection, index: 0)
        encoder.setFragmentTexture(shadowMap?.texture, index: 1)
        encoder.setFragmentTexture(groundTexture ?? blankReflection, index: 2)
        encoder.setFragmentTexture(postProcess?.occlusion ?? blankReflection, index: 3)
        // Opaque seabed, coral and hulls first; translucent sea then tints submerged geometry.
        // Closed shapes cull their backs; ranges flagged double-sided (fronds, sails) do not.
        var cullMode: MTLCullMode = .back
        func cull(_ doubleSided: Bool) {
            let wanted: MTLCullMode = doubleSided ? .none : .back
            if wanted != cullMode { encoder.setCullMode(wanted); cullMode = wanted }
        }
        let opaqueRanges = mainRanges.filter { $0.category != .water && $0.category != .propGlow }
        encoder.setDepthStencilState(depthState)
        for range in opaqueRanges {
            cull(range.doubleSided)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        // Instanced prototypes: full detail near the eye, light tessellation beyond `lodDistance`.
        func drawGroup(_ group: DioramaInstanceGroup) {
            let centre = (group.minimum + group.maximum) * 0.5
            let far = simd_distance(centre, eye) > lodDistance && group.lightCount > 0
            let start = far ? group.lightStart : group.fullStart
            let count = far ? group.lightCount : group.fullCount
            guard count > 0 else { return }
            cull(group.doubleSided)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: indexBuffer,
                                          indexBufferOffset: start * MemoryLayout<UInt32>.stride, instanceCount: group.instances.count,
                                          baseVertex: 0, baseInstance: group.firstInstance)
        }
        if let instanceBuffer, let instancedPipeline {
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 3)
            encoder.setRenderPipelineState(instancedPipeline)
            for group in drawnGroups where group.category != .propGlow { drawGroup(group) }
        }
        encoder.setDepthStencilState(noWriteDepthState)
        encoder.setRenderPipelineState(waterPipeline ?? pipeline)
        cull(true)
        for range in mainRanges where range.category == .water {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        encoder.setRenderPipelineState(glowPipeline ?? pipeline)
        for range in mainRanges where range.category == .propGlow {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        if let instanceBuffer, let instancedGlowPipeline {
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 3)
            encoder.setRenderPipelineState(instancedGlowPipeline)
            for group in drawnGroups where group.category == .propGlow { drawGroup(group) }
        }
        if !bloomLevels.isEmpty, let postProcess {
            encoder.setTriangleFillMode(.fill)
            postProcess.composite(bloomLevels, into: encoder, strength: bloomStrength)
        }
        if visible.contains(.buildings), !wireframe {
            labelRenderer?.draw(encoder: encoder, matrix: matrix, width: texture.width, height: texture.height, zoom: parameters.zoom, reveal: reveal)
        }
        encoder.endEncoding()
    }

    func renderingWillEnd() {
        pipeline = nil
        glowPipeline = nil
        waterPipeline = nil
        depthState = nil
        noWriteDepthState = nil
        vertexBuffer = nil
        indexBuffer = nil
        instanceBuffer = nil
        instancedPipeline = nil
        instancedGlowPipeline = nil
        lightBuffer = nil
        lightTableBuffer = nil
        lightIndexBuffer = nil
        blankReflection = nil
        groundTexture = nil
        shadowMap = nil
        postProcess = nil
        labelRenderer = nil
        lock.lock(); labelsReady = false; lock.unlock()
    }

    private func setDiagnostic(_ text: String) {
        lock.lock()
        diagnosticText = text
        lock.unlock()
    }
}
