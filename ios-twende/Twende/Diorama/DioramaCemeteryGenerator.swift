import Foundation

/// Neutral uninscribed markers within mapped cemetery polygons. Rows are illustrative, not grave records.
nonisolated enum DioramaCemeteryGenerator {
    static func generate(_ area: DioramaAreaFeature, data: DioramaTileData, terrain: DioramaTerrain,
                         roads: DioramaRoadIndex, into mesh: inout DioramaMesh) {
        guard let outer = area.rings.first else { return }
        let clipped = DioramaPolygon.clipPolygon(outer, to: data.rect)
        guard clipped.count >= 3 else { return }
        let box = DioramaPolygon.minimumAreaRectangle(clipped)
        let occupied = data.buildings.flatMap(\.footprints)
            + data.water.compactMap { $0.rings.first }
            + data.landuse.filter { ["pool", "pitch", "parking", "fuel", "terrace"].contains($0.kind) }.compactMap { $0.rings.first }
        func clear(_ p: DV2) -> Bool {
            DioramaPolygon.contains(polygon: area.rings, p) && data.rect.contains(p)
                && !occupied.contains { DioramaPolygon.contains($0, p) } && !roads.isOnCarriageway(p, margin: 1)
                && !data.paths.contains { DioramaShoreline.distance(p, line: $0.line) < 1.5 }
        }
        // Limit density for large grounds; preserve a central access aisle.
        let spacing = max(3.2, sqrt(DioramaPolygon.area(clipped) / 450))
        for row in 0..<max(1, Int(box.halfWidth * 2 / spacing)) {
            let v = -box.halfWidth + spacing * (Double(row) + 0.5)
            guard abs(v) > 1.7 else { continue }
            for column in 0..<max(1, Int(box.halfLength * 2 / spacing)) {
                let u = -box.halfLength + spacing * (Double(column) + 0.5)
                let p = box.centre + box.axis * u + box.across * v
                let footprint = DioramaOrientedRect(centre: p, axis: box.axis, halfLength: 0.53, halfWidth: 1.02)
                guard footprint.corners.allSatisfy(clear) else { continue }
                let z = terrain.foundationHeight(footprint.corners)
                mesh.box(centre: p, z0: z - 0.12, axis: box.axis, halfLength: 0.48, halfWidth: 0.93,
                         height: 0.23, .rockPale, bevel: 0.08)
                let head = p + box.across * 0.72
                mesh.box(centre: head, z0: z + 0.1, axis: box.axis, halfLength: 0.36, halfWidth: 0.12,
                         height: 0.9, .poolCoping, bevel: 0.1)
            }
        }
    }
}
