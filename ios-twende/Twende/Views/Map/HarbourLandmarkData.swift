import Foundation
import simd

/// Researched mapped parts remain separate from photo-authored elevations and pool details.
nonisolated struct HarbourLandmarkData: Decodable {
    nonisolated struct Part: Decodable {
        let id: String
        let osmWay: Int
        let ring: [[Double]]
    }
    let sites: [DarLandmarkSite]
    let parts: [Part]

    static let bundled: HarbourLandmarkData? = {
        guard let url = Bundle.main.url(forResource: "harbour_landmarks", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let data = try? JSONDecoder().decode(Self.self, from: bytes),
              data.sites.count == 2, data.parts.count == 2,
              data.sites.allSatisfy({ valid($0.ring) && $0.height.isFinite && $0.height > 0 && $0.bearing.isFinite }),
              data.parts.allSatisfy({ valid($0.ring) }) else { return nil }
        return data
    }()

    private static func valid(_ ring: [[Double]]) -> Bool {
        ring.count >= 4 && ring.count <= 128 && ring.first == ring.last && ring.allSatisfy {
            $0.count == 2 && $0[0].isFinite && $0[1].isFinite && abs($0[0]) <= 180 && abs($0[1]) < 85
        }
    }

    @MainActor func localPart(_ id: String, site: DarLandmarkSite) -> [SIMD2<Double>] {
        guard let part = parts.first(where: { $0.id == id }) else { return [] }
        return MoroccoSquareData.local(part.ring, origin: site.anchor.coordinate)
            .map { SIMD2(simd_dot($0, site.right), simd_dot($0, site.inward)) }
    }
}
