import Foundation

/// Bundled OSM geometry, fetched 2026-10-06. Architecture is photo-led; horizontal outlines are mapped.
nonisolated enum DioramaSeaCliffSite {
    static let buildingID: UInt64 = 8_844_582
    static let poolID: UInt64 = 141_608_483
    static let siteID: UInt64 = 169_835_957
    static let tile = DioramaTileID(latitude: -6.7395, longitude: 39.2845, zoom: 16)
    private static let buildingFile = load("seacliff_building_osm")
    private static let siteFile = load("seacliff_site_osm")
    private static let poolFile = load("seacliff_pool_osm")

    private struct File: Decodable, Sendable { let elements: [Element] }
    private struct Element: Decodable, Sendable {
        let type: String
        let id: UInt64
        let lat: Double?
        let lon: Double?
        let nodes: [UInt64]?
    }
    private static func load(_ resource: String) -> File? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: bytes)
    }
    private static func ring(_ id: UInt64, file: File?, projection: DioramaProjection) -> [DV2] {
        guard let file, let way = file.elements.first(where: { $0.type == "way" && $0.id == id }), let nodes = way.nodes else { return [] }
        let coordinates = Dictionary(uniqueKeysWithValues: file.elements.compactMap { element -> (UInt64, DV2)? in
            guard element.type == "node", let lon = element.lon, let lat = element.lat else { return nil }
            return (element.id, projection.local(longitude: lon, latitude: lat))
        })
        let points = nodes.compactMap { coordinates[$0] }
        guard points.count == nodes.count else { return [] }
        return DioramaPolygon.counterClockwise(DioramaPolygon.clean(points, flags: []).points)
    }
    static func site(_ projection: DioramaProjection) -> [DV2] { ring(siteID, file: siteFile, projection: projection) }
    static func courtyard(_ projection: DioramaProjection) -> [DV2] { ring(637_489_336, file: buildingFile, projection: projection) }
    static func owns(_ p: DV2, data: DioramaTileData) -> Bool {
        guard data.tile == tile else { return false }
        return data.landuse.contains { $0.kind == "seacliffGrounds" && DioramaPolygon.contains(polygon: $0.rings, p) }
    }

    /// Run before pool recognition, ownership resolution and coastal deformation.
    static func merge(into original: DioramaTileData) -> DioramaTileData {
        guard original.tile == tile else { return original }
        var data = original
        let outline = ring(141_608_447, file: buildingFile, projection: data.projection)
        let hole = courtyard(data.projection)
        let basin = ring(poolID, file: poolFile, projection: data.projection)
        let grounds = site(data.projection)
        guard outline.count >= 3, hole.count >= 3, basin.count >= 3, grounds.count >= 3 else {
            print("[Diorama Sea Cliff] Landmark resources unavailable; retaining source buildings")
            return data
        }
        let pieces = DioramaGroundCutouts(polygons: [hole]).subtract(from: outline)
        // The OSM one-level tag is contradicted by the supplied aerial. 10.2 m is a photo estimate.
        data.buildings.append(.init(id: buildingID, ring: outline, clipped: Array(repeating: false, count: outline.count),
            area: pieces.reduce(0) { $0 + DioramaPolygon.area($1) }, centroid: DioramaPolygon.centroid(outline),
            height: 10.2, type: "hotel", name: "Sea Cliff Hotel", occupiedPieces: pieces, sourceFootprint: outline))
        data.landuse.append(.init(id: poolID, rings: [basin], clipped: Array(repeating: false, count: basin.count),
            kind: "pool", tags: ["leisure": "swimming_pool", "source": "OSM way 141608483"]))
        data.landuse.append(.init(id: siteID, rings: [grounds], clipped: Array(repeating: false, count: grounds.count),
            kind: "seacliffGrounds", tags: ["source": "OSM way 169835957"]))
        return data
    }
}
