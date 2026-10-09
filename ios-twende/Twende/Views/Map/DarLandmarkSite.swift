@_spi(Experimental) import MapboxMaps
import UIKit
import simd

/// Research provenance and unsimplified OSM geometry live in the bundled catalog, not Swift constants.
nonisolated struct DarLandmarkSite: Decodable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let osmWay: Int
    let bearing: Double
    let height: Double
    let heightEvidence: String
    let reference: String
    let photo: String
    let orientationEvidence: String
    let ring: [[Double]]

    @MainActor static let all: [DarLandmarkSite] = {
        guard let url = Bundle.main.url(forResource: "dar_landmarks", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(DarLandmarkCatalog.self, from: data) else { return [] }
        return (catalog.sites + (MoroccoSquareData.bundled?.sites ?? [])).filter { $0.ring.count >= 4 && $0.ring.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } }
    }()

    @MainActor var geometry: Geometry {
        .polygon(Polygon([ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }]))
    }

    @MainActor var anchor: GeoPoint {
        let points = ring.dropLast()
        return GeoPoint(latitude: points.reduce(0) { $0 + $1[1] } / Double(points.count), longitude: points.reduce(0) { $0 + $1[0] } / Double(points.count))
    }

    @MainActor var footprint: BuildingFootprint? {
        guard case .polygon(let polygon) = geometry else { return nil }
        return BuildingFootprint(coordinates: polygon.coordinates, origin: anchor.coordinate)
    }

    @MainActor func matches(_ geometry: Geometry) -> Bool {
        guard case .polygon(let polygon) = geometry,
              let candidate = BuildingFootprint(coordinates: polygon.coordinates, origin: anchor.coordinate),
              let ring = candidate.rings.first, let reference = footprint else { return false }
        let expanded = BuildingFootprint(rings: reference.rings.map { $0.map { $0 * 1.05 } })
        return ring.filter { expanded.path.contains(CGPoint(x: $0.x, y: $0.y)) }.count >= max(3, Int(ceil(Double(ring.count) * 0.8)))
    }

    @MainActor static func isBespoke(_ geometry: Geometry) -> Bool {
        AirtelBuildingSite.matches(geometry) || all.contains { $0.matches(geometry) }
    }

    /// x = screen-right from the front, y = into the building. Positive determinant, never mirrored.
    var right: SIMD2<Double> { let a = bearing * .pi / 180; return SIMD2(-cos(a), sin(a)) }
    var inward: SIMD2<Double> { let a = bearing * .pi / 180; return SIMD2(-sin(a), -cos(a)) }
}
