import Foundation
import simd

/// Source-backed names (or honest building categories) anchored above the generated roof.
nonisolated struct DioramaBuildingLabel: Codable, Sendable {
    let id: UInt64
    let title: String
    let anchor: SIMD3<Float>
    let footprint: [DV2]
    let isNamed: Bool

    static func make(_ building: DioramaBuilt, terrain: DioramaTerrain, config: DioramaConfig) -> Self {
        let f = building.feature
        let known: [UInt64: String] = [
            DioramaHotelGenerator.gallery: "Hotel Slipway",
            DioramaHotelGenerator.delta: "Delta Hotels",
        ]
        let name = f.name ?? known[f.id]
        let fallback: String
        if f.type == "mosque" { fallback = "Masjid" }
        else {
            switch building.kind {
            case .villa: fallback = "Residence"
            case .apartments: fallback = f.type == "hotel" ? "Hotel" : "Apartments"
            case .commercial: fallback = "Commercial building"
            }
        }
        let centre = DioramaPolygon.contains(f.ring, building.box.centre) ? building.box.centre : f.ring[0] * 0.1 + f.centroid * 0.9
        let roof = terrain.buildingHeight(f) + building.height + (building.flatRoof ? config.roofBevel : config.hipRoofMaxRise)
        return Self(id: f.id, title: name?.isEmpty == false ? name ?? fallback : fallback,
                    anchor: SIMD3(Float(centre.x), Float(centre.y), Float(roof + 1.2)),
                    footprint: f.ring, isNamed: name?.isEmpty == false)
    }
}
