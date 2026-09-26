#if DEBUG
@_spi(Experimental) import MapboxMaps
import UIKit
import SceneKit

/// Debug-only harness that renders a real `MapView` in a window, applies one vehicle pipeline and
/// measures how many pixels around the anchor actually changed. Used by the test target to decide
/// empirically which 3D pipeline renders on this SDK/simulator instead of guessing.
final class MapRenderProbe {
    enum Pipeline {
        /// Style model + `ModelLayer` fed by a GeoJSON point.
        case modelLayer(url: URL, scale: Double, slot: Slot?, type: ModelType)
        /// Location puck rendered as a 3D model at a fixed location.
        case puck3D(url: URL, scale: Double)
        /// SceneKit view hosted in a `ViewAnnotation`.
        case procedural
        /// Native custom-layer architecture with a filled deck and reflective glass.
        case architecture(BuildingMaterialStyle)
        /// Exercises the two additional roof renderers in the real native map pass.
        case architecturalRoof(BuildingRoof.Style)
        case bridge
        case bridgeCrown
        case airtel(bearing: Double)
        case cityLandmark(String)
        case glassTower
        /// Exercises the production selection, actual footprint and height rather than a synthetic test box.
        case selectedArchitecture
        /// Nothing added; measures snapshot noise.
        case none
    }

    struct Result: CustomStringConvertible {
        var styleLoaded: Bool = false
        var idleBefore: Bool = false
        var idleAfter: Bool = false
        var mapChanged: Int = 0
        var architectureContribution: Int = 0
        var glowContribution: Int = 0
        var matchedLandmarkBuildings: Int = 0
        var nativeClipContribution: Int = 0
        var landmarkLifecycleRestored: Bool = false
        var neighbourCount: Int = 0
        var neighbourContribution: Int = 0
        var hierarchyChanged: Int = 0
        var labelInkBefore: Int = 0
        var labelInkAfter: Int = 0
        var nativeLabelPixelsBefore: Int = 0
        var nativeLabelPixelsAfter: Int = 0
        var probeArea: Int = 0
        var errors: [String] = []

        var description: String {
            "style=\(styleLoaded) idle=\(idleBefore)/\(idleAfter) mapΔ=\(mapChanged) geometryΔ=\(architectureContribution) hierΔ=\(hierarchyChanged) area=\(probeArea) landmarkMatches=\(matchedLandmarkBuildings) clipΔ=\(nativeClipContribution) lifecycle=\(landmarkLifecycleRestored) errors=\(errors)"
        }
    }

    private static let center = CLLocationCoordinate2D(latitude: -6.8115, longitude: 39.2875)
    private var window: UIWindow? = nil
    private var mapView: MapView? = nil
    private var marker: ProceduralTukTukMarker? = nil
    private var architecture: BuildingRenderLayer? = nil
    private var selectedArchitecture: BuildingIllumination? = nil
    private var airtel: AirtelBuildingLandmark? = nil
    private var cityLandmarks: DarCityLandmarks? = nil

    func run(_ pipeline: Pipeline, isolatesGeometry: Bool = false) async -> Result {
        var result = Result()
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            result.errors.append("no window scene")
            return result
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 80, width: 320, height: 320)
        window.windowLevel = .alert + 1
        window.backgroundColor = .magenta
        window.isHidden = false
        self.window = window

        let isBridge: Bool
        if case .bridge = pipeline { isBridge = true } else { isBridge = false }
        let isCrown: Bool
        if case .bridgeCrown = pipeline { isCrown = true } else { isCrown = false }
        let airtelBearing: Double?
        if case .airtel(let bearing) = pipeline { airtelBearing = bearing } else { airtelBearing = nil }
        let citySite: DarLandmarkSite?
        if case .cityLandmark(let id) = pipeline { citySite = DarLandmarkSite.all.first { $0.id == id } } else { citySite = nil }
        let probeCenter = citySite?.anchor.coordinate ?? (airtelBearing != nil ? AirtelBuildingSite.anchor.coordinate : isBridge ? TanzaniteBridgeAlignment.anchor.coordinate : Self.center)
        let options = MapInitOptions(
            cameraOptions: CameraOptions(center: probeCenter, zoom: citySite != nil ? (citySite?.kind == "tower" ? 16.3 : 18) : airtelBearing != nil ? 18 : isBridge ? 15.3 : isCrown ? 20 : 17, bearing: citySite.map { ($0.bearing + 180).truncatingRemainder(dividingBy: 360) } ?? airtelBearing ?? (isBridge ? 25 : 0), pitch: 45),
            styleURI: .standard
        )
        let mapView = MapView(frame: window.bounds, mapInitOptions: options)
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden
        window.addSubview(mapView)
        self.mapView = mapView

