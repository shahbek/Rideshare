@_spi(Experimental) import MapboxMaps
import SceneKit
import Metal
import simd

/// Bundled landmarks use the tile renderer's lighting, material response, AO, bloom and cached shadows.
/// Site geometry remains geographic; downloaded scenery and native surroundings are never regenerated.
nonisolated final class DioramaLandmarkLayer: NSObject, CustomLayerHost, @unchecked Sendable {
    let isAirtel: Bool
    let landmarkID: String?
    var viewport: DioramaViewport? { didSet { renderer.viewport = viewport } }
    var onInitializationFailed: (@Sendable () -> Void)?
    var onInitialized: (@Sendable () -> Void)?
    private var isReady: Bool = false
    private let origin: CLLocationCoordinate2D
    private let usesSeaDatum: Bool
    private let bridgeAlignment: TanzaniteBridgeAlignment?
    private let renderer: DioramaRenderLayer
    private let vertices: [BuildingRenderVertex]
    private let indices: [UInt32]
    private let minimum: SIMD3<Float>
    private let maximum: SIMD3<Float>
    private let floorAnchors: [GeoPoint]
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var projected: DioramaProjectedShadow?
    private let settingsLock = NSLock()
    private var time: DioramaTimeOfDay = .day
    private var reduced: Bool = false
    private var lastHeight: Double?
    private var lastSupport: ObjectIdentifier?
    private var receiverKey: SIMD4<Float>?
    private var receiverHeight: Double?
    private var receiver: [SIMD4<Float>] = []

    var diagnostic: String { renderer.diagnostic }

    @MainActor init(origin: CLLocationCoordinate2D, scene: SCNScene, ring: [SIMD2<Double>] = [],
                    isAirtel: Bool = false, landmarkID: String? = nil, usesSeaDatum: Bool = false, bridgeAlignment: TanzaniteBridgeAlignment? = nil,
                    groundImage: DioramaGroundImage? = nil, groundRect: DioramaRect? = nil) {
        self.origin = origin; self.isAirtel = isAirtel; self.usesSeaDatum = usesSeaDatum
        self.landmarkID = isAirtel ? "airtel" : landmarkID
        self.bridgeAlignment = bridgeAlignment
        let projection = DioramaProjection(origin: origin)
        floorAnchors = ring.map { xy in
            let c = projection.coordinate(DV2(xy.x, xy.y))
            return GeoPoint(latitude: c.latitude, longitude: c.longitude)
        } + [GeoPoint(origin)]
        let geometry = DioramaLandmarkMesh.standard(scene)
        let low = geometry.minimum, high = geometry.maximum
        vertices = geometry.vertices; indices = geometry.indices; minimum = low; maximum = high
        let rect = DioramaRect(minX: Double(low.x) - 2, minY: Double(low.y) - 2, maxX: Double(high.x) + 2, maxY: Double(high.y) + 2)
        renderer = DioramaRenderLayer(origin: origin, vertices: geometry.vertices, indices: geometry.indices, ranges: geometry.ranges,
            lightGrid: DioramaLightGrid.build(geometry.lights, rect: rect, cells: 8, perCell: 16), waterHeight: 0,
            groundImage: groundImage, groundRect: groundRect ?? rect, visible: Set(DioramaCategory.allCases), timeOfDay: .day,
            animates: false, materialsPrepared: true, isLandmarkModel: true)
        renderer.setTileCoverage(edges: .zero, role: 0, paired: false)
        super.init()
        renderer.onInitializationFailed = { [weak self] in self?.onInitializationFailed?() }
    }

    @MainActor init(airportOrigin origin: CLLocationCoordinate2D, artifacts: DioramaTileArtifacts?, resident: DioramaResidentTile? = nil, groundRect: DioramaRect) {
        self.origin = origin; isAirtel = false; landmarkID = "jnia-airport"; usesSeaDatum = true; bridgeAlignment = nil
        floorAnchors = []; vertices = []; indices = []; minimum = .zero; maximum = .zero
        if let resident {
            renderer = DioramaRenderLayer(resident: resident, groundRect: groundRect, visible: Set(DioramaCategory.allCases), timeOfDay: .day,
                config: .slipway, labels: [], displayScale: Float(UIScreen.main.scale), contextOnly: false, origin: origin)
        } else {
            let a = artifacts
            renderer = DioramaRenderLayer(origin: origin, vertices: a?.vertices ?? [], indices: a?.indices ?? [], ranges: a?.ranges ?? [], groups: a?.groups ?? [], instances: a?.allInstances ?? [],
                lightGrid: a?.lightGrid ?? DioramaLightGrid.build([], rect: groundRect, cells: 1, perCell: 1), waterHeight: 0, groundImage: a?.groundImage,
                groundRect: groundRect, visible: Set(DioramaCategory.allCases), timeOfDay: .day, animates: false, materialsPrepared: true, isLandmarkModel: true)
        }
        renderer.setTileCoverage(edges: .zero, role: 0, paired: false)
        super.init()
        renderer.onInitializationFailed = { [weak self] in self?.onInitializationFailed?() }
    }

    func setAirportGroundDetail(_ page: DioramaResidentTile?, rect: DioramaRect?) { renderer.setAirportGroundDetail(page, rect: rect) }
    func setAirportGroundPaint(_ paint: DioramaResidentTile?) { renderer.setAirportGroundPaint(paint) }
    var transitionRenderer: DioramaRenderLayer { renderer }
    var hasAnalyticAirportGround: Bool { renderer.usesAnalyticAirportGround }
    var storedMeshBytes: Int { renderer.storedMeshBytes }

    func setLighting(time: DioramaTimeOfDay, reduced: Bool) {
        settingsLock.lock(); self.time = time; self.reduced = reduced; settingsLock.unlock()
        renderer.setVisible(Set(DioramaCategory.allCases), timeOfDay: time)
        renderer.setReducedEffects(reduced)
    }

    func renderingWillStart(_ device: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        renderer.renderingWillStart(device, colorPixelFormat: colorPixelFormat, depthStencilPixelFormat: depthStencilPixelFormat)
        isReady = renderer.isRendererReady
        guard isReady else { return }
        if let bridgeAlignment { viewport?.publishBridge(bridgeAlignment, owner: ObjectIdentifier(self)) }
        func upload<T>(_ list: [T]) -> MTLBuffer? {
            list.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress, !bytes.isEmpty else { return nil }
                return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
            }
        }
        vertexBuffer = upload(vertices); indexBuffer = upload(indices)
        if !vertices.isEmpty {
            projected = DioramaProjectedShadow(device: device, color: colorPixelFormat, depth: depthStencilPixelFormat, size: 1024)
        }
        print("[Landmark3D] shared renderer \(renderer.diagnostic); ground-shadow=\(projected == nil ? "unavailable" : "1024px mesh silhouette")")
        if landmarkID != nil, renderer.isRendererReady, let viewport { DioramaLandmarkPresence.shared.publish(host: self, viewport: viewport) }
        onInitialized?()
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard isReady else { return }
        settingsLock.lock(); let time = self.time; let reduced = self.reduced; settingsLock.unlock()
        let environment = viewport.flatMap { DioramaFleetLighting.shared.environment(at: GeoPoint(origin), viewport: $0) }
        let host = environment?.0
        let identity = host.map(ObjectIdentifier.init)
        if lastHeight == nil || lastSupport != identity || host == nil {
            lastHeight = usesSeaDatum ? 0 : floorAnchors.compactMap { point in
                host?.groundHeight(at: point) ?? parameters.elevationData?.getElevationFor(point.coordinate)?.doubleValue
            }.max() ?? 0
            lastSupport = identity
        }
        let height = lastHeight ?? 0
        renderer.setElevationOffset(height)
        renderer.render(parameters, mtlCommandBuffer: mtlCommandBuffer, mtlRenderPassDescriptor: mtlRenderPassDescriptor)
        guard let projected, let vertexBuffer, let indexBuffer, let target = mtlRenderPassDescriptor.colorAttachments[0].texture,
              parameters.projectionMatrix.count == 16 else { return }
        var projection = matrix_identity_double4x4
        for c in 0..<4 { for r in 0..<4 { projection[c,r] = parameters.projectionMatrix[c * 4 + r].doubleValue } }
        let point = Projection.project(origin, zoomScale: CGFloat(pow(2, parameters.zoom)))
        let scale = 1 / Double(Projection.metersPerPoint(for: origin.latitude, zoom: CGFloat(parameters.zoom)))
        var model = matrix_identity_double4x4
        model[0,0] = scale; model[1,1] = -scale; model[3,0] = point.x; model[3,1] = point.y; model[3,2] = height
        let transform = projection * model
        let matrix = simd_float4x4(columns: (SIMD4(transform.columns.0), SIMD4(transform.columns.1), SIMD4(transform.columns.2), SIMD4(transform.columns.3)))
        let lighting = DioramaLighting.uniforms(for: time, eye: .zero)
        let sun = SIMD3(lighting.sunDirection.x, lighting.sunDirection.y, lighting.sunDirection.z)
        let bounds = DioramaProjectedShadow.receiverBounds(minimum: minimum, maximum: maximum, sun: sun)
        guard DioramaRenderLayer.Range(category: .ground, start: 0, count: 0,
            minimum: SIMD3(bounds.x, bounds.y, -2), maximum: SIMD3(bounds.z, bounds.w, maximum.z)).intersects(matrix) else { return }
        if receiverKey != bounds || receiverHeight != height {
            let geographic = DioramaProjection(origin: origin)
            receiver = (0..<25).map { i in
                let x = bounds.x + (bounds.z - bounds.x) * Float(i % 5) / 4
                let y = bounds.y + (bounds.w - bounds.y) * Float(i / 5) / 4
                let c = geographic.coordinate(DV2(Double(x), Double(y)))
                let point = GeoPoint(latitude: c.latitude, longitude: c.longitude)
                let z = usesSeaDatum ? 0 : host?.groundHeight(at: point)
                    ?? parameters.elevationData?.getElevationFor(point.coordinate)?.doubleValue ?? height
                return SIMD4(x, y, Float(z - height + 0.035), 1)
            }
            receiverKey = bounds; receiverHeight = height
        }
        guard let field = projected.encode(command: mtlCommandBuffer, vertices: vertexBuffer, indices: indexBuffer, count: indices.count,
            minimum: minimum, maximum: maximum, sun: sun, receiver: receiver),
              let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Landmark ground/water cast-shadow receiver"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: Double(parameters.depthRange.min), zfar: Double(parameters.depthRange.max)))
        projected.receive(encoder: encoder, field: field, points: receiver, matrix: matrix,
            opacity: time == .night ? 0.12 : reduced ? 0.24 : 0.32)
        encoder.endEncoding()
    }

    func renderingWillEnd() {
        isReady = false
        viewport?.removeBridge(owner: ObjectIdentifier(self))
        DioramaLandmarkPresence.shared.remove(host: self)
        renderer.renderingWillEnd(); vertexBuffer = nil; indexBuffer = nil; projected = nil
        receiver.removeAll(); receiverKey = nil; receiverHeight = nil; lastHeight = nil; lastSupport = nil
    }
}
