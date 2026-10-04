import CoreLocation
import Foundation
@_spi(Experimental) import MapboxMaps

/// Plain, Sendable copies of the vector-tile features one tile needs, in local metres around the tile
/// centre. Converted on the main thread straight after the query; everything after runs off-main.
nonisolated struct DioramaTileData: Sendable {
    let tile: DioramaTileID
    let projection: DioramaProjection
    let rect: DioramaRect
    var buildings: [DioramaBuildingFeature]
    var roads: [DioramaRoadFeature]
    var water: [DioramaAreaFeature]
    var landuse: [DioramaAreaFeature]

    var isEmpty: Bool { buildings.isEmpty && roads.isEmpty && water.isEmpty }
}

nonisolated struct DioramaBuildingFeature: Sendable {
    let id: UInt64
    /// Counter-clockwise outer ring, cleaned.
    let ring: [DV2]
    /// `clipped[i]` is true when edge i → i+1 lies on a vector-tile boundary and is not a real wall.
    let clipped: [Bool]
    let area: Double
    let centroid: DV2
    /// Height from the data, or nil when Mapbox filled in its ~3 m placeholder.
    let height: Double?
    let type: String
}

nonisolated struct DioramaRoadFeature: Sendable {
    let id: UInt64
    let line: [DV2]
    let roadClass: String
    let isPaved: Bool
    /// Approximate carriageway width in metres.
    let width: Double
    var isMain: Bool { ["motorway", "trunk", "primary", "secondary", "tertiary"].contains(roadClass) }
}

nonisolated struct DioramaAreaFeature: Sendable {
    let id: UInt64
    /// Outer ring first, holes after; outer ring counter-clockwise.
    let rings: [[DV2]]
    /// Clip flags for the outer ring edges.
    let clipped: [Bool]
    let kind: String
}

/// Owns the `mapbox-streets-v8` vector source, its invisible query layers and the feature conversion.
@MainActor
final class DioramaDataLoader {
    static let sourceID = "zuri-diorama-streets"
    static let buildingLayerID = "zuri-diorama-q-building"
    static let roadLayerID = "zuri-diorama-q-road"
    static let waterLayerID = "zuri-diorama-q-water"
    static let landuseLayerID = "zuri-diorama-q-landuse"
    private static let sourceLayers = ["building", "road", "water", "landuse"]

    private let config: DioramaConfig
    private var query: Cancelable?

    init(config: DioramaConfig) {
        self.config = config
    }

    /// Adds the source plus one fully transparent layer per source layer so the tiles load and can be
    /// queried. Mapbox Standard's own data is not queryable through `querySourceFeatures`.
    func install(on map: MapboxMap) throws {
        guard !map.sourceExists(withId: Self.sourceID) else { return }
        var source = VectorSource(id: Self.sourceID)
        source.url = "mapbox://mapbox.mapbox-streets-v8"
        source.minzoom = 13
        source.maxzoom = 16
        try map.addSource(source)

        var building = FillLayer(id: Self.buildingLayerID, source: Self.sourceID)
        building.sourceLayer = "building"
        building.minZoom = 13
        building.slot = .middle
        building.fillOpacity = .constant(0)
        building.fillColor = .constant(StyleColor(rawValue: "#FF2D95"))
        try map.addLayer(building)

        var road = LineLayer(id: Self.roadLayerID, source: Self.sourceID)
        road.sourceLayer = "road"
        road.minZoom = 13
        road.slot = .middle
        road.lineOpacity = .constant(0)
        try map.addLayer(road)

        var water = FillLayer(id: Self.waterLayerID, source: Self.sourceID)
        water.sourceLayer = "water"
        water.slot = .middle
        water.fillOpacity = .constant(0)
        try map.addLayer(water)

        var landuse = FillLayer(id: Self.landuseLayerID, source: Self.sourceID)
        landuse.sourceLayer = "landuse"
        landuse.slot = .middle
        landuse.fillOpacity = .constant(0)
        try map.addLayer(landuse)
    }

    func remove(from map: MapboxMap) {
        query?.cancel()
        query = nil
        for id in [Self.buildingLayerID, Self.roadLayerID, Self.waterLayerID, Self.landuseLayerID] where map.layerExists(withId: id) {
            try? map.removeLayer(withId: id)
        }
        if map.sourceExists(withId: Self.sourceID) { try? map.removeSource(withId: Self.sourceID) }
    }

