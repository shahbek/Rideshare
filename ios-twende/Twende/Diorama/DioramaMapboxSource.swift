import Foundation
@_spi(Experimental) import MapboxMaps

/// Queries complete loaded Streets source tiles rather than collision-filtered rendered labels.
/// z14 is the Streets source's native maximum; one parent contains the whole z16 diorama.
@MainActor
final class DioramaMapboxSource {
    private let sourceID = "zuri-diorama-streets"
    private let layers = ["building", "road", "poi_label", "housenum_label"]
    private var loaded: [String: [Feature]] = [:]
    private var pending: Set<String> = []
    private var revision: Int = 0
    var onReady: (() -> Void)? = nil

    func install(on map: MapboxMap) throws {
        guard !map.sourceExists(withId: sourceID) else { return }
        var source = VectorSource(id: sourceID)
        source.url = "mapbox://mapbox.mapbox-streets-v8"
        source.maxzoom = 14
        try map.addSource(source)
        // Visible layout (not visibility:none) keeps source tiles available to source queries.
        var probe = LineLayer(id: sourceID + "-probe", source: sourceID)
        probe.sourceLayer = "road"
        // A mathematically zero opacity can let the SDK skip loading the source entirely.
        probe.lineOpacity = .constant(0.001)
        probe.lineWidth = .constant(0.01)
        probe.slot = .bottom
        try map.addLayer(probe)
    }

    func reset() { revision += 1; loaded = [:]; pending = [] }

    func remove(from map: MapboxMap) {
        reset()
        if map.layerExists(withId: sourceID + "-probe") { try? map.removeLayer(withId: sourceID + "-probe") }
        if map.sourceExists(withId: sourceID) { try? map.removeSource(withId: sourceID) }
    }

    func request(on map: MapboxMap) {
        let version = revision
        for layer in layers where !pending.contains(layer) {
            pending.insert(layer)
            map.querySourceFeatures(for: sourceID, options: SourceQueryOptions(sourceLayerIds: [layer], filter: true)) { [weak self] result in
                guard let self, self.revision == version else { return }
                self.pending.remove(layer)
                if case .success(let features) = result { self.loaded[layer] = features.map(\.queriedFeature.feature) }
                if self.isReady { self.onReady?() }
            }
        }
    }

    var isReady: Bool { !(loaded["building"] ?? []).isEmpty && !(loaded["road"] ?? []).isEmpty && layers.allSatisfy { loaded[$0] != nil } }

