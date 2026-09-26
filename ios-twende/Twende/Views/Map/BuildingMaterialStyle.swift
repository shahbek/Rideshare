import Foundation

/// Natural, texture-free secondary finishes. Existing family identifiers remain stable.
nonisolated enum BuildingMaterialStyle: Int, CaseIterable {
    case royalStone, timber, brutalist, rock

    var wall: String {
        switch self {
        case .royalStone: "#DED4C0"
        case .timber: "#E8DDC9"
        case .brutalist: "#C9C8C1"
        case .rock: "#B3B1A9"
        }
    }

    var trim: String { "#EEE6D8" }
}
