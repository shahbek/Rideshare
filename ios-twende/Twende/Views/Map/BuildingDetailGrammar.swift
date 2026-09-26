import Foundation

/// Stable, mutually exclusive bay treatments. Selection depends on architecture and available space,
/// not per-frame randomness. Roof ornament has a separate budget from facade embellishment.
struct BuildingDetailGrammar {
    enum Treatment: String, CaseIterable {
        case none, triangularPediment, segmentalPediment, shutters, balcony, medallion, briseSoleil
    }
    let identity: BuildingIdentity

    func treatment(floor: Int, bay: Int, width: Double, storey: Double, isEntry: Bool, isCourtyard: Bool) -> Treatment {
        guard !isEntry, !isCourtyard, width >= 3.5, storey >= 3, storey <= 6 else { return .none }
        let cadence = (bay + identity.detailVariant) % 3
        switch identity.order {
        case .doric:
            return floor == 1 && cadence != 2 ? .triangularPediment : .none
        case .ionic, .corinthian:
            if floor == 1 && cadence == 0 { return .balcony }
            return floor > 0 && floor < 4 && cadence != 2 ? (identity.detailVariant % 2 == 0 ? .segmentalPediment : .triangularPediment) : .none
        case .roman:
            return floor > 0 && floor < 4 && cadence == 1 ? .medallion : .none
        case .gallery:
            if floor == 1 && cadence == 0 { return .balcony }
            return floor > 0 && floor < 4 ? .shutters : .none
        case .domed:
            return floor > 0 && cadence == 1 ? .medallion : .none
        case .vaulted:
            return floor < 3 && cadence != 2 ? .briseSoleil : .none
        case .terraced:
            return floor > 0 && floor < 5 && cadence == 0 ? .balcony : .none
        }
    }

    var hasDentils: Bool { [.doric, .ionic, .corinthian].contains(identity.order) }
    var hasBalustrade: Bool { [.roman, .gallery, .terraced].contains(identity.order) }
}
