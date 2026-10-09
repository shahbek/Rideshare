@_spi(Experimental) import MapboxMaps
import Foundation
import simd

/// Bundled mapped outlines and separately identified render-guided upper masses.
nonisolated struct MoroccoSquareData: Decodable {
    nonisolated struct Tower: Decodable {
        let id: String
        let kind: String
        let osmWay: Int
        let floors: Int
        let height: Double
        let ring: [[Double]]
        let upperRing: [[Double]]?
    }
    let sites: [DarLandmarkSite]
    let towers: [Tower]
    let atrium: [Double]

    static let bundled: MoroccoSquareData? = {
        guard let url = Bundle.main.url(forResource: "morocco_square", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), let data = try? JSONDecoder().decode(Self.self, from: bytes),
              data.towers.count == 4, data.atrium.count == 2, data.atrium.allSatisfy(\.isFinite),
              data.towers.allSatisfy({ valid($0.ring) && ($0.upperRing.map(valid) ?? true) && $0.floors > 2 && $0.floors <= 24 && $0.height.isFinite && $0.height > 10 }),
              data.sites.allSatisfy({ valid($0.ring) }) else { return nil }
        return data
    }()

    private static func valid(_ ring: [[Double]]) -> Bool {
        ring.count >= 4 && ring.count <= 512 && ring.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) }
    }

    @MainActor static func local(_ ring: [[Double]], origin: CLLocationCoordinate2D) -> [SIMD2<Double>] {
        guard valid(ring) else { return [] }
        let coordinates = ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
        return BuildingFootprint(coordinates: [coordinates], origin: origin)?.rings.first ?? []
    }
}
