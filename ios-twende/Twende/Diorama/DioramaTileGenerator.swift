import Foundation

/// Per-category results for one generated tile.
nonisolated struct DioramaTileArtifacts: Sendable {
    nonisolated struct Part: Sendable {
        let category: DioramaCategory
        let url: URL
        let triangles: Int
        let bytes: Int
    }

    let tile: DioramaTileID
    let parts: [Part]
    let generationSeconds: Double

    var totalTriangles: Int { parts.reduce(0) { $0 + $1.triangles } }
    var totalBytes: Int { parts.reduce(0) { $0 + $1.bytes } }
}

/// Runs the whole pipeline for one tile off the main thread and writes one .glb per category.
/// Files are cached by tile and generator version; bumping `DioramaConfig.generatorVersion` invalidates.
nonisolated enum DioramaTileGenerator {
    static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ZuriDiorama", isDirectory: true)
    }

    static func url(for tile: DioramaTileID, category: DioramaCategory, version: Int, reduced: Bool) -> URL {
        cacheDirectory().appendingPathComponent("v\(version)/\(tile.key)\(reduced ? "-lite" : "")-\(category.rawValue).glb")
    }

    static func cached(_ tile: DioramaTileID, config: DioramaConfig, reduced: Bool) -> DioramaTileArtifacts? {
        let manifest = manifestURL(tile, version: config.generatorVersion, reduced: reduced)
        guard let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else { return nil }
        var parts: [DioramaTileArtifacts.Part] = []
        for entry in entries {
            let url = Self.url(for: tile, category: entry.category, version: config.generatorVersion, reduced: reduced)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            parts.append(.init(category: entry.category, url: url, triangles: entry.triangles, bytes: entry.bytes))
        }
        return DioramaTileArtifacts(tile: tile, parts: parts, generationSeconds: 0)
    }

    static func clearCache(for tile: DioramaTileID, config: DioramaConfig) {
        for reduced in [false, true] {
            try? FileManager.default.removeItem(at: manifestURL(tile, version: config.generatorVersion, reduced: reduced))
            for category in DioramaCategory.allCases {
                try? FileManager.default.removeItem(at: url(for: tile, category: category, version: config.generatorVersion, reduced: reduced))
            }
        }
    }

    private nonisolated struct ManifestEntry: Codable, Sendable {
        let category: DioramaCategory
        let triangles: Int
        let bytes: Int
    }

    private static func manifestURL(_ tile: DioramaTileID, version: Int, reduced: Bool) -> URL {
        cacheDirectory().appendingPathComponent("v\(version)/\(tile.key)\(reduced ? "-lite" : "").json")
    }

    /// Generates (or loads from cache) all models for a tile. Call from any thread.
    static func generate(_ data: DioramaTileData, config: DioramaConfig, library: DioramaPropLibrary, reduced: Bool) throws -> DioramaTileArtifacts {
        if let cached = cached(data.tile, config: config, reduced: reduced) { return cached }
        let started = Date()

        let roadIndex = DioramaRoadIndex(roads: data.roads)
        var buildings = DioramaMesh()
        var windowGlow = DioramaMesh()
        var walls = DioramaMesh()
        var ground = DioramaMesh()
        var vegetation = DioramaMesh()
        var props = DioramaMesh()
        var propGlow = DioramaMesh()

        let builder = DioramaBuildingGenerator(config: config, roads: roadIndex)
        var built: [DioramaBuilt] = []
        built.reserveCapacity(data.buildings.count)
        for feature in data.buildings {
            built.append(builder.build(feature, into: &buildings, glow: &windowGlow, lights: true))
        }

        let wallGenerator = DioramaCompoundWallGenerator(config: config, roads: roadIndex, buildings: built, tileRect: data.rect)
        let compounds = wallGenerator.generate(into: &walls)

        DioramaGroundGenerator(config: config, data: data, roads: roadIndex).generate(compounds: compounds, into: &ground)

        let placer = DioramaPropPlacer(config: config, data: data, roads: roadIndex, library: library, buildings: built, compounds: compounds, reduceDetail: reduced)
        placer.vegetation(into: &vegetation)
        placer.props(into: &props, glow: &propGlow)

        guard let atlas = DioramaAtlas.png(config: config) else {
            throw NSError(domain: "Diorama", code: 1, userInfo: [NSLocalizedDescriptionKey: "palette atlas failed"])
        }

        let meshes: [(DioramaCategory, DioramaMesh)] = [
            (.buildings, buildings), (.walls, walls), (.ground, ground), (.vegetation, vegetation),
            (.props, props), (.windowGlow, windowGlow), (.propGlow, propGlow),
        ]
        var parts: [DioramaTileArtifacts.Part] = []
        var manifest: [ManifestEntry] = []
        for (category, mesh) in meshes where !mesh.isEmpty {
            let target = url(for: data.tile, category: category, version: config.generatorVersion, reduced: reduced)
            let stats = try DioramaGLBWriter.write(mesh, emissive: category.isEmissive, atlas: atlas, to: target)
            parts.append(.init(category: category, url: target, triangles: stats.triangles, bytes: stats.bytes))
            manifest.append(ManifestEntry(category: category, triangles: stats.triangles, bytes: stats.bytes))
        }
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: manifestURL(data.tile, version: config.generatorVersion, reduced: reduced), options: .atomic)
        return DioramaTileArtifacts(tile: data.tile, parts: parts, generationSeconds: Date().timeIntervalSince(started))
    }
}
