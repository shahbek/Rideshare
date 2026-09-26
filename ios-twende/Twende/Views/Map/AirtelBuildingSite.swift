@_spi(Experimental) import MapboxMaps
import simd
import UIKit

/// Verified OSM way 367430152; local geometry always uses Mapbox's own metric projection.
enum AirtelBuildingSite {
    static let anchor = GeoPoint(latitude: -6.77784798, longitude: 39.26466405)
    static let geometry: Geometry? = {
        guard let url = Bundle.main.url(forResource: "airtel_house", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let feature = try? JSONDecoder().decode(Feature.self, from: data) else { return nil }
        return feature.geometry
    }()

    static func footprint(_ geometry: Geometry) -> BuildingFootprint? {
        guard case .polygon(let polygon) = geometry else { return nil }
        return BuildingFootprint(coordinates: polygon.coordinates, origin: anchor.coordinate)
    }

    /// Tight geographic matching excludes adjacent buildings and accepts smaller tile fragments.
    static func matches(_ candidate: Geometry) -> Bool {
        guard let reference = geometry.flatMap(footprint), let shape = footprint(candidate),
              let ring = shape.rings.first, let referenceRing = reference.rings.first else { return false }
        let centre = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
        guard simd_length(centre) < 42 else { return false }
        let expanded = BuildingFootprint(rings: [referenceRing.map { $0 * 1.06 }])
        let inside = ring.filter { expanded.path.contains(CGPoint(x: $0.x, y: $0.y)) }.count
        return inside >= max(3, Int(ceil(Double(ring.count) * 0.75)))
    }

    /// Accept a complete provider footprint only when size and boundary agree with the verified site.
    /// Tile fragments must never shrink or rotate the landmark.
    static func fittedGeometry(candidates: [Geometry]) -> Geometry? {
        guard let geometry, let reference = footprint(geometry), let ref = reference.rings.first else { return nil }
        let area = abs(BuildingFootprint.area(ref))
        return candidates.filter { candidate in
            guard matches(candidate), let shape = footprint(candidate), shape.rings.count == 1,
                  let ring = shape.rings.first else { return false }
            let ratio = abs(BuildingFootprint.area(ring)) / area
            return ratio > 0.9 && ratio < 1.1 && ref.allSatisfy { p in
                ring.indices.map { i in
                    let a = ring[i], delta = ring[(i + 1) % ring.count] - a
                    let t = max(0, min(1, simd_dot(p - a, delta) / max(0.001, simd_length_squared(delta))))
                    return simd_distance(p, a + delta * t)
                }.min() ?? 100 < 2.5
            }
        }.max { a, b in
            abs(BuildingFootprint.area(footprint(a)?.rings.first ?? [])) < abs(BuildingFootprint.area(footprint(b)?.rings.first ?? []))
        } ?? geometry
    }

    static func frontEdge(_ ring: [SIMD2<Double>]) -> Int {
        ring.indices.filter { i in
            let d = ring[(i + 1) % ring.count] - ring[i]
            return -d.x > abs(d.y) * 2
        }.max { a, b in
            simd_distance(ring[a], ring[(a + 1) % ring.count]) < simd_distance(ring[b], ring[(b + 1) % ring.count])
        } ?? 0
    }
}
