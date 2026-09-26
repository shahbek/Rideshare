@_spi(Experimental) import MapboxMaps
import SceneKit

/// A bounded settled-camera neighbourhood, independent of the destination's selection state.
@MainActor
final class BuildingNeighbourhood {
    private let layerID = "twende-neighbourhood-architecture"
    private var host: BuildingRenderLayer?
    private var pending: Task<Void, Never>?
    private var query: Cancelable?
    private var revision: UInt = 0
    private var signatures: [UInt64] = []
    private(set) var buildingCount: Int = 0

    static func coordinate(_ geometry: Geometry) -> LocationCoordinate2D? {
        let points: [LocationCoordinate2D]
        switch geometry {
        case .polygon(let p): points = p.coordinates.first ?? []
        case .multiPolygon(let p): points = p.coordinates.flatMap { $0.first ?? [] }
        default: return nil
        }
        guard !points.isEmpty else { return nil }
        return LocationCoordinate2D(latitude: ((points.map(\.latitude).min() ?? 0) + (points.map(\.latitude).max() ?? 0)) / 2, longitude: ((points.map(\.longitude).min() ?? 0) + (points.map(\.longitude).max() ?? 0)) / 2)
    }

    func refresh(excluding selected: [StandardBuildingsFeature], on map: MapboxMap) {
        pending?.cancel()
        query?.cancel()
        revision &+= 1
        let version = revision
        pending = Task { [weak self, weak map] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self, let map, version == self.revision,
                  let origin = selected.first.flatMap({ Self.coordinate($0.geometry) }) else { return }
            self.query = map.queryRenderedFeatures(featureset: .standardBuildings) { [weak self, weak map] result in
                guard let self, let map, self.revision == version, case .success(let candidates) = result else { return }
                self.query = nil
                let excluded = Set(selected.map { BuildingIdentity(geometry: $0.geometry).seed })
                var seen: Set<UInt64> = []
                let nearby = candidates.compactMap { building -> (StandardBuildingsFeature, Double, UInt64)? in
                    let seed = BuildingIdentity(geometry: building.geometry).seed
                    guard !DarLandmarkSite.isBespoke(building.geometry),
                          !excluded.contains(seed), !selected.contains(where: { $0.id != nil && $0.id == building.id }),
                          let centre = Self.coordinate(building.geometry) else { return nil }
                    let dx = (centre.longitude - origin.longitude) * 111_320 * cos(origin.latitude * .pi / 180)
                    let dy = (centre.latitude - origin.latitude) * 110_540
                    let distance = hypot(dx, dy)
                    guard distance < 280, distance > 4, seen.insert(seed).inserted else { return nil }
                    return (building, distance, seed)
                }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }
                // Prefer different palette/order pairings without changing a building's own identity.
                var chosen: [(StandardBuildingsFeature, Double, UInt64)] = []
                var combinations: Set<String> = []
                for candidate in nearby {
                    let identity = BuildingIdentity(seed: candidate.2)
                    let key = "\(identity.order.rawValue):\(identity.paletteIndex)"
                    if combinations.insert(key).inserted { chosen.append(candidate) }
                    if chosen.count == 8 { break }
                }
                let keys = chosen.map { entry in
                    BuildingIdentity.hash("\(entry.2):\(entry.0.properties["height"]??.number ?? 12):\(entry.0.properties["min_height"]??.number ?? 0):\(entry.0.geometry)")
                }
                guard keys != self.signatures || !map.layerExists(withId: self.layerID) else { return }
                let scene = SCNScene()
                for (building, _, seed) in chosen {
                    let related = candidates.filter { other in
                        (building.id != nil && other.id == building.id) || other.geometry == building.geometry
                    }.compactMap { $0.properties["height"]??.number }
                    let height = BuildingEnvelope.roof(height: building.properties["height"]??.number, relatedHeights: related)
                    let rawBase = building.properties["min_height"]??.number ?? 0
                    let base = rawBase.isFinite && rawBase >= 0 && rawBase < height ? rawBase : 0
                    scene.rootNode.addChildNode(BuildingArchitecture.make(geometry: BuildingIllumination.expanded(building.geometry, by: 0.7), origin: origin, base: base, roof: height, windowLimit: 64, roofStyle: (building.properties["roof:shape"]??.string).map { BuildingRoof.style(roofShape: $0) }, identity: BuildingIdentity(seed: seed)))
                }
                if map.layerExists(withId: self.layerID) { try? map.removeLayer(withId: self.layerID) }
                self.host = nil
                do {
                    if !chosen.isEmpty {
                        let host = BuildingRenderLayer(origin: origin, scene: scene)
                        try map.addCustomLayer(withId: self.layerID, layerHost: host, layerPosition: nil)
                        try map.setLayerProperty(for: self.layerID, property: "slot", value: "middle")
                        self.host = host
                    }
                    self.signatures = keys
                    self.buildingCount = chosen.count
                } catch {
                    if map.layerExists(withId: self.layerID) { try? map.removeLayer(withId: self.layerID) }
                    self.signatures = []
                    self.buildingCount = 0
                }
            }
        }
    }

    func remove(from map: MapboxMap) {
        reset()
        if map.layerExists(withId: layerID) { try? map.removeLayer(withId: layerID) }
    }
    func reset() {
        revision &+= 1
        pending?.cancel(); pending = nil
        query?.cancel(); query = nil
        signatures = []
        buildingCount = 0
        host = nil
    }
}