        var loadErrors: [String] = []
        let errorToken = mapView.mapboxMap.onMapLoadingError.observe { error in
            loadErrors.append("\(error.type): \(error.message)")
        }
        defer { errorToken.cancel() }

        result.styleLoaded = await waitFor(mapView.mapboxMap.onStyleLoaded, timeout: 25)
        guard result.styleLoaded else {
            result.errors.append("style never loaded")
            result.errors.append(contentsOf: loadErrors)
            tearDown()
            return result
        }
        try? mapView.mapboxMap.setStyleImportConfigProperty(for: "basemap", config: "lightPreset", value: "day")

        if isolatesGeometry {
            try? mapView.mapboxMap.setStyleImportConfigProperty(for: "basemap", config: "show3dObjects", value: false)
        }
        result.idleBefore = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 20)
        try? await Task.sleep(for: .seconds(1.5))
        let protectsLabel: Bool
        if case .glassTower = pipeline { protectsLabel = true } else { protectsLabel = airtelBearing != nil || citySite != nil }
        if protectsLabel {
            do {
                try installProtectedLabel(on: mapView.mapboxMap, coordinate: probeCenter)
                mapView.mapboxMap.triggerRepaint()
                _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 5)
            } catch { result.errors.append("label setup failed") }
        }
        let baselineMap = captureMap()
        let baselineHierarchy = captureHierarchy()
        if case .selectedArchitecture = pipeline {
            setNativeLabels(false, on: mapView.mapboxMap)
            mapView.mapboxMap.triggerRepaint()
            _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 5)
            result.nativeLabelPixelsBefore = Self.diff(baselineMap, captureMap()).changed
            setNativeLabels(true, on: mapView.mapboxMap)
            mapView.mapboxMap.triggerRepaint()
            _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 5)
        }

        do {
            if let site = citySite {
                let buildings = await withCheckedContinuation { continuation in
                    _ = mapView.mapboxMap.queryRenderedFeatures(featureset: .standardBuildings) { queryResult in
                        continuation.resume(returning: (try? queryResult.get()) ?? [])
                    }
                }
                result.matchedLandmarkBuildings = buildings.filter { site.matches($0.geometry) }.count
                let landmarks = DarCityLandmarks()
                try landmarks.install(site, on: mapView.mapboxMap)
                cityLandmarks = landmarks
            } else if airtelBearing != nil {
                let buildings = await withCheckedContinuation { continuation in
                    _ = mapView.mapboxMap.queryRenderedFeatures(featureset: .standardBuildings) { queryResult in
                        continuation.resume(returning: (try? queryResult.get()) ?? [])
                    }
                }
                result.matchedLandmarkBuildings = buildings.filter { AirtelBuildingSite.matches($0.geometry) }.count
                guard let geometry = AirtelBuildingSite.fittedGeometry(candidates: buildings.map(\.geometry)) else {
                    result.errors.append("apply: Airtel footprint missing")
                    tearDown(); return result
                }
                let landmark = AirtelBuildingLandmark()
                try landmark.install(geometry: geometry, on: mapView.mapboxMap)
                airtel = landmark
            } else if case .selectedArchitecture = pipeline {
                let buildings = await withCheckedContinuation { continuation in
                    _ = mapView.mapboxMap.queryRenderedFeatures(with: CGPoint(x: 160, y: 160), featureset: .standardBuildings) { result in
                        continuation.resume(returning: (try? result.get()) ?? [])
                    }
                }
                if let building = buildings.first {
                    let illumination = BuildingIllumination()
                    illumination.show([building], on: mapView.mapboxMap)
                    selectedArchitecture = illumination
                } else { result.errors.append("apply: no real building at the probe coordinate") }
            } else {
                try apply(pipeline, to: mapView)
            }
        } catch {
            result.errors.append("apply: \(error)")
        }

        result.idleAfter = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 20)
        try? await Task.sleep(for: .seconds(4))
        // Force one more frame so async model loads that completed during the sleep get drawn.
        mapView.mapboxMap.triggerRepaint()
        _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 10)
        try? await Task.sleep(for: .seconds(1))

        let afterMap = captureMap()
        let afterHierarchy = captureHierarchy()
        if case .bridgeCrown = pipeline {
            do {
                try mapView.mapboxMap.removeLayer(withId: "architecture-probe")
                try installCrown(on: mapView.mapboxMap, includeHalo: false)
                mapView.mapboxMap.triggerRepaint()
                _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 8)
                result.glowContribution = Self.diff(afterMap, captureMap()).changed
            } catch { result.errors.append("apply: crown glow comparison failed") }
        }
        if protectsLabel {
            result.labelInkBefore = Self.labelInk(baselineMap)
            result.labelInkAfter = Self.labelInk(afterMap)
        }
        if let cityLandmarks, let site = citySite, let map = mapView.mapboxMap {
            do {
                try map.removeLayer(withId: DarCityLandmarks.layerID(site.id))
                map.triggerRepaint()
                _ = await waitFor(map.onMapIdle, timeout: 8)
                let clipped = captureMap()
                result.architectureContribution = Self.diff(afterMap, clipped).changed
                cityLandmarks.remove(from: map)
                map.triggerRepaint()
                _ = await waitFor(map.onMapIdle, timeout: 8)
                result.nativeClipContribution = Self.diff(clipped, captureMap()).changed
                let removed = !map.layerExists(withId: DarCityLandmarks.clipID(site.id)) && !map.sourceExists(withId: DarCityLandmarks.sourceID(site.id))
                cityLandmarks.styleDidReload()
                try cityLandmarks.install(site, on: map)
                result.landmarkLifecycleRestored = removed && map.layerExists(withId: DarCityLandmarks.layerID(site.id))
            } catch { result.errors.append("apply: city landmark lifecycle failed: \(error)") }
        }
        if let airtel, let map = mapView.mapboxMap {
            result.errors.append("renderer: \(airtel.diagnostic)")
            do {
                if let geometry = AirtelBuildingSite.geometry {
                    let unlitScene = AirtelBuildingGeometry.make(geometry: geometry)
                    var halos: [SCNNode] = []
                    unlitScene.rootNode.enumerateChildNodes { node, _ in
                        if node.name == "airtelSignHalo" { halos.append(node) }
                        if node.geometry?.firstMaterial?.name == "airtel.signLight" {
                            node.geometry?.materials = [AirtelBuildingGeometry.red]
                        }
                    }
                    for halo in halos { halo.removeFromParentNode() }
                    try map.removeLayer(withId: AirtelBuildingLandmark.layerID)
                    let unlit = BuildingRenderLayer(origin: AirtelBuildingSite.anchor.coordinate, scene: unlitScene)
                    try map.addCustomLayer(withId: AirtelBuildingLandmark.layerID, layerHost: unlit, layerPosition: nil)
                    try await map.setLayerProperty(for: AirtelBuildingLandmark.layerID, property: "slot", value: "middle")
                    map.triggerRepaint()
                    _ = await waitFor(map.onMapIdle, timeout: 8)
                    result.glowContribution = Self.diff(afterMap, captureMap()).changed
                }
                try map.removeLayer(withId: AirtelBuildingLandmark.layerID)
                map.triggerRepaint()
                _ = await waitFor(map.onMapIdle, timeout: 8)
                let clippedOnly = captureMap()
                result.architectureContribution = Self.diff(afterMap, clippedOnly).changed
                airtel.remove(from: map)
                map.triggerRepaint()
                _ = await waitFor(map.onMapIdle, timeout: 8)
                result.nativeClipContribution = Self.diff(clippedOnly, captureMap()).changed
                let removed = !map.layerExists(withId: AirtelBuildingLandmark.clipID) && !map.sourceExists(withId: AirtelBuildingLandmark.sourceID)
                airtel.styleDidReload()
                if let geometry = AirtelBuildingSite.geometry {
                    try airtel.install(geometry: geometry, on: map)
                    result.landmarkLifecycleRestored = removed && map.layerExists(withId: AirtelBuildingLandmark.layerID) && map.layerExists(withId: AirtelBuildingLandmark.clipID)
                }
            } catch { result.errors.append("apply: Airtel lifecycle comparison failed: \(error)") }
        }
        if let selectedArchitecture {
            setNativeLabels(false, on: mapView.mapboxMap)
            mapView.mapboxMap.triggerRepaint()
            _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 5)
            result.nativeLabelPixelsAfter = Self.diff(afterMap, captureMap()).changed
            setNativeLabels(true, on: mapView.mapboxMap)
            mapView.mapboxMap.triggerRepaint()
            _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 5)
            result.neighbourCount = selectedArchitecture.neighbourCount
            // Keep the production coloured fallback and basemap intact; isolate the actual mesh's pixels.
            do {
                try mapView.mapboxMap.removeLayer(withId: "twende-building-architecture-mesh")
                mapView.mapboxMap.triggerRepaint()
                _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 8)
                let withoutSelected = captureMap()
                result.architectureContribution = Self.diff(afterMap, withoutSelected).changed
                if mapView.mapboxMap.layerExists(withId: "twende-neighbourhood-architecture") {
                    try mapView.mapboxMap.removeLayer(withId: "twende-neighbourhood-architecture")
                    mapView.mapboxMap.triggerRepaint()
                    _ = await waitFor(mapView.mapboxMap.onMapIdle, timeout: 8)
                    result.neighbourContribution = Self.diff(withoutSelected, captureMap()).changed
                }
            } catch { result.errors.append("mesh removal failed") }
        }
        let (mapChanged, area) = Self.diff(baselineMap, afterMap)
        let (hierChanged, _) = Self.diff(baselineHierarchy, afterHierarchy)
        result.mapChanged = mapChanged
        result.hierarchyChanged = hierChanged
        result.probeArea = area
        result.errors.append(contentsOf: loadErrors)
        if let architecture {
            result.errors.append("renderer: \(architecture.diagnostic)")
            let native = await withCheckedContinuation { continuation in
                _ = mapView.mapboxMap.queryRenderedFeatures(with: CGPoint(x: 160, y: 160), featureset: .standardBuildings) { result in
                    continuation.resume(returning: (try? result.get()) ?? [])
                }
            }
            result.errors.append("native buildings: \(native.prefix(3).map { $0.properties })")
        }
        tearDown()
        return result
    }

    private func apply(_ pipeline: Pipeline, to mapView: MapView) throws {
        let map: MapboxMap = mapView.mapboxMap
        switch pipeline {
        case .none, .selectedArchitecture, .airtel, .cityLandmark:
            break
        case .modelLayer(let url, let scale, let slot, let type):
            try map.addStyleModel(modelId: "probe-model", modelUri: url.absoluteString)
            var source = GeoJSONSource(id: "probe-source")
            source.data = .feature(Feature(geometry: .point(Point(Self.center))))
            try map.addSource(source)
            var layer = ModelLayer(id: "probe-layer", source: "probe-source")
            layer.modelId = .constant("probe-model")
            layer.modelType = .constant(type)
            layer.modelScale = .constant([scale, scale, scale])
            layer.modelRotation = .constant([0, 0, 0])
            layer.modelTranslation = .constant([0, 0, 0])
            layer.modelOpacity = .constant(1)
            layer.slot = slot
            try map.addLayer(layer)
        case .puck3D(let url, let scale):
            let model = Model(uri: url, orientation: [0, 0, 0])
            let configuration = Puck3DConfiguration(
                model: model,
                modelScale: .constant([scale, scale, scale]),
                modelOpacity: .constant(1)
            )
            mapView.location.options.puckType = .puck3D(configuration)
            mapView.location.options.puckBearingEnabled = false
            mapView.location.override(locationProvider: Signal(just: [Location(coordinate: Self.center)]))
        case .procedural:
            marker = ProceduralTukTukMarker(mapView: mapView, point: GeoPoint(Self.center), heading: 45, isAssigned: true)
        case .bridgeCrown:
            try installCrown(on: map, includeHalo: true)
        case .bridge:
            guard let alignment = TanzaniteBridgeAlignment.load() else { throw NSError(domain: "bridge", code: 1) }
            let host = BuildingRenderLayer(origin: TanzaniteBridgeAlignment.anchor.coordinate, scene: TanzaniteBridgeGeometry.make(alignment: alignment))
            try map.addCustomLayer(withId: "architecture-probe", layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: "architecture-probe", property: "slot", value: "middle")
            architecture = host
        case .glassTower:
            let origin = GeoPoint(Self.center)
            let ring = [origin.offset(eastMetres: -20, northMetres: -16), origin.offset(eastMetres: 20, northMetres: -16), origin.offset(eastMetres: 20, northMetres: 16), origin.offset(eastMetres: -20, northMetres: 16), origin.offset(eastMetres: -20, northMetres: -16)].map(\.coordinate)
            let scene = SCNScene()
            scene.rootNode.addChildNode(BuildingArchitecture.make(geometry: .polygon(Polygon([ring])), origin: Self.center, base: 0, roof: 85))
            let host = BuildingRenderLayer(origin: Self.center, scene: scene)
            try map.addCustomLayer(withId: "architecture-probe", layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: "architecture-probe", property: "slot", value: "middle")
            architecture = host
        case .architecturalRoof(let roofStyle):
            let origin = GeoPoint(Self.center)
            let ring = [origin.offset(eastMetres: -20, northMetres: -12), origin.offset(eastMetres: 20, northMetres: -12), origin.offset(eastMetres: 20, northMetres: 12), origin.offset(eastMetres: -20, northMetres: 12), origin.offset(eastMetres: -20, northMetres: -12)].map(\.coordinate)
            let scene = BuildingIllumination.scene()
            scene.rootNode.addChildNode(BuildingArchitecture.make(geometry: .polygon(Polygon([ring])), origin: Self.center, base: 0, roof: 18, roofStyle: roofStyle, identity: BuildingIdentity(seed: 7)))
            let host = BuildingRenderLayer(origin: Self.center, scene: scene)
            try map.addCustomLayer(withId: "architecture-probe", layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: "architecture-probe", property: "slot", value: "middle")
            architecture = host
        case .architecture(let style):
            let origin = GeoPoint(Self.center)
            let ring = [origin.offset(eastMetres: -20, northMetres: -16), origin.offset(eastMetres: 20, northMetres: -16), origin.offset(eastMetres: 20, northMetres: 16), origin.offset(eastMetres: -20, northMetres: 16), origin.offset(eastMetres: -20, northMetres: -16)].map(\.coordinate)
            let scene = BuildingIllumination.scene()
            scene.rootNode.addChildNode(BuildingArchitecture.make(geometry: .polygon(Polygon([ring])), origin: Self.center, base: 0, roof: 16, style: style))
            let host = BuildingRenderLayer(origin: Self.center, scene: scene)
            try map.addCustomLayer(withId: "architecture-probe", layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: "architecture-probe", property: "slot", value: "middle")
            architecture = host
        }
    }

    private func installCrown(on map: MapboxMap, includeHalo: Bool) throws {
        let scene = SCNScene()
        let crown = TanzaniteCrown.make(origin: .zero, forward: SIMD3(1, 0, 0), across: SIMD3(0, 1, 0))
        // Isolate the production lantern at street level for a close pixel comparison.
        crown.position.z = -75
        if !includeHalo { crown.childNode(withName: "tanzaniteLightHalo", recursively: true)?.removeFromParentNode() }
        scene.rootNode.addChildNode(crown)
        let host = BuildingRenderLayer(origin: Self.center, scene: scene)
        try map.addCustomLayer(withId: "architecture-probe", layerHost: host, layerPosition: nil)
        try map.setLayerProperty(for: "architecture-probe", property: "slot", value: "middle")
        architecture = host
    }

    private func setNativeLabels(_ visible: Bool, on map: MapboxMap) {
        for config in ["showPointOfInterestLabels", "showPlaceLabels", "showRoadLabels", "showLandmarkIconLabels"] {
            try? map.setStyleImportConfigProperty(for: "basemap", config: config, value: visible)
        }
    }

    private func installProtectedLabel(on map: MapboxMap, coordinate: CLLocationCoordinate2D) throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 18))
        let image = renderer.image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 18))
        }
        try map.addImage(image, id: "probe-label-image")
        var source = GeoJSONSource(id: "probe-label-source")
        source.data = .feature(Feature(geometry: .point(Point(coordinate))))
        try map.addSource(source)
        var layer = SymbolLayer(id: "probe-label", source: source.id)
        layer.slot = .top
        layer.iconImage = .constant(.name("probe-label-image"))
        layer.iconAllowOverlap = .constant(true)
        layer.iconOcclusionOpacity = .constant(1)
        try map.addLayer(layer)
    }

    private static func labelInk(_ image: UIImage?) -> Int {
        guard let data = rgba(image) else { return 0 }
        return stride(from: 0, to: data.count, by: 4).reduce(0) { count, i in
            count + (data[i] > 200 && data[i + 1] < 70 && data[i + 2] > 200 ? 1 : 0)
        }
    }

    private func tearDown() {
        marker?.remove()
        marker = nil
        if let map = mapView?.mapboxMap, map.layerExists(withId: "architecture-probe") { try? map.removeLayer(withId: "architecture-probe") }
        architecture = nil
        if let map = mapView?.mapboxMap { selectedArchitecture?.remove(from: map) }
        selectedArchitecture = nil
        if let map = mapView?.mapboxMap { airtel?.remove(from: map) }
        airtel = nil
        if let map = mapView?.mapboxMap { cityLandmarks?.remove(from: map) }
        cityLandmarks = nil
        mapView?.removeFromSuperview()
        mapView = nil
        window?.isHidden = true
        window = nil
    }

    private func waitFor<T>(_ signal: Signal<T>, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            box.token = signal.observeNext { _ in box.finish(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { box.finish(false) }
        }
    }

    private final class ContinuationBox {
        private var continuation: CheckedContinuation<Bool, Never>?
        var token: AnyCancelable?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            token?.cancel()
            continuation.resume(returning: value)
        }
    }

    private func captureMap() -> UIImage? {
        guard let mapView else { return nil }
        return try? mapView.snapshot()
    }

    private func captureHierarchy() -> UIImage? {
        guard let mapView else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: mapView.bounds)
        return renderer.image { _ in
            mapView.drawHierarchy(in: mapView.bounds, afterScreenUpdates: true)
        }
    }

    /// Counts pixels in the central 50% square whose colour moved by more than a noise threshold.
    private static func diff(_ a: UIImage?, _ b: UIImage?) -> (changed: Int, area: Int) {
        guard let a = rgba(a), let b = rgba(b) else { return (-1, 0) }
        let size = 160
        let start = size / 4, end = size * 3 / 4
        var changed = 0
        for y in start..<end {
            for x in start..<end {
                let i = (y * size + x) * 4
                let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                if d > 60 { changed += 1 }
            }
        }
        return (changed, (end - start) * (end - start))
    }

    private static func rgba(_ image: UIImage?) -> [UInt8]? {
        guard let cgImage = image?.cgImage else { return nil }
        let size = 160
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return bytes
    }
}
#endif
