import Foundation

/// Street and garden trees, rebuilt on the skill's puff kit (`DioramaPuffKit`): puff crowns with
/// canopy normals and a vertex gradient, open 6-sided trunks, buried faces removed.
nonisolated enum DioramaTreeModels {
    static func make(variant: Int, light: Bool = false) -> DioramaMesh {
        let seed = UInt64(variant + 1)
        switch variant {
        case 1:
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 2.8, radius: 3.0, squash: 0.88, ring: 6, DioramaPuffKit.green, light: light, trunkRadius: 0.3)
        case 2:
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 2.1, radius: 2.2, squash: 0.92, ring: 5, DioramaPuffKit.deep, light: light)
        case 3:
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 2.4, radius: 2.5, squash: 0.9, ring: 6, DioramaPuffKit.lime, light: light)
        case 4:
            return DioramaPuffKit.tieredTree(seed: seed, trunkHeight: 2.2, tiers: 3, radius: 2.3, taper: 0.35, step: 1.5, DioramaPuffKit.green, light: light)
        case 5:
            return DioramaPuffKit.tieredTree(seed: seed, trunkHeight: 2.0, tiers: 3, radius: 2.1, taper: 0.4, step: 1.4, DioramaPuffKit.deep, light: light)
        case 6:
            // Umbrella: wide, flat table crown on a tall stem.
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 3.4, radius: 3.2, squash: 0.5, ring: 6, spread: 0.68, DioramaPuffKit.olive, light: light)
        case 7:
            return DioramaPuffKit.tieredTree(seed: seed, trunkHeight: 2.8, tiers: 4, radius: 1.7, taper: 0.45, step: 1.25, DioramaPuffKit.green, light: light)
        case 8:
            // Small ornamental in bloom.
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 1.6, radius: 1.5, squash: 0.92, ring: 4, DioramaPuffKit.blossom, light: light, trunkRadius: 0.14)
        case 9:
            return DioramaPuffKit.cypressTree(light: light)
        default:
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 2.4, radius: 2.6, squash: 0.9, ring: 6, DioramaPuffKit.green, light: light)
        }
    }
}
