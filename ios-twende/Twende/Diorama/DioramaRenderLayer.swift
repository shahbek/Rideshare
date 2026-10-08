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
/// permanent exposed tile edges blend at rest; paired full/coarse coverage owns disjoint pixels.
/// Water samples a cached,
/// reduced-resolution reflected scene.
nonisolated final class DioramaRenderLayer: NSObject, CustomLayerHost {
    nonisolated struct Range: Sendable {
        let category: DioramaCategory
        let start: Int
        let count: Int
        var minimum: SIMD3<Float> = SIMD3(repeating: -.greatestFiniteMagnitude)
        var maximum: SIMD3<Float> = SIMD3(repeating: .greatestFiniteMagnitude)
        /// Thin open surfaces (fronds, sails, canopies, sprites) drawn without back-face culling.
        var doubleSided: Bool = false

        /// Reject only boxes wholly behind the reveal front; crossing geometry still uses fragment clipping.
        func intersectsReveal(_ reveal: SIMD4<Float>) -> Bool {
            guard reveal.w > 0.5, minimum.x > -.greatestFiniteMagnitude,
                  minimum.x.isFinite, minimum.y.isFinite, maximum.x.isFinite, maximum.y.isFinite,
                  reveal.x.isFinite, reveal.y.isFinite, reveal.z.isFinite else { return true }
            let margin: Float = DioramaRevealStyle.support + 0.02
            if reveal.w > 1.5 {
                let x0 = reveal.x * minimum.x, x1 = reveal.x * maximum.x
                let y0 = reveal.y * minimum.y, y1 = reveal.y * maximum.y
                return reveal.w > 2.5
                    ? max(x0, x1) + max(y0, y1) >= reveal.z - margin
                    : min(x0, x1) + min(y0, y1) <= reveal.z + margin
            }
            return maximum.x >= reveal.x - reveal.z - margin && minimum.x <= reveal.x + reveal.z + margin
                && maximum.y >= reveal.y - reveal.z - margin && minimum.y <= reveal.y + reveal.z + margin
        }

        func intersects(_ matrix: simd_float4x4, mirrorHeight: Float? = nil) -> Bool {
            guard minimum.x > -.greatestFiniteMagnitude else { return true }
            var outside: UInt8 = 15
            for corner in 0..<8 {
                let x = corner & 4 == 0 ? minimum.x : maximum.x
                let y = corner & 2 == 0 ? minimum.y : maximum.y
                let z = corner & 1 == 0 ? minimum.z : maximum.z
                let height = mirrorHeight.map { 2 * $0 - z } ?? z
                let p = matrix * SIMD4(x, y, height, 1)
                // Near-camera boxes and non-finite projections cannot safely be CPU-rejected.
                guard p.x.isFinite, p.y.isFinite, p.w.isFinite, p.w > 0.00001 else { return true }
                // Mapbox owns depth-range mapping; only reject lateral/behind-camera planes.
                var mask: UInt8 = 0
                if p.x < -p.w { mask |= 1 }
                if p.x > p.w { mask |= 2 }
                if p.y < -p.w { mask |= 4 }
                if p.y > p.w { mask |= 8 }
                outside &= mask
                if outside == 0 { return true }
            }
            return outside == 0
        }
    }

    /// Immutable rendered XY envelope, including prototype/structure overhangs beyond the tile.
    let revealBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)

    private let groundQueryLock = NSLock()
    private var cameraGround = DioramaCameraGround()

    /// Resident CPU buffers are immutable; this tiny query cache is independent of the render thread.
    func groundHeight(at point: GeoPoint) -> Double? {
        let local = DioramaProjection(origin: origin).local(longitude: point.longitude, latitude: point.latitude)
        guard groundRect.contains(local) else { return nil }
        groundQueryLock.lock(); defer { groundQueryLock.unlock() }
        return cameraGround.height(local, vertices: vertices, indices: indices, ranges: ranges)
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
    private let poolBounds: Range?
    private let groundImage: DioramaGroundImage?
    private let groundRect: DioramaRect
    private let materialFrame: SIMD4<Float>
    private var groundTexture: MTLTexture?
    private var surfaceTexture: MTLTexture?
    private var paintBuffer: MTLBuffer?
    private var paintTableBuffer: MTLBuffer?
    private var paintIndexBuffer: MTLBuffer?
    private var reflectionPass: DioramaReflection?
    /// Whether the water animates (false when Reduce Motion is on: waves then freeze mid-roll).
    private let contextOnly: Bool
    private let animates: Bool
    private var waterMotionEnabled: Bool = true
    private var waterInView: Bool = false
    private var loggedCameraFallback: Bool = false
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
    private var completedReveal: SIMD4<Float>?
    private var lifecycleReveal: SIMD4<Float> = .zero
    private var completedLifecycleReveal: SIMD4<Float>?
    private var tileEdges: SIMD4<Float> = SIMD4(repeating: 1)
    private var tileState: SIMD4<Float> = SIMD4(1, 0, 0, 0)

    var hasWaterInView: Bool {
        lock.lock(); defer { lock.unlock() }
        return waterInView
    }

    func setWaterMotion(_ enabled: Bool) {
        lock.lock(); waterMotionEnabled = enabled; lock.unlock()
    }

    func setTileCoverage(edges: SIMD4<Float>, role: Float, paired: Bool) {
        lock.lock()
        tileEdges = edges
        tileState = SIMD4(1, role, 0, paired ? 1 : 0)
        lock.unlock()
    }

    func setLifecycleReveal(_ value: SIMD4<Float>) {
        lock.lock(); lifecycleReveal = value; lock.unlock()
    }

    func hasCompletedLifecycle(_ value: SIMD4<Float>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return completedLifecycleReveal == value
    }

    /// GPU completion, not a claim that the drawable has reached the display.
    func hasCompleted(reveal value: SIMD4<Float>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return completedReveal == value
    }

    private func didComplete(_ value: SIMD4<Float>, lifecycle: SIMD4<Float>) {
        lock.lock(); completedReveal = value; completedLifecycleReveal = lifecycle; lock.unlock()
    }
    private var labelsReady: Bool = false
    private var acceptedLabels: Set<UInt64> = []
    var onLabelsChanged: (@Sendable (Set<UInt64>) -> Void)?
    var onFrameReport: (@Sendable (String) -> Void)?
    private let frameMetrics = DioramaFrameMetrics()
    // Render-thread-only preparation cache. Water/reveal uniforms still update every frame.
    private var selectionVisible: Set<DioramaCategory>?
    private var selectionGlow: Bool = false
    private var eligibleRanges: [Range] = []
    private var eligibleGroups: [DioramaInstanceGroup] = []
    private var eligibleCasters: [DioramaInstanceGroup] = []
    private var selectionTransform: simd_double4x4?
    private var selectedReveal: SIMD4<Float>?
    private var selectedLifecycle: SIMD4<Float>?
    private var selectedEdges: SIMD4<Float>?
    private var selectedTileState: SIMD4<Float>?
    private var drawRevision: UInt64 = 0
    private var cameraRanges: [Range] = []
    private var cameraGroups: [DioramaInstanceGroup] = []
    private var selectedRanges: [Range] = []
    private var selectedGroups: [DioramaInstanceGroup] = []
    private var selectedRangeDraws: [Range] = []
    private var selectedInstanceDraws: [DioramaDrawPlan.Instance] = []

    private func publishLabels(_ ids: Set<UInt64>) {
        lock.lock()
        let changed = acceptedLabels != ids
        acceptedLabels = ids
        lock.unlock()
        if changed { onLabelsChanged?(ids) }
    }

    var hasCustomLabels: Bool {
        lock.lock(); defer { lock.unlock() }
        return labelsReady
    }

    func setReveal(_ value: SIMD4<Float>) {
        lock.lock(); reveal = value; lock.unlock()
    }

    init(origin: CLLocationCoordinate2D, vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [Range], groups: [DioramaInstanceGroup] = [], instances: [DioramaInstanceData] = [], lightGrid: DioramaLightGrid, waterHeight: Double, groundImage: DioramaGroundImage?, groundRect: DioramaRect, visible: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay, animates: Bool, config: DioramaConfig = .slipway, labels: [DioramaBuildingLabel] = [], displayScale: Float = 3, contextOnly: Bool = false) {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for range in ranges where range.minimum.x > -.greatestFiniteMagnitude && range.minimum.x.isFinite && range.maximum.x.isFinite {
            low = simd_min(low, range.minimum); high = simd_max(high, range.maximum)
        }
        for group in groups {
            low = simd_min(low, group.minimum); high = simd_max(high, group.maximum)
        }
        revealBounds = low.x < high.x ? (low, high) : (SIMD3(Float(groundRect.minX), Float(groundRect.minY), 0), SIMD3(Float(groundRect.maxX), Float(groundRect.maxY), 0))
        self.contextOnly = contextOnly
        tileState.y = contextOnly ? 0 : 1
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
        var poolLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var poolHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for vertex in vertices where vertex.appearance.y > 4.5 && vertex.appearance.y < 5.5 && vertex.appearance.w < 0.5 {
            let p = SIMD3(vertex.position.x, vertex.position.y, vertex.position.z)
            poolLow = simd_min(poolLow, p); poolHigh = simd_max(poolHigh, p)
        }
        poolBounds = poolLow.x <= poolHigh.x ? Range(category: .water, start: 0, count: 0, minimum: poolLow, maximum: poolHigh) : nil
        self.groundImage = groundImage
        self.groundRect = groundRect
        let referenceLatitude = -6.75
        let reference = DioramaProjection(origin: CLLocationCoordinate2D(latitude: referenceLatitude, longitude: 39.28))
        let offset = reference.local(longitude: origin.longitude, latitude: origin.latitude)
        materialFrame = SIMD4(Float(offset.x), Float(offset.y), Float(cos(referenceLatitude * .pi / 180) / cos(origin.latitude * .pi / 180)), 0)
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
            pipeline = try DioramaPipelineCache.shared.state(device: metalDevice, descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true))
            waterPipeline = try DioramaPipelineCache.shared.state(device: metalDevice, descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true, blended: true))
            glowPipeline = waterPipeline
            instancedPipeline = try DioramaPipelineCache.shared.state(device: metalDevice, descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true, instanced: true))
            instancedGlowPipeline = try DioramaPipelineCache.shared.state(device: metalDevice, descriptor: descriptor(color: colorFormat, depth: depthFormat, stencil: true, blended: true, instanced: true))
            if !contextOnly {
                reflectionPass = DioramaReflection(device: metalDevice, library: library)
                shadowMap = DioramaShadowMap(device: metalDevice, library: library, vertices: vertices, instances: instances)
                postProcess = DioramaPostProcess(device: metalDevice, library: library, colorFormat: colorFormat, depthFormat: depthFormat)
            }
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
            surfaceTexture = DioramaSurfaceTexture.texture(device: metalDevice)
            lightBuffer = upload(lightGrid.lights, fallback: DioramaShaderLight(position: .zero, color: .zero))
            lightTableBuffer = upload(lightGrid.table, fallback: SIMD2<UInt32>(0, 0))
            lightIndexBuffer = upload(lightGrid.indices, fallback: UInt32(0))
            let materialUpload = DioramaLegacyFoliageMaterial.tagged(vertices, indices: indices, ranges: ranges, groups: groups)
            vertexBuffer = upload(materialUpload.vertices, fallback: vertices[0])
            #if DEBUG
            print("[Diorama material] legacy_foliage_vertices=\(materialUpload.count) legacy_architecture_vertices=\(materialUpload.architectureCount) preset=\(timeOfDay.rawValue) color_format=\(colorPixelFormat) natural_finish=coverage-v2 reveal=persistent-v2 vegetation=savanna-v4")
            #endif
            indexBuffer = upload(indices, fallback: 0)
            instanceBuffer = upload(instances, fallback: .identity)
            let paint = groundImage?.paint ?? DioramaVectorPaint()
            paintBuffer = upload(paint.triangles, fallback: DioramaPaintTriangle.empty)
            paintTableBuffer = upload(paint.table, fallback: SIMD2<UInt32>(0, 0))
            paintIndexBuffer = upload(paint.indices, fallback: UInt32(0))

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
              let depthState, let noWriteDepthState, let paintBuffer, let paintTableBuffer, let paintIndexBuffer,
              let texture = mtlRenderPassDescriptor.colorAttachments[0].texture,
              parameters.projectionMatrix.count == 16 else { publishLabels([]); return }
        lock.lock()
        let visible = self.visible
        let timeOfDay = self.timeOfDay
        let reducedEffects = self.reducedEffects
        let wireframe = self.wireframe
        let reveal = self.reveal
        let lifecycleReveal = self.lifecycleReveal
        let tileEdges = self.tileEdges
        let tileState = self.tileState
        let waterMotionEnabled = self.waterMotionEnabled
        waterInView = false
        lock.unlock()
        let encodeStarted = CACurrentMediaTime()
        let glowOn = timeOfDay.showsLights
        if selectionVisible != visible || selectionGlow != glowOn {
            eligibleRanges = ranges.filter { $0.count > 0 && visible.contains($0.category) && (!$0.category.isEmissive || glowOn) }
            eligibleGroups = groups.filter { !$0.instances.isEmpty && visible.contains($0.category) && (!$0.category.isEmissive || glowOn) }
            eligibleCasters = eligibleGroups.filter { !$0.category.isEmissive }
            selectionVisible = visible; selectionGlow = glowOn; selectionTransform = nil
        }
        let drawn = eligibleRanges
        guard !drawn.isEmpty || !eligibleGroups.isEmpty else {
            publishLabels([])
            mtlCommandBuffer.addCompletedHandler { [weak self] command in
                if command.status == .completed { self?.didComplete(reveal, lifecycle: lifecycleReveal) }
            }
            return
        }

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
        let selectionChanged = selectionTransform != transform
        if selectionChanged {
            cameraRanges = drawn.filter { $0.intersects(matrix) }
            cameraGroups = eligibleGroups.filter { group in
                Range(category: group.category, start: 0, count: 0, minimum: group.minimum, maximum: group.maximum).intersects(matrix)
            }
            selectionTransform = transform
        }
        let planChanged = selectionChanged || selectedReveal != reveal || selectedLifecycle != lifecycleReveal
            || selectedEdges != tileEdges || selectedTileState != tileState
        if planChanged {
            let selectionMask = tileState.y > 1.5 ? SIMD4<Float>.zero : reveal
            selectedRanges = cameraRanges.filter { $0.intersectsReveal(selectionMask) && $0.intersectsReveal(lifecycleReveal) }
            selectedGroups = cameraGroups.filter { group in
                let bounds = Range(category: group.category, start: 0, count: 0, minimum: group.minimum, maximum: group.maximum)
                return bounds.intersectsReveal(selectionMask) && bounds.intersectsReveal(lifecycleReveal)
            }
            selectedReveal = reveal
            selectedLifecycle = lifecycleReveal
            selectedEdges = tileEdges
            selectedTileState = tileState
            drawRevision &+= 1
        }
        let mainRanges = selectedRanges
        let drawnGroups = selectedGroups
        guard !mainRanges.isEmpty || !drawnGroups.isEmpty else {
            publishLabels([])
            mtlCommandBuffer.addCompletedHandler { [weak self] command in
                if command.status == .completed { self?.didComplete(reveal, lifecycle: lifecycleReveal) }
            }
            return
        }
        let cameraEye = MapRenderCamera.eye(transform: transform, parameters: parameters, origin: origin)
        let eye = cameraEye.position
        #if DEBUG
        if cameraEye.usedFallback && !loggedCameraFallback {
            loggedCameraFallback = true
            print("[Diorama camera] finite-eye fallback pitch=\(parameters.pitch) depth=\(parameters.depthRange.min)…\(parameters.depthRange.max)")
        }
        #endif
        let poolVisible = visible.contains(.props) && poolBounds?.intersects(matrix) == true
            && poolBounds?.intersectsReveal(lifecycleReveal) == true
        lock.lock(); waterInView = mainRanges.contains { $0.category == .water } || poolVisible; lock.unlock()

        var uniforms = DioramaLighting.uniforms(for: timeOfDay, eye: eye)
        uniforms.groundColor.w = surfaceTexture == nil ? 0 : 1
        uniforms.reveal = reveal
        uniforms.lifecycleReveal = lifecycleReveal
        uniforms.tileBounds = SIMD4(Float(groundRect.minX), Float(groundRect.minY), Float(groundRect.maxX), Float(groundRect.maxY))
        uniforms.tileEdges = tileEdges
        uniforms.tileState = tileState
        uniforms.shoreline = shorelineSettings
        uniforms.shoreline.z = reducedEffects ? 1 : 0
        uniforms.shoreline.w = contextOnly ? 1 : 0
        uniforms.waterDeep = waterDeepTint
        uniforms.waterShallow = waterShallowTint
        uniforms.groundImage = SIMD4<Float>(Float(groundRect.minX), Float(groundRect.minY), Float(1 / max(groundRect.width, 1)), Float(1 / max(groundRect.height, 1)))
        uniforms.materialFrame = materialFrame
        uniforms.lightGrid = SIMD4<Float>(lightGrid.minX, lightGrid.minY, lightGrid.cellSize, Float(lightGrid.cells))
        // Wrapped so the float stays precise however long the map is open; 1.7 s into the cycle when frozen.
        uniforms.params.y = animates && waterMotionEnabled && !reducedEffects ? Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 3600)) : 1.7

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
        let castingGroups = eligibleCasters
        if reveal.w < 0.5, lifecycleReveal.w < 0.5, let shadowMap, let shadowMatrix = shadowMap.update(command: mtlCommandBuffer, vertices: vertexBuffer, indices: indexBuffer, instances: instanceBuffer,
            ranges: drawn, groups: castingGroups, focus: viewLow.x.isFinite && viewHigh.x > viewLow.x ? (viewLow, viewHigh) : nil,
            sun: SIMD3(uniforms.sunDirection.x, uniforms.sunDirection.y, uniforms.sunDirection.z), preset: timeOfDay) {
            uniforms.shadowMatrix = shadowMatrix
            uniforms.shadowParams = SIMD4(1, 1.0 / 2048.0, 0.00006, timeOfDay == .day ? 0.65 : 0.85)
        }

        uniforms.water = SIMD4<Float>(waterHeight, 0, Float(texture.width), Float(texture.height))
        var reflected: MTLTexture?
        if !reducedEffects, !wireframe, mainRanges.contains(where: { $0.category == .water }), let reflectionPass {
            let reflectionGroups = eligibleGroups
            reflected = reflectionPass.encode(command: mtlCommandBuffer, width: texture.width, height: texture.height,
                depthRange: (Double(parameters.depthRange.min), Double(parameters.depthRange.max)), matrix: matrix, uniforms: uniforms,
                signature: timeOfDay.rawValue + visible.map(\.rawValue).sorted().joined(),
                vertices: vertexBuffer, indices: indexBuffer, instances: instanceBuffer,
                fragmentBuffers: [lightBuffer, lightTableBuffer, lightIndexBuffer, paintBuffer, paintTableBuffer, paintIndexBuffer],
                textures: [blankReflection, shadowMap?.texture, groundTexture ?? blankReflection, blankReflection, surfaceTexture ?? blankReflection], ranges: drawn, groups: reflectionGroups)
        }
        uniforms.water.y = reflected == nil ? 0 : 1

        // Screen-space passes first: occlusion the main pass samples, bloom added at the end.
        // Reduced effects (Low Power, thermal) drop them entirely; geometry is unchanged.
        let effectsOn = !reducedEffects && !wireframe
        let hasOpaque = mainRanges.contains { $0.category != .water && !$0.category.isEmissive }
            || drawnGroups.contains { !$0.category.isEmissive }
        let hasEmission = mainRanges.contains { $0.category.isEmissive } || drawnGroups.contains { $0.category.isEmissive }
        let aoStrength: Float = effectsOn && hasOpaque ? postSettings.ao : 0
        let bloomStrength: Float = effectsOn && glowOn && hasEmission ? postSettings.bloom : 0
        uniforms.post = SIMD4<Float>(aoStrength, bloomStrength, postSettings.grade, postSettings.haze)
        let lodDistance: Float = 140
        if planChanged {
            selectedRangeDraws = DioramaDrawPlan.ranges(mainRanges)
            selectedInstanceDraws = DioramaDrawPlan.instances(drawnGroups, eye: eye, lodDistance: lodDistance)
            selectionTransform = transform
        }
        let submittedRanges = selectedRangeDraws
        let submittedGroups = selectedInstanceDraws
        var bloomLevels: [MTLTexture] = []
        if let postProcess, aoStrength > 0 || bloomStrength > 0 {
            bloomLevels = postProcess.encode(
                command: mtlCommandBuffer, targetWidth: texture.width, targetHeight: texture.height,
                vertices: vertexBuffer, indices: indexBuffer, instances: instanceBuffer,
                opaqueRanges: submittedRanges.filter { $0.category != .water && $0.category != .propGlow && !$0.category.isEmissive },
                emissiveRanges: submittedRanges.filter { $0.category.isEmissive },
                opaqueGroups: submittedGroups.filter { !$0.category.isEmissive },
                emissiveGroups: submittedGroups.filter { $0.category.isEmissive },
                matrix: matrix, uniforms: uniforms, eye: eye,
                aoRadius: postSettings.aoRadius, aoStrength: aoStrength, bloomStrength: bloomStrength, lodDistance: lodDistance,
                revision: drawRevision)
        }
        if aoStrength > 0, postProcess?.occlusion == nil { uniforms.post.x = 0 }

        guard let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Zuri diorama"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: Double(parameters.depthRange.min), zfar: Double(parameters.depthRange.max)))
        encoder.setRenderPipelineState(waterPipeline ?? pipeline)
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
        encoder.setFragmentBuffer(paintBuffer, offset: 0, index: 4)
        encoder.setFragmentBuffer(paintTableBuffer, offset: 0, index: 5)
        encoder.setFragmentBuffer(paintIndexBuffer, offset: 0, index: 6)
        encoder.setFragmentTexture(reflected ?? blankReflection, index: 0)
        encoder.setFragmentTexture(shadowMap?.texture, index: 1)
        encoder.setFragmentTexture(groundTexture ?? blankReflection, index: 2)
        encoder.setFragmentTexture(postProcess?.occlusion ?? blankReflection, index: 3)
        encoder.setFragmentTexture(surfaceTexture ?? blankReflection, index: 4)
        // Opaque seabed, coral and hulls first; translucent sea then tints submerged geometry.
        // Closed shapes cull their backs; ranges flagged double-sided (fronds, sails) do not.
        var cullMode: MTLCullMode = .back
        func cull(_ doubleSided: Bool) {
            let wanted: MTLCullMode = doubleSided ? .none : .back
            if wanted != cullMode { encoder.setCullMode(wanted); cullMode = wanted }
        }
        let opaqueRanges = submittedRanges.filter { $0.category != .water && $0.category != .propGlow }
        encoder.setDepthStencilState(depthState)
        for range in opaqueRanges {
            cull(range.doubleSided)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        // Instanced prototypes: full detail near the eye, light tessellation beyond `lodDistance`.
        func drawGroup(_ group: DioramaDrawPlan.Instance) {
            let start = group.start
            let count = group.count
            cull(group.doubleSided)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: indexBuffer,
                                          indexBufferOffset: start * MemoryLayout<UInt32>.stride, instanceCount: group.instanceCount,
                                          baseVertex: 0, baseInstance: group.firstInstance)
        }
        if let instanceBuffer, let instancedPipeline {
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 3)
            encoder.setRenderPipelineState(instancedGlowPipeline ?? instancedPipeline)
            for group in submittedGroups where group.category != .propGlow { drawGroup(group) }
        }
        encoder.setDepthStencilState(noWriteDepthState)
        encoder.setRenderPipelineState(waterPipeline ?? pipeline)
        cull(true)
        for range in submittedRanges where range.category == .water {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        encoder.setRenderPipelineState(glowPipeline ?? pipeline)
        for range in submittedRanges where range.category == .propGlow {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        if let instanceBuffer, let instancedGlowPipeline {
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 3)
            encoder.setRenderPipelineState(instancedGlowPipeline)
            for group in submittedGroups where group.category == .propGlow { drawGroup(group) }
        }
        if !bloomLevels.isEmpty, let postProcess {
            encoder.setTriangleFillMode(.fill)
            postProcess.composite(bloomLevels, into: encoder, strength: bloomStrength)
        }
        let labelIDs: Set<UInt64>
        if visible.contains(.buildings), !wireframe {
            labelIDs = labelRenderer?.draw(encoder: encoder, matrix: matrix, width: texture.width, height: texture.height, zoom: parameters.zoom, uniforms: uniforms) ?? []
        } else { labelIDs = [] }
        publishLabels(labelIDs)
        encoder.endEncoding()
        let triangles = submittedRanges.reduce(0) { $0 + $1.count / 3 }
            + submittedGroups.reduce(0) { $0 + $1.count / 3 * $1.instanceCount }
        let drawCalls = submittedRanges.count + submittedGroups.count
        let unmergedDrawCalls = mainRanges.count + drawnGroups.count
        let cpuMS = (CACurrentMediaTime() - encodeStarted) * 1000
        let metrics = frameMetrics
        let callback = onFrameReport
        mtlCommandBuffer.addCompletedHandler { [weak self] command in
            guard command.status == .completed else { return }
            self?.didComplete(reveal, lifecycle: lifecycleReveal)
            let gpuMS = command.gpuEndTime > command.gpuStartTime ? (command.gpuEndTime - command.gpuStartTime) * 1000 : nil
            if let report = metrics.record(triangles: triangles, cpuMS: cpuMS, gpuMS: gpuMS, drawCalls: drawCalls, unmergedDrawCalls: unmergedDrawCalls) { callback?(report) }
        }
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
        surfaceTexture = nil
        paintBuffer = nil; paintTableBuffer = nil; paintIndexBuffer = nil
        reflectionPass = nil
        shadowMap = nil
        postProcess = nil
        labelRenderer = nil
        publishLabels([])
        lock.lock(); labelsReady = false; lock.unlock()
    }

    private func setDiagnostic(_ text: String) {
        lock.lock()
        diagnosticText = text
        lock.unlock()
    }
}
