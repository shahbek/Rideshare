import Foundation

/// Versioned, editable geographic overrides; no site extents are hardcoded in generators.
nonisolated enum DioramaShorelineOverrides {
    nonisolated struct Entry: Decodable, Sendable {
        let id: String
        let type: DioramaShoreline.Kind
        /// [west, south, east, north] in WGS84.
        let bounds: [Double]
        let revetment: Bool
        let preserveMappedDecks: Bool
        let note: String

        func contains(_ p: DV2, projection: DioramaProjection) -> Bool {
            guard bounds.count == 4, bounds.allSatisfy(\.isFinite), bounds[0] <= bounds[2], bounds[1] <= bounds[3] else { return false }
            let a = projection.local(longitude: bounds[0], latitude: bounds[1])
            let b = projection.local(longitude: bounds[2], latitude: bounds[3])
            return DioramaRect.bounding([a, b]).contains(p)
        }
    }
    nonisolated struct File: Decodable, Sendable { let version: Int; let segments: [Entry] }

    static func load() -> [Entry] {
        guard let url = Bundle.main.url(forResource: "slipway_shoreline_overrides", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: bytes), file.version == 1 else {
            print("[Diorama] Shoreline override file unavailable; using source data and fallback rules")
            return []
        }
        return file.segments
    }
}
