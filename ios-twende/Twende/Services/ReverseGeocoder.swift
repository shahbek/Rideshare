import CoreLocation
import Foundation

/// Street address for a coordinate, using Apple's free on-device geocoder. Results are cached by a
/// ~20 m grid so dragging the pin back and forth never repeats a lookup.
@MainActor
enum ReverseGeocoder {
    private static var cache: [String: Place] = [:]
    private static let geocoder = CLGeocoder()

    private static func key(for point: GeoPoint) -> String {
        String(format: "%.4f,%.4f", point.latitude, point.longitude)
    }

    /// Cached result without a network call.
    static func cached(for point: GeoPoint) -> Place? {
        cache[key(for: point)]
    }

    /// Resolves "19 Kumbukumbu Street, Mikocheni" style labels. Returns nil offline or when Apple has no data.
    static func place(for point: GeoPoint) async -> Place? {
        let cacheKey = key(for: point)
        if let hit = cache[cacheKey] { return hit }
        if geocoder.isGeocoding { geocoder.cancelGeocode() }
        do {
            let marks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: point.latitude, longitude: point.longitude),
                preferredLocale: Locale(identifier: "en_TZ")
            )
            guard let mark = marks.first else { return nil }
            let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
            let area = [mark.subLocality, mark.locality].compactMap { $0 }
            let name: String
            if !street.isEmpty {
                name = street
            } else if let poi = mark.areasOfInterest?.first {
                name = poi
            } else if let first = area.first {
                name = first
            } else {
                return nil
            }
            let address = area.filter { $0 != name }.joined(separator: ", ")
            let place = Place(
                id: "geo-\(cacheKey)",
                name: name,
                address: address.isEmpty ? L(.darEsSalaam) : address,
                point: point
            )
            cache[cacheKey] = place
            return place
        } catch {
            return nil
        }
    }
}
