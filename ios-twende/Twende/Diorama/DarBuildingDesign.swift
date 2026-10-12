import Foundation

/// Stable, use-led architectural decisions. These are district interpretations, not surveyed facades.
/// Variation changes opening proportions, structural rhythm and roof massing, never source height.
nonisolated struct DarBuildingDesign {
    enum Family: String { case kisutu, tiled, glass, ribbon, modernist, coastal }
    let family: Family
    let variant: Int
    let cornerRadius: Double
    let recess: Double
    let bayWidth: Double
    let windowShare: Double
    let groundFloor: Double
    let hasUpperSetback: Bool
    let tankCount: Int
    let hasRoofAccess: Bool

    init(site: DarSkylineSite) {
        family = Family(rawValue: site.style) ?? .kisutu
        var rng = DioramaRandom(seed: site.osm, salt: 417)
        variant = Int(rng.unit() * 4)
        let broad = rng.range(0.0...1.0)
        switch family {
        case .kisutu:
            cornerRadius = 0.35 + broad * 0.35; recess = 0.26
            bayWidth = 3.6 + broad * 1.2; windowShare = 0.46 + broad * 0.17; groundFloor = 3.6
        case .tiled:
            cornerRadius = 0.3; recess = 0.22
            bayWidth = 3.5 + broad * 1.5; windowShare = 0.52 + broad * 0.2; groundFloor = 4.0
        case .glass:
            cornerRadius = 1.1 + broad * 1.3; recess = 0.16
            bayWidth = 3.4 + broad * 1.3; windowShare = 0.97; groundFloor = 4.6
        case .ribbon:
            cornerRadius = 0.8 + broad * 1.2; recess = 0.45
            bayWidth = 5.0 + broad * 1.5; windowShare = 0.91; groundFloor = 4.3
        case .modernist:
            cornerRadius = 0.35 + broad * 0.3; recess = 0.72
            bayWidth = 4.2 + broad * 1.4; windowShare = 0.76; groundFloor = 4.1
        case .coastal:
            cornerRadius = 0.7 + broad * 1.1; recess = 1.25 + broad * 0.45
            bayWidth = 4.2 + broad * 1.8; windowShare = 0.72; groundFloor = 3.5
        }
        hasUpperSetback = site.levels >= 9 && site.crown != "hip"
            && (family == .glass || family == .tiled || family == .coastal) && variant >= 2
        // Office plant belongs inside the building, not in an invented fenced pen on every roof.
        let residential = family == .kisutu || family == .coastal || family == .tiled
        tankCount = residential && rng.chance(0.48) ? (rng.chance(0.3) ? 2 : 1) : 0
        hasRoofAccess = residential && rng.chance(0.55)
    }

    /// Respect use and district, without assigning every apartment or office the same elevation.
    static func ordinaryFamily(id: UInt64, type: String, commercial: Bool, city: Bool, floors: Int) -> String {
        var rng = DioramaRandom(seed: id, salt: 809)
        if type.lowercased() == "office" {
            return rng.pick(floors >= 8 ? ["glass", "ribbon", "modernist", "tiled"] : ["ribbon", "modernist", "tiled"])
        }
        if commercial { return rng.pick(["tiled", "ribbon", "modernist", "kisutu"]) }
        return rng.pick(city ? ["kisutu", "kisutu", "tiled", "coastal"] : ["coastal", "coastal", "tiled", "kisutu"])
    }

    static func ordinaryRoof(id: UInt64, family: String, city: Bool, floors: Int) -> String {
        guard !city, family == "coastal", floors <= 12 else { return "flat" }
        var rng = DioramaRandom(seed: id, salt: 913)
        return rng.pick(["flat", "flat", "teal", "terracotta"])
    }
}
