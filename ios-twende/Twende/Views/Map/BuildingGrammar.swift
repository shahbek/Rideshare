import Foundation
import simd

/// Deterministic PCG design rules based on footprint proportions, courtyards and height.
/// These are stylised interpretations, not surveyed facade classifications or Apple's landmark assets.
struct BuildingGrammar {
    enum Family: String {
        case townhouse, pavilion, urbanBlock, courtyard, tower, civic
    }

    let family: Family
    let roofStyle: BuildingRoof.Style
    let bayWidth: Double
    let recess: Double
    let hasFloorBands: Bool
    let crownHeight: Double

    var material: BuildingMaterialStyle {
        switch family {
        case .tower: .brutalist
        case .pavilion: .timber
        case .townhouse: .rock
        default: .royalStone
        }
    }

    init(footprint: BuildingFootprint, height: Double, roofOverride: BuildingRoof.Style?) {
        let rectangle = footprint.rectangle
        let length = rectangle.map { simd_distance($0[0], $0[1]) } ?? 0
        let width = rectangle.map { simd_distance($0[1], $0[2]) } ?? 0
        if roofOverride == .dome {
            family = .civic
        } else if footprint.rings.count > 1 {
            family = .courtyard
        } else if height >= 32 {
            family = .tower
        } else if rectangle != nil, height <= 13.5, width <= 19, length <= 38 {
            family = .townhouse
        } else if rectangle != nil, height <= 13.5, length / max(1, width) >= 1.5 {
            family = .pavilion
        } else {
            family = .urbanBlock
        }
        if let roofOverride {
            roofStyle = roofOverride
        } else {
            switch family {
            case .townhouse: roofStyle = length / max(1, width) > 2 ? .gable : .hip
            case .pavilion: roofStyle = .vault
            default: roofStyle = .terrace
            }
        }
        bayWidth = family == .tower ? 4.5 : family == .pavilion ? 5.0 : 3.8
        recess = family == .urbanBlock || family == .courtyard ? 0.32 : 0.22
        hasFloorBands = family == .urbanBlock || family == .courtyard || family == .tower
        crownHeight = rectangle == nil || roofStyle != .terrace ? 0 : family == .tower ? 2.8 : 1.2
    }
}
