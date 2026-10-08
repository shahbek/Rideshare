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
    private var revision: UInt = 0

    func update(on map: MapboxMap) {
        updateLighting()
        let camera = map.cameraState
        let distance = GeoPoint(camera.center).distanceKm(to: TanzaniteBridgeAlignment.anchor)
        guard camera.zoom >= 12.5, distance < 5 else { remove(from: map); return }
        guard !map.layerExists(withId: Self.layerID), pending == nil else { return }
        let expected = revision
        pending = Task { [weak self, weak map] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, let self, let map, self.revision == expected else { return }
            self.pending = nil
            guard map.cameraState.zoom >= 12.5,
                  GeoPoint(map.cameraState.center).distanceKm(to: TanzaniteBridgeAlignment.anchor) < 5 else { return }
            guard let alignment = TanzaniteBridgeAlignment.load() else { return }
            let scene: SCNScene
            if let cached = Self.cachedScene { scene = cached }
            else {
                scene = TanzaniteBridgeGeometry.make(alignment: alignment)
                Self.cachedScene = scene
            }
            self.install(scene: scene, alignment: alignment, on: map)
        }
    }

    private func install(scene: SCNScene, alignment: TanzaniteBridgeAlignment, on map: MapboxMap) {
        do {
            let host = DioramaLandmarkLayer(origin: TanzaniteBridgeAlignment.anchor.coordinate, scene: scene,
                usesSeaDatum: true, bridgeAlignment: alignment)
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

    func styleDidReload() {
        revision &+= 1
        pending?.cancel(); pending = nil
        if let host { viewport?.removeBridge(owner: ObjectIdentifier(host)) }
        host = nil
    }
    func remove(from map: MapboxMap) {
        revision &+= 1
        pending?.cancel(); pending = nil
        if map.layerExists(withId: Self.layerID) { try? map.removeLayer(withId: Self.layerID) }
        if let host { viewport?.removeBridge(owner: ObjectIdentifier(host)) }
        host = nil
    }
}
