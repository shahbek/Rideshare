import CoreLocation
import Foundation

/// Codable coordinate used throughout the app. Convert to `CLLocationCoordinate2D` only at the MapKit boundary.
nonisolated struct GeoPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Great-circle distance in kilometres.
    func distanceKm(to other: GeoPoint) -> Double {
        let radius = 6371.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Linear interpolation towards `other` (fine for city-scale distances).
    func interpolated(to other: GeoPoint, fraction: Double) -> GeoPoint {
        let t = min(max(fraction, 0), 1)
        return GeoPoint(
            latitude: latitude + (other.latitude - latitude) * t,
            longitude: longitude + (other.longitude - longitude) * t
        )
    }

    /// Compass bearing in degrees from this point to `other`.
    func bearing(to other: GeoPoint) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Returns a point offset by metres east/north.
    func offset(eastMetres: Double, northMetres: Double) -> GeoPoint {
        let dLat = northMetres / 111_320.0
        let dLon = eastMetres / (111_320.0 * cos(latitude * .pi / 180))
        return GeoPoint(latitude: latitude + dLat, longitude: longitude + dLon)
    }
}

/// Well-known coordinates for the Dar es Salaam service zone and demo trip.
nonisolated enum DarEsSalaam {
    static let centre = GeoPoint(latitude: -6.8160, longitude: 39.2800)
    static let serviceRadiusKm = 45.0
    static let upanga = GeoPoint(latitude: -6.7987, longitude: 39.2765)
    static let mikocheni = GeoPoint(latitude: -6.7595, longitude: 39.2385)

    static func isInServiceZone(_ point: GeoPoint) -> Bool {
        centre.distanceKm(to: point) <= serviceRadiusKm
    }
}
