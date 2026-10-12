import Foundation

/// Per-address architectural compositions. Photo evidence and inferred massing are recorded separately
/// from the original OSM envelope; no random seed chooses a major building's silhouette.
nonisolated struct DarSkylineComposition: Decodable, Sendable {
    enum Elevation: String, Decodable, Sendable {
        case punched, paired, horizontal, vertical, frame, gallery, curtain, hotel, nikko, rainbow
    }

    struct Part: Decodable, Sendable {
        /// Bounds in the source's dominant-axis frame, normalized 0...1. Intersect, never replace, the source ring.
        let zone: [Double]
        /// Zero is the original top floor; negative values count down from it.
        let top: Int
        let from: Int?
        let elevation: Elevation
        let sides: Elevation?
        let roof: String?
        let bay: Double?
        let radius: Double?
    }

    let id: String
    let intent: String
    let evidence: String?
    let references: [String]?
    let frontBearing: Double?
    let wall: String?
    let accent: String?
    let glass: String?
    let podium: Int
    let podiumStyle: Elevation?
    let parts: [Part]

    private struct Catalog: Decodable { let designs: [DarSkylineComposition] }

    private static let catalog: [String: DarSkylineComposition] = {
        guard let url = Bundle.main.url(forResource: "dar_skyline_compositions", withExtension: "json") else {
            print("[DarSkyline] composition resource missing; retaining validated legacy fallback")
            return [:]
        }
        do {
            let items = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).designs
            guard Set(items.map(\.id)).count == items.count else {
                print("[DarSkyline] duplicate composition identities; retaining fallback")
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        } catch {
            print("[DarSkyline] composition resource could not be decoded; retaining fallback")
            return [:]
        }
    }()

    static func design(for id: String) -> DarSkylineComposition? { catalog[id] }
}
