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

    var isEmpty: Bool { buildings.isEmpty && roads.isEmpty && water.isEmpty }
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

/// The diorama's source data is a small OpenStreetMap extract of the Slipway tile bundled with the app
/// (`slipway_tile.json`), so the map never has to download, style or query a vector source for it.
/// Decoding and projection run off the main thread; nothing here touches Mapbox.
nonisolated enum DioramaBundledTile {
    nonisolated struct File: Decodable, Sendable {
        nonisolated struct Tile: Decodable, Sendable { let z: Int; let x: Int; let y: Int }
        nonisolated struct Building: Decodable, Sendable { let id: UInt64; let type: String; let height: Double?; let ring: [[Double]] }
        nonisolated struct Road: Decodable, Sendable { let id: UInt64; let `class`: String; let paved: Bool; let line: [[Double]] }
        nonisolated struct Area: Decodable, Sendable { let id: UInt64; let kind: String?; let rings: [[[Double]]]; let clipped: [Bool]? }
        let tile: Tile
        let buildings: [Building]
        let roads: [Road]
        let water: [Area]
        let landuse: [Area]
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
            guard area > 12 else { continue }
            let centroid = DioramaPolygon.centroid(pts)
            guard rect.contains(centroid) else { continue }
            let height = (b.height ?? 0) > config.placeholderHeight ? b.height : nil
            if let existing = buildings[b.id], existing.area >= area { continue }
            buildings[b.id] = DioramaBuildingFeature(id: b.id, ring: pts, clipped: flags, area: area, centroid: centroid, height: height, type: b.type)
        }

        var roads: [UInt64: DioramaRoadFeature] = [:]
        for r in file.roads {
            let width: Double
            switch r.class {
            case "motorway", "trunk", "primary": width = 12
            case "secondary": width = 10
            case "tertiary": width = 8
            case "street", "street_limited": width = 6
            case "service": width = 4
            default: width = 5
            }
            let line = r.line.compactMap(local)
            guard line.count >= 2 else { continue }
            for (pieceIndex, piece) in DioramaPolygon.clip(line, to: rect).enumerated() where DioramaPolygon.length(piece) > 3 {
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
            guard outer.count >= 3, DioramaRect.bounding(outer).intersects(bounds) else { return nil }
            var rings = [outer]
            for hole in a.rings.dropFirst() {
                let cleaned = DioramaPolygon.clean(hole.compactMap(local), flags: [Bool](repeating: false, count: hole.count)).points
                if cleaned.count >= 3 { rings.append(cleaned) }
            }
            return DioramaAreaFeature(id: a.id, rings: rings, clipped: fl, kind: kind)
        }

        let water = file.water.compactMap { area($0, kind: "water", bounds: outside) }
        let landuse = file.landuse.compactMap { area($0, kind: $0.kind ?? "park", bounds: rect) }

        return DioramaTileData(
            tile: tile, projection: projection, rect: rect,
            buildings: Array(buildings.values.sorted { $0.area != $1.area ? $0.area > $1.area : $0.id < $1.id }.prefix(config.maxBuildingsPerTile)).sorted { $0.id < $1.id },
            roads: Array(roads.values.sorted { $0.id < $1.id }.prefix(config.maxRoadsPerTile)),
            water: water.sorted { $0.id < $1.id },
            landuse: landuse.sorted { $0.id < $1.id }
        )
    }
}
