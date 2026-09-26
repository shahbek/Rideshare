@_spi(Experimental) import MapboxMaps
import SceneKit

/// Independent real-location landmark with a single cached mesh and distance/zoom lifecycle.
@MainActor
final class TanzaniteBridgeLandmark {
    static let layerID = "twende-tanzanite-bridge"
    private static var cachedScene: SCNScene?
    private var host: BuildingRenderLayer?
    private var pending: Task<Void, Never>?

    func update(on map: MapboxMap) {
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
            let host = BuildingRenderLayer(origin: TanzaniteBridgeAlignment.anchor.coordinate, scene: scene)
            try map.addCustomLayer(withId: Self.layerID, layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: Self.layerID, property: "slot", value: "middle")
            self.host = host
            map.triggerRepaint()
        } catch {
            if map.layerExists(withId: Self.layerID) { try? map.removeLayer(withId: Self.layerID) }
            print("[TanzaniteBridge] Landmark layer unavailable")
        }
    }

    func styleDidReload() { pending?.cancel(); pending = nil; host = nil }
    func remove(from map: MapboxMap) {
        pending?.cancel(); pending = nil
        if map.layerExists(withId: Self.layerID) { try? map.removeLayer(withId: Self.layerID) }
        host = nil
    }
}
