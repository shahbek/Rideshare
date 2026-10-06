import Foundation

/// Pool evidence must be resolved before coastline classification or heightfield construction.
/// Swimming symbols select bounded mapped basins, never fabricate polygons or convert open sea.
nonisolated enum DioramaPoolRecognition {
    static func isPool(_ tags: [String: String]) -> Bool {
        ["class", "type", "leisure", "subclass"].contains {
            ["swimming_pool", "swimming pool", "pool"].contains(tags[$0]?.lowercased() ?? "")
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
        }.flatMap { feature in feature.paths.flatMap { $0.map { local($0, extent: feature.extent) } } }
        var candidates: [DioramaAreaFeature] = []
        var possibleBasins: [DioramaAreaFeature] = []
        for feature in features where feature.type == 3 && ["water", "landuse", "landuse_overlay"].contains(feature.layer) {
            for (part, path) in feature.paths.enumerated() where DioramaPolygon.signedArea(path) > 0 {
                let outer = DioramaPolygon.counterClockwise(DioramaPolygon.clean(path.map { local($0, extent: feature.extent) }, flags: []).points)
                guard outer.count >= 3, DioramaRect.bounding(outer).intersects(data.rect) else { continue }
                let holes = feature.paths.dropFirst(part + 1).prefix { DioramaPolygon.signedArea($0) < 0 }
                    .map { $0.map { local($0, extent: feature.extent) } }
                let area = DioramaPolygon.area(outer)
                let tagged = isPool(feature.properties)
                let flowingOrMarine: Set<String> = ["river", "stream", "canal", "reservoir", "ocean", "sea"]
                let natural = ["water", "class", "type"].contains { flowingOrMarine.contains(feature.properties[$0]?.lowercased() ?? "") }
                let box = DioramaPolygon.minimumAreaRectangle(outer)
                // Lake/pond are broad source classes, not enough to overrule swimming evidence.
                // Kidney/L-shaped basins and planted islands must not fail a rectangle test.
                let compact = feature.layer == "water" && !natural && area >= 4 && area <= 3000
                    && area / max(box.area, 1) > 0.28 && max(box.halfLength, box.halfWidth) <= 55
                    && !outer.contains { p in
                        abs(p.x - data.rect.minX) < 0.3 || abs(p.x - data.rect.maxX) < 0.3
                            || abs(p.y - data.rect.minY) < 0.3 || abs(p.y - data.rect.maxY) < 0.3
                    }
                guard tagged || compact else { continue }
                let basin = DioramaAreaFeature(id: DioramaRandom.hash("pool:\(data.tile.key):\(feature.layer):\(feature.id):\(part)"),
                    rings: [outer] + holes, clipped: Array(repeating: false, count: outer.count), kind: "pool",
                    sport: feature.properties["access"] == "private" || area < 180 ? "private" : nil,
                    tags: feature.properties)
                if tagged { candidates.append(basin) } else { possibleBasins.append(basin) }
            }
        }
        var matched: Set<UInt64> = []
        for symbol in symbols {
            let ranked = possibleBasins.compactMap { basin -> (DioramaAreaFeature, Double)? in
                guard let ring = basin.rings.first else { return nil }
                let distance = DioramaPolygon.contains(polygon: basin.rings, symbol) ? 0 : DioramaPolygon.distanceToRing(ring, symbol)
                return distance <= 8 ? (basin, distance) : nil
            }.sorted { $0.1 < $1.1 }
            guard let best = ranked.first else { continue }
            // Near-but-outside symbols are accepted only with an unambiguous nearest basin.
            guard ranked.count == 1 || best.1 == 0 || ranked[1].1 - best.1 > 3 else { continue }
            if matched.insert(best.0.id).inserted { candidates.append(best.0) }
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
