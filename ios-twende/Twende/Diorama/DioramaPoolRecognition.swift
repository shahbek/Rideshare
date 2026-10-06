import Foundation

/// Pool evidence must be resolved before coastline classification or heightfield construction.
/// A swimming symbol alone never invents a basin: it must lie inside a small mapped water polygon.
nonisolated enum DioramaPoolRecognition {
    static func isPool(_ tags: [String: String]) -> Bool {
        ["class", "type", "leisure", "subclass"].contains {
            ["swimming_pool", "swimming pool"].contains(tags[$0]?.lowercased() ?? "")
        }
    }

    static func merge(_ features: [DioramaVectorTile.Feature], into original: DioramaTileData) -> DioramaTileData {
        var data = original
        func local(_ point: DV2, extent: Double) -> DV2 {
            let n = pow(2.0, Double(data.tile.z))
            return data.projection.local(longitude: (Double(data.tile.x) + point.x / extent) / n * 360 - 180,
                latitude: atan(sinh(.pi * (1 - 2 * (Double(data.tile.y) + point.y / extent) / n))) * 180 / .pi)
        }
        let symbols: [DV2] = features.filter {
            $0.layer == "poi_label" && $0.type == 1 &&
                (isPool($0.properties) || $0.properties["maki"] == "swimming")
        }.compactMap { feature in feature.paths.first?.first.map { local($0, extent: feature.extent) } }
        var candidates: [DioramaAreaFeature] = []
        for feature in features where feature.type == 3 && ["water", "landuse", "landuse_overlay"].contains(feature.layer) {
            for (part, path) in feature.paths.enumerated() where DioramaPolygon.signedArea(path) > 0 {
                let outer = DioramaPolygon.counterClockwise(DioramaPolygon.clean(path.map { local($0, extent: feature.extent) }, flags: []).points)
                guard outer.count >= 3, DioramaRect.bounding(outer).intersects(data.rect) else { continue }
                let holes = feature.paths.dropFirst(part + 1).prefix { DioramaPolygon.signedArea($0) < 0 }
                    .map { $0.map { local($0, extent: feature.extent) } }
                let area = DioramaPolygon.area(outer)
                let tagged = isPool(feature.properties)
                let naturalKinds: Set<String> = ["lake", "pond", "river", "stream", "reservoir", "ocean", "sea", "basin"]
                let natural = ["water", "class", "type"].contains { naturalKinds.contains(feature.properties[$0] ?? "") }
                let box = DioramaPolygon.minimumAreaRectangle(outer)
                // A swimming icon may describe open-water recreation, not a constructed basin.
                // Symbol-only matching is deliberately limited to compact, pool-like outlines.
                let symbolMatch = feature.layer == "water" && !natural && area >= 6 && area <= 2500 && holes.isEmpty
                    && area / max(box.area, 1) > 0.8 && max(box.halfLength, box.halfWidth) < 40
                    && symbols.contains { DioramaPolygon.contains(outer, $0) }
                guard tagged || symbolMatch else { continue }
                // Keep complete mapped outlines; a partially visible basin is still one pool.
                let flags = Array(repeating: false, count: outer.count)
                candidates.append(.init(id: DioramaRandom.hash("pool:\(data.tile.key):\(feature.layer):\(feature.id):\(part)"),
                    rings: [outer] + holes, clipped: flags, kind: "pool",
                    sport: feature.properties["access"] == "private" || area < 180 ? "private" : nil,
                    tags: feature.properties))
            }
        }
        // Also protect bundled/tagged water when no supplementary tile can be obtained.
        for water in data.water where isPool(water.tags) {
            candidates.append(.init(id: water.id, rings: water.rings, clipped: water.clipped, kind: "pool", tags: water.tags))
        }
        for candidate in candidates {
            guard let ring = candidate.rings.first else { continue }
            let area = DioramaPolygon.area(ring)
            let existingPools = data.landuse.filter { $0.kind == "pool" }.compactMap { $0.rings.first }
            let remaining = DioramaGroundCutouts(polygons: existingPools).subtract(from: ring)
                .reduce(0.0) { $0 + DioramaPolygon.area($1) }
            if remaining / max(area, 1) < 0.15 { continue }
            // A more complete mapped outline replaces contained smaller representations, rather
            // than disappearing because a few square centimetres overlap an existing pool.
            data.landuse.removeAll { existing in
                guard existing.kind == "pool", let outline = existing.rings.first else { return false }
                let outside = DioramaGroundCutouts(polygons: [ring]).subtract(from: outline)
                    .reduce(0.0) { $0 + DioramaPolygon.area($1) }
                return outside / max(DioramaPolygon.area(outline), 1) < 0.15
            }
            data.landuse.append(candidate)
        }
        let pools = data.landuse.filter { $0.kind == "pool" }.compactMap { $0.rings.first }
        data.water.removeAll { water in
            guard let outer = water.rings.first else { return false }
            let area = DioramaPolygon.area(outer)
            guard area > 0, isPool(water.tags) || area <= 5000 else { return false }
            // Match duplicate pool polygons from different sources, without deleting a sea/river.
            let remaining = DioramaGroundCutouts(polygons: pools).subtract(from: outer)
                .reduce(0.0) { $0 + DioramaPolygon.area($1) }
            return remaining / area < 0.15
        }
        return data
    }
}
