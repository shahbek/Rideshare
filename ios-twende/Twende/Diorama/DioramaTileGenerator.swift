import Foundation
import simd

/// Everything the renderer needs for one generated tile: one interleaved vertex buffer, one index
/// buffer, and the index range each category occupies so categories can be toggled per frame.
nonisolated struct DioramaTileArtifacts: Sendable {
    nonisolated struct Part: Sendable {
        let category: DioramaCategory
        let triangles: Int
    }

    let tile: DioramaTileID
    let vertices: [BuildingRenderVertex]
    let indices: [UInt32]
    let ranges: [DioramaRenderLayer.Range]
    let parts: [Part]
    let lights: [DioramaLight]
    let generationSeconds: Double

    var totalTriangles: Int { indices.count / 3 }
    var totalBytes: Int { vertices.count * MemoryLayout<BuildingRenderVertex>.stride + indices.count * MemoryLayout<UInt32>.stride }
}

/// Runs the whole pipeline for one tile off the main thread. Output stays in memory and goes straight
/// into Metal buffers through `DioramaRenderLayer`; there is no file format or model loader in between.
nonisolated enum DioramaTileGenerator {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DioramaTileArtifacts] = [:]

    private static func cacheKey(_ tile: DioramaTileID, config: DioramaConfig, reduced: Bool) -> String {
        "v\(config.generatorVersion)/\(tile.key)\(reduced ? "-lite" : "")"
    }

    static func cached(_ tile: DioramaTileID, config: DioramaConfig, reduced: Bool) -> DioramaTileArtifacts? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[cacheKey(tile, config: config, reduced: reduced)]
    }

    static func clearCache(for tile: DioramaTileID, config: DioramaConfig) {
        cacheLock.lock()
        for reduced in [false, true] { cache[cacheKey(tile, config: config, reduced: reduced)] = nil }
        cacheLock.unlock()
    }

    /// Generates (or returns the in-memory copy of) one tile. Call from any thread.
    static func generate(_ data: DioramaTileData, config: DioramaConfig, library: DioramaPropLibrary, reduced: Bool) throws -> DioramaTileArtifacts {
        if let cached = cached(data.tile, config: config, reduced: reduced) { return cached }
        let started = Date()

        let roadIndex = DioramaRoadIndex(roads: data.roads, pavementWidth: config.pavementWidth)
        let terrain = DioramaTerrain.load(rect: data.rect)
        var buildings = DioramaMesh()
        var windowGlow = DioramaMesh()
        var walls = DioramaMesh()
        var ground = DioramaMesh()
        var water = DioramaMesh()
        var roadsMesh = DioramaMesh()
        var vegetation = DioramaMesh()
        var props = DioramaMesh()
        var propGlow = DioramaMesh()
        var lights: [DioramaLight] = []

        let builder = DioramaBuildingGenerator(config: config, roads: roadIndex, terrain: terrain)
        var built: [DioramaBuilt] = []
        built.reserveCapacity(data.buildings.count)
        var porchLights: [DioramaLight] = []
        for feature in data.buildings {
            built.append(builder.build(feature, into: &buildings, glow: &windowGlow, lights: true, pointLights: &porchLights))
        }

        let wallGenerator = DioramaCompoundWallGenerator(config: config, roads: roadIndex, buildings: built, tileRect: data.rect, terrain: terrain)
        let compounds = wallGenerator.generate(into: &walls)

        DioramaGroundGenerator(config: config, data: data, roads: roadIndex, terrain: terrain).generate(compounds: compounds, into: &ground, water: &water)
        DioramaRoadGenerator(config: config, data: data, roads: roadIndex, terrain: terrain).generate(into: &roadsMesh)

        let placer = DioramaPropPlacer(config: config, data: data, roads: roadIndex, library: library, buildings: built, compounds: compounds, reduceDetail: reduced, terrain: terrain)
        placer.vegetation(into: &vegetation)
        placer.props(into: &props, glow: &propGlow, lights: &lights)
        // Street lamps take priority in the GPU light budget; porch lights fill what is left.
        for light in porchLights where lights.count < config.maxLights { lights.append(light) }

        // Order matters: opaque categories first, translucent halos (propGlow) last.
        let meshes: [(DioramaCategory, DioramaMesh)] = [
            (.ground, ground), (.water, water), (.roads, roadsMesh), (.buildings, buildings), (.walls, walls), (.vegetation, vegetation),
            (.props, props), (.windowGlow, windowGlow), (.propGlow, propGlow),
        ]

        var vertices: [BuildingRenderVertex] = []
        var indices: [UInt32] = []
        var ranges: [DioramaRenderLayer.Range] = []
        var parts: [DioramaTileArtifacts.Part] = []
        vertices.reserveCapacity(meshes.reduce(0) { $0 + $1.1.positions.count })
        indices.reserveCapacity(meshes.reduce(0) { $0 + $1.1.indices.count })

        for (category, mesh) in meshes where !mesh.isEmpty {
            let start = indices.count
            let base = vertices.count
            let count = mesh.positions.count
            // Shader paths (appearance.w): 0 lit surface, 1 water, 4 emissive, 5 halo sprite.
            let baseCode: Float = category.isEmissive ? 4 : (category == .water ? 1 : 0)
            for i in 0..<count {
                let p = mesh.positions[i]
                let n = mesh.normals[i]
                let cell = DioramaAtlas.lookup(mesh.uvs[i])
                let isHalo = category == .propGlow && cell?.swatch == .lampGlow && p.z > 0 && abs(n.z) > 1.5
                let appearance = SIMD4<Float>(0.85, 0, 0, isHalo ? 5 : baseCode)
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                    vertices.append(BuildingRenderVertex(position: SIMD4(0, 0, 0, 1), normal: SIMD4(0, 0, 1, 0), color: SIMD4(1, 0, 1, 1), appearance: appearance))
                    continue
                }
                let color = cell.map { DioramaAtlas.color($0.swatch, dark: $0.dark, config: config) } ?? SIMD4<Float>(1, 0, 1, 1)
                var normal = SIMD4<Float>(Float(n.x), Float(n.y), Float(n.z), 0)
                if !(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite) { normal = SIMD4(0, 0, 1, 0) }
                vertices.append(BuildingRenderVertex(
                    position: SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1),
                    normal: normal, color: color, appearance: appearance
                ))
            }
            let limit = UInt32(count)
            for raw in mesh.indices {
                // Never hand the GPU an index outside the buffer.
                indices.append(UInt32(base) + (raw < limit ? raw : 0))
            }
            let indexCount = indices.count - start
            ranges.append(.init(category: category, start: start, count: indexCount))
            parts.append(.init(category: category, triangles: indexCount / 3))
        }

        guard !indices.isEmpty else {
            throw NSError(domain: "Diorama", code: 1, userInfo: [NSLocalizedDescriptionKey: "tile produced no geometry"])
        }

        let artifacts = DioramaTileArtifacts(
            tile: data.tile, vertices: vertices, indices: indices, ranges: ranges, parts: parts, lights: lights,
            generationSeconds: Date().timeIntervalSince(started)
        )
        cacheLock.lock()
        cache[cacheKey(data.tile, config: config, reduced: reduced)] = artifacts
        cacheLock.unlock()
        return artifacts
    }
}
