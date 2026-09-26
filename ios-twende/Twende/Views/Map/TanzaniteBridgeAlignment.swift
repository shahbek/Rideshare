@_spi(Experimental) import MapboxMaps
import simd

/// WGS84 centerline with distances in the same local Mercator metre frame as the map's 3D renderer.
struct TanzaniteBridgeAlignment {
    nonisolated struct Record: Decodable {
        let source: String
        let widthMetres: Double
        let coordinates: [GeoPoint]
        let pylonChainages: [Double]
        let notes: String
    }
    static let anchor = GeoPoint(latitude: -6.79292, longitude: 39.28545)
    let record: Record
    let points: [SIMD2<Double>]
    let chainages: [Double]
    var length: Double { chainages.last ?? 0 }

    init?(record: Record) {
        guard record.coordinates.count >= 2, record.widthMetres > 0,
              record.coordinates.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) < 85 && abs($0.longitude) < 180 }) else { return nil }
        self.record = record
        let origin = Projection.project(Self.anchor.coordinate, zoomScale: 1)
        let scale = Double(Projection.metersPerPoint(for: Self.anchor.latitude, zoom: 0))
        points = record.coordinates.map { coordinate in
            let p = Projection.project(coordinate.coordinate, zoomScale: 1)
            return SIMD2((p.x - origin.x) * scale, (origin.y - p.y) * scale)
        }
        var distances: [Double] = [0]
        for i in 1..<points.count { distances.append((distances.last ?? 0) + simd_distance(points[i - 1], points[i])) }
        guard (distances.last ?? 0) > 100 else { return nil }
        chainages = distances
    }

    static func load() -> TanzaniteBridgeAlignment? {
        guard let url = Bundle.main.url(forResource: "tanzanite_bridge_alignment", withExtension: "json"),
              let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return TanzaniteBridgeAlignment(record: record)
    }

    func point(at distance: Double, offset: Double = 0, elevation: Double? = nil) -> SIMD3<Double> {
        let d = min(length, max(0, distance))
        var index = 0
        while index + 1 < chainages.count - 1 && chainages[index + 1] < d { index += 1 }
        let span = max(0.01, chainages[index + 1] - chainages[index])
        let t = (d - chainages[index]) / span
        let delta = points[index + 1] - points[index]
        let tangent = simd_normalize(delta), normal = SIMD2(-tangent.y, tangent.x)
        let xy = points[index] + delta * t + normal * offset
        return SIMD3(xy.x, xy.y, elevation ?? deckElevation(at: d))
    }

    func tangent(at distance: Double) -> SIMD3<Double> {
        let a = point(at: max(0, distance - 0.5), elevation: 0)
        let b = point(at: min(length, distance + 0.5), elevation: 0)
        return simd_normalize(b - a)
    }

    /// Illustrative vertical profile: gently rises from the approaches to the navigable central span.
    func deckElevation(at distance: Double) -> Double {
        let ramp = min(1, max(0, min(distance / 180, (length - distance) / 160)))
        return 4 + 16 * (ramp * ramp * (3 - 2 * ramp))
    }
}
