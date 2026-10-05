import CoreLocation
import Foundation

/// Plain, Sendable copies of the features one tile needs, in local metres around the tile centre.
nonisolated struct DioramaTileData: Sendable {
    let tile: DioramaTileID
    let projection: DioramaProjection
    let rect: DioramaRect
    var buildings: [DioramaBuildingFeature]
    var roads: [DioramaRoadFeature]
    var water: [DioramaAreaFeature]
    var landuse: [DioramaAreaFeature]
    /// Individually mapped trees (OSM `natural=tree`).
    var trees: [DV2] = []
    /// Footways, steps, the pier walkway and the slipway ramp.
    var paths: [DioramaPathFeature] = []
    /// Point features worth a model: masts, playgrounds, artwork, the mosque.
    var pois: [DioramaPointFeature] = []
    /// Mapped courtyard with a bounded margin, shared by hardscape and furniture exclusions.
    var hotelCourtyardOutline: [DV2] = []
    /// Paved dining apron in front of Hotel Slipway's arcade (photo-led, not a mapped area).
    var hotelDiningOutline: [DV2] = []

    /// Classified real coast only, excluding artificial tile closure edges.
    var shorelines: [DioramaShorelineSegment] = []
    var shorelineLandMasks: [[DV2]] = []

    var isEmpty: Bool { buildings.isEmpty && roads.isEmpty && water.isEmpty }
}

nonisolated struct DioramaPathFeature: Sendable {
    let id: UInt64
    let line: [DV2]
    /// `footway`, `steps`, `path`, `pier`, `slipway`.
    let kind: String
    let isLit: Bool
    var sourceID: UInt64? = nil
    var tags: [String: String] = [:]
}

nonisolated struct DioramaPointFeature: Sendable {
    let id: UInt64
    let point: DV2
    /// `tower`, `playground`, `artwork`, `mosque`.
    let kind: String
    var name: String? = nil
}

nonisolated struct DioramaBuildingFeature: Sendable {
    let id: UInt64
    /// Counter-clockwise outer ring, cleaned.
    let ring: [DV2]
    /// `clipped[i]` is true when edge i → i+1 is a data boundary rather than a real wall.
    let clipped: [Bool]
    let area: Double
    let centroid: DV2
    /// Height from the data, or nil when unknown (inferred from the footprint area instead).
    let height: Double?
    let type: String
    var name: String? = nil
}

nonisolated struct DioramaRoadFeature: Sendable {
    let id: UInt64
    let line: [DV2]
    let roadClass: String
    let isPaved: Bool
    /// Approximate carriageway width in metres.
    let width: Double
    var name: String? = nil
    var isMain: Bool { ["motorway", "trunk", "primary", "secondary", "tertiary"].contains(roadClass) }
}

nonisolated struct DioramaAreaFeature: Sendable {
    let id: UInt64
    /// Outer ring first, holes after; outer ring counter-clockwise.
    let rings: [[DV2]]
    /// Clip flags for the outer ring edges.
    let clipped: [Bool]
    /// `park`, `common`, `garden`, `pitch`, `parking`, `fuel`, `pool`, `terrace`, `water`.
    let kind: String
    /// OSM `sport` tag for pitches (`padel`, `tennis`, ...).
    var sport: String? = nil
    var tags: [String: String] = [:]
}

