@_spi(Experimental) import MapboxMaps
import SceneKit

/// Independent real-location landmark with a single cached mesh and distance/zoom lifecycle.
@MainActor
final class TanzaniteBridgeLandmark {
    static let layerID = "twende-tanzanite-bridge"
    private static var cachedScene: SCNScene?
    var viewport: DioramaViewport?
    private var host: DioramaLandmarkLayer?
    private var pending: Task<Void, Never>?

    func update(on map: MapboxMap) {
        updateLighting()
        let camera = map.cameraState
        let distance = GeoPoint(camera.center).distanceKm(to: TanzaniteBridgeAlignment.anchor)
        guard camera.zoom >= 12.5, distance < 5 else { remove(from: map); return }
        guard !map.layerExists(withId: Self.layerID), pending == nil else { return }
        pending = Task { [weak self, weak map] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, let map else { return }
            self.pending = nil
            guard let alignment = TanzaniteBridgeAlignment.load() else { return }
            let scene: SCNScene
            if let cached = Self.cachedScene { scene = cached }
            else {
                scene = TanzaniteBridgeGeometry.make(alignment: alignment)
                Self.cachedScene = scene
            }
            self.install(scene: scene, on: map)
        }
    }

    private func install(scene: SCNScene, on map: MapboxMap) {
        do {
            let host = DioramaLandmarkLayer(origin: TanzaniteBridgeAlignment.anchor.coordinate, scene: scene, usesSeaDatum: true)
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
            self.host = host
            map.triggerRepaint()
        } catch {
            if map.layerExists(withId: Self.layerID) { try? map.removeLayer(withId: Self.layerID) }
            print("[TanzaniteBridge] Landmark layer unavailable")
        }
    }

    func updateLighting() { if let host { configureLighting(host) } }
    private func configureLighting(_ host: DioramaLandmarkLayer) {
        let state = DioramaState.shared
        host.setLighting(time: state.isEnabled && !state.isBasemapOnly ? state.timeOfDay
            : DioramaTimeOfDay(rawValue: AppSettings.shared.mapStyle.lightPreset) ?? .day,
            reduced: ProcessInfo.processInfo.isLowPowerModeEnabled
                || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
    }

    func styleDidReload() { pending?.cancel(); pending = nil; host = nil }
    func remove(from map: MapboxMap) {
        pending?.cancel(); pending = nil
        if map.layerExists(withId: Self.layerID) { try? map.removeLayer(withId: Self.layerID) }
        host = nil
    }
}
