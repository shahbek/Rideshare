import Foundation

/// Full-tile Mapbox Streets supplement, independent of camera visibility and symbol collision.
/// The bundled OSM architecture/shoreline remains authoritative for authored landmarks.
nonisolated enum DioramaMapboxSource {
    static func supplement(_ original: DioramaTileData, token: String, offline: Bool) async -> DioramaTileData {
        var data = original
        // Names must come from Mapbox; never silently retain category or authored name fallbacks.
        for i in data.buildings.indices { data.buildings[i].name = nil }
        var components = URLComponents(string: "https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/\(data.tile.z)/\(data.tile.x)/\(data.tile.y).vector.pbf")
        components?.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = components?.url, !token.isEmpty else { return data }
        let request = URLRequest(url: url, cachePolicy: offline ? .returnCacheDataDontLoad : .returnCacheDataElseLoad, timeoutInterval: 12)
        do {
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DioramaVectorTile.Failure.malformed }
            let layers = try DioramaVectorTile.decode(bytes)
            guard !layers.isEmpty else {
                throw DioramaVectorTile.Failure.malformed
            }
            merge(layers, into: &data)
            data.sourceCoverage = "Mapbox tile + bundled landmarks"
            print("[Diorama coverage] \(data.buildings.count) buildings, \(data.roads.count) road segments, \(data.buildings.filter { $0.name != nil }.count) named buildings")
        } catch {
            data.sourceCoverage = "Bundled coverage only · Mapbox unavailable; Regenerate to retry"
            print("[Diorama coverage] Mapbox supplement unavailable; using bundled geometry without invented names")
        }
        return data
    }

    private static func merge(_ layers: [DioramaVectorTile.Layer], into data: inout DioramaTileData) {
        func local(_ p: DV2, extent: Double) -> DV2 {
            let n = pow(2.0, Double(data.tile.z))
            let longitude = (Double(data.tile.x) + p.x / extent) / n * 360 - 180
            let latitude = atan(sinh(.pi * (1 - 2 * (Double(data.tile.y) + p.y / extent) / n))) * 180 / .pi
            return data.projection.local(longitude: longitude, latitude: latitude)
        }
        func name(_ properties: [String: String]) -> String? {
            let text = (properties["name"] ?? properties["name_en"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        var usedIDs = Set(data.buildings.map(\.id) + data.roads.map(\.id) + data.landuse.map(\.id))
        func uniqueID(_ source: UInt64, _ part: Int, _ domain: UInt64) -> UInt64 {
            var id = DioramaRandom.mix(DioramaRandom.mix(source) ^ DioramaRandom.mix(UInt64(part)) ^ domain) | (1 << 63)
            while usedIDs.contains(id) { id = (id &+ 1) | (1 << 63) }
            usedIDs.insert(id)
            return id
        }
        for layer in layers where layer.name == "building" {
            for feature in layer.features where feature.type == 3 {
                for (part, raw) in feature.paths.enumerated() where raw.count >= 3 {
                    // MVT exterior rings are clockwise in y-down tile coordinates; holes reverse it.
                    let signed = zip(raw, raw.dropFirst() + [raw[0]]).reduce(0.0) { $0 + $1.0.cross($1.1) }
                    guard signed > 0 else { continue }
                    let projected = raw.map { local($0, extent: layer.extent) }
                    let ring = DioramaPolygon.counterClockwise(DioramaPolygon.clean(projected, flags: Array(repeating: false, count: projected.count)).points)
                    guard ring.count >= 3, DioramaPolygon.area(DioramaPolygon.clipPolygon(ring, to: data.rect)) > 2 else { continue }
                    let centre = DioramaPolygon.centroid(ring)
                    let matches = data.buildings.indices.filter {
                        DioramaPolygon.contains(data.buildings[$0].ring, centre) || DioramaPolygon.contains(ring, data.buildings[$0].centroid)
                    }
                    if !matches.isEmpty {
                        if let title = name(feature.properties) {
                            for i in matches where data.buildings[i].name == nil { data.buildings[i].name = title }
                        }
                        continue
                    }
                    let id = uniqueID(feature.id, part, 1)
                    let height = Double(feature.properties["height"] ?? "").flatMap { $0.isFinite && $0 > 3.1 ? $0 : nil }
                    let f = DioramaBuildingFeature(id: id, ring: ring, clipped: Array(repeating: false, count: ring.count),
                        area: DioramaPolygon.area(ring), centroid: centre, height: height,
                        type: feature.properties["type"] ?? "house", name: name(feature.properties))
                    data.buildings.append(DioramaFootprints.softened(f))
                }
            }
        }
        // Read road lines, not path/steps/rail/ferry geometry. Access rights are not inferred.
        let roadClasses: Set<String> = ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link", "tertiary", "tertiary_link", "street", "street_limited", "residential", "unclassified", "service", "living_street", "track"]
        var mappedRoads: [DioramaRoadFeature] = []
        for layer in layers where layer.name == "road" {
            for feature in layer.features where feature.type == 2 {
                let cls = feature.properties["class"] ?? ""
                guard roadClasses.contains(cls) else { continue }
                let width: Double
                switch cls {
                case "motorway", "trunk", "primary": width = 12
                case "secondary": width = 10
                case "tertiary": width = 8
                case "service", "track": width = 4
                default: width = 6
                }
                var part = 0
                for raw in feature.paths {
                    for line in DioramaPolygon.clip(raw.map({ local($0, extent: layer.extent) }), to: data.rect) where DioramaPolygon.length(line) > 0.25 {
                        part += 1
                        let id = uniqueID(feature.id, part, 2)
                        let surface = feature.properties["surface"] ?? ""
                        let paved = !["unpaved", "dirt", "earth", "gravel", "sand"].contains(surface) && cls != "track"
                        mappedRoads.append(DioramaRoadFeature(id: id, line: line, roadClass: cls, isPaved: paved, width: width, name: name(feature.properties)))
                    }
                }
            }
        }
        if !mappedRoads.isEmpty {
            let index = DioramaRoadIndex(roads: mappedRoads, pavementWidth: 0)
            // Retain source ways that Mapbox lacks, but not a second offset copy of the same street.
            var extra: [DioramaRoadFeature] = []
            for road in data.roads {
                let samples = DioramaPolygon.densify(road.line, maxStep: 2)
                var run: [DV2] = [], part = 0
                func flush() {
                    guard run.count >= 2 else { run = []; return }
                    part += 1
                    extra.append(DioramaRoadFeature(id: uniqueID(road.id, part, 3), line: run,
                        roadClass: road.roadClass, isPaved: road.isPaved, width: road.width, name: road.name))
                    run = []
                }
                for (a, b) in zip(samples, samples.dropFirst()) {
                    let near = index.nearest(to: (a + b) * 0.5, within: 3)
                    let covered = near.map { abs($0.direction.dot((b - a).normalized)) > 0.85 } ?? false
                    if covered { flush() }
                    else { if run.isEmpty { run.append(a) }; run.append(b) }
                }
                flush()
            }
            data.roads = (mappedRoads + extra).sorted { $0.id < $1.id }
        }
        for layer in layers where layer.name == "poi_label" {
            for feature in layer.features {
                guard let title = name(feature.properties), let raw = feature.paths.first?.first else { continue }
                let p = local(raw, extent: layer.extent)
                guard data.rect.contains(p) else { continue }
                // No nearest-business guesses across streets: require the POI inside its host footprint.
                if let i = data.buildings.indices.filter({ DioramaPolygon.contains(data.buildings[$0].ring, p) })
                    .min(by: { data.buildings[$0].area < data.buildings[$1].area }), data.buildings[i].name == nil {
                    data.buildings[i].name = title
                }
            }
        }
        for layer in layers where layer.name == "landuse" || layer.name == "landcover" {
            for feature in layer.features where feature.type == 3 {
                let cls = feature.properties["class"] ?? ""
                guard ["grass", "wood", "scrub", "park", "sand", "bare_rock"].contains(cls) else { continue }
                let rings = feature.paths.filter { $0.count >= 3 }.map {
                    DioramaPolygon.clipPolygon($0.map { local($0, extent: layer.extent) }, to: data.rect)
                }.filter { $0.count >= 3 }
                guard let first = rings.first else { continue }
                let kind = ["grass", "wood", "park"].contains(cls) ? "mapped_green" : "natural_earth"
                // Preserve holes and disconnected exteriors in the painter's even-odd fill.
                data.landuse.append(DioramaAreaFeature(id: uniqueID(feature.id, 0, layer.name == "landuse" ? 4 : 5),
                    rings: rings, clipped: Array(repeating: false, count: first.count), kind: kind))
            }
        }
        data.buildings.sort { $0.id < $1.id }
    }
}
