import CoreLocation
import Foundation

/// Street address for a coordinate. Zuri's own offline household addressing (street + metric house
/// number + ward + Plus Code) comes first; Apple's geocoder is only a fallback where no named street
/// is mapped nearby. Results are cached by a ~10 m grid so dragging the pin never repeats a lookup.
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

    /// Offline Zuri address as a place: "147 Haile Selassie Road" / "Masaki, Kinondoni · 67RG+XP7".
    static func zuriPlace(for point: GeoPoint) async -> Place? {
        let address = await Task.detached(priority: .userInitiated) { ZuriAddressService.address(for: point) }.value
        guard address.street != nil else { return nil }
        let locality = address.locality.isEmpty ? L(.darEsSalaam) : address.locality
        return Place(id: "zuri-\(address.fullCode)", name: address.headline, address: "\(locality) · \(address.code)", point: point)
    }

    /// Resolves "147 Kumbukumbu Street, Mikocheni" style labels. Zuri addressing first (offline), then Apple;
    /// finally the bare Plus Code, so every point has an address.
    static func place(for point: GeoPoint) async -> Place? {
        let cacheKey = key(for: point)
        if let hit = cache[cacheKey] { return hit }
        if let zuri = await zuriPlace(for: point) {
            cache[cacheKey] = zuri
            return zuri
        }
        if geocoder.isGeocoding { geocoder.cancelGeocode() }
        do {
            let marks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: point.latitude, longitude: point.longitude),
                preferredLocale: Locale(identifier: "en_TZ")
            )
            guard let mark = marks.first else { return codePlace(for: point) }
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
                return codePlace(for: point)
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
            return codePlace(for: point)
        }
    }

    /// No street anywhere near: the Plus Code is still a precise, shareable household address.
    private static func codePlace(for point: GeoPoint) -> Place {
        let address = ZuriAddressService.address(for: point)
        return Place(id: "zuri-\(address.fullCode)", name: address.code,
                     address: address.locality.isEmpty ? L(.darEsSalaam) : address.locality, point: point)
    }
}
