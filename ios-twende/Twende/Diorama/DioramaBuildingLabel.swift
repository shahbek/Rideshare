import Foundation
import simd

/// Only names supplied by Mapbox Streets; unnamed architecture never gets a generic label.
nonisolated struct DioramaBuildingLabel: Sendable {
    let id: UInt64
    let title: String
    let anchor: SIMD3<Float>
    let footprint: [DV2]
    let isNamed: Bool

    static func makeAll(_ buildings: [DioramaBuilt], data: DioramaTileData, terrain: DioramaTerrain, config: DioramaConfig) -> [Self] {
        data.pois.filter { $0.kind == "mapboxLabel" }.compactMap { poi in
            guard let title = poi.name, !title.isEmpty else { return nil }
            let host = buildings.filter { $0.feature.footprints.contains { DioramaPolygon.contains($0, poi.point) } }.min { $0.feature.area < $1.feature.area }
            var height = terrain.height(poi.point) + 0.2
            if let host {
                height = terrain.buildingHeight(host.feature) + host.height + (host.flatRoof ? config.roofBevel : config.hipRoofMaxRise) + 0.15
            } else if let fuel = data.landuse.first(where: { $0.kind == "fuel" && DioramaPolygon.contains(polygon: $0.rings, poi.point) }), let ring = fuel.rings.first {
                height = terrain.foundationHeight(ring) + 6.5
            }
            return Self(id: poi.id, title: title, anchor: SIMD3(Float(poi.point.x), Float(poi.point.y), Float(height)),
                        footprint: host?.feature.ring ?? [], isNamed: true)
        }
    }
}