/// The diorama's source data is a small OpenStreetMap extract of the Slipway tile bundled with the app
/// (`slipway_tile.json`), so the map never has to download, style or query a vector source for it.
/// Decoding and projection run off the main thread; nothing here touches Mapbox.
nonisolated enum DioramaBundledTile {
    nonisolated struct File: Decodable, Sendable {
        nonisolated struct Tile: Decodable, Sendable { let z: Int; let x: Int; let y: Int }
        nonisolated struct Building: Decodable, Sendable { let id: UInt64; let type: String; let height: Double?; let ring: [[Double]]; var name: String? = nil }
        nonisolated struct Road: Decodable, Sendable { let id: UInt64; let `class`: String; let paved: Bool; let line: [[Double]] }
        nonisolated struct Area: Decodable, Sendable { let id: UInt64; let kind: String?; let sport: String?; let rings: [[[Double]]]; let clipped: [Bool]?; let tags: [String: String]? }
        nonisolated struct Path: Decodable, Sendable { let id: UInt64; let kind: String; let lit: Bool?; let line: [[Double]]; let tags: [String: String]? }
        nonisolated struct Point: Decodable, Sendable { let id: UInt64; let kind: String; let point: [Double]; var name: String? = nil }
        let tile: Tile
        let buildings: [Building]
        let roads: [Road]
        let water: [Area]
        let landuse: [Area]
        let trees: [[Double]]?
        let paths: [Path]?
        let pois: [Point]?
    }

    static let resourceName = "slipway_tile"

    /// Loads and projects the bundled tile. Returns nil when the resource is missing or malformed.
    static func load(config: DioramaConfig) -> DioramaTileData? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            print("[Diorama] bundled tile missing or unreadable")
            return nil
        }
        return convert(file, config: config)
    }

    static func convert(_ file: File, config: DioramaConfig) -> DioramaTileData {
        let tile = DioramaTileID(z: file.tile.z, x: file.tile.x, y: file.tile.y)
        let projection = DioramaProjection(origin: tile.centre)
        let rect = projection.rect(of: tile)
        let tileSize = rect.width
        let outside = rect.expanded(by: tileSize * 0.08)

        func local(_ p: [Double]) -> DV2? {
            guard p.count == 2, p[0].isFinite, p[1].isFinite else { return nil }
            return projection.local(longitude: p[0], latitude: p[1])
        }

        var buildings: [UInt64: DioramaBuildingFeature] = [:]
        for b in file.buildings {
            let ring = b.ring.compactMap(local)
            guard ring.count >= 3, ring.count == b.ring.count else { continue }
            var (pts, flags) = DioramaPolygon.clean(ring, flags: [Bool](repeating: false, count: ring.count))
            (pts, flags) = DioramaPolygon.counterClockwise(pts, flags: flags)
            guard pts.count >= 3 else { continue }
            let area = DioramaPolygon.area(pts)
            guard area > 0.1 else { continue }
            let centroid = DioramaPolygon.centroid(pts)
            guard DioramaPolygon.area(DioramaPolygon.clipPolygon(pts, to: rect)) > 0.1 else { continue }
            // This is bundled OSM, not Mapbox's synthesized 3 m fallback: keep genuine low heights.
            let height = b.height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if let existing = buildings[b.id], existing.area >= area { continue }
            buildings[b.id] = DioramaBuildingFeature(id: b.id, ring: pts, clipped: flags, area: area, centroid: centroid, height: height, type: b.type, name: b.name)
        }

        buildings = buildings.mapValues(DioramaFootprints.landmarkPlan)
        DioramaFootprints.carveStairGap(&buildings)
        buildings = buildings.mapValues(DioramaFootprints.softened)

        var roads: [UInt64: DioramaRoadFeature] = [:]
        for r in file.roads {
            let width: Double
            switch r.class {
            case "motorway", "trunk", "primary": width = 12
            case "secondary": width = 10
            case "tertiary": width = 8
            case "street", "street_limited", "residential", "unclassified": width = 6
            case "service": width = 4
            default: width = 5
            }
            let line = r.line.compactMap(local)
            guard line.count >= 2 else { continue }
            for (pieceIndex, piece) in DioramaPolygon.clip(line, to: rect).enumerated() where DioramaPolygon.length(piece) > 0.05 {
                let key = DioramaRandom.mix(r.id &+ UInt64(pieceIndex) &* 977)
                roads[key] = DioramaRoadFeature(id: key, line: piece, roadClass: r.class, isPaved: r.paved, width: width)
            }
        }

        func area(_ a: File.Area, kind: String, bounds: DioramaRect) -> DioramaAreaFeature? {
            guard let outerRaw = a.rings.first else { return nil }
            let outerLocal = outerRaw.compactMap(local)
            guard outerLocal.count == outerRaw.count, outerLocal.count >= 3 else { return nil }
            var flags = a.clipped ?? [Bool](repeating: false, count: outerLocal.count)
            if flags.count != outerLocal.count { flags = [Bool](repeating: false, count: outerLocal.count) }
            var (outer, fl) = DioramaPolygon.clean(outerLocal, flags: flags)
            (outer, fl) = DioramaPolygon.counterClockwise(outer, flags: fl)
            if kind == "water" { (outer, fl) = DioramaCoastline.rounded(outer, flags: fl) }
            guard outer.count >= 3, DioramaRect.bounding(outer).intersects(bounds) else { return nil }
            var rings = [outer]
            for hole in a.rings.dropFirst() {
                let cleaned = DioramaPolygon.clean(hole.compactMap(local), flags: [Bool](repeating: false, count: hole.count)).points
                if cleaned.count >= 3 { rings.append(cleaned) }
            }
            return DioramaAreaFeature(id: a.id, rings: rings, clipped: fl, kind: kind, sport: a.sport, tags: a.tags ?? [:])
        }

        let water = file.water.compactMap { area($0, kind: "water", bounds: outside) }
        let landuse = file.landuse.compactMap { area($0, kind: $0.kind ?? "park", bounds: rect) }

        let inner = rect.expanded(by: -1)
        let trees = (file.trees ?? []).compactMap(local).filter { inner.contains($0) }

        var paths: [DioramaPathFeature] = []
        for p in file.paths ?? [] {
            let line = p.line.compactMap(local)
            guard line.count >= 2 else { continue }
            for (pieceIndex, piece) in DioramaPolygon.clip(line, to: rect).enumerated() where DioramaPolygon.length(piece) > 1 {
                let key = DioramaRandom.mix(p.id &+ UInt64(pieceIndex) &* 613)
                paths.append(DioramaPathFeature(id: key, line: piece, kind: p.id == 1286596031 ? "pier" : p.kind, isLit: p.lit ?? false, sourceID: p.id, tags: p.id == 1286596031 ? (p.tags ?? [:]).merging(["zuri:structure": "raised Delta waterfront walkway; user correction, height illustrative"], uniquingKeysWith: { _, new in new }) : (p.tags ?? [:])))
            }
        }

        let pois: [DioramaPointFeature] = (file.pois ?? []).compactMap { poi in
            guard let p = local(poi.point), inner.contains(p) else { return nil }
            return DioramaPointFeature(id: poi.id, point: p, kind: poi.kind, name: poi.name)
        }

        // The bundled Masjid 36 is a named point with no footprint (nearest house is 52 m away).
        // Use a compact explicitly illustrative hall at its actual point, never relabel that house.
        let roadIndex = DioramaRoadIndex(roads: Array(roads.values), pavementWidth: config.pavementWidth)
        for poi in pois where poi.kind == "mosque" {
            if let host = buildings.values.filter({ DioramaPolygon.contains($0.ring, poi.point) }).min(by: { $0.area < $1.area }) {
                if buildings[host.id]?.name == nil { buildings[host.id]?.name = poi.name }
                continue
            }
            let axis = roadIndex.nearest(to: poi.point, within: 60)?.direction ?? DV2(1, 0)
            let ring = DioramaOrientedRect(centre: poi.point, axis: axis, halfLength: 7, halfWidth: 5).corners
            let probes = DioramaPolygon.densify(ring + [ring[0]], maxStep: 1) + [poi.point]
            guard probes.allSatisfy({ p in
                inner.contains(p) && !roadIndex.isOnRoad(p, margin: 1)
                    && !water.contains(where: { DioramaPolygon.contains(polygon: $0.rings, p) })
                    && !buildings.values.contains(where: { DioramaPolygon.contains($0.ring, p) })
            }) else { continue }
            let hall = DioramaBuildingFeature(id: poi.id, ring: ring, clipped: [false, false, false, false],
                area: 140, centroid: poi.point, height: 4.8, type: "mosque", name: poi.name)
            buildings[poi.id] = DioramaFootprints.softened(hall)
        }

        var result = DioramaTileData(
            tile: tile, projection: projection, rect: rect,
            buildings: buildings.values.sorted { $0.id < $1.id },
            roads: roads.values.sorted { $0.id < $1.id },
            water: water.sorted { $0.id < $1.id },
            landuse: landuse.sorted { $0.id < $1.id },
            trees: trees,
            paths: paths.sorted { $0.id < $1.id },
            pois: pois.sorted { $0.id < $1.id }
        )
        result.hotelCourtyardOutline = DioramaHotelGrounds.courtyardOutline(data: result)
        result.hotelDiningOutline = DioramaHotelGrounds.diningOutline(data: result)
        result.shorelines = DioramaShoreline.classify(data: result, config: config,
                                                    overrides: DioramaShorelineOverrides.load())
        result.shorelineLandMasks = DioramaShoreline.landMasks(result.shorelines, config: config)
        return result
    }
}
