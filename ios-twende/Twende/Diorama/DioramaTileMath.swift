import CoreLocation
import Foundation

/// A Web Mercator (slippy map) tile.
nonisolated struct DioramaTileID: Hashable, Sendable, CustomStringConvertible {
    let z: Int
    let x: Int
    let y: Int

    init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    /// Standard Web Mercator tile formula; never hardcode tile numbers.
    init(latitude: Double, longitude: Double, zoom: Int) {
        let n = Double(1 << zoom)
        let lat = min(max(latitude, -85.05112878), 85.05112878) * Double.pi / 180
        let fx = (longitude + 180) / 360 * n
        let fy = (1 - log(tan(lat) + 1 / cos(lat)) / Double.pi) / 2 * n
        let maxIndex = (1 << zoom) - 1
        self.init(z: zoom, x: min(max(Int(floor(fx)), 0), maxIndex), y: min(max(Int(floor(fy)), 0), maxIndex))
    }

    var description: String { "\(z)/\(x)/\(y)" }
    var key: String { "\(z)-\(x)-\(y)" }

    static func longitude(x: Double, zoom: Int) -> Double {
        x / Double(1 << zoom) * 360 - 180
    }

    static func latitude(y: Double, zoom: Int) -> Double {
        let n = Double.pi - 2 * Double.pi * y / Double(1 << zoom)
        return atan(sinh(n)) * 180 / Double.pi
    }

    var west: Double { Self.longitude(x: Double(x), zoom: z) }
    var east: Double { Self.longitude(x: Double(x + 1), zoom: z) }
    var north: Double { Self.latitude(y: Double(y), zoom: z) }
    var south: Double { Self.latitude(y: Double(y + 1), zoom: z) }

    /// Mercator centre of the tile; generated models are anchored here.
    var centre: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: Self.latitude(y: Double(y) + 0.5, zoom: z),
            longitude: Self.longitude(x: Double(x) + 0.5, zoom: z)
        )
    }

    func offset(dx: Int, dy: Int) -> DioramaTileID {
        DioramaTileID(z: z, x: x + dx, y: y + dy)
    }

    /// Ring of corner coordinates (closed) for debug drawing.
    var outline: [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: north, longitude: west),
            CLLocationCoordinate2D(latitude: north, longitude: east),
            CLLocationCoordinate2D(latitude: south, longitude: east),
            CLLocationCoordinate2D(latitude: south, longitude: west),
            CLLocationCoordinate2D(latitude: north, longitude: west),
        ]
    }
}

/// Local east/north metres around a tile origin, consistent with how Mapbox scales a model at that point
/// (Mercator north, scaled by the origin latitude).
nonisolated struct DioramaProjection: Sendable {
    let originLongitude: Double
    let originLatitude: Double
    private let metresPerDegreeLongitude: Double
    private let originMercatorY: Double
    private let metresPerMercatorUnit: Double

    init(origin: CLLocationCoordinate2D) {
        let earthRadius = 6_378_137.0
        let latRad = origin.latitude * Double.pi / 180
        originLongitude = origin.longitude
        originLatitude = origin.latitude
        metresPerDegreeLongitude = Double.pi / 180 * earthRadius * cos(latRad)
        originMercatorY = log(tan(Double.pi / 4 + latRad / 2))
        metresPerMercatorUnit = earthRadius * cos(latRad)
    }

    func local(longitude: Double, latitude: Double) -> DV2 {
        let latRad = latitude * Double.pi / 180
        let mercator = log(tan(Double.pi / 4 + latRad / 2))
        return DV2((longitude - originLongitude) * metresPerDegreeLongitude, (mercator - originMercatorY) * metresPerMercatorUnit)
    }

    /// `lonLat` is (longitude, latitude).
    func local(_ lonLat: DV2) -> DV2 { local(longitude: lonLat.x, latitude: lonLat.y) }

    func coordinate(_ p: DV2) -> (longitude: Double, latitude: Double) {
        let longitude = originLongitude + p.x / metresPerDegreeLongitude
        let mercator = originMercatorY + p.y / metresPerMercatorUnit
        let latitude = (2 * atan(exp(mercator)) - Double.pi / 2) * 180 / Double.pi
        return (longitude, latitude)
    }

    func rect(of tile: DioramaTileID) -> DioramaRect {
        let sw = local(longitude: tile.west, latitude: tile.south)
        let ne = local(longitude: tile.east, latitude: tile.north)
        return DioramaRect(minX: sw.x, minY: sw.y, maxX: ne.x, maxY: ne.y)
    }

    func tile(containing p: DV2, zoom: Int) -> DioramaTileID {
        let c = coordinate(p)
        return DioramaTileID(latitude: c.latitude, longitude: c.longitude, zoom: zoom)
    }
}
