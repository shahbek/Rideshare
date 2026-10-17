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
/// Water is shaded analytically (no reflection pass).
nonisolated final class DioramaRenderLayer: NSObject, CustomLayerHost, @unchecked Sendable {
    nonisolated struct Range: Sendable {
        let category: DioramaCategory
        let start: Int
        let count: Int
        var minimum: SIMD3<Float> = SIMD3(repeating: -.greatestFiniteMagnitude)
        var maximum: SIMD3<Float> = SIMD3(repeating: .greatestFiniteMagnitude)
        /// Thin open surfaces (fronds, sails, canopies, sprites) drawn without back-face culling.
        var doubleSided: Bool = false
        /// Landmark-only glazing, depth tested after opaque furniture with no depth writes.
        var translucent: Bool = false
        var landmarkPlaceholder: Bool = false
        /// Transient owner only; never written into the offline archive.
        var landmarkID: String? = nil
        /// Index into the tile's LOD table, or -1 when no simplified levels exist.
        var lodSlot: Int32 = -1
        /// Indices refer to the LOD index buffer instead of the tile's original index buffer.
        var usesLODBuffer: Bool = false

        /// Reject only boxes wholly behind the reveal front; crossing geometry still uses fragment clipping.
        func intersectsReveal(_ reveal: SIMD4<Float>) -> Bool {
            guard reveal.w > 0.5, minimum.x > -.greatestFiniteMagnitude,
                  minimum.x.isFinite, minimum.y.isFinite, maximum.x.isFinite, maximum.y.isFinite,
                  reveal.x.isFinite, reveal.y.isFinite, reveal.z.isFinite else { return true }
            let margin: Float = DioramaRevealStyle.support + 0.02
            // Multi-edge growth depends on tile bounds, not a directional dot product.
            // Keep these batches conservatively; all passes share exact fragment coverage.
            if reveal.w > 3.5 { return true }
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
        if let resident, let grid = resident.groundIndex {
            return cameraGround.height(local, grid: grid, index: resident.index, position: resident.position)
        }
        if let resident {
            return cameraGround.height(local, ranges: ranges, index: resident.index, position: resident.position, isGround: resident.isPaintedGround)
        }
        return cameraGround.height(local, vertices: vertices, indices: indices, ranges: ranges)
    }

    var viewport: DioramaViewport?
    private let labels: [DioramaBuildingLabel]
    private let displayScale: Float
    private var labelRenderer: DioramaLabelRenderer?
    private let origin: CLLocationCoordinate2D
    private let vertices: [BuildingRenderVertex]
    /// Saved tiles: GPU-shared buffers are the only copy; `vertices`/`indices` stay empty.
    private let resident: DioramaResidentTile?
    private let materialsPrepared: Bool
    private let materialCounts: SIMD2<Int>
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
    private var airportGroundDetail: DioramaResidentTile?
    private var airportGroundDetailRect: DioramaRect?
    private var airportGroundPaint: DioramaResidentTile?
    private let hasAnalyticAirportGround: Bool
    /// Compact tile: vector hard finishes over a low-resolution natural raster.
    private let hasVectorFinishes: Bool

    var storedMeshBytes: Int {
        if let resident { return resident.gpuBytes + resident.cpuBytes }
        return vertices.count * MemoryLayout<BuildingRenderVertex>.stride * 2 + indices.count * 4
            + instances.count * MemoryLayout<DioramaInstanceData>.stride * 2
    }

    var usesAnalyticAirportGround: Bool {
        lock.lock(); defer { lock.unlock() }
        return airportGroundPaint != nil || hasAnalyticAirportGround
    }

    /// Checked surface ownership, sharing the existing paint fragment pass and buffer layout.
    func setAirportGroundPaint(_ paint: DioramaResidentTile?) {
        lock.lock(); airportGroundPaint = paint; drawRevision &+= 1; selectionTransform = nil; lock.unlock()
    }

    /// One checked HD paint page replaces pigment in the existing ground fragment; no overlay surface/pass.
    func setAirportGroundDetail(_ page: DioramaResidentTile?, rect: DioramaRect?) {
        lock.lock()
        airportGroundDetail = page; airportGroundDetailRect = rect
        drawRevision &+= 1; selectionTransform = nil
        lock.unlock()
    }
    /// Shared tiling roof/wall material array (texture 7).
    private var paintBuffer: MTLBuffer?
    private var paintTableBuffer: MTLBuffer?
    private var paintIndexBuffer: MTLBuffer?
    /// Whether the water animates (false when Reduce Motion is on: waves then freeze mid-roll).
    private let contextOnly: Bool
    /// Stylised bake: lighting lives in the vertex colours and ground image; the fragment only samples.
    private let stylised: Bool
    private let animates: Bool
    private var waterMotionEnabled: Bool = true
    private var waterPhase: Float = 1.7
    private var previousCameraFrame: CFTimeInterval?
    private var waterInView: Bool = false
    private var loggedCameraFallback: Bool = false
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var geometryChunks: DioramaGeometryChunks?
    private var lightBuffer: MTLBuffer?
    private var lightTableBuffer: MTLBuffer?
    private var lightIndexBuffer: MTLBuffer?
    private var pipeline: MTLRenderPipelineState?
    private var preparedFormats: SIMD2<UInt>?
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
    /// Pre-baked low-frequency ground grade fields (broad moisture, lawn patches, asphalt weathering)
    /// over this renderer's ground rectangle. Fragments whose pixel covers more than one baked texel
    /// sample it; closer fragments evaluate the same fields live, so close-up ground is unchanged.
    private var shadowMap: DioramaShadowMap?
    private var postProcess: DioramaPostProcess?
    private let postSettings: (ao: Float, aoRadius: Float, bloom: Float, grade: Float, haze: Float)
    private let lock = NSLock()
    private var visible: Set<DioramaCategory>
    private var timeOfDay: DioramaTimeOfDay
    private var elevationOffset: Double = 0
    private var diagnosticText: String = "not started"
    private var rendererReady: Bool = false
    private var reveal: SIMD4<Float> = .zero
    private var completedReveal: SIMD4<Float>?
    private var lifecycleReveal: SIMD4<Float> = .zero
    private var completedLifecycleReveal: SIMD4<Float>?
    private var tileEdges: SIMD4<Float> = SIMD4(repeating: 1)
    private var tileState: SIMD4<Float> = SIMD4(1, 0, 0, 0)
    private var focusEdges: SIMD4<Float> = .zero
    private var unionShape: DioramaUnionShape?
    private var unionState: SIMD4<Float> = .zero
    private var completedUnion: SIMD4<Float>?
    private var selectedUnion: SIMD4<Float>?
    private var selectedFocusEdges: SIMD4<Float>?

    var hasWaterInView: Bool {
        lock.lock(); defer { lock.unlock() }
        return waterInView
    }

    func setWaterMotion(_ enabled: Bool) {
        lock.lock(); waterMotionEnabled = enabled; lock.unlock()
    }

    func setTileCoverage(edges: SIMD4<Float>, role: Float, paired: Bool, focusEdges: SIMD4<Float>? = nil) {
        lock.lock()
        tileEdges = edges
        self.focusEdges = focusEdges ?? edges
        tileState = SIMD4(1, role, 0, paired ? 1 : 0)
        lock.unlock()
    }

    func setUnionCoverage(_ shape: DioramaUnionShape?, state: SIMD4<Float>) {
        lock.lock(); unionShape = shape; unionState = state; lock.unlock()
    }

    func hasCompletedUnion(_ value: SIMD4<Float>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return completedUnion == value
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

    private func didComplete(_ value: SIMD4<Float>, lifecycle: SIMD4<Float>, union: SIMD4<Float>) {
        lock.lock()
        let changed = completedLifecycleReveal != lifecycle
        let revealChanged = completedReveal != value
        let unionChanged = completedUnion != union
        completedReveal = value; completedLifecycleReveal = lifecycle; completedUnion = union
        lock.unlock()
        if changed { onLifecycleCompleted?() }
        if revealChanged { onRevealCompleted?(value) }
        if unionChanged { onUnionCompleted?() }
    }

    private func publishWaterVisibility(_ visible: Bool) {
        lock.lock()
        let changed = waterInView != visible
        waterInView = visible
        lock.unlock()
        if changed { onWaterVisibilityChanged?() }
    }
    private var labelsReady: Bool = false
    private var acceptedLabels: Set<UInt64> = []
    var onLabelsChanged: (@Sendable (Set<UInt64>) -> Void)?
    var onFrameReport: (@Sendable (String) -> Void)?
    var onWaterVisibilityChanged: (@Sendable () -> Void)?
    var onLifecycleCompleted: (@Sendable () -> Void)?
    var onUnionCompleted: (@Sendable () -> Void)?
    var onRevealCompleted: (@Sendable (SIMD4<Float>) -> Void)?
    var onInitializationFailed: (@Sendable () -> Void)?
    var onInitialized: (@Sendable () -> Void)?

    /// Resource readiness is independent of diagnostic wording and offscreen frame callbacks.
    var isRendererReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return rendererReady
    }
    private let frameMetrics = DioramaFrameMetrics()
    private var passTimer: DioramaPassTimer?
    var onPassReport: (@Sendable (String) -> Void)?
    // Render-thread-only preparation cache. Water/reveal uniforms still update every frame.
    private var selectionVisible: Set<DioramaCategory>?
    private var selectionGlow: Bool = false
    private var selectionLandmarks: Set<String> = []
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
    private var selectedOpaqueRanges: [Range] = []
    private var selectedWaterRanges: [Range] = []
    private var selectedGlassRanges: [Range] = []
    private var selectedGlowRanges: [Range] = []
    private var selectedOpaqueGroups: [DioramaDrawPlan.Instance] = []
    private var selectedGlowGroups: [DioramaDrawPlan.Instance] = []
    private var selectedFocalPixels: Float?
    private var selectedDrawableSize: SIMD2<Int>?
    private var postOpaqueRanges: [Range] = []
    private var postEmissionRanges: [Range] = []
    private var postOpaqueGroups: [DioramaDrawPlan.Instance] = []
    private var postEmissionGroups: [DioramaDrawPlan.Instance] = []
    private var postRangeDraws: [Range] = []
    private var postInstanceDraws: [DioramaDrawPlan.Instance] = []
    /// Camera at which the cached AO/bloom outputs were rendered, and the plan revision they used.
    private var effectTransform: simd_double4x4?
    /// Heights the last culling plan's drift is measured on; the camera transform of the previous frame.
    private var planPlanes: SIMD2<Double>?
    private var lastFrameTransform: simd_double4x4?
    private var effectRevision: UInt64 = 0

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

    convenience init(origin: CLLocationCoordinate2D, vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [Range], groups: [DioramaInstanceGroup] = [], instances: [DioramaInstanceData] = [], lightGrid: DioramaLightGrid, waterHeight: Double, groundImage: DioramaGroundImage?, groundRect: DioramaRect, visible: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay, animates: Bool, config: DioramaConfig = .slipway, labels: [DioramaBuildingLabel] = [], displayScale: Float = 3, contextOnly: Bool = false, materialsPrepared: Bool = false,
         materialCounts: SIMD2<Int> = .zero, preparedPoolBounds: Range? = nil, isLandmarkModel: Bool = false) {
        self.init(origin: origin, vertices: vertices, indices: indices, ranges: ranges, groups: groups, instances: instances,
            lightGrid: lightGrid, waterHeight: waterHeight, groundImage: groundImage, groundRect: groundRect, visible: visible,
            timeOfDay: timeOfDay, animates: animates, config: config, labels: labels, displayScale: displayScale,
            contextOnly: contextOnly, materialsPrepared: materialsPrepared, materialCounts: materialCounts,
            preparedPoolBounds: preparedPoolBounds, resident: nil, isLandmarkModel: isLandmarkModel)
    }

    /// Saved tile already decoded into shared Metal storage (ownership/material tags applied).
    convenience init(resident tile: DioramaResidentTile, groundRect: DioramaRect, visible: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay,
                     config: DioramaConfig, labels: [DioramaBuildingLabel], displayScale: Float, contextOnly: Bool, origin: CLLocationCoordinate2D? = nil,
                     stylised: Bool = false) {
        self.init(origin: origin ?? tile.tile.centre, vertices: [], indices: [], ranges: tile.ranges, groups: tile.groups, instances: [],
            lightGrid: tile.lightGrid, waterHeight: tile.waterHeight, groundImage: nil, groundRect: groundRect, visible: visible,
            timeOfDay: timeOfDay, animates: true, config: config, labels: labels, displayScale: displayScale,
            contextOnly: contextOnly, materialsPrepared: true, materialCounts: tile.materialCounts,
            preparedPoolBounds: tile.poolBounds, resident: tile, isLandmarkModel: false, stylised: stylised)
    }

    private init(origin: CLLocationCoordinate2D, vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [Range], groups: [DioramaInstanceGroup], instances: [DioramaInstanceData], lightGrid: DioramaLightGrid, waterHeight: Double, groundImage: DioramaGroundImage?, groundRect: DioramaRect, visible: Set<DioramaCategory>, timeOfDay: DioramaTimeOfDay, animates: Bool, config: DioramaConfig, labels: [DioramaBuildingLabel], displayScale: Float, contextOnly: Bool, materialsPrepared: Bool,
         materialCounts: SIMD2<Int>, preparedPoolBounds: Range?, resident: DioramaResidentTile?, isLandmarkModel: Bool, stylised: Bool = false) {
        self.stylised = stylised
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
        self.materialsPrepared = materialsPrepared
        self.materialCounts = materialCounts
        tileState.y = contextOnly ? 0 : 1
        self.origin = origin
        self.labels = labels
        self.displayScale = displayScale
        self.vertices = vertices
        self.resident = resident
        // Ownership hides ordinary scenery shells beneath a designed landmark. Applying it to the landmark's
        // own model made every bespoke POI suppress itself once its host became present.
        let ownership = resident != nil || isLandmarkModel ? (indices: indices, ranges: ranges, groups: groups)
            : DioramaLandmarkOwnership.partition(vertices: vertices, indices: indices, ranges: ranges, groups: groups, origin: origin)
        self.indices = ownership.indices
        self.ranges = ownership.ranges
        self.groups = ownership.groups
        self.instances = instances
        self.lightGrid = lightGrid
        self.waterHeight = Float(waterHeight)
        var poolLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var poolHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        if !materialsPrepared {
            for vertex in vertices where vertex.appearance.y > 4.5 && vertex.appearance.y < 5.5 && vertex.appearance.w < 0.5 {
                let p = SIMD3(vertex.position.x, vertex.position.y, vertex.position.z)
                poolLow = simd_min(poolLow, p); poolHigh = simd_max(poolHigh, p)
            }
        }
        poolBounds = materialsPrepared ? preparedPoolBounds
            : (poolLow.x <= poolHigh.x ? Range(category: .water, start: 0, count: 0, minimum: poolLow, maximum: poolHigh) : nil)
        self.groundImage = groundImage
        if let resident {
            let count = resident.paintBuffer.length / MemoryLayout<DioramaPaintTriangle>.stride
            let values = resident.paintBuffer.contents().assumingMemoryBound(to: DioramaPaintTriangle.self)
            hasAnalyticAirportGround = (0..<count).contains { values[$0].color.w < 0 && values[$0].color.w > DioramaGroundPainter.hybridThreshold }
            hasVectorFinishes = (0..<count).contains { values[$0].color.w < DioramaGroundPainter.hybridThreshold }
        } else {
            hasAnalyticAirportGround = groundImage?.paint.triangles.contains { $0.color.w < 0 && $0.color.w > DioramaGroundPainter.hybridThreshold } ?? false
            hasVectorFinishes = groundImage?.paint.triangles.contains { $0.color.w < DioramaGroundPainter.hybridThreshold } ?? false
        }
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

    /// Local landmark meshes may follow the resident ground without lifting saved tile geometry.
    func setElevationOffset(_ height: Double) {
        lock.lock(); elevationOffset = height.isFinite ? height : 0; lock.unlock()
    }

    func setWireframe(_ enabled: Bool) {
        lock.lock(); wireframe = enabled; lock.unlock()
    }

    func setReducedEffects(_ reduced: Bool) {
        lock.lock()
        reducedEffects = reduced
        lock.unlock()
    }

    /// Called only before registration, while the SDK cannot concurrently render this host.
    func prepareOutputSize(width: Int, height: Int) {
        postProcess?.prepareSize(width: width, height: height)
    }

    func renderingWillStart(_ metalDevice: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        DioramaGPUPreparation.shared.capture(device: metalDevice, color: colorPixelFormat, depth: depthStencilPixelFormat)
        let formats = SIMD2(colorPixelFormat, depthStencilPixelFormat)
        if preparedFormats == formats, isRendererReady { onInitialized?(); return }
        lock.lock()
        rendererReady = false; completedReveal = nil; completedLifecycleReveal = nil; completedUnion = nil
        lock.unlock()
        selectionTransform = nil; selectionVisible = nil
        let uploadStarted = CACurrentMediaTime()
        let hasGeometry = resident.map { $0.vertexCount > 0 && $0.indexCount > 0 && $0.device === metalDevice }
            ?? (!vertices.isEmpty && !indices.isEmpty)
        guard hasGeometry,
              let library = DioramaShaderSource.library(for: metalDevice),
              let vertex = library.makeFunction(name: "dioramaVertex"),
              let instancedVertex = library.makeFunction(name: "dioramaInstancedVertex"),
              let fragment = library.makeFunction(name: "dioramaFragment"),
              let colorFormat = MTLPixelFormat(rawValue: colorPixelFormat),
              let depthFormat = MTLPixelFormat(rawValue: depthStencilPixelFormat) else {
            setDiagnostic(resident.map { $0.device !== metalDevice } == true ? "failed: scenery decoded on a different Metal device" : "missing geometry or shader resources")
            onInitializationFailed?()
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
                passTimer = DioramaPassTimer(device: metalDevice)
                shadowMap = DioramaShadowMap(device: metalDevice, library: library, bounds: resident?.shadowBounds ?? Self.casterBounds(vertices, instances))
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
            geometryChunks = DioramaGeometryChunks(device: metalDevice, context: contextOnly)
            lightBuffer = upload(lightGrid.lights, fallback: DioramaShaderLight(position: .zero, color: .zero))
            lightTableBuffer = upload(lightGrid.table, fallback: SIMD2<UInt32>(0, 0))
            lightIndexBuffer = upload(lightGrid.indices, fallback: UInt32(0))
            if let resident {
                // Decoded straight into shared Metal storage: adopt, never copy.
                vertexBuffer = resident.vertexBuffer; indexBuffer = resident.indexBuffer
                instanceBuffer = resident.instanceBuffer
                paintBuffer = resident.paintBuffer; paintTableBuffer = resident.paintTableBuffer
                paintIndexBuffer = resident.paintIndexBuffer; groundTexture = resident.groundTexture
            } else {
                let materialUpload = materialsPrepared ? (vertices: vertices, count: materialCounts.x, architectureCount: materialCounts.y)
                    : DioramaLegacyFoliageMaterial.tagged(vertices, indices: indices, ranges: ranges, groups: groups)
                vertexBuffer = upload(materialUpload.vertices.map(DioramaPackedVertex.init), fallback: .empty)
                indexBuffer = upload(indices, fallback: 0)
                instanceBuffer = upload(instances, fallback: .identity)
                let paint = groundImage?.paint ?? DioramaVectorPaint()
                paintBuffer = upload(paint.triangles, fallback: DioramaPaintTriangle.empty)
                paintTableBuffer = upload(paint.table, fallback: SIMD2<UInt32>(0, 0))
                paintIndexBuffer = upload(paint.indices, fallback: UInt32(0))
            }
            #if DEBUG
            print("[Diorama material] legacy_foliage_vertices=\(materialCounts.x) legacy_architecture_vertices=\(materialCounts.y) preset=\(timeOfDay.rawValue) color_format=\(colorPixelFormat) vertex=packed32 resident=\(resident != nil)")
            #endif

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
            if DioramaConfig.buildingLabels, !contextOnly, !labels.isEmpty {
                labelRenderer = DioramaLabelRenderer(device: metalDevice, labels: labels, scale: displayScale, color: colorFormat, depthFormat: depthFormat)
            }
            guard vertexBuffer != nil, indexBuffer != nil, instanceBuffer != nil,
                  lightBuffer != nil, lightTableBuffer != nil, lightIndexBuffer != nil,
                  paintBuffer != nil, paintTableBuffer != nil, paintIndexBuffer != nil,
                  depthState != nil, noWriteDepthState != nil, blankReflection != nil else {
                setDiagnostic("GPU resource allocation failed")
                onInitializationFailed?()
                return
            }
            lock.lock(); labelsReady = labelRenderer != nil; rendererReady = true; lock.unlock()
            preparedFormats = formats
            setDiagnostic("ready vertices=\(resident?.vertexCount ?? vertices.count) triangles=\((resident?.indexCount ?? indices.count) / 3) instances=\(resident?.instanceCount ?? instances.count) lights=\(lightGrid.lights.count)")
            onInitialized?()
            print("[Diorama load] context=\(contextOnly) GPU-setup=\(String(format: "%.3f", CACurrentMediaTime() - uploadStarted))s (not GPU execution)")
        } catch {
            setDiagnostic("pipeline creation failed")
            onInitializationFailed?()
            print("[Diorama] render pipeline unavailable")
        }
    }

    private static func casterBounds(_ vertices: [BuildingRenderVertex], _ instances: [DioramaInstanceData]) -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for v in vertices where v.appearance.w < 3.5 {
            let p = SIMD3<Float>(v.position.x, v.position.y, v.position.z)
            low = simd_min(low, p); high = simd_max(high, p)
        }
        for i in instances {
            low = simd_min(low, i.centre - SIMD3(repeating: i.radius)); high = simd_max(high, i.centre + SIMD3(repeating: i.radius))
        }
        return low.x.isFinite && high.x > low.x ? (low, high) : nil
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let pipeline, let vertexBuffer, let indexBuffer, let geometryChunks, let lightBuffer, let lightTableBuffer, let lightIndexBuffer,
              let depthState, let noWriteDepthState, let paintBuffer, let paintTableBuffer, let paintIndexBuffer,
              let texture = mtlRenderPassDescriptor.colorAttachments[0].texture,
              parameters.projectionMatrix.count == 16 else {
            publishWaterVisibility(false); publishLabels([]); return
        }
        lock.lock()
        let visible = self.visible
        let elevationOffset = self.elevationOffset
        let timeOfDay = self.timeOfDay
        let reducedEffects = self.reducedEffects
        let wireframe = self.wireframe
        let reveal = self.reveal
        let lifecycleReveal = self.lifecycleReveal
        let tileEdges = self.tileEdges
        let tileState = self.tileState
        let focusEdges = self.focusEdges
        let unionState = self.unionState
        let unionShape = self.unionShape
        let waterMotionEnabled = self.waterMotionEnabled
        let airportDetail = self.airportGroundDetail
        let airportDetailRect = self.airportGroundDetailRect
        let airportPaint = self.airportGroundPaint
        lock.unlock()
        let debug = DioramaDebugSwitches.shared.flags
        let hostID = ObjectIdentifier(self)
        let analyticAirport = airportPaint != nil || hasAnalyticAirportGround
        let scenePaint = airportPaint?.paintBuffer ?? paintBuffer
        let scenePaintTable = airportPaint?.paintTableBuffer ?? paintTableBuffer
        let scenePaintIndices = airportPaint?.paintIndexBuffer ?? paintIndexBuffer
        DioramaGPUPreparation.shared.captureSize(width: texture.width, height: texture.height)
        let encodeStarted = CACurrentMediaTime()
        let passReport = onPassReport
        let timing = passReport == nil ? nil : passTimer?.begin()
        if let timing, let passTimer, let passReport {
            passTimer.finish(timing, command: mtlCommandBuffer, report: passReport)
        }
        let glowOn = timeOfDay.showsLights
        let landmarks = DioramaLandmarkPresence.shared.activeIDs(viewport: viewport)
        if selectionVisible != visible || selectionGlow != glowOn || selectionLandmarks != landmarks {
            eligibleRanges = ranges.filter { $0.count > 0 && visible.contains($0.category) && (!$0.category.isEmissive || glowOn)
                && (!$0.landmarkPlaceholder || !landmarks.contains($0.landmarkID ?? "airtel")) }
            eligibleGroups = groups.filter { !$0.instances.isEmpty && visible.contains($0.category) && (!$0.category.isEmissive || glowOn)
                && (!$0.landmarkPlaceholder || !landmarks.contains($0.landmarkID ?? "airtel")) }
            eligibleCasters = eligibleGroups.filter { !$0.category.isEmissive }
            selectionVisible = visible; selectionGlow = glowOn; selectionLandmarks = landmarks; selectionTransform = nil
        }
        let drawn = eligibleRanges
        guard !drawn.isEmpty || !eligibleGroups.isEmpty else {
            publishWaterVisibility(false)
            publishLabels([])
            mtlCommandBuffer.addCompletedHandler { [weak self] command in
                if command.status == .completed { self?.didComplete(reveal, lifecycle: lifecycleReveal, union: unionState) }
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
        model[3, 2] = elevationOffset
        let transform = projection * model
        viewport?.publish(DioramaViewport.Snapshot(transform: transform, origin: origin,
            latitude: parameters.latitude, longitude: parameters.longitude, zoom: parameters.zoom,
            bearing: parameters.bearing, pitch: parameters.pitch,
            size: CGSize(width: parameters.width, height: parameters.height)))
        var matrix = simd_float4x4(columns: (
            SIMD4<Float>(transform.columns.0), SIMD4<Float>(transform.columns.1),
            SIMD4<Float>(transform.columns.2), SIMD4<Float>(transform.columns.3)
        ))
        let envelope = Range(category: .ground, start: 0, count: 0,
            minimum: revealBounds.minimum - SIMD3(0, 0, 2), maximum: revealBounds.maximum + SIMD3(0, 0, 2))
        if !envelope.intersects(matrix) {
            publishWaterVisibility(false); publishLabels([])
            mtlCommandBuffer.addCompletedHandler { [weak self] command in
                if command.status == .completed { self?.didComplete(reveal, lifecycle: lifecycleReveal, union: unionState) }
            }
            return
        }
        let selectionReset = selectionTransform == nil
        let cameraMoved = lastFrameTransform != transform
        lastFrameTransform = transform
        // Culling and LOD planning are reused while the camera has drifted under 24 px since the plan.
        // The plan culls against a frustum 15% wider on each side (≥ 80 px on a phone), so nothing that
        // enters the view within that drift was rejected; extra batches past the edge are GPU-clipped.
        let selectionChanged = selectionReset || selectionTransform.map { cached in
            guard cached != transform else { return false }
            guard let planes = planPlanes else { return true }
            return DioramaEffectDrift.pixels(from: cached, to: transform, width: texture.width, height: texture.height, planes: planes) >= 24
        } ?? true
        if selectionChanged {
            var padded = matrix
            for c in 0..<4 { padded[c].x /= 1.15; padded[c].y /= 1.15 }
            cameraRanges = drawn.filter { $0.intersects(padded) }
            cameraGroups = eligibleGroups.filter { group in
                Range(category: group.category, start: 0, count: 0, minimum: group.minimum, maximum: group.maximum).intersects(padded)
            }
            selectionTransform = transform
        }
        let fov = Float(max(1, min(120, parameters.fieldOfView))) * .pi / 180
        let focal = Float(texture.height) * 0.5 / tan(fov * 0.5)
        let drawableSize = SIMD2(texture.width, texture.height)
        // Everything except pure camera motion: these always refresh cached effects.
        let inputsChanged = selectionReset || selectedFocalPixels != focal || selectedDrawableSize != drawableSize
            || selectedReveal != reveal || selectedLifecycle != lifecycleReveal
            || selectedEdges != tileEdges || selectedTileState != tileState
            || selectedUnion != unionState || selectedFocusEdges != focusEdges
        let planChanged = selectionChanged || inputsChanged
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
            selectedUnion = unionState; selectedFocusEdges = focusEdges
            selectedFocalPixels = focal; selectedDrawableSize = drawableSize
            drawRevision &+= 1
        }
        let mainRanges = selectedRanges
        let drawnGroups = selectedGroups
        guard !mainRanges.isEmpty || !drawnGroups.isEmpty else {
            publishWaterVisibility(false)
            publishLabels([])
            mtlCommandBuffer.addCompletedHandler { [weak self] command in
                if command.status == .completed { self?.didComplete(reveal, lifecycle: lifecycleReveal, union: unionState) }
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
        let poolVisible = (visible.contains(.props) || (contextOnly && visible.contains(.ground)))
            && poolBounds?.intersects(matrix) == true && poolBounds?.intersectsReveal(reveal) == true
            && poolBounds?.intersectsReveal(lifecycleReveal) == true
        publishWaterVisibility(mainRanges.contains { $0.category == .water } || poolVisible)

        var uniforms = DioramaLighting.uniforms(for: timeOfDay, eye: eye)
        uniforms.groundColor.w = 0
        uniforms.style.z = DioramaConfig.clayRendering ? 1 : 0
        uniforms.style.w = (debug.facadeShader ? 0 : 1) + (debug.groundPaint ? 0 : 2)
        uniforms.reveal = reveal
        uniforms.lifecycleReveal = lifecycleReveal
        uniforms.tileBounds = SIMD4(Float(groundRect.minX), Float(groundRect.minY), Float(groundRect.maxX), Float(groundRect.maxY))
        uniforms.tileEdges = tileEdges
        uniforms.tileState = tileState
        uniforms.focusEdges = focusEdges; uniforms.unionState = unionState
        unionShape?.write(to: &uniforms)
        uniforms.shoreline = shorelineSettings
        uniforms.shoreline.z = reducedEffects ? 1 : 0
        uniforms.shoreline.w = contextOnly ? 1 : 0
        uniforms.waterDeep = waterDeepTint
        uniforms.waterShallow = waterShallowTint
        uniforms.groundImage = SIMD4<Float>(Float(groundRect.minX), Float(groundRect.minY), Float(1 / max(groundRect.width, 1)), Float(1 / max(groundRect.height, 1)))
        if airportDetail?.groundTexture != nil, let r = airportDetailRect {
            uniforms.airportDetailBounds = SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY))
            uniforms.airportDetailImage = SIMD4(Float(r.minX), Float(r.minY), Float(1 / r.width), Float(1 / r.height))
        }
        uniforms.materialFrame = materialFrame
        uniforms.materialFrame.w = analyticAirport ? 1 : (hasVectorFinishes ? 2 : 0)
        uniforms.lightGrid = SIMD4<Float>(lightGrid.minX, lightGrid.minY, lightGrid.cellSize, debug.pointLights ? Float(lightGrid.cells) : 0)
        // Idle SDK/vehicle frames keep exactly the last water phase. Bound the step when the
        // camera resumes so a long pause never jumps the shoreline or animates at rest.
        let now = CACurrentMediaTime()
        if cameraMoved, animates, waterMotionEnabled, !reducedEffects {
            let dt = previousCameraFrame.map { min(1.0 / 12.0, max(0, now - $0)) } ?? 0
            waterPhase = (waterPhase + Float(dt)).truncatingRemainder(dividingBy: 3600)
        }
        if cameraMoved { previousCameraFrame = now }
        uniforms.params.y = waterPhase

        // One drawable pixel of measured geometric error: removed detail is smaller than a pixel.
        // 0.9 px while planning leaves headroom for the eye movement before the next re-plan.
        let lodBase = resident?.lod.map { DioramaLODSelector(table: $0, eye: eye, focalPixels: focal, tolerance: 0.9) }

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
        if debug.shadows, reveal.w < 0.5, lifecycleReveal.w < 0.5, unionState.x < 0.5, let shadowMap, let shadowMatrix = shadowMap.update(command: mtlCommandBuffer, vertices: vertexBuffer, indices: indexBuffer, instances: instanceBuffer,
            ranges: drawn, groups: castingGroups, focus: viewLow.x.isFinite && viewHigh.x > viewLow.x ? (viewLow, viewHigh) : nil,
            sun: SIMD3(uniforms.sunDirection.x, uniforms.sunDirection.y, uniforms.sunDirection.z), preset: timeOfDay, landmarkPresent: landmarks,
            chunks: geometryChunks, lod: lodBase, timing: timing) {
            uniforms.shadowMatrix = shadowMatrix
            uniforms.shadowParams = SIMD4(1, 1.0 / 2048.0, 0.00006, timeOfDay == .day ? 0.65 : 0.85)
        }

        uniforms.water = SIMD4<Float>(waterHeight, 0, Float(texture.width), Float(texture.height))
        // Screen-space passes first: occlusion the main pass samples, bloom added at the end.
        // Reduced effects (Low Power, thermal) drop them entirely; geometry is unchanged.
        let effectsOn = !reducedEffects && !wireframe
        let hasOpaque = mainRanges.contains { $0.category != .water && !$0.category.isEmissive }
            || drawnGroups.contains { !$0.category.isEmissive }
        let hasEmission = mainRanges.contains { $0.category.isEmissive } || drawnGroups.contains { $0.category.isEmissive }
        // Clay keeps no screen-space occlusion: that pass re-drew every opaque triangle into a
        // position/normal buffer each time the camera moved more than a texel.
        let aoStrength: Float = effectsOn && hasOpaque && !DioramaConfig.clayRendering ? postSettings.ao : 0
        let bloomStrength: Float = debug.bloom && effectsOn && glowOn && hasEmission ? postSettings.bloom : 0
        uniforms.post = SIMD4<Float>(aoStrength, bloomStrength, postSettings.grade, postSettings.haze)
        let lodDistance: Float = 140
        let lodSelector = lodBase
        if planChanged {
            selectedRangeDraws = DioramaDrawPlan.ranges(DioramaDrawPlan.levels(mainRanges, selector: lodSelector))
            selectedInstanceDraws = DioramaDrawPlan.instances(drawnGroups, eye: eye, lodDistance: lodDistance, selector: lodSelector,
                                                               focalPixels: focal, minimumPixels: 1.2)
            // Half-resolution AO accepts two full-resolution pixels of error (one of its own).
            let aoSelector = lodSelector?.scaled(2)
            postRangeDraws = DioramaDrawPlan.ranges(DioramaDrawPlan.levels(mainRanges, selector: aoSelector))
            postInstanceDraws = DioramaDrawPlan.instances(drawnGroups, eye: eye, lodDistance: lodDistance, selector: aoSelector,
                                                           focalPixels: focal, minimumPixels: 2.4)
            selectedOpaqueRanges = selectedRangeDraws.filter { $0.category != .water && $0.category != .propGlow && !$0.translucent }
            selectedWaterRanges = selectedRangeDraws.filter { $0.category == .water }
            // Preserve the exact pane order when concatenating transparent indices.
            selectedGlassRanges = selectedRangeDraws.filter(\.translucent).sorted {
                simd_distance_squared(($0.minimum + $0.maximum) * 0.5, eye) > simd_distance_squared(($1.minimum + $1.maximum) * 0.5, eye)
            }
            selectedGlowRanges = selectedRangeDraws.filter { $0.category == .propGlow }
            selectedOpaqueGroups = selectedInstanceDraws.filter { $0.category != .propGlow }
            selectedGlowGroups = selectedInstanceDraws.filter { $0.category == .propGlow }
            postOpaqueRanges = postRangeDraws.filter { $0.category != .water && $0.category != .propGlow && !$0.category.isEmissive && !$0.translucent }
            postEmissionRanges = postRangeDraws.filter { $0.category.isEmissive }
            postOpaqueGroups = postInstanceDraws.filter { !$0.category.isEmissive }
            postEmissionGroups = postInstanceDraws.filter { $0.category.isEmissive }
            selectionTransform = transform
        }
        // Half-resolution AO/bloom texels are two drawable pixels wide. While the camera has moved
        // less than 1.5 px since they were rendered, re-rendering would only shift them sub-texel.
        let effectPlanes = SIMD2<Double>(Double(viewLow.z.isFinite ? viewLow.z : waterHeight),
            Double(viewHigh.z.isFinite ? min(viewHigh.z, (viewLow.z.isFinite ? viewLow.z : waterHeight) + 80) : waterHeight + 30))
        if planChanged { planPlanes = effectPlanes }
        if inputsChanged || effectTransform.map({ DioramaEffectDrift.pixels(from: $0, to: transform,
            width: texture.width, height: texture.height, planes: effectPlanes) >= 1.5 }) ?? true {
            effectTransform = transform; effectRevision = drawRevision
        }
        var bloomLevels: [MTLTexture] = []
        // Conservative screen bounds of everything this tile draws; screen-space effects run only there.
        var effectFocus: SIMD4<Float>?
        if viewLow.x.isFinite, viewHigh.x >= viewLow.x {
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            var projectable = true
            for corner in 0..<8 where projectable {
                let p = SIMD4<Float>(corner & 1 == 0 ? viewLow.x : viewHigh.x, corner & 2 == 0 ? viewLow.y : viewHigh.y,
                                     corner & 4 == 0 ? viewLow.z : viewHigh.z, 1)
                let q = matrix * p
                guard q.w > 0.0001, q.x.isFinite, q.y.isFinite else { projectable = false; break }
                let uv = SIMD2<Float>(q.x / q.w * 0.5 + 0.5, 0.5 - q.y / q.w * 0.5)
                lo = simd_min(lo, uv); hi = simd_max(hi, uv)
            }
            if projectable { effectFocus = SIMD4(max(lo.x, 0), max(lo.y, 0), min(hi.x, 1), min(hi.y, 1)) }
        }
        if let postProcess, aoStrength > 0 || bloomStrength > 0 {
            bloomLevels = postProcess.encode(
                command: mtlCommandBuffer, targetWidth: texture.width, targetHeight: texture.height,
                vertices: vertexBuffer, indices: indexBuffer, lodIndices: resident?.lod?.indexBuffer, instances: instanceBuffer,
                opaqueRanges: postOpaqueRanges,
                emissiveRanges: postEmissionRanges,
                opaqueGroups: postOpaqueGroups,
                emissiveGroups: postEmissionGroups,
                matrix: matrix, uniforms: uniforms, eye: eye,
                aoRadius: postSettings.aoRadius, aoStrength: aoStrength, bloomStrength: bloomStrength, lodDistance: lodDistance,
                revision: effectRevision, chunks: geometryChunks, timing: timing, focus: effectFocus)
        }
        if aoStrength > 0, postProcess?.occlusion == nil { uniforms.post.x = 0 }
        DioramaFleetLighting.shared.publish(host: self, snapshot: .init(origin: origin, uniforms: uniforms,
            buffers: [lightBuffer, lightTableBuffer, lightIndexBuffer, paintBuffer, paintTableBuffer, paintIndexBuffer],
            textures: [blankReflection, shadowMap?.texture, blankReflection,
                       postProcess?.occlusion ?? blankReflection, blankReflection], fullDetail: !contextOnly,
            viewportID: viewport.map(ObjectIdentifier.init)))

        let lodIndices: MTLBuffer = resident?.lod?.indexBuffer ?? indexBuffer
        timing?.attach(mtlRenderPassDescriptor, "Main")
        let madeEncoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor)
        // Mapbox may reuse its descriptor; never leave our sample buffer attached to its passes.
        if timing != nil { DioramaPassTimer.Frame.detach(mtlRenderPassDescriptor) }
        guard let encoder = madeEncoder else { return }
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
        encoder.setFragmentBuffer(scenePaint, offset: 0, index: 4)
        encoder.setFragmentBuffer(scenePaintTable, offset: 0, index: 5)
        encoder.setFragmentBuffer(scenePaintIndices, offset: 0, index: 6)
        encoder.setFragmentTexture(shadowMap?.texture, index: 1)
        encoder.setFragmentTexture(postProcess?.occlusion ?? blankReflection, index: 3)
        // Batch only inside an identical pipeline/depth phase. Culling and LOD already ran on
        // the original spatial bins; chunking never submits culled geometry or changes vertices.
        var submission = DioramaGeometryChunks.Statistics()
        func drawRanges(_ ranges: [Range], cull: MTLCullMode? = nil) {
            submission.add(geometryChunks.drawRanges(ranges, encoder: encoder, command: mtlCommandBuffer,
                indices: indexBuffer, lodIndices: lodIndices, cull: cull))
        }
        encoder.setDepthStencilState(depthState)
        drawRanges(selectedOpaqueRanges)
        if let instanceBuffer, let instancedPipeline {
            encoder.setRenderPipelineState(instancedGlowPipeline ?? instancedPipeline)
            submission.add(geometryChunks.drawInstances(selectedOpaqueGroups, encoder: encoder, command: mtlCommandBuffer,
                indices: indexBuffer, lodIndices: lodIndices, instances: instanceBuffer))
        }
        encoder.setDepthStencilState(noWriteDepthState)
        encoder.setRenderPipelineState(waterPipeline ?? pipeline)
        drawRanges(selectedWaterRanges, cull: MTLCullMode.none)
        // Glass stays back-to-front, depth tested and without depth writes.
        drawRanges(selectedGlassRanges, cull: .back)
        encoder.setRenderPipelineState(glowPipeline ?? pipeline)
        drawRanges(selectedGlowRanges, cull: MTLCullMode.none)
        if let instanceBuffer, let instancedGlowPipeline {
            encoder.setRenderPipelineState(instancedGlowPipeline)
            submission.add(geometryChunks.drawInstances(selectedGlowGroups, encoder: encoder, command: mtlCommandBuffer,
                indices: indexBuffer, lodIndices: lodIndices, instances: instanceBuffer))
        }
        if !bloomLevels.isEmpty, let postProcess {
            encoder.setTriangleFillMode(.fill)
            postProcess.composite(bloomLevels, into: encoder, strength: bloomStrength, targetWidth: texture.width, targetHeight: texture.height)
        }
        let labelIDs: Set<UInt64>
        if debug.labels, visible.contains(.buildings), !wireframe {
            labelIDs = labelRenderer?.draw(encoder: encoder, frame: ObjectIdentifier(mtlCommandBuffer), matrix: matrix, width: texture.width, height: texture.height, zoom: parameters.zoom, uniforms: uniforms) ?? []
        } else { labelIDs = [] }
        publishLabels(labelIDs)
        encoder.endEncoding()
        let triangles = submission.triangles
        timing?.count("Main", triangles: triangles, draws: submission.draws, inputDraws: submission.inputDraws)
        let drawCalls = submission.draws
        let chunkCopiedBytes = submission.copiedBytes
        let chunkCacheHits = submission.cacheHits
        let chunkFallbackDraws = submission.fallbackDraws
        let unmergedDrawCalls = mainRanges.count + drawnGroups.count
        let cpuMS = (CACurrentMediaTime() - encodeStarted) * 1000
        let metrics = frameMetrics
        let callback = onFrameReport
        var perCategory: [DioramaCategory: Int] = [:]
        for r in selectedRangeDraws { perCategory[r.category, default: 0] += r.count / 3 }
        for g in selectedInstanceDraws { perCategory[g.category, default: 0] += g.count / 3 * g.instanceCount }
        var casterTriangles = 0
        if uniforms.shadowParams.x > 0.5 {
            for r in drawn where !r.category.isEmissive && r.category != .water { casterTriangles += r.count / 3 }
            for g in castingGroups { casterTriangles += g.fullCount / 3 * g.instances.count }
        }
        let labelCount = labelIDs.count
        let lightCount = debug.pointLights ? lightGrid.lights.count : 0
        let profileFrame: DioramaProfiler.Frame? = DioramaProfiler.shared.isRecording
            ? DioramaProfiler.Frame(t: 0, host: hostID.hashValue, zoom: Double(parameters.zoom), pitch: Double(parameters.pitch),
                bearing: Double(parameters.bearing), latitude: Double(parameters.latitude), longitude: Double(parameters.longitude),
                cpuMS: cpuMS, gpuMS: nil)
            : nil
        DioramaDebugSwitches.shared.record(hostID) { stats in
            stats.triangles = perCategory; stats.drawCalls = drawCalls; stats.shadowTriangles = casterTriangles
            stats.labels = labelCount; stats.lights = lightCount
        }
        mtlCommandBuffer.addCompletedHandler { [weak self] command in
            guard command.status == .completed else { return }
            self?.didComplete(reveal, lifecycle: lifecycleReveal, union: unionState)
            let gpuMS = command.gpuEndTime > command.gpuStartTime ? (command.gpuEndTime - command.gpuStartTime) * 1000 : nil
            DioramaDebugSwitches.shared.record(hostID) { $0.gpuMS = gpuMS }
            if var sample = profileFrame {
                sample.t = CACurrentMediaTime(); sample.gpuMS = gpuMS
                DioramaProfiler.shared.record(sample)
            }
            if let report = metrics.record(triangles: triangles, cpuMS: cpuMS, gpuMS: gpuMS, drawCalls: drawCalls,
                unmergedDrawCalls: unmergedDrawCalls, chunkCopiedBytes: chunkCopiedBytes,
                chunkCacheHits: chunkCacheHits, chunkFallbackDraws: chunkFallbackDraws) { callback?(report) }
        }
    }

    func renderingWillEnd() {
        DioramaDebugSwitches.shared.remove(ObjectIdentifier(self))
        DioramaFleetLighting.shared.remove(host: self)
        publishWaterVisibility(false)
        preparedFormats = nil
        pipeline = nil
        glowPipeline = nil
        waterPipeline = nil
        depthState = nil
        noWriteDepthState = nil
        vertexBuffer = nil
        indexBuffer = nil
        geometryChunks = nil
        selectionTransform = nil; selectionVisible = nil
        instanceBuffer = nil
        instancedPipeline = nil
        instancedGlowPipeline = nil
        lightBuffer = nil
        lightTableBuffer = nil
        lightIndexBuffer = nil
        blankReflection = nil
        groundTexture = nil
        lock.lock(); airportGroundDetail = nil; airportGroundDetailRect = nil; lock.unlock()
        paintBuffer = nil; paintTableBuffer = nil; paintIndexBuffer = nil
        passTimer = nil
        shadowMap = nil
        postProcess = nil
        labelRenderer = nil
        publishLabels([])
        lock.lock()
        labelsReady = false; rendererReady = false
        completedReveal = nil; completedLifecycleReveal = nil; completedUnion = nil
        lock.unlock()
    }

    private func setDiagnostic(_ text: String) {
        lock.lock()
        diagnosticText = text
        lock.unlock()
    }
}