    /// Shows raw footprints for the debug overlay.
    func setFootprintsVisible(_ visible: Bool, on map: MapboxMap) {
        guard map.layerExists(withId: Self.buildingLayerID) else { return }
        try? map.setLayerProperty(for: Self.buildingLayerID, property: "fill-opacity", value: visible ? 0.35 : 0)
        try? map.setLayerProperty(for: Self.buildingLayerID, property: "fill-outline-color", value: visible ? "#FF2D95" : "rgba(0,0,0,0)")
    }

    /// Reads every loaded feature of the four source layers and keeps what belongs to `tile`.
    func load(_ tile: DioramaTileID, on map: MapboxMap, completion: @escaping @MainActor (DioramaTileData?) -> Void) {
        let options = SourceQueryOptions(sourceLayerIds: Self.sourceLayers, filter: ["all"])
        let config = config
        query = map.querySourceFeatures(for: Self.sourceID, options: options) { result in
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    print("[Diorama] querySourceFeatures failed: \(error)")
                    completion(nil)
                case .success(let features):
                    completion(Self.convert(features, tile: tile, config: config))
                }
            }
        }
    }

    // MARK: Conversion

    private static func convert(_ features: [QueriedSourceFeature], tile: DioramaTileID, config: DioramaConfig) -> DioramaTileData {
        let projection = DioramaProjection(origin: tile.centre)
        let rect = projection.rect(of: tile)
        // Vector tiles carry a small buffer beyond their edge; clipped geometry lands near those lines.
        let tileSize = rect.width
        let clipTolerance = tileSize * 0.02
        let outside = rect.expanded(by: tileSize * 0.05)

        var buildings: [UInt64: DioramaBuildingFeature] = [:]
        var roads: [UInt64: DioramaRoadFeature] = [:]
        var water: [UInt64: DioramaAreaFeature] = [:]
        var landuse: [UInt64: DioramaAreaFeature] = [:]

        for queried in features {
            let feature = queried.queriedFeature.feature
            let layer = queried.queriedFeature.sourceLayer ?? ""
            let props = feature.properties ?? [:]
            let id = identifier(feature, fallback: props)

            switch layer {
            case "building":
                guard props["underground"]??.string != "true" else { continue }
                for ring in polygonRings(feature.geometry).compactMap(\.first) {
                    let local = ring.map { projection.local(longitude: $0.longitude, latitude: $0.latitude) }
                    var flags = clipFlags(local, tileSize: tileSize, tolerance: clipTolerance)
                    var (pts, fl) = DioramaPolygon.clean(local, flags: flags)
                    (pts, fl) = DioramaPolygon.counterClockwise(pts, flags: fl)
                    flags = fl
                    guard pts.count >= 3 else { continue }
                    let area = DioramaPolygon.area(pts)
                    guard area > 12 else { continue }
                    let centroid = DioramaPolygon.centroid(pts)
                    guard rect.contains(centroid) else { continue }
                    let rawHeight = props["height"]??.number
                    let height = (rawHeight ?? 0) > config.placeholderHeight ? rawHeight : nil
                    let candidate = DioramaBuildingFeature(
                        id: id, ring: pts, clipped: flags, area: area, centroid: centroid, height: height,
                        type: props["type"]??.string ?? "building"
                    )
                    // The same OSM way can arrive once per overlapping tile; keep the biggest piece.
                    if let existing = buildings[id], existing.area >= area { continue }
                    buildings[id] = candidate
                }
            case "road":
                guard props["structure"]??.string != "tunnel" else { continue }
                let roadClass = props["class"]??.string ?? "street"
                guard !["path", "pedestrian", "ferry", "aerialway", "golf", "track"].contains(roadClass) else { continue }
                let surface = props["surface"]??.string
                let isPaved = surface == "paved" || (surface == nil && ["motorway", "trunk", "primary", "secondary", "tertiary", "street", "motorway_link", "primary_link", "secondary_link", "tertiary_link"].contains(roadClass))
                let width: Double
                switch roadClass {
                case "motorway", "trunk", "primary": width = 12
                case "secondary": width = 10
                case "tertiary": width = 8
                case "street", "street_limited": width = 6
                case "service": width = 4
                default: width = 5
                }
                for (index, line) in lineStrings(feature.geometry).enumerated() {
                    let local = line.map { projection.local(longitude: $0.longitude, latitude: $0.latitude) }
                    for (pieceIndex, piece) in DioramaPolygon.clip(local, to: rect).enumerated() where DioramaPolygon.length(piece) > 3 {
                        let key = DioramaRandom.mix(id &+ UInt64(index) &* 31 &+ UInt64(pieceIndex) &* 977 &+ UInt64(bitPattern: Int64((piece[0].x * 10).rounded())))
                        roads[key] = DioramaRoadFeature(id: key, line: piece, roadClass: roadClass, isPaved: isPaved, width: width)
                    }
                }
            case "water":
                for polygon in polygonRings(feature.geometry) {
                    guard let area = areaFeature(polygon, id: id, kind: "water", projection: projection, rect: outside, tileSize: tileSize, tolerance: clipTolerance) else { continue }
                    water[area.id] = area
                }
            case "landuse":
                let kind = props["class"]??.string ?? ""
                guard ["park", "grass", "pitch", "cemetery", "wood", "scrub", "garden", "recreation_ground"].contains(kind) else { continue }
                for polygon in polygonRings(feature.geometry) {
                    guard let area = areaFeature(polygon, id: id, kind: kind, projection: projection, rect: rect, tileSize: tileSize, tolerance: clipTolerance) else { continue }
                    landuse[area.id] = area
                }
            default:
                continue
            }
        }

        return DioramaTileData(
            tile: tile, projection: projection, rect: rect,
            buildings: Array(buildings.values).sorted { $0.id < $1.id },
            roads: Array(roads.values).sorted { $0.id < $1.id },
            water: Array(water.values).sorted { $0.id < $1.id },
            landuse: Array(landuse.values).sorted { $0.id < $1.id }
        )
    }

    private static func areaFeature(_ polygon: [[CLLocationCoordinate2D]], id: UInt64, kind: String, projection: DioramaProjection, rect: DioramaRect, tileSize: Double, tolerance: Double) -> DioramaAreaFeature? {
        guard let outerRaw = polygon.first else { return nil }
        let outerLocal = outerRaw.map { projection.local(longitude: $0.longitude, latitude: $0.latitude) }
        let flags = clipFlags(outerLocal, tileSize: tileSize, tolerance: tolerance)
        var (outer, fl) = DioramaPolygon.clean(outerLocal, flags: flags)
        (outer, fl) = DioramaPolygon.counterClockwise(outer, flags: fl)
        guard outer.count >= 3, DioramaRect.bounding(outer).intersects(rect) else { return nil }
        var rings = [outer]
        for hole in polygon.dropFirst() {
            let local = hole.map { projection.local(longitude: $0.longitude, latitude: $0.latitude) }
            let cleaned = DioramaPolygon.clean(local, flags: [Bool](repeating: false, count: local.count)).points
            if cleaned.count >= 3 { rings.append(cleaned) }
        }
        let key = DioramaRandom.mix(id &+ UInt64(bitPattern: Int64((outer[0].x * 7 + outer[0].y * 13).rounded())))
        return DioramaAreaFeature(id: key, rings: rings, clipped: fl, kind: kind)
    }

    /// Edges that run exactly along a tile (or tile buffer) line are vector-tile clips, not real edges.
    private static func clipFlags(_ ring: [DV2], tileSize: Double, tolerance: Double) -> [Bool] {
        let n = ring.count
        var flags = [Bool](repeating: false, count: n)
        guard n >= 2 else { return flags }
        let half = tileSize / 2
        func nearBoundary(_ v: Double) -> Bool {
            // Local coordinates are centred on the tile, so boundaries sit at odd multiples of half a tile.
            let shifted = v + half
            let r = shifted - (shifted / tileSize).rounded() * tileSize
            return abs(r) < tolerance
        }
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            if abs(a.x - b.x) < 0.05, nearBoundary(a.x) { flags[i] = true }
            if abs(a.y - b.y) < 0.05, nearBoundary(a.y) { flags[i] = true }
        }
        return flags
    }

    private static func identifier(_ feature: Feature, fallback: JSONObject) -> UInt64 {
        switch feature.identifier {
        case .number(let n): return UInt64(max(n, 0))
        case .string(let s): return DioramaRandom.hash(s)
        case nil:
            let coordinates = polygonRings(feature.geometry).first?.first?.first ?? lineStrings(feature.geometry).first?.first
            return DioramaRandom.hash("\(coordinates?.latitude ?? 0),\(coordinates?.longitude ?? 0),\(fallback.count)")
        }
    }

    private static func polygonRings(_ geometry: Geometry?) -> [[[CLLocationCoordinate2D]]] {
        switch geometry {
        case .polygon(let polygon): return [polygon.coordinates]
        case .multiPolygon(let multi): return multi.coordinates
        default: return []
        }
    }

    private static func lineStrings(_ geometry: Geometry?) -> [[CLLocationCoordinate2D]] {
        switch geometry {
        case .lineString(let line): return [line.coordinates]
        case .multiLineString(let multi): return multi.coordinates
        default: return []
        }
    }
}
