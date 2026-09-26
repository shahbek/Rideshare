import Foundation

/// Morphology is the first PCG stage; the architectural order supplies compatible detail afterward.
/// Family names describe stylised forms, not inferred real-world uses.
struct BuildingMorphology {
    enum Family: String, CaseIterable {
        case cottage, rowHouse, villa, courtyard, marketHall, atelierHall, rotunda
        case civicHall, mansion, cornerBlock, slenderTower, slabTower, terraceTower, urbanBlock
    }
    let family: Family
    let metrics: BuildingFootprintMetrics
    let identity: BuildingIdentity
    let roofStyle: BuildingRoof.Style
    let bayWidth: Double
    let windowRatio: Double
    let floorSpacing: Double
    let bandStride: Int
    let crownHeight: Double
    let crownLevels: Int
    let usesVerticalRibs: Bool
    let hasClassicalOrnaments: Bool
    var isTower: Bool { [.slenderTower, .slabTower, .terraceTower].contains(family) }

    init(footprint: BuildingFootprint, height: Double, identity original: BuildingIdentity, roofOverride: BuildingRoof.Style? = nil) {
        let shape = BuildingFootprintMetrics(footprint)
        metrics = shape
        let variant = original.variant(channel: 1, count: 4)
        let rectangle = footprint.rectangle != nil
        if height >= 32 {
            if shape.aspect >= 2.1 { family = .slabTower }
            else if height / max(1, shape.width) >= 2.5 { family = .slenderTower }
            else { family = .terraceTower }
        } else if shape.hasCourtyard {
            family = .courtyard
        } else if shape.isRound {
            family = .rotunda
        } else if shape.fill < 0.74 {
            family = .cornerBlock
        } else if height <= 16 && shape.aspect >= 2.2 && shape.length >= 35 {
            family = original.order == .vaulted || variant % 2 == 0 ? .marketHall : .atelierHall
        } else if shape.width < 9 && shape.aspect >= 1.8 {
            family = .rowHouse
        } else if height <= 9 && shape.area < 220 {
            family = .cottage
        } else if height <= 14 && shape.area < 650 {
            family = .villa
        } else if height <= 22 && shape.area >= 900 {
            family = .civicHall
        } else if rectangle && height >= 15 && height < 30 && variant % 2 == 1 {
            family = .mansion
        } else {
            family = .urbanBlock
        }
        let tower = [.slenderTower, .slabTower, .terraceTower].contains(family)
        let order: BuildingIdentity.Order
        switch family {
        case .slenderTower, .slabTower, .terraceTower: order = .terraced
        case .marketHall, .atelierHall: order = .vaulted
        case .courtyard: order = variant % 2 == 0 ? .gallery : .roman
        case .rotunda: order = .domed
        case .rowHouse, .cottage: order = .gallery
        default: order = original.order
        }
        identity = original.withOrder(order)
        let requested: BuildingRoof.Style
        switch family {
        case .slenderTower, .slabTower, .terraceTower, .courtyard, .cornerBlock: requested = .terrace
        case .marketHall: requested = .vault
        case .atelierHall: requested = .sawtooth
        case .mansion: requested = .mansard
        case .rotunda: requested = .dome
        case .cottage: requested = variant % 2 == 0 ? .hip : .gable
        case .rowHouse: requested = variant < 2 ? .mansard : .gable
        default:
            switch order {
            case .domed: requested = .dome
            case .vaulted: requested = .vault
            case .doric, .ionic, .corinthian: requested = .gable
            case .roman, .gallery, .terraced: requested = .terrace
            }
        }
        let preferred = roofOverride ?? requested
        let needsRectangle = [.gable, .hip, .vault, .mansard, .sawtooth].contains(preferred)
        roofStyle = needsRectangle && !rectangle ? .terrace : preferred
        hasClassicalOrnaments = !tower && ![.marketHall, .atelierHall, .cottage, .rowHouse].contains(family)
        usesVerticalRibs = family == .slenderTower || family == .slabTower || (family == .terraceTower && variant > 1)
        switch family {
        case .cottage, .rowHouse: bayWidth = 3.1; windowRatio = 0.55; floorSpacing = 3.2; bandStride = 2
        case .marketHall, .atelierHall: bayWidth = 5.5; windowRatio = 0.78; floorSpacing = 4.4; bandStride = 3
        case .slenderTower: bayWidth = 3.7; windowRatio = 0.78; floorSpacing = 3.5; bandStride = 4
        case .slabTower: bayWidth = 4.5; windowRatio = 0.82; floorSpacing = 3.4; bandStride = 3
        case .terraceTower: bayWidth = 4.0; windowRatio = 0.72; floorSpacing = 3.6; bandStride = 2
        case .civicHall, .rotunda: bayWidth = 4.5; windowRatio = 0.65; floorSpacing = 4.0; bandStride = 1
        default: bayWidth = 3.8; windowRatio = 0.62; floorSpacing = 3.6; bandStride = 1
        }
        crownHeight = !rectangle || roofStyle != .terrace ? 0 : tower ? min(5.5, max(2.8, height * 0.07)) : 1.2
        crownLevels = family == .slenderTower ? 3 : family == .terraceTower ? 2 : 1
    }
}