    func snapshot(tile: DioramaTileID) -> DioramaMapSupplement {
        let projection = DioramaProjection(origin: tile.centre), rect = projection.rect(of: tile)
        var result = DioramaMapSupplement()
        func local(_ c: CLLocationCoordinate2D) -> DV2 { projection.local(longitude: c.longitude, latitude: c.latitude) }
        func title(_ f: Feature) -> String? {
            for key in ["name", "name_en", "house_num", "housenumber", "addr:housenumber"] {
                if let s = f.properties?[key]??.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
                if let n = f.properties?[key]??.number { return String(format: "%g", n) }
            }
            return nil
        }
        for feature in loaded["building"] ?? [] {
            let polygons: [[[CLLocationCoordinate2D]]]
            switch feature.geometry {
            case .polygon(let p): polygons = [p.coordinates]
            case .multiPolygon(let p): polygons = p.coordinates
            default: continue
            }
            for polygon in polygons {
                guard let raw = polygon.first else { continue }
                let ring = DioramaPolygon.counterClockwise(DioramaPolygon.clean(raw.map(local), flags: Array(repeating: false, count: raw.count)).points)
                guard ring.count >= 3, DioramaPolygon.area(DioramaPolygon.clipPolygon(ring, to: rect)) > 0.1 else { continue }
                let id = Self.identity("building", points: ring)
                result.buildings.append(DioramaBuildingFeature(id: id, ring: ring, clipped: Array(repeating: false, count: ring.count), area: DioramaPolygon.area(ring), centroid: DioramaPolygon.centroid(ring), height: feature.properties?["height"]??.number, type: feature.properties?["type"]??.string ?? "building", name: title(feature)))
            }
        }
        for feature in loaded["road"] ?? [] {
            let lines: [[CLLocationCoordinate2D]]
            switch feature.geometry {
            case .lineString(let l): lines = [l.coordinates]
            case .multiLineString(let l): lines = l.coordinates
            default: continue
            }
            let kind = feature.properties?["class"]??.string ?? "street"
            guard !["ferry", "rail", "aerialway"].contains(kind) else { continue }
            let width: Double = ["primary", "trunk", "motorway"].contains(kind) ? 12 : (kind == "secondary" ? 10 : (kind == "tertiary" ? 8 : (["path", "pedestrian"].contains(kind) ? 1.6 : (kind == "service" ? 4 : 6))))
            for line in lines { for piece in DioramaPolygon.clip(line.map(local), to: rect) where DioramaPolygon.length(piece) > 0.05 {
                result.roads.append(DioramaRoadFeature(id: Self.identity("road", points: piece), line: piece, roadClass: kind, isPaved: feature.properties?["surface"]??.string != "unpaved", width: width, name: title(feature)))
            } }
        }
        for layer in ["poi_label", "housenum_label"] {
            for feature in loaded[layer] ?? [] {
                guard case .point(let point) = feature.geometry, let name = title(feature) else { continue }
                let p = local(point.coordinates)
                guard rect.contains(p) else { continue }
                let kind = feature.properties?["type"]??.string ?? "poi"
                result.pois.append(DioramaPointFeature(id: Self.identity(name, points: [p]), point: p, kind: kind.lowercased().contains("mosque") ? "mosque" : "label", name: name))
            }
        }
        result.buildings = Array(Dictionary(result.buildings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        result.roads = Array(Dictionary(result.roads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        result.pois = Array(Dictionary(result.pois.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        return result
    }

    private static func identity(_ prefix: String, points: [DV2]) -> UInt64 {
        let text = prefix + points.map { "\(Int(($0.x * 10).rounded())),\(Int(($0.y * 10).rounded()))" }.joined(separator: ";")
        return text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

/// Only local, Sendable values cross into background geometry generation.
nonisolated struct DioramaMapSupplement: Sendable {
    var buildings: [DioramaBuildingFeature] = []
    var roads: [DioramaRoadFeature] = []
    var pois: [DioramaPointFeature] = []

    func merging(into original: DioramaTileData, config: DioramaConfig) -> DioramaTileData {
        var data = original
        for building in buildings.sorted(by: { $0.id < $1.id }) {
            let probes = building.ring + [building.centroid]
            let existing = data.buildings.firstIndex { other in
                DioramaPolygon.contains(other.ring, building.centroid) || DioramaPolygon.contains(building.ring, other.centroid)
                    || Double(probes.filter { DioramaPolygon.distanceToRing(other.ring, $0) < 1.5 }.count) / Double(probes.count) > 0.6
            }
            if let existing {
                if let name = building.name { data.buildings[existing].name = name }
            } else { data.buildings.append(DioramaFootprints.softened(building)) }
        }
        // Resolve source names against overlapping linework. Add uncovered stretches, not parallel duplicates.
        let index = DioramaRoadIndex(roads: data.roads, pavementWidth: 0)
        for road in roads.sorted(by: { $0.id < $1.id }) {
            let dense = DioramaPolygon.densify(road.line, maxStep: 1)
            if let name = road.name {
                let ids = Set(dense.compactMap { index.nearest(to: $0, within: 3)?.road.id })
                let sourceIndex = DioramaRoadIndex(roads: [road], pavementWidth: 0)
                for i in data.roads.indices where ids.contains(data.roads[i].id) {
                    let samples = DioramaPolygon.densify(data.roads[i].line, maxStep: 2)
                    let matches = zip(samples, samples.dropFirst()).filter { a, b in
                        guard let hit = sourceIndex.nearest(to: (a + b) * 0.5, within: 3) else { return false }
                        return abs((b - a).normalized.dot(hit.direction)) > 0.9
                    }.count
                    // A shared junction alone must never rename the intersecting street.
                    if Double(matches) / Double(max(1, samples.count - 1)) > 0.65 { data.roads[i].name = name }
                }
            }
            var run: [DV2] = []
            var part: UInt64 = 0
            func appendRun() {
                guard run.count >= 2 else { run = []; return }
                data.roads.append(DioramaRoadFeature(id: DioramaRandom.mix(road.id &+ part), line: run, roadClass: road.roadClass, isPaved: road.isPaved, width: road.width, name: road.name))
                part += 1; run = []
            }
            for (i, point) in dense.enumerated() {
                if index.nearest(to: point, within: 2) == nil {
                    if run.isEmpty, i > 0 { run.append(dense[i - 1]) }
                    run.append(point)
                } else if !run.isEmpty { run.append(point); appendRun() }
            }
            appendRun()
        }
        for poi in pois {
            if !data.pois.contains(where: { $0.name == poi.name && $0.point.distance(to: poi.point) < 10 }) { data.pois.append(poi) }
            if let host = data.buildings.indices.filter({ DioramaPolygon.contains(data.buildings[$0].ring, poi.point) }).min(by: { data.buildings[$0].area < data.buildings[$1].area }), data.buildings[host].name == nil {
                data.buildings[host].name = poi.name
            }
        }
        data.buildings.sort { $0.id < $1.id }
        data.roads.sort { $0.id < $1.id }
        print("[Diorama coverage] bundled \(original.buildings.count) buildings / \(original.roads.count) roads; merged \(data.buildings.count) buildings / \(data.roads.count) roads; Mapbox \(pois.count) named points")
        return data
    }
}
