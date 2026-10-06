import Foundation

/// Fetches the entire tile, not just visible/decluttered features. Bundled authored scenery wins conflicts.
nonisolated enum DioramaMapboxData {
    static func load(tile: DioramaTileID, token: String, offline: Bool) async -> [DioramaVectorTile.Feature]? {
        guard !token.isEmpty,
              var url = URLComponents(string: "https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/\(tile.z)/\(tile.x)/\(tile.y).vector.pbf") else { return nil }
        url.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let address = url.url else { return nil }
        let request = URLRequest(url: address, cachePolicy: offline ? .returnCacheDataDontLoad : .useProtocolCachePolicy, timeoutInterval: 12)
        do {
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                print("[Diorama coverage] Mapbox tile unavailable; using bundled geometry")
                return nil
            }
            let features = try DioramaVectorTile.decode(bytes)
            guard !features.isEmpty else { return nil }
            return features
        } catch {
            // Never print the request or error URL: it contains the access token.
            print("[Diorama coverage] Mapbox tile could not load/decode; bundled fallback, Regenerate to retry")
            return nil
        }
    }

    /// Exact positive-area intersection, including crossing edges where neither centroid is contained.
    static func overlaps(_ a: [DV2], _ b: [DV2]) -> Bool {
        guard DioramaRect.bounding(a).intersects(DioramaRect.bounding(b)) else { return false }
        let remaining = DioramaGroundCutouts(polygons: [b]).subtract(from: a).reduce(0.0) { $0 + DioramaPolygon.area($1) }
        return DioramaPolygon.area(a) - remaining > 0.15
    }

    private static func landmarkIDs(in data: DioramaTileData) -> Set<UInt64> {
        DioramaHotelGenerator.ids.union(DioramaSlipwayPavilion.buildingIDs)
            .union(DioramaMosqueGenerator.buildingIDs(in: data)).union([165_397_124])
    }

    /// Reserve both the original mapped outline and the authored replacement. A replacement may
    /// deliberately recede a facade or stair passage; that space must not respawn as a second building.
    private static func reservation(_ feature: DioramaBuildingFeature) -> [[DV2]] {
        [feature.ring, feature.sourceFootprint].filter { $0.count >= 3 }
    }

    static func merge(_ features: [DioramaVectorTile.Feature], into original: DioramaTileData) -> DioramaTileData {
        var data = original
        data.hasMapboxCoverage = true
        func local(_ p: DV2, extent: Double) -> DV2 {
            let count = pow(2.0, Double(data.tile.z))
            let longitude = (Double(data.tile.x) + p.x / extent) / count * 360 - 180
            let latitude = atan(sinh(.pi * (1 - 2 * (Double(data.tile.y) + p.y / extent) / count))) * 180 / .pi
            return data.projection.local(longitude: longitude, latitude: latitude)
        }
        func name(_ f: DioramaVectorTile.Feature) -> String? {
            let value = (f.properties["name"] ?? f.properties["name_en"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value.prefix(96))
        }
        // POIs remain at their actual coordinates. No nearest-house renaming and no category fallback.
        var seenNames: Set<String> = []
        for f in features where f.layer == "poi_label" && f.type == 1 {
            guard let title = name(f), let point = f.paths.first?.first else { continue }
            let p = local(point, extent: f.extent)
            guard data.rect.contains(p), seenNames.insert("\(title):\(Int(p.x / 3)):\(Int(p.y / 3))").inserted else { continue }
            data.pois.append(.init(id: DioramaRandom.mix(f.id ^ 0xB0_0000_0000), point: p, kind: "mapboxLabel", name: title))
        }
        let fuel = data.landuse.filter { $0.kind == "fuel" }.compactMap { $0.rings.first }
        let protectedIDs = landmarkIDs(in: data)
        let protectedSites = data.buildings.filter { protectedIDs.contains($0.id) }.flatMap(reservation)
        var rejectedLandmarkDuplicates = 0
        var added = 0
        for f in features.filter({ $0.layer == "building" && $0.type == 3 }).sorted(by: { $0.id < $1.id }) {
            for (part, path) in f.paths.enumerated() {
                // MVT holes follow their exterior until the next positive-winding ring.
                guard DioramaPolygon.signedArea(path) > 0 else { continue }
                let clipped = DioramaPolygon.clipPolygon(path.map { local($0, extent: f.extent) }, to: data.rect)
                let clean = DioramaPolygon.clean(clipped, flags: []).points
                let ring = DioramaPolygon.counterClockwise(clean)
                let outerArea = DioramaPolygon.area(ring)
                guard ring.count >= 3, outerArea > 1 else { continue }
                let holes = f.paths.dropFirst(part + 1).prefix(while: { DioramaPolygon.signedArea($0) < 0 })
                    .map { $0.map { local($0, extent: f.extent) } }
                let basePieces = holes.isEmpty ? [ring] : DioramaGroundCutouts(polygons: holes).subtract(from: ring)
                // Never salvage wings from a second representation of a bespoke landmark.
                // Doing so retained the original Slipway outline around the authored smaller plan.
                if protectedSites.contains(where: { owner in basePieces.contains { overlaps($0, owner) } }) {
                    rejectedLandmarkDuplicates += 1
                    continue
                }
                let owners = fuel + data.buildings.flatMap(\.footprints)
                let relevant = owners.filter { owner in basePieces.contains { overlaps($0, owner) } }
                let pieces = relevant.isEmpty ? basePieces : basePieces.flatMap { DioramaGroundCutouts(polygons: relevant).subtract(from: $0) }
                let area = pieces.reduce(0.0) { $0 + DioramaPolygon.area($1) }
                let sourceArea = basePieces.reduce(0.0) { $0 + DioramaPolygon.area($1) }
                // Near-total overlap is a duplicate, not a row of sub-metre facade slivers.
                guard area > 1, relevant.isEmpty || area / max(sourceArea, 1) > 0.1 else { continue }
                let centroid = DioramaPolygon.centroid(ring)
                // Do not synthesize buildings in the sea from imprecise supplemental polygons.
                guard !data.water.contains(where: { DioramaPolygon.contains(polygon: $0.rings, centroid) }) else { continue }
                let rawHeight = Double(f.properties["height"] ?? "")
                let height = rawHeight.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                let building = DioramaBuildingFeature(id: DioramaRandom.hash("mapbox:building:\(f.id):\(part)") | (1 << 63),
                    ring: ring, clipped: ring.map { p in abs(p.x - data.rect.minX) < 0.1 || abs(p.x - data.rect.maxX) < 0.1 || abs(p.y - data.rect.minY) < 0.1 || abs(p.y - data.rect.maxY) < 0.1 },
                    area: area, centroid: centroid, height: height, type: f.properties["type"] ?? "house",
                    occupiedPieces: holes.isEmpty && relevant.isEmpty ? [] : pieces)
                // Keep the source outline: expanding supplemental footprints could reintroduce overlaps.
                data.buildings.append(building); added += 1
            }
        }
        let driving: Set<String> = ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link", "tertiary", "tertiary_link", "street", "street_limited", "residential", "unclassified", "service", "track"]
        var roadAdded = 0
        for f in features where f.layer == "road" && f.type == 2 {
            let roadClass = f.properties["class"] ?? ""
            guard driving.contains(roadClass) else { continue }
            let title = name(f)
            for (part, path) in f.paths.enumerated() {
                for (pieceIndex, line) in DioramaPolygon.clip(path.map { local($0, extent: f.extent) }, to: data.rect).enumerated() {
                    guard DioramaPolygon.length(line) > 0.2 else { continue }
                    let probes = DioramaPolygon.densify(line, maxStep: 4)
                    let index = DioramaRoadIndex(roads: data.roads, pavementWidth: 0)
                    var matching: Set<UInt64> = []
                    func existing(_ a: DV2, _ b: DV2) -> DioramaRoadFeature? {
                        guard let hit = index.nearest(to: (a + b) * 0.5, within: 2.5),
                              abs(hit.direction.dot((b - a).normalized)) > 0.8 else { return nil }
                        return hit.road
                    }
                    var represented = true
                    for (a, b) in zip(probes, probes.dropFirst()) {
                        if let road = existing(a, b) { matching.insert(road.id) }
                        else { represented = false }
                    }
                    if let title {
                        for i in data.roads.indices where matching.contains(data.roads[i].id) && data.roads[i].name == nil { data.roads[i].name = title }
                    }
                    if represented { continue }
                    let width: Double = ["motorway", "trunk", "primary"].contains(roadClass) ? 12 : roadClass == "secondary" ? 10 : roadClass == "tertiary" ? 8 : roadClass == "service" ? 4 : 6
                    // Add only missing stretches; keep established carriageways at matched locations.
                    var run: [DV2] = []
                    var ordinal: UInt64 = 0
                    func flush() {
                        defer { run = [] }
                        guard run.count > 1, DioramaPolygon.length(run) > 0.2 else { return }
                        let id = DioramaRandom.hash("mapbox:road:\(f.id):\(part):\(pieceIndex):\(ordinal)") | (1 << 63)
                        data.roads.append(.init(id: id, line: run, roadClass: roadClass,
                            isPaved: f.properties["surface"] != "unpaved" && roadClass != "track", width: width, name: title))
                        ordinal += 1; roadAdded += 1
                    }
                    for (a, b) in zip(probes, probes.dropFirst()) {
                        if existing(a, b) == nil {
                            if run.isEmpty { run.append(a) }; run.append(b)
                        } else { flush() }
                    }
                    flush()
                }
            }
        }
        print("[Diorama coverage] Mapbox added \(added) buildings, \(roadAdded) road stretches, \(seenNames.count) real POI names; rejected \(rejectedLandmarkDuplicates) landmark duplicates")
        return data
    }

    /// Authored landmarks first, then mapped houses. Fuel parcels reserve their models before houses.
    static func resolveOwnership(_ original: DioramaTileData) -> DioramaTileData {
        var data = original
        let landmarks = landmarkIDs(in: data)
        let protectedSites = data.buildings.filter { landmarks.contains($0.id) }.flatMap(reservation)
        let fuel = data.landuse.filter { $0.kind == "fuel" }.compactMap { $0.rings.first }
        var accepted: [DioramaBuildingFeature] = []
        for f in data.buildings.sorted(by: { a, b in
            let pa = landmarks.contains(a.id), pb = landmarks.contains(b.id)
            if pa != pb { return pa }
            return a.area != b.area ? a.area > b.area : a.id < b.id
        }) {
            if !landmarks.contains(f.id), protectedSites.contains(where: { owner in f.footprints.contains { overlaps($0, owner) } }) { continue }
            let owners = accepted.flatMap(\.footprints) + (landmarks.contains(f.id) ? [] : fuel)
            let conflicts = owners.filter { owner in f.footprints.contains { overlaps($0, owner) } }
            guard !conflicts.isEmpty else { accepted.append(f); continue }
            // Preserve meaningful remaining wings rather than throwing out an entire partial overlap.
            let pieces = f.footprints.flatMap { DioramaGroundCutouts(polygons: conflicts).subtract(from: $0) }
            let area = pieces.reduce(0.0) { $0 + DioramaPolygon.area($1) }
            guard area > 1, area / max(f.area, 1) > 0.1 else { continue }
            // Bespoke landmark generators use their full source plan, so do not feed them clipped wings.
            guard !landmarks.contains(f.id) else { continue }
            accepted.append(.init(id: f.id, ring: f.ring, clipped: f.clipped, area: area, centroid: f.centroid,
                height: f.height, type: f.type, name: f.name, occupiedPieces: pieces, sourceFootprint: f.sourceFootprint))
        }
        data.buildings = accepted.sorted { $0.id < $1.id }
        print("[Diorama coverage] \(data.buildings.count) buildings / \(data.roads.count) roads; \(original.buildings.count - accepted.count) conflicting footprints replaced by owners")
        return data
    }
}
