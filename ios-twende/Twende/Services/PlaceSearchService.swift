import MapKit
import Observation
import CoreLocation

/// Place search limited to the Dar es Salaam service zone. Uses Apple Maps (free, no per-request fee)
/// plus the local catalogue. Queries that start with a house number ("19 kumbukumbu") also run the
/// address geocoder, and the typed number is kept on the result so the driver sees the exact address.
@Observable
final class PlaceSearchService {
    private(set) var results: [Place] = []
    private(set) var isSearching: Bool = false

    private static let searchRegion = MKCoordinateRegion(
        center: DarEsSalaam.centre.coordinate,
        latitudinalMeters: DarEsSalaam.serviceRadiusKm * 2000,
        longitudinalMeters: DarEsSalaam.serviceRadiusKm * 2000
    )

    /// Splits "19 kumbukumbu" or "kumbukumbu 19" into a house number and the street text.
    nonisolated static func houseNumber(in query: String) -> (number: String, street: String)? {
        let words = query.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        let isNumber: (String) -> Bool = { word in
            guard let first = word.first, first.isNumber else { return false }
            return word.count <= 6 && word.allSatisfy { $0.isNumber || $0.isLetter || $0 == "/" || $0 == "-" }
        }
        if isNumber(words[0]) { return (words[0], words.dropFirst().joined(separator: " ")) }
        if let last = words.last, isNumber(last) { return (last, words.dropLast().joined(separator: " ")) }
        return nil
    }

    /// Debounced search; returns catalogue matches immediately and appends Apple Maps results when available.
    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let local = DemoPlaces.search(trimmed)
        results = local
        guard trimmed.count >= 3 else {
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }

        let house = Self.houseNumber(in: trimmed)
        async let poiAndStreets = mapSearch(house.map { "\($0.street), Dar es Salaam" } ?? trimmed)
        async let exact = house == nil ? [] : geocode("\(trimmed), Dar es Salaam, Tanzania")
        var remote = await exact
        remote += await poiAndStreets

        if Task.isCancelled { return }
        // Apple often knows a street but not each plot; keep the typed number on street matches.
        if let house {
            remote = remote.map { place in
                guard place.category == nil, !place.name.contains(house.number),
                      place.name.localizedCaseInsensitiveContains(house.street.split(separator: " ").first.map(String.init) ?? house.street)
                else { return place }
                var numbered = place
                numbered.name = "\(house.number) \(place.name)"
                numbered.id = "\(place.id)-\(house.number)"
                return numbered
            }
        }
        var seen = Set(local.map { $0.name.lowercased() })
        var merged = local
        for place in remote where place.isInServiceZone && seen.insert(place.name.lowercased()).inserted {
            merged.append(place)
        }
        results = Array(merged.prefix(12))
        isSearching = false
    }

    private func mapSearch(_ text: String) async -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = Self.searchRegion
        request.regionPriority = .required
        request.resultTypes = [.pointOfInterest, .address]
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { item -> Place? in
                guard let name = item.name else { return nil }
                let mark = item.placemark
                let coordinate = mark.coordinate
                let address = [mark.thoroughfare, mark.subLocality, mark.locality]
                    .compactMap { $0 }
                    .filter { $0 != name }
                    .joined(separator: ", ")
                return Place(
                    id: "mk-\(name)-\(coordinate.latitude)-\(coordinate.longitude)",
                    name: name,
                    address: address.isEmpty ? L(.darEsSalaam) : address,
                    point: GeoPoint(coordinate),
                    category: item.pointOfInterestCategory.flatMap(Self.category)
                )
            }
        } catch {
            print("[PlaceSearch] Apple Maps lookup failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Exact street-address match, restricted to the service zone.
    private func geocode(_ text: String) async -> [Place] {
        let region = CLCircularRegion(center: DarEsSalaam.centre.coordinate, radius: DarEsSalaam.serviceRadiusKm * 1000, identifier: "dar")
        do {
            let marks = try await CLGeocoder().geocodeAddressString(text, in: region, preferredLocale: Locale(identifier: "en_TZ"))
            return marks.compactMap { mark -> Place? in
                guard let location = mark.location, mark.thoroughfare != nil else { return nil }
                let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
                let area = [mark.subLocality, mark.locality].compactMap { $0 }.joined(separator: ", ")
                return Place(
                    id: "geo-\(location.coordinate.latitude)-\(location.coordinate.longitude)",
                    name: street,
                    address: area.isEmpty ? L(.darEsSalaam) : area,
                    point: GeoPoint(location.coordinate)
                )
            }
        } catch {
            return []
        }
    }

    private static func category(_ poi: MKPointOfInterestCategory) -> PlaceCategory? {
        switch poi {
        case .school, .university: .school
        case .fitnessCenter: .gym
        case .stadium: .sports
        case .restaurant, .bakery, .foodMarket: .food
        case .hospital, .pharmacy: .hospital
        case .cafe: .cafe
        case .hotel: .hotel
        case .beach: .beach
        case .publicTransport: .bus
        case .bank, .atm: .bank
        case .gasStation, .evCharger: .fuel
        case .nightlife, .brewery, .winery: .bar
        case .airport: .airport
        case .store: .shopping
        default: nil
        }
    }
}
