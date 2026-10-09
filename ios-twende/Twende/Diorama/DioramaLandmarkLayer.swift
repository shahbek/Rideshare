@_spi(Experimental) import MapboxMaps
import SceneKit
import Metal
import simd

/// Bundled landmarks use the tile renderer's lighting, material response, AO, bloom and cached shadows.
/// Site geometry remains geographic; downloaded scenery and native surroundings are never regenerated.
nonisolated final class DioramaLandmarkLayer: NSObject, CustomLayerHost, @unchecked Sendable {
    let isAirtel: Bool
    var viewport: DioramaViewport?
    var onInitializationFailed: (@Sendable () -> Void)?
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
                    isAirtel: Bool = false, usesSeaDatum: Bool = false, bridgeAlignment: TanzaniteBridgeAlignment? = nil) {
        self.origin = origin; self.isAirtel = isAirtel; self.usesSeaDatum = usesSeaDatum
        self.bridgeAlignment = bridgeAlignment
        let projection = DioramaProjection(origin: origin)
        floorAnchors = ring.map { xy in
            let c = projection.coordinate(DV2(xy.x, xy.y))
            return GeoPoint(latitude: c.latitude, longitude: c.longitude)
        } + [GeoPoint(origin)]
        var packed: [BuildingRenderVertex] = [], cells: [String: (DioramaCategory, [UInt32], Bool)] = [:]
        let baked = BuildingRenderGeometry.vertices(from: scene)
        func append(_ v: [BuildingRenderVertex], category: DioramaCategory, doubleSided: Bool, translucent: Bool = false) {
            let base = UInt32(packed.count)
            packed.append(contentsOf: v)
            let p = (v[0].position + v[1].position + v[2].position) / 3
            // Glass triangles retain separate ranges for back-to-front composition.
            let key = "\(category.rawValue)/\(Int(floor(p.x / 60)))/\(Int(floor(p.y / 60)))/\(doubleSided)/\(translucent ? "glass-\(base)" : "solid")"
            if cells[key] == nil { cells[key] = (category, [], doubleSided) }
            cells[key]?.1.append(contentsOf: [base, base + 1, base + 2])
        }
        for start in stride(from: 0, to: baked.count - 2, by: 3) {
            let raw = Array(baked[start..<(start + 3)])
            let code = raw[0].appearance.w
            // Old billboard halos carried a different normal grammar; real bloom replaces them.
            if code == 3 { continue }
            let material: Float = code == -12 ? 15 : code == 1 || code == 2 || code == -11 ? 6 : code == -5 ? 10 : code == -2 ? 13 : code == -6 ? 4 : code == -7 ? 3 : code == -8 ? 11 : code == -9 || code == 4 ? 0 : 12
            var solid = raw.map { v in
                BuildingRenderVertex(position: v.position, normal: v.normal,
                    color: code == -11 ? SIMD4(0.255, 0.494, 0.525, 1) : v.color,
                    appearance: SIMD4(0.85, material, material == 12 ? 100 + v.position.z : 0, 0))
            }
            let p = solid.map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
            let n = solid.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.normal.x, $1.normal.y, $1.normal.z) }
            if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) < 0 { solid.swapAt(1, 2) }
            let category: DioramaCategory = code == -5 || code == -2 ? .vegetation : code == -6 ? .ground : .buildings
            append(solid, category: category, doubleSided: code == -5 || material == 6, translucent: code == -12)
            if code == 4 || code == 2 || code == -11 {
                let glow = solid.map { v in BuildingRenderVertex(position: v.position, normal: v.normal,
                    color: code == -11 ? SIMD4(1, 0.78, 0.46, 1) : v.color, appearance: SIMD4(0.85, 0, 0, 4)) }
                append(glow, category: .windowGlow, doubleSided: true)
            }
        }
        var indices: [UInt32] = [], ranges: [DioramaRenderLayer.Range] = []
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for key in cells.keys.sorted() {
            guard let (category, batch, doubleSided) = cells[key] else { continue }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for id in batch { let p = packed[Int(id)].position; lo = simd_min(lo, SIMD3(p.x,p.y,p.z)); hi = simd_max(hi, SIMD3(p.x,p.y,p.z)) }
            ranges.append(.init(category: category, start: indices.count, count: batch.count, minimum: lo, maximum: hi, doubleSided: doubleSided, translucent: key.contains("/glass-")))
            indices.append(contentsOf: batch)
            if !category.isEmissive { low = simd_min(low, lo); high = simd_max(high, hi) }
        }
        vertices = packed; self.indices = indices; minimum = low; maximum = high
        let rect = DioramaRect(minX: Double(low.x) - 2, minY: Double(low.y) - 2, maxX: Double(high.x) + 2, maxY: Double(high.y) + 2)
        var lights: [DioramaLight] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            guard node.name == "landmarkPointLight", let light = node.light else { return }
            let p = node.simdWorldPosition
            lights.append(.init(position: DV3(Double(p.x), Double(p.y), Double(p.z)),
                color: SIMD3(1, 0.78, 0.46), radius: Double(light.attenuationEndDistance), intensity: Float(light.intensity) / 1000))
        }
        renderer = DioramaRenderLayer(origin: origin, vertices: packed, indices: indices, ranges: ranges,
            lightGrid: DioramaLightGrid.build(lights, rect: rect, cells: 8, perCell: 16), waterHeight: 0,
            groundImage: nil, groundRect: rect, visible: Set(DioramaCategory.allCases), timeOfDay: .day,
            animates: false, materialsPrepared: true)
        renderer.setTileCoverage(edges: .zero, role: 0, paired: false)
        super.init()
        renderer.onInitializationFailed = { [weak self] in self?.onInitializationFailed?() }
    }

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
        projected = DioramaProjectedShadow(device: device, color: colorPixelFormat, depth: depthStencilPixelFormat, size: 1024)
        print("[Landmark3D] shared renderer \(renderer.diagnostic); ground-shadow=\(projected == nil ? "unavailable" : "1024px mesh silhouette")")
        if isAirtel, renderer.diagnostic.hasPrefix("ready"), let viewport { DioramaLandmarkPresence.shared.publish(host: self, viewport: viewport) }
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
