@_spi(Experimental) import MapboxMaps
import SceneKit

/// Independently cached landmark layers. Only each mapped building is clipped; symbols and roads survive.
@MainActor
final class DarCityLandmarks {
    var viewport: DioramaViewport?
    private var hosts: [String: DioramaLandmarkLayer] = [:]
    private static var scenes: [String: SCNScene] = [:]
    private var pending: Task<Void, Never>?
    private var revision: UInt = 0

    static func layerID(_ id: String) -> String { "twende-landmark-\(id)" }
    static func clipID(_ id: String) -> String { "twende-landmark-clip-\(id)" }
    static func sourceID(_ id: String) -> String { "twende-landmark-site-\(id)" }

    func update(on map: MapboxMap) {
        updateLighting()
        let desired = DarLandmarkSite.all.filter { map.cameraState.zoom >= 14.5 && GeoPoint(map.cameraState.center).distanceKm(to: $0.anchor) < 1.6 }
        for id in Array(hosts.keys) where !desired.contains(where: { $0.id == id }) { remove(id: id, from: map) }
        guard pending == nil, desired.contains(where: { !map.layerExists(withId: Self.layerID($0.id)) }) else { return }
        let version = revision
        pending = Task { [weak self, weak map] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, let map, self.revision == version else { return }
            self.pending = nil
            for site in desired where map.cameraState.zoom >= 14.5 && GeoPoint(map.cameraState.center).distanceKm(to: site.anchor) < 1.6 {
                guard !map.layerExists(withId: Self.layerID(site.id)) else { continue }
                do { try self.install(site, on: map) }
                catch { self.remove(id: site.id, from: map); print("[DarLandmarks] Installation failed; native building retained") }
            }
        }
    }

    func install(_ site: DarLandmarkSite, on map: MapboxMap) throws {
        remove(id: site.id, from: map)
        let scene = Self.scenes[site.id] ?? DarLandmarkGeometry.make(site)
        Self.scenes[site.id] = scene
        do {
            let host = DioramaLandmarkLayer(origin: site.anchor.coordinate, scene: scene, ring: site.footprint?.rings.first ?? [],
                landmarkID: site.kind.hasPrefix("morocco-") ? site.id : nil)
            host.viewport = viewport
            host.onInitializationFailed = { [weak self, weak map, weak host] in
                Task { @MainActor [weak self, weak map, weak host] in
                    guard let self, let map, let host, self.hosts[site.id] === host else { return }
                    self.remove(id: site.id, from: map)
                }
            }
            configureLighting(host)
            try map.addCustomLayer(withId: Self.layerID(site.id), layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: Self.layerID(site.id), property: "slot", value: "middle")
            var source = GeoJSONSource(id: Self.sourceID(site.id))
            source.data = .geometry(BuildingIllumination.expanded(site.geometry, by: 0.35))
            try map.addSource(source)
            var clip = ClipLayer(id: Self.clipID(site.id), source: Self.sourceID(site.id))
            clip.slot = .top
            clip.clipLayerScope = .constant(["basemap"])
            clip.clipLayerTypes = .constant([.model])
            try map.addLayer(clip)
            hosts[site.id] = host
            map.triggerRepaint()
        } catch { remove(id: site.id, from: map); throw error }
    }

    func updateLighting() { for host in hosts.values { configureLighting(host) } }
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
        hosts.removeAll()
    }

    func remove(from map: MapboxMap) {
        revision &+= 1
        pending?.cancel(); pending = nil
        for site in DarLandmarkSite.all { remove(id: site.id, from: map) }
    }

    private func remove(id: String, from map: MapboxMap) {
        for layer in [Self.clipID(id), Self.layerID(id)] where map.layerExists(withId: layer) { try? map.removeLayer(withId: layer) }
        if map.sourceExists(withId: Self.sourceID(id)) { try? map.removeSource(withId: Self.sourceID(id)) }
        hosts[id] = nil
    }
}
