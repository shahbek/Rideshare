import Foundation
import simd

/// Real source names only. Unnamed buildings retain their footprint but render no invented title.
nonisolated struct DioramaBuildingLabel: Sendable {
    let id: UInt64
    let title: String
    let anchor: SIMD3<Float>
    let footprint: [DV2]
    let isNamed: Bool
    var roadDirection: SIMD2<Float>? = nil

    static func make(_ building: DioramaBuilt, terrain: DioramaTerrain, config: DioramaConfig) -> Self {
        let f = building.feature
        let name = f.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let centre = DioramaPolygon.contains(f.ring, building.box.centre) ? building.box.centre : f.ring[0] * 0.1 + f.centroid * 0.9
        let roof = terrain.buildingHeight(f) + building.height + (building.flatRoof ? config.roofBevel : config.hipRoofMaxRise)
        return Self(id: f.id, title: name, anchor: SIMD3(Float(centre.x), Float(centre.y), Float(roof + 1.2)), footprint: f.ring, isNamed: !name.isEmpty)
    }

    static func all(buildings: [DioramaBuilt], data: DioramaTileData, terrain: DioramaTerrain, config: DioramaConfig) -> [Self] {
        var result = buildings.map { make($0, terrain: terrain, config: config) }
        for poi in data.pois {
            guard let name = poi.name, !name.isEmpty,
                  !result.contains(where: { $0.title == name }) else { continue }
            let host = buildings.filter { DioramaPolygon.contains($0.feature.ring, poi.point) }.min { $0.feature.area < $1.feature.area }
            let z = host.map { terrain.buildingHeight($0.feature) + $0.height + config.hipRoofMaxRise + 1.2 } ?? (terrain.height(poi.point) + 1.2)
            result.append(Self(id: poi.id, title: name, anchor: SIMD3(Float(poi.point.x), Float(poi.point.y), Float(z)), footprint: [], isNamed: true))
        }
        var namedRoads: Set<String> = []
        for road in data.roads.sorted(by: { DioramaPolygon.length($0.line) > DioramaPolygon.length($1.line) }) {
            guard let name = road.name, !name.isEmpty, !namedRoads.contains(name), DioramaPolygon.length(road.line) > 20 else { continue }
            let samples = DioramaPolygon.densify(road.line, maxStep: 2)
            guard samples.count >= 3 else { continue }
            let i = samples.count / 2, p = samples[i]
            let dir = (samples[min(i + 2, samples.count - 1)] - samples[max(i - 2, 0)]).normalized
            result.append(Self(id: road.id, title: name, anchor: SIMD3(Float(p.x), Float(p.y), Float(terrain.height(p) + 0.45)), footprint: [], isNamed: true, roadDirection: SIMD2(Float(dir.x), Float(dir.y))))
            namedRoads.insert(name)
        }
        return result
    }
}
