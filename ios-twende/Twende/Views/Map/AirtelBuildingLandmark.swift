@_spi(Experimental) import MapboxMaps
import SceneKit

/// One cached landmark, clipped only against the underlying basemap building, with symmetric teardown.
@MainActor
final class AirtelBuildingLandmark {
    static let layerID = "twende-airtel-house"
    static let clipID = "twende-airtel-native-clip"
    static let sourceID = "twende-airtel-footprint"
    private static var cached: (Geometry, SCNScene)?
    var viewport: DioramaViewport?
    private var host: DioramaLandmarkLayer?
    private var pending: Task<Void, Never>?
    private var query: Cancelable?
    private var revision: UInt = 0
    private var fittedNative: Bool = false
    private var installedGeometry: Geometry?

    var diagnostic: String { host?.diagnostic ?? "not installed" }

    func update(on map: MapboxMap, settled: Bool = false) {
        let camera = map.cameraState
        updateLighting()
        guard camera.zoom >= 12.5, GeoPoint(camera.center).distanceKm(to: AirtelBuildingSite.anchor) < 6 else {
            remove(from: map); return
        }
        guard pending == nil, query == nil,
              !map.layerExists(withId: Self.layerID) || (settled && !fittedNative) else { return }
        let version = revision
        pending = Task { [weak self, weak map] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, let map, self.revision == version else { return }
            self.pending = nil
            self.query = map.queryRenderedFeatures(featureset: .standardBuildings) { [weak self, weak map] result in
                guard let self, let map, self.revision == version else { return }
                self.query = nil
                let candidates = (try? result.get())?.map(\.geometry) ?? []
                guard let geometry = AirtelBuildingSite.fittedGeometry(candidates: candidates) else { return }
                self.fittedNative = candidates.contains { $0 == geometry }
                if self.installedGeometry == geometry, map.layerExists(withId: Self.layerID) { return }
                do { try self.install(geometry: geometry, on: map) }
                catch {
                    self.remove(from: map)
                    print("[AirtelHouse] Landmark unavailable; native map building retained")
                }
            }
        }
    }

    /// Also used by the rendering probe to exercise the production clip and native Metal host.
    func install(geometry: Geometry, on map: MapboxMap) throws {
        let scene: SCNScene
        if let cache = Self.cached, cache.0 == geometry { scene = cache.1 }
        else { scene = AirtelBuildingGeometry.make(geometry: geometry); Self.cached = (geometry, scene) }
        removeLayers(from: map)
        do {
            let host = DioramaLandmarkLayer(origin: AirtelBuildingSite.anchor.coordinate, scene: scene,
                ring: AirtelBuildingSite.footprint(geometry)?.rings.first ?? [], isAirtel: true)
            host.viewport = viewport
            host.onInitializationFailed = { [weak self, weak map, weak host] in
                Task { @MainActor [weak self, weak map, weak host] in
                    guard let self, let map, let host, self.host === host else { return }
                    self.remove(from: map)
                }
            }
            configureLighting(host)
            try map.addCustomLayer(withId: Self.layerID, layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: Self.layerID, property: "slot", value: "middle")
            var source = GeoJSONSource(id: Self.sourceID)
            source.data = .geometry(BuildingIllumination.expanded(geometry, by: 0.6))
            try map.addSource(source)
            var clip = ClipLayer(id: Self.clipID, source: Self.sourceID)
            // Clip layers always cut fill-extrusions. Include models, but deliberately NOT symbols.
            // Top placement controls the clipping scope, not the custom building's draw ordering.
            clip.slot = .top
            clip.clipLayerScope = .constant(["basemap"])
            clip.clipLayerTypes = .constant([.model])
            try map.addLayer(clip)
            self.host = host
            installedGeometry = geometry
            map.triggerRepaint()
        } catch {
            removeLayers(from: map)
            throw error
        }
    }

    func updateLighting() { if let host { configureLighting(host) } }

    private func configureLighting(_ host: DioramaLandmarkLayer) {
        let state = DioramaState.shared
        let time = state.isEnabled && !state.isBasemapOnly ? state.timeOfDay
            : DioramaTimeOfDay(rawValue: AppSettings.shared.mapStyle.lightPreset) ?? .day
        host.setLighting(time: time, reduced: ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
    }

    func styleDidReload() {
        revision &+= 1
        pending?.cancel(); pending = nil
        query?.cancel(); query = nil
        installedGeometry = nil; host = nil; fittedNative = false
    }

    func remove(from map: MapboxMap) {
        styleDidReload()
        removeLayers(from: map)
    }

    private func removeLayers(from map: MapboxMap) {
        for id in [Self.clipID, Self.layerID] where map.layerExists(withId: id) { try? map.removeLayer(withId: id) }
        if map.sourceExists(withId: Self.sourceID) { try? map.removeSource(withId: Self.sourceID) }
        host = nil; installedGeometry = nil
    }
}
