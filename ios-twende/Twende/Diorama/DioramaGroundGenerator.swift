import Foundation

/// Ground details that live in the model: grass and paved courtyards inside compounds, sandy shoulders
/// along paved roads and a pale sand strip along the shoreline. Roads and water themselves are styled
/// Mapbox layers (see `DioramaMapStyling`) so they stay crisp at every zoom and keep real road labels.
nonisolated struct DioramaGroundGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex

    func generate(compounds: [DioramaCompound], into mesh: inout DioramaMesh) {
        // Compound ground: a grass plot with a paved courtyard between gate and house.
        for compound in compounds {
            var rng = DioramaRandom(seed: compound.building.feature.id, salt: 11)
            let plot = DioramaPolygon.offset(compound.ring, by: -0.35) ?? compound.ring
            mesh.polygon(plot, z: 0.04, .grass)
            if let gate = compound.gate {
                let house = compound.building.box
                let toHouse = (house.centre - gate.point)
                let length = max(toHouse.length - min(house.halfLength, house.halfWidth) * 0.5, 2)
                let dir = toHouse.normalized
                let across = dir.left
                let width = rng.range(2.6...3.4)
                let a = gate.point - across * width, b = gate.point + across * width
                let c = gate.point + dir * length + across * width, d = gate.point + dir * length - across * width
                mesh.polygon([a, b, c, d], z: 0.07, .courtyard)
            }
        }

        // Sandy shoulders beside paved roads.
        for road in data.roads where road.isPaved {
            strip(along: road.line, inner: road.width / 2 - 0.1, outer: road.width / 2 + 1.4, .courtyard, z: 0.03, into: &mesh)
        }

        // Pale sand along the shoreline: a strip inland of each real water edge.
        for water in data.water {
            guard let outer = water.rings.first else { continue }
            let n = outer.count
            for i in 0..<n where !water.clipped[i] {
                let a = outer[i], b = outer[(i + 1) % n]
                guard a.distance(to: b) > 1, data.rect.expanded(by: 5).contains((a + b) * 0.5) else { continue }
                // Water rings are counter-clockwise, so land lies to the right of travel.
                let out = (b - a).normalized.right
                mesh.quad(DV3(a - out * 1.5, 0.02), DV3(b - out * 1.5, 0.02), DV3(b + out * 7, 0.05), DV3(a + out * 7, 0.05), .courtyard, normal: .up)
            }
        }
    }

    private func strip(along line: [DV2], inner: Double, outer: Double, _ s: DioramaSwatch, z: Double, into mesh: inout DioramaMesh) {
        for i in 0..<max(line.count - 1, 0) {
            let a = line[i], b = line[i + 1]
            let dir = (b - a).normalized
            for side in [-1.0, 1.0] {
                let n = dir.right * side
                mesh.quad(DV3(a + n * inner, z), DV3(b + n * inner, z), DV3(b + n * outer, z), DV3(a + n * outer, z), s, normal: .up)
            }
        }
    }
}
