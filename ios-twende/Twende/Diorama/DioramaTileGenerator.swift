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
    let lightGrid: DioramaLightGrid
    let waterHeight: Double
    let shorelineReport: [String]
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
    static func generate(_ data: DioramaTileData, config: DioramaConfig, library: DioramaPropLibrary, reduced: Bool, sampledTerrain: DioramaTerrain? = nil) throws -> DioramaTileArtifacts {
        if sampledTerrain == nil, let cached = cached(data.tile, config: config, reduced: reduced) { return cached }
        let started = Date()

        let roadIndex = DioramaRoadIndex(roads: data.roads, pavementWidth: config.pavementWidth)
        var datum = sampledTerrain ?? DioramaTerrain.load(rect: data.rect, config: config)
        datum.midTideDatum = config.waterLevel
        let terrain = datum.resolvingSurfaces(in: data)
        let streetLayout = DioramaStreetLayout(data: data, config: config)
        var buildings = DioramaMesh()
        var windowGlow = DioramaMesh()
        var walls = DioramaMesh()
        var ground = DioramaMesh()
        var water = DioramaMesh()
        var roadsMesh = DioramaMesh()
        var vegetation = DioramaMesh()
        var props = DioramaMesh()
        var propGlow = DioramaMesh()
        var shorelineDebug = DioramaMesh()
        var lights: [DioramaLight] = []

        let builder = DioramaBuildingGenerator(config: config, roads: roadIndex, terrain: terrain)
        var built: [DioramaBuilt] = []
        built.reserveCapacity(data.buildings.count)
        var porchLights: [DioramaLight] = []
        for feature in data.buildings {
            if DioramaSlipwayPavilion.buildingIDs.contains(feature.id) {
                built.append(DioramaSlipwayPavilion(data: data, terrain: terrain).build(feature, mesh: &buildings))
            } else if DioramaHotelGenerator.ids.contains(feature.id) {
                built.append(DioramaHotelGenerator(terrain: terrain, courtyardCentre: data.landuse.first(where: { $0.id == DioramaHotelGrounds.courtyardID })?.rings.first.map { DioramaPolygon.centroid($0) }).build(feature, mesh: &buildings, glow: &windowGlow, lights: &porchLights))
            } else {
                built.append(builder.build(feature, into: &buildings, glow: &windowGlow, lights: true, pointLights: &porchLights))
            }
        }

        let wallGenerator = DioramaCompoundWallGenerator(config: config, roads: roadIndex, buildings: built, tileRect: data.rect, terrain: terrain, landuse: data.landuse)
        let compounds = wallGenerator.generate(into: &walls)

        DioramaGroundGenerator(config: config, data: data, roads: roadIndex, terrain: terrain, cutouts: DioramaGroundCutouts(data: data, pavementWidth: config.pavementWidth, streetPolygons: streetLayout.corridor.polygons, additionalMasks: data.hotelCourtyardOutline.isEmpty ? [] : [data.hotelCourtyardOutline])).generate(compounds: compounds, into: &ground, water: &water)
        DioramaRoadGenerator(config: config, data: data, roads: roadIndex, terrain: terrain, layout: streetLayout, compounds: compounds).generate(into: &roadsMesh)

        DioramaShorelineGenerator(config: config, data: data, terrain: terrain, library: library)
            .generate(ground: &ground, props: &props, vegetation: &vegetation, debug: &shorelineDebug)

        let amenities = DioramaAmenityGenerator(config: config, data: data, roads: roadIndex, library: library, buildings: built, terrain: terrain)
        amenities.generate(ground: &ground, props: &props, glow: &propGlow, lights: &lights)

        DioramaHotelGrounds(data: data, terrain: terrain, library: library, roads: roadIndex, streetPolygons: streetLayout.corridor.polygons)
            .generate(ground: &ground, props: &props, vegetation: &vegetation, glow: &propGlow, lights: &lights)

        let placer = DioramaPropPlacer(config: config, data: data, roads: roadIndex, library: library, buildings: built, compounds: compounds, reduceDetail: reduced, terrain: terrain)
        placer.vegetation(into: &vegetation)
        placer.props(into: &props, glow: &propGlow, lights: &lights)
        // Street lamps take priority in the GPU light budget; facade and porch lights fill what is left.
        for light in porchLights where lights.count < config.maxLights { lights.append(light) }
        let lightGrid = DioramaLightGrid.build(lights, rect: data.rect, cells: config.lightGridCells, perCell: config.lightsPerCell)

        // Order matters: opaque categories first, translucent halos (propGlow) last.
        let meshes: [(DioramaCategory, DioramaMesh)] = [
            (.ground, ground), (.roads, roadsMesh), (.buildings, buildings), (.walls, walls), (.vegetation, vegetation),
            (.props, props), (.water, water), (.windowGlow, windowGlow), (.propGlow, propGlow), (.shorelineDebug, shorelineDebug),
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
            let baseCode: Float = category == .shorelineDebug ? 6 : (category.isEmissive ? 4 : (category == .water ? 1 : 0))
            for i in 0..<count {
                let p = mesh.positions[i]
                let n = mesh.normals[i]
                let cell = DioramaAtlas.lookup(mesh.uvs[i])
                let isHalo = category == .propGlow && cell?.swatch == .lampGlow && p.z > 0 && abs(n.z) > 1.5
                // appearance.y picks a procedural surface texture: 1 grass, 2 sand, 3 asphalt, 4 paving,
                // 5 pool water. appearance.z carries the mesh's free attribute (shore distance on water).
                let texture: Float
                switch cell?.swatch {
                case .grass, .lawn, .pitchGreen: texture = 1
                case .earth, .wetSand, .seabed: texture = 2
                case .asphalt: texture = 3
                case .paving, .pavement, .concrete: texture = 4
                case .poolBlue: texture = 5
                case .glass, .glassPale: texture = 6
                case .tileClay: texture = 7
                case .muralBlue: texture = 8
                default: texture = 0
                }
                let attribute = i < mesh.attributes.count ? mesh.attributes[i] : 0
                let appearance = SIMD4<Float>(0.85, texture, attribute.isFinite ? attribute : 0, isHalo ? 5 : baseCode)
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
            // Sort triangles once into deterministic spatial batches. GPU buffers stay immutable;
            // camera changes only select ranges, rather than redrawing all 304 buildings.
            var cells: [Int: [UInt32]] = [:]
            for i in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
                guard a < UInt32(count), b < UInt32(count), c < UInt32(count) else { continue }
                let p = mesh.positions[Int(a)], q = mesh.positions[Int(b)], r = mesh.positions[Int(c)]
                func valid(_ v: DV3) -> Bool {
                    v.x.isFinite && v.y.isFinite && v.z.isFinite && abs(v.x) < 1_000_000 && abs(v.y) < 1_000_000 && abs(v.z) < 10_000
                }
                guard valid(p), valid(q), valid(r) else { continue }
                let key = Int(floor((p.x + q.x + r.x) / 240)) + Int(floor((p.y + q.y + r.y) / 240)) * 10000
                cells[key, default: []].append(contentsOf: [UInt32(base) + a, UInt32(base) + b, UInt32(base) + c])
            }
            for key in cells.keys.sorted() {
                guard let batch = cells[key] else { continue }
                var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for index in batch {
                    let p = vertices[Int(index)].position
                    low = simd_min(low, SIMD3(p.x, p.y, p.z)); high = simd_max(high, SIMD3(p.x, p.y, p.z))
                }
                // Halo shader expands billboards from their centres; preserve a generous guard band.
                let padding: Float = category == .propGlow ? 12 : 2
                ranges.append(.init(category: category, start: indices.count, count: batch.count,
                                    minimum: low - SIMD3(repeating: padding), maximum: high + SIMD3(repeating: padding)))
                indices.append(contentsOf: batch)
            }
            let indexCount = indices.count - start
            parts.append(.init(category: category, triangles: indexCount / 3))
        }

        guard !indices.isEmpty else {
            throw NSError(domain: "Diorama", code: 1, userInfo: [NSLocalizedDescriptionKey: "tile produced no geometry"])
        }

        let artifacts = DioramaTileArtifacts(
            tile: data.tile, vertices: vertices, indices: indices, ranges: ranges, parts: parts, lights: lights, lightGrid: lightGrid,
            waterHeight: terrain.waterLevel, shorelineReport: DioramaShoreline.report(data.shorelines), generationSeconds: Date().timeIntervalSince(started)
        )
        if sampledTerrain == nil {
            cacheLock.lock()
            cache[cacheKey(data.tile, config: config, reduced: reduced)] = artifacts
            cacheLock.unlock()
        }
        return artifacts
    }
}
