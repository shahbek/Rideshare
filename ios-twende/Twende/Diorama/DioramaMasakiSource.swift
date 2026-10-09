import CoreGraphics
import CoreLocation
import Foundation
import ImageIO

/// Geographically addressed source ingestion. No Slipway scenery or height grid is copied to
/// other coordinates. Streets supplies footprints/water/land use; Terrain-RGB supplies elevation.
nonisolated enum DioramaMasakiSource {
    static let slipway = DioramaTileID(latitude: -6.7546, longitude: 39.2734, zoom: 16)

    /// Working peninsula envelope, not an assertion of an administrative ward boundary.
    static func contains(latitude: Double, longitude: Double) -> Bool {
        (-6.785 ... -6.730).contains(latitude) && (39.260 ... 39.305).contains(longitude)
    }

    static func load(tile: DioramaTileID, config: DioramaConfig, token: String, offline: Bool) async -> DioramaTileData? {
        if tile == slipway {
            guard let bundled = DioramaBundledTile.load(config: config) else { return nil }
            var data = DioramaMapboxData.resolveOwnership(bundled)
            if let features = await DioramaMapboxData.load(tile: tile, token: token, offline: offline, includesEnvironment: true) {
                data = DioramaPoolRecognition.merge(features, into: data)
                data = DioramaMapboxData.merge(features, into: data)
            } else {
                data = DioramaPoolRecognition.merge([], into: data)
            }
            data.shorelines = DioramaShoreline.classify(data: data, config: config, overrides: DioramaShorelineOverrides.load())
            data.shorelineLandMasks = DioramaShoreline.landMasks(data.shorelines, config: config)
            // Use the same addressed elevation source as neighbours, not a different boundary datum.
            if config.terrainEdgeEase == 0 {
                guard let terrain = await elevation(tile: tile, rect: data.rect, config: config, token: token, offline: offline) else { return nil }
                data.sourceTerrain = terrain
            }
            return data
        }
        guard DioramaOfflineStore.tiles.contains(tile),
              let features = await DioramaMapboxData.load(tile: tile, token: token, offline: offline, includesEnvironment: true),
              !Task.isCancelled else { return nil }
        let projection = DioramaProjection(origin: tile.centre)
        let rect = projection.rect(of: tile)
        guard let terrain = await elevation(tile: tile, rect: rect, config: config, token: token, offline: offline),
              !Task.isCancelled else { return nil }
        var data = DioramaTileData(tile: tile, projection: projection, rect: rect,
                                   buildings: [], roads: [], water: [], landuse: [])
        func local(_ p: DV2, extent: Double) -> DV2 {
            let n = pow(2.0, Double(tile.z))
            return projection.local(longitude: (Double(tile.x) + p.x / extent) / n * 360 - 180,
                latitude: atan(sinh(.pi * (1 - 2 * (Double(tile.y) + p.y / extent) / n))) * 180 / .pi)
        }
        for feature in features where feature.type == 3 && ["water", "landuse", "landuse_overlay"].contains(feature.layer) {
            let sourceClass = feature.properties["class"] ?? ""
            let kind: String
            if feature.layer == "water" { kind = "water" }
            else {
                switch sourceClass {
                case "park", "grass", "wood", "scrub": kind = "park"
                case "cemetery", "grave_yard": kind = "cemetery"
                case "pitch": kind = "pitch"
                case "sand": kind = "sand"
                default: continue
                }
            }
            for (part, path) in feature.paths.enumerated() where DioramaPolygon.signedArea(path) > 0 {
                let outer = DioramaPolygon.counterClockwise(DioramaPolygon.clean(path.map { local($0, extent: feature.extent) }, flags: []).points)
                guard outer.count >= 3, DioramaRect.bounding(outer).intersects(rect) else { continue }
                let holes = feature.paths.dropFirst(part + 1).prefix { DioramaPolygon.signedArea($0) < 0 }
                    .map { $0.map { local($0, extent: feature.extent) } }
                // Buffered MVT closure edges are artificial too. Never turn a tile boundary into a seawall.
                let flags = outer.indices.map { i in
                    let a = outer[i], b = outer[(i + 1) % outer.count]
                    return (a.x <= rect.minX + 0.1 && b.x <= rect.minX + 0.1)
                        || (a.x >= rect.maxX - 0.1 && b.x >= rect.maxX - 0.1)
                        || (a.y <= rect.minY + 0.1 && b.y <= rect.minY + 0.1)
                        || (a.y >= rect.maxY - 0.1 && b.y >= rect.maxY - 0.1)
                }
                let area = DioramaAreaFeature(id: DioramaRandom.hash("\(tile.key):\(feature.layer):\(feature.id):\(part)"),
                    rings: [outer] + holes, clipped: flags, kind: kind, tags: feature.properties)
                if kind == "water" { data.water.append(area) } else { data.landuse.append(area) }
            }
        }
        data = DioramaSeaCliffSite.merge(into: data)
        data = DioramaPoolRecognition.merge(features, into: data)
        data = DioramaMapboxData.merge(features, into: data)
        data.shorelines = DioramaShoreline.classify(data: data, config: config, overrides: [])
        data.shorelineLandMasks = DioramaShoreline.landMasks(data.shorelines, config: config)
        data.sourceTerrain = terrain
        return data
    }

    /// Decode native PNG samples without colour management: these bytes encode heights, not colours.
    private static func elevation(tile: DioramaTileID, rect: DioramaRect, config: DioramaConfig,
                                  token: String, offline: Bool) async -> DioramaTerrain? {
        let z = min(tile.z, 14), divisor = 1 << (tile.z - z)
        let parentX = tile.x / divisor, parentY = tile.y / divisor
        guard var components = URLComponents(string: "https://api.mapbox.com/v4/mapbox.terrain-rgb/\(z)/\(parentX)/\(parentY).pngraw") else { return nil }
        components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = components.url else { return nil }
        do {
            let bytes = try await DioramaSourceStore.shared.data(url: url, key: "terrain-\(z)-\(parentX)-\(parentY).png", offline: offline)
            guard let raster = DioramaElevationRaster(data: bytes) else { return nil }
            // Share the two pixels on either side of a parent-PNG boundary. Independent clamp
            // sampling gives adjacent children different edge heights even without the old ramp.
            var neighbours: [String: DioramaElevationRaster] = [:]
            let xs = tile.x % divisor == 0 ? [-1, 0] : tile.x % divisor == divisor - 1 ? [0, 1] : [0]
            let ys = tile.y % divisor == 0 ? [-1, 0] : tile.y % divisor == divisor - 1 ? [0, 1] : [0]
            for dx in xs {
                for dy in ys where dx != 0 || dy != 0 {
                    let px = parentX + dx, py = parentY + dy
                    guard DioramaOfflineStore.tiles.contains(where: { $0.x / divisor == px && $0.y / divisor == py }) else { continue }
                    guard var neighbourURL = URLComponents(string: "https://api.mapbox.com/v4/mapbox.terrain-rgb/\(z)/\(px)/\(py).pngraw") else { return nil }
                    neighbourURL.queryItems = [URLQueryItem(name: "access_token", value: token)]
                    guard let url = neighbourURL.url else { return nil }
                    let bytes = try await DioramaSourceStore.shared.data(url: url, key: "terrain-\(z)-\(px)-\(py).png", offline: offline)
                    guard let neighbour = DioramaElevationRaster(data: bytes), neighbour.width == raster.width,
                          neighbour.height == raster.height else { return nil }
                    neighbours["\(dx),\(dy)"] = neighbour
                }
            }
            func height(_ x: Int, _ y: Int) -> Double {
                let dx = x < 0 ? -1 : x >= raster.width ? 1 : 0
                let dy = y < 0 ? -1 : y >= raster.height ? 1 : 0
                if let neighbour = neighbours["\(dx),\(dy)"] {
                    return neighbour.sample(x: x - dx * raster.width, y: y - dy * raster.height)
                }
                return raster.sample(x: x, y: y)
            }
            let size = 33
            var elevations: [Double] = []
            elevations.reserveCapacity(size * size)
            for row in 0..<size {
                for column in 0..<size {
                    let u = (Double(tile.x % divisor) + Double(column) / Double(size - 1)) / Double(divisor)
                    let v = (Double(tile.y % divisor) + 1 - Double(row) / Double(size - 1)) / Double(divisor)
                    let x = u * Double(raster.width) - 0.5, y = v * Double(raster.height) - 0.5
                    let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
                    let a = height(ix, iy) * (1 - fx) + height(ix + 1, iy) * fx
                    let b = height(ix, iy + 1) * (1 - fx) + height(ix + 1, iy + 1) * fx
                    let value = a * (1 - fy) + b * fy
                    guard value.isFinite, (-500 ... 9000).contains(value) else { return nil }
                    elevations.append(value)
                }
            }
            return DioramaTerrain(rect: rect, columns: size, rows: size, values: elevations,
                relief: config.terrainRelief, edgeEase: config.terrainEdgeEase, midTideDatum: config.waterLevel)
        } catch {
            print("[Diorama coverage] Elevation unavailable; retaining basemap, no substitute terrain")
            return nil
        }
    }
}
