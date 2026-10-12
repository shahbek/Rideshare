import Foundation
import simd

/// Bundled, offline Dar es Salaam atlas (OpenStreetMap, ODbL): named street chains, place names
/// and district/ward boundaries. Powers Zuri's own map labels and household addressing, so neither
/// depends on Mapbox labels or a network geocoder.
nonisolated final class DarAtlas: @unchecked Sendable {
    /// One continuous named street (same-name OSM ways joined end to end).
    struct Street: Sendable {
        let id: Int
        let name: String
        /// 0 trunk/motorway … 5 service/living street.
        let rank: Int
        /// Local metres (east, north) around `DarAtlas.origin`.
        let points: [SIMD2<Double>]
        /// Cumulative metres along the chain at each point.
        let distances: [Double]
        var length: Double { distances.last ?? 0 }
    }

    enum PlaceKind: Int, Sendable {
        case city = 0, town, suburb, quarter, village, hamlet, bay, country, sea
    }

    struct PlaceName: Sendable {
        let name: String
        let kind: PlaceKind
        let point: GeoPoint
    }

    struct Area: Sendable {
        let name: String
        /// 5 district (municipal council), 9 ward.
        let level: Int
        let rings: [[SIMD2<Double>]]
        let minimum: SIMD2<Double>
        let maximum: SIMD2<Double>
    }

    /// Projection origin (Askari Monument). Equirectangular metres are accurate to well under 0.1 %
    /// across the 45 km service zone.
    static let origin = GeoPoint(latitude: -6.8180, longitude: 39.2880)
    private static let metresPerDegreeLat = 110_574.0
    private static let metresPerDegreeLon = 111_320.0 * cos(-6.8180 * .pi / 180)

    static let shared = DarAtlas()

    let streets: [Street]
    let places: [PlaceName]
    let areas: [Area]
    /// 200 m cells → indices of (street, segment) pairs crossing the cell.
    private let grid: [SIMD2<Int32>: [SIMD2<Int32>]]
    static let cellSize = 200.0

    static func local(_ point: GeoPoint) -> SIMD2<Double> {
        SIMD2((point.longitude - origin.longitude) * metresPerDegreeLon,
              (point.latitude - origin.latitude) * metresPerDegreeLat)
    }

    static func geo(_ local: SIMD2<Double>) -> GeoPoint {
        GeoPoint(latitude: origin.latitude + local.y / metresPerDegreeLat,
                 longitude: origin.longitude + local.x / metresPerDegreeLon)
    }

    private struct File: Decodable {
        struct Road: Decodable { let n: String; let r: Int; let p: [[Double]] }
        struct Place: Decodable { let n: String; let k: Int; let a: Double; let o: Double }
        struct AreaRecord: Decodable { let n: String; let l: Int; let g: [[[Double]]] }
        let roads: [Road]
        let places: [Place]
        let areas: [AreaRecord]
    }

    private init() {
        let file: File? = Bundle.main.url(forResource: "dar_atlas", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        if file == nil { print("[DarAtlas] bundled atlas unavailable; labels and addresses fall back") }
        var streets: [Street] = []
        var grid: [SIMD2<Int32>: [SIMD2<Int32>]] = [:]
        for road in file?.roads ?? [] {
            let points = road.p.compactMap { $0.count == 2 ? DarAtlas.local(GeoPoint(latitude: $0[0], longitude: $0[1])) : nil }
            guard points.count >= 2 else { continue }
            var distances: [Double] = [0]
            for i in 1..<points.count { distances.append(distances[i - 1] + simd_distance(points[i - 1], points[i])) }
            let id = streets.count
            streets.append(Street(id: id, name: road.n, rank: road.r, points: points, distances: distances))
            for s in 0..<(points.count - 1) {
                let lo = simd_min(points[s], points[s + 1]), hi = simd_max(points[s], points[s + 1])
                let c0 = SIMD2<Int32>(Int32(floor(lo.x / Self.cellSize)), Int32(floor(lo.y / Self.cellSize)))
                let c1 = SIMD2<Int32>(Int32(floor(hi.x / Self.cellSize)), Int32(floor(hi.y / Self.cellSize)))
                for cx in c0.x...c1.x { for cy in c0.y...c1.y { grid[SIMD2(cx, cy), default: []].append(SIMD2(Int32(id), Int32(s))) } }
            }
        }
        self.streets = streets
        self.grid = grid
        places = (file?.places ?? []).map {
            PlaceName(name: $0.n, kind: PlaceKind(rawValue: $0.k) ?? .village, point: GeoPoint(latitude: $0.a, longitude: $0.o))
        }
        areas = (file?.areas ?? []).compactMap { record in
            let rings = record.g.map { ring in ring.compactMap { $0.count == 2 ? DarAtlas.local(GeoPoint(latitude: $0[0], longitude: $0[1])) : nil } }
                .filter { $0.count >= 4 }
            let all = rings.flatMap { $0 }
            guard let first = all.first else { return nil }
            let lo = all.reduce(first) { simd_min($0, $1) }, hi = all.reduce(first) { simd_max($0, $1) }
            return Area(name: record.n, level: record.l, rings: rings, minimum: lo, maximum: hi)
        }
    }

    /// Street segments whose cells intersect a square of `radius` metres around `p`.
    func candidates(near p: SIMD2<Double>, radius: Double) -> [SIMD2<Int32>] {
        let c0 = SIMD2<Int32>(Int32(floor((p.x - radius) / Self.cellSize)), Int32(floor((p.y - radius) / Self.cellSize)))
        let c1 = SIMD2<Int32>(Int32(floor((p.x + radius) / Self.cellSize)), Int32(floor((p.y + radius) / Self.cellSize)))
        var seen = Set<SIMD2<Int32>>(), out: [SIMD2<Int32>] = []
        for cx in c0.x...c1.x {
            for cy in c0.y...c1.y {
                for entry in grid[SIMD2(cx, cy)] ?? [] where seen.insert(entry).inserted { out.append(entry) }
            }
        }
        return out
    }

    /// Smallest-level containing areas: (ward, district).
    func areas(containing point: GeoPoint) -> (ward: String?, district: String?) {
        let p = Self.local(point)
        var ward: String?, district: String?
        for area in areas where p.x >= area.minimum.x && p.y >= area.minimum.y && p.x <= area.maximum.x && p.y <= area.maximum.y {
            guard area.rings.contains(where: { Self.contains($0, p) }) else { continue }
            if area.level >= 9 { ward = ward ?? area.name } else { district = district ?? area.name }
        }
        return (ward, district)
    }

    /// Nearest suburb/quarter/neighbourhood name within `limit` metres.
    func neighbourhood(near point: GeoPoint, limit: Double = 2_500) -> String? {
        let p = Self.local(point)
        return places.filter { [.suburb, .quarter, .town].contains($0.kind) }
            .map { ($0, simd_distance(Self.local($0.point), p)) }
            .filter { $0.1 < limit }
            .min { $0.1 < $1.1 }?.0.name
    }

    private static func contains(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
