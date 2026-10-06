import Foundation
import simd

/// Mapbox-sourced names only. Unnamed buildings remain rendered, without category labels.
nonisolated struct DioramaBuildingLabel: Sendable {
    let id: UInt64
    let title: String
    let anchor: SIMD3<Float>
    let footprint: [DV2]
    let isNamed: Bool

    static func make(_ building: DioramaBuilt, terrain: DioramaTerrain, config: DioramaConfig) -> Self? {
        let f = building.feature
        guard let name = f.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let centre = DioramaPolygon.contains(f.ring, building.box.centre) ? building.box.centre : f.ring[0] * 0.1 + f.centroid * 0.9
        let roof = terrain.buildingHeight(f) + building.height + (building.flatRoof ? config.roofBevel : config.hipRoofMaxRise)
        return Self(id: f.id, title: name, anchor: SIMD3(Float(centre.x), Float(centre.y), Float(roof + 0.15)),
                    footprint: f.ring, isNamed: true)
    }
}
