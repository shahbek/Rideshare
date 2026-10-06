import Foundation
import simd

/// One GPU instance: xyz translation + rotation about z, then xyz scale + bounding radius.
/// Layout mirrors `DioramaInstance` in the Metal source.
nonisolated struct DioramaInstanceData: Sendable {
    var placement: SIMD4<Float>
    var scale: SIMD4<Float>
    var tint: SIMD4<Float> = SIMD4(repeating: 1)
    var grading: SIMD4<Float> = .zero

    static let identity = DioramaInstanceData(placement: SIMD4(0, 0, 0, 0), scale: SIMD4(1, 1, 1, 0))

    var centre: SIMD3<Float> { SIMD3(placement.x, placement.y, placement.z) }
    var radius: Float { scale.w }
}

/// All placements of one prototype inside one category, with the prototype's full and light index
/// ranges in the shared index buffer and the world bounds of every placement.
nonisolated struct DioramaInstanceGroup: Sendable {
    let category: DioramaCategory
    let fullStart: Int
    let fullCount: Int
    let lightStart: Int
    let lightCount: Int
    /// The prototype contains thin open surfaces and is drawn without back-face culling.
    let doubleSided: Bool
    let instances: [DioramaInstanceData]
    /// Offset of this group's first instance in the artifacts' flat instance list.
    let firstInstance: Int
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
}

/// Everything the renderer needs for one generated tile: one interleaved vertex buffer, one index
/// buffer, the index range each category occupies so categories can be toggled per frame, and the
/// instanced prototypes with their placements.
nonisolated struct DioramaTileArtifacts: Sendable {
    nonisolated struct Part: Sendable {
        let category: DioramaCategory
        let triangles: Int
        let instances: Int
    }

    let tile: DioramaTileID
    let vertices: [BuildingRenderVertex]
    let indices: [UInt32]
    let ranges: [DioramaRenderLayer.Range]
    let groups: [DioramaInstanceGroup]
    /// Every instance of every group, contiguous in group order (the shadow pass draws them all).
    let allInstances: [DioramaInstanceData]
    let parts: [Part]
    let lights: [DioramaLight]
    let lightGrid: DioramaLightGrid
    let waterHeight: Double
    let shorelineReport: [String]
    let generationSeconds: Double
    /// Top-down painted ground (roads, lawns, paving, sand) sampled by the terrain skin.
    let groundImage: DioramaGroundImage?
    var buildingLabels: [DioramaBuildingLabel] = []
    var hasMapboxCoverage: Bool = false
    var optimizationReport: [String] = []
    var stageTimings: [String] = []

    /// Unique triangles in the buffers (each prototype counted once, not per placement).
    var totalTriangles: Int { indices.count / 3 }
    var totalInstances: Int { allInstances.count }
    /// Triangles the GPU would process with every placement drawn at full detail (close-up worst case).
    var drawnTriangles: Int {
        ranges.reduce(0) { $0 + $1.count / 3 } + groups.reduce(0) { $0 + $1.instances.count * ($1.fullCount / 3) }
    }
    /// Triangles with every placement at light detail: the whole-tile view, where everything is
    /// beyond the LOD distance. The typical view lies between this and `drawnTriangles`.
    var lightDrawnTriangles: Int {
        ranges.reduce(0) { $0 + $1.count / 3 } + groups.reduce(0) { $0 + $1.instances.count * (($1.lightCount > 0 ? $1.lightCount : $1.fullCount) / 3) }
    }
    var totalBytes: Int {
        vertices.count * MemoryLayout<BuildingRenderVertex>.stride + indices.count * MemoryLayout<UInt32>.stride
            + allInstances.count * MemoryLayout<DioramaInstanceData>.stride + (groundImage?.rgba.count ?? 0)
    }
}

/// Runs the whole pipeline for one tile off the main thread. Output stays in memory and goes straight
/// into Metal buffers through `DioramaRenderLayer`; there is no file format or model loader in between.
nonisolated enum DioramaTileGenerator {
    /// Side of the spatial batches triangles and instances are sorted into for frustum culling.
    static let binSize: Double = 60
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DioramaTileArtifacts] = [:]

    private static func cacheKey(_ tile: DioramaTileID, config: DioramaConfig, reduced: Bool) -> String {
        "v\(config.generatorVersion)/\(tile.key)\(reduced ? "-lite" : "")\(config.instancesArchitecture ? "-instanced" : "-baked")"
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
        try Task.checkCancellation()
        let audit = DioramaGenerationAudit.current
        // Audits are always cold, and must never populate or reuse the interactive app's cache.
        if audit == nil, let cached = cached(data.tile, config: config, reduced: reduced) { return cached }
        let started = Date()
        var checkpoint = DioramaGenerationAudit.now
        var stageTimings: [String] = []
        func timing(_ stage: String) throws {
            try Task.checkCancellation()
            let now = DioramaGenerationAudit.now
            let seconds = now - checkpoint
            audit?.stage(stage, seconds: seconds)
            stageTimings.append("\(stage): \(String(format: "%.3f", seconds))s")
            print("[Diorama timing] \(stage): \(String(format: "%.3f", seconds))s")
            checkpoint = now
        }

        let roadIndex = DioramaRoadIndex(roads: data.roads, pavementWidth: config.pavementWidth)
        guard data.tile == DioramaMasakiSource.slipway || data.sourceTerrain != nil else {
            throw NSError(domain: "Diorama", code: 3, userInfo: [NSLocalizedDescriptionKey: "This tile needs its own elevation source"])
        }
        let terrain = (data.sourceTerrain ?? DioramaTerrain.load(rect: data.rect, config: config)).resolvingSurfaces(in: data)
        let streetLayout = DioramaStreetLayout(data: data, config: config)
        guard let painter = DioramaGroundPainter(rect: data.rect, size: reduced ? config.reducedGroundImageSize : config.groundImageSize, config: config) else {
            throw NSError(domain: "Diorama", code: 2, userInfo: [NSLocalizedDescriptionKey: "ground image could not be created"])
        }
        try timing("terrain + street layout + painter")
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
        let registry = DioramaPrimitiveRegistry(firstID: library.prototypes.count)
        if config.instancesArchitecture {
            buildings.primitiveRegistry = registry
            windowGlow.primitiveRegistry = registry
            walls.primitiveRegistry = registry
            ground.primitiveRegistry = registry
            roadsMesh.primitiveRegistry = registry
            props.primitiveRegistry = registry
            propGlow.primitiveRegistry = registry
        }

        let builder = DioramaBuildingGenerator(config: config, roads: roadIndex, terrain: terrain)
        var built: [DioramaBuilt] = []
        built.reserveCapacity(data.buildings.count)
        var porchLights: [DioramaLight] = []
        let mosqueIDs = DioramaMosqueGenerator.buildingIDs(in: data)
        for feature in data.buildings {
            if feature.id == DioramaSeaCliffSite.buildingID {
                built.append(DioramaSeaCliffGenerator(data: data, terrain: terrain, config: config).build(feature, mesh: &buildings, glow: &windowGlow))
            } else if !feature.occupiedPieces.isEmpty {
                built.append(DioramaClippedBuilding.build(feature, terrain: terrain, config: config, mesh: &buildings, glow: &windowGlow, lights: true))
            } else if mosqueIDs.contains(feature.id) {
                built.append(DioramaMosqueGenerator(config: config, terrain: terrain).build(feature, into: &buildings))
            } else if DioramaSlipwayPavilion.buildingIDs.contains(feature.id) {
                built.append(DioramaSlipwayPavilion(data: data, terrain: terrain).build(feature, mesh: &buildings))
            } else if DioramaHotelGenerator.ids.contains(feature.id) {
                built.append(DioramaHotelGenerator(terrain: terrain, courtyardCentre: data.landuse.first(where: { $0.id == DioramaHotelGrounds.courtyardID })?.rings.first.map { DioramaPolygon.centroid($0) }).build(feature, mesh: &buildings, glow: &windowGlow, lights: &porchLights))
            } else {
                built.append(builder.build(feature, into: &buildings, glow: &windowGlow, lights: true, pointLights: &porchLights))
            }
        }

        try timing("buildings")
        let wallGenerator = DioramaCompoundWallGenerator(config: config, roads: roadIndex, buildings: built, tileRect: data.rect, terrain: terrain, landuse: data.landuse)
        let compounds = wallGenerator.generate(into: &walls)
        try timing("compounds")

        // Paint order matters: base grass and lawns, then footways and hotel paving, then roads over
        // everything, then the sea floor so coastal paint stops at the mapped water edge.
        let groundGenerator = DioramaGroundGenerator(config: config, data: data, roads: roadIndex, terrain: terrain, painter: painter)
        groundGenerator.generate(compounds: compounds, into: &ground, water: &water)
        try timing("connected ground + water + reef")

        DioramaShorelineGenerator(config: config, data: data, terrain: terrain, library: library)
            .generate(ground: &ground, props: &props, vegetation: &vegetation, debug: &shorelineDebug)

        try timing("shore structures")
        let amenities = DioramaAmenityGenerator(config: config, data: data, roads: roadIndex, library: library, buildings: built, terrain: terrain, painter: painter)
        amenities.generate(ground: &ground, props: &props, glow: &propGlow, lights: &lights)

        try timing("amenities")
        if data.tile == DioramaMasakiSource.slipway {
            DioramaHotelGrounds(data: data, terrain: terrain, library: library, roads: roadIndex, streetPolygons: streetLayout.corridor.polygons, painter: painter)
                .generate(ground: &ground, props: &props, vegetation: &vegetation, glow: &propGlow, lights: &lights)
        }

        if data.tile == DioramaSeaCliffSite.tile {
            DioramaSeaCliffGrounds(data: data, terrain: terrain, config: config, library: library, painter: painter)
                .generate(ground: &ground, props: &props, vegetation: &vegetation, glow: &propGlow, lights: &lights)
        }
        try timing("hotel grounds")
        DioramaRoadGenerator(config: config, data: data, roads: roadIndex, terrain: terrain, layout: streetLayout, compounds: compounds, painter: painter).generate(into: &roadsMesh)
        groundGenerator.paintWater()
        try timing("roads + coastal paint")

        let placer = DioramaPropPlacer(config: config, data: data, roads: roadIndex, library: library, buildings: built, compounds: compounds, reduceDetail: reduced, terrain: terrain)
        placer.vegetation(into: &vegetation)
        placer.props(into: &props, glow: &propGlow, lights: &lights)
        // Street lamps take priority in the GPU light budget; facade and porch lights fill what is left.
        for light in porchLights where lights.count < config.maxLights { lights.append(light) }
        let lightGrid = DioramaLightGrid.build(lights, rect: data.rect, cells: config.lightGridCells, perCell: config.lightsPerCell)

        try timing("props + light grid")
        let uniquePrimitives = Dictionary(uniqueKeysWithValues: registry.entries.filter { $0.placements == 1 }.map { ($0.prototype.id, $0.prototype) })
        buildings.bakeUniquePrimitives(uniquePrimitives)
        windowGlow.bakeUniquePrimitives(uniquePrimitives)
        walls.bakeUniquePrimitives(uniquePrimitives)
        ground.bakeUniquePrimitives(uniquePrimitives)
        roadsMesh.bakeUniquePrimitives(uniquePrimitives)
        props.bakeUniquePrimitives(uniquePrimitives)
        propGlow.bakeUniquePrimitives(uniquePrimitives)
        try timing("unique primitive consolidation")
        // Order matters: opaque categories first, translucent halos (propGlow) last.
        let meshes: [(DioramaCategory, DioramaMesh)] = [
            (.ground, ground), (.roads, roadsMesh), (.buildings, buildings), (.walls, walls), (.vegetation, vegetation),
            (.props, props), (.water, water), (.windowGlow, windowGlow), (.propGlow, propGlow), (.shorelineDebug, shorelineDebug),
        ]

        let prototypes = library.prototypes + registry.prototypes
        var vertices: [BuildingRenderVertex] = []
        var indices: [UInt32] = []
        var ranges: [DioramaRenderLayer.Range] = []
        var parts: [DioramaTileArtifacts.Part] = []
        var groups: [DioramaInstanceGroup] = []
        var allInstances: [DioramaInstanceData] = []
        vertices.reserveCapacity(meshes.reduce(0) { $0 + $1.1.positions.count })
        indices.reserveCapacity(meshes.reduce(0) { $0 + $1.1.indices.count })

        /// Appends a mesh's vertices with the shader codes of `category`; returns the first vertex index.
        func bake(_ mesh: DioramaMesh, category: DioramaCategory) -> Int {
            let base = vertices.count
            // Shader paths (appearance.w): 0 lit surface, 1 water, 4 emissive, 5 halo sprite.
            let baseCode: Float = category == .shorelineDebug ? 6 : (category.isEmissive ? 4 : (category == .water ? 1 : 0))
            for i in 0..<mesh.positions.count {
                let p = mesh.positions[i]
                let n = mesh.normals[i]
                let cell = DioramaAtlas.lookup(mesh.uvs[i])
                let isHalo = category == .propGlow && cell?.swatch == .lampGlow && p.z > 0 && abs(n.z) > 1.5
                // appearance.y picks a procedural surface texture: 1 grass, 2 sand, 3 asphalt, 4 paving,
                // 5 pool water, 9 painted ground image. appearance.z carries the mesh's free attribute
                // (shore distance on water).
                let texture: Float
                switch cell?.swatch {
                case .painted: texture = 9
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
                var color = cell.map { DioramaAtlas.color($0.swatch, dark: $0.dark, config: config) } ?? SIMD4<Float>(1, 0, 1, 1)
                if i < mesh.tints.count {
                    let t = mesh.tints[i]
                    color = SIMD4(min(color.x * t.x, 1), min(color.y * t.y, 1), min(color.z * t.z, 1), color.w)
                }
                var normal = SIMD4<Float>(Float(n.x), Float(n.y), Float(n.z), 0)
                if !(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite) { normal = SIMD4(0, 0, 1, 0) }
                vertices.append(BuildingRenderVertex(
                    position: SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1),
                    normal: normal, color: color, appearance: appearance
                ))
            }
            return base
        }

        /// Prototype meshes baked once per shader code, keyed by prototype id and emissiveness.
        var bakedPrototypes: [Int: (fullStart: Int, fullCount: Int, lightStart: Int, lightCount: Int)] = [:]
        func prototypeRanges(_ prototype: DioramaPrototype, category: DioramaCategory) -> (Int, Int, Int, Int) {
            let key = prototype.id * 2 + (category.isEmissive ? 1 : 0)
            if let found = bakedPrototypes[key] { return found }
            func lay(_ mesh: DioramaMesh) -> (Int, Int) {
                let base = bake(mesh, category: category)
                let start = indices.count
                indices.append(contentsOf: mesh.indices.map { UInt32(base) + $0 })
                return (start, indices.count - start)
            }
            let full = lay(prototype.full)
            let light = prototype.hasLightVariant ? lay(prototype.light) : full
            let result = (full.0, full.1, light.0, light.1)
            bakedPrototypes[key] = result
            return result
        }

        for (category, mesh) in meshes where !mesh.isEmpty {
            let start = indices.count
            let base = bake(mesh, category: category)
            let count = mesh.positions.count
            // Sort triangles once into deterministic 60 m spatial batches, double-sided ones apart.
            // GPU buffers stay immutable; camera changes only select ranges, so off-screen parts of
            // the tile are really skipped.
            var cells: [Int: [UInt32]] = [:]
            let flags = mesh.doubleSidedTriangles
            for i in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
                guard a < UInt32(count), b < UInt32(count), c < UInt32(count) else { continue }
                let p = mesh.positions[Int(a)], q = mesh.positions[Int(b)], r = mesh.positions[Int(c)]
                func valid(_ v: DV3) -> Bool {
                    v.x.isFinite && v.y.isFinite && v.z.isFinite && abs(v.x) < 1_000_000 && abs(v.y) < 1_000_000 && abs(v.z) < 10_000
                }
                guard valid(p), valid(q), valid(r) else { continue }
                let triangle = i / 3
                let twoSided = triangle < flags.count && flags[triangle]
                let key = (Int(floor((p.x + q.x + r.x) / (3 * Self.binSize))) + Int(floor((p.y + q.y + r.y) / (3 * Self.binSize))) * 10000) * 2 + (twoSided ? 1 : 0)
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
                                    minimum: low - SIMD3(repeating: padding), maximum: high + SIMD3(repeating: padding),
                                    doubleSided: key & 1 == 1 || category == .propGlow || category == .water))
                indices.append(contentsOf: batch)
            }
            let indexCount = indices.count - start

            // Instances: one group per prototype, placements binned like triangles so distant groups cull.
            var placements: [Int: [Int: [DioramaInstanceData]]] = [:]
            for placement in mesh.instances {
                guard placement.prototype >= 0, placement.prototype < prototypes.count else { continue }
                let t = placement.transform
                guard t.translation.x.isFinite, t.translation.y.isFinite, t.translation.z.isFinite else { continue }
                let prototype = prototypes[placement.prototype]
                let radius = Float(prototype.radius * max(t.scale.x, max(t.scale.y, t.scale.z)))
                let data = DioramaInstanceData(
                    placement: SIMD4(Float(t.translation.x), Float(t.translation.y), Float(t.translation.z), Float(t.rotation)),
                    scale: SIMD4(Float(t.scale.x), Float(t.scale.y), Float(t.scale.z), radius),
                    tint: SIMD4(placement.tint, 1), grading: placement.grading)
                let bin = Int(floor(t.translation.x / Self.binSize)) + Int(floor(t.translation.y / Self.binSize)) * 10000
                placements[placement.prototype, default: [:]][bin, default: []].append(data)
            }
            var instanceCount = 0
            for prototypeID in placements.keys.sorted() {
                let prototype = prototypes[prototypeID]
                let (fullStart, fullCount, lightStart, lightCount) = prototypeRanges(prototype, category: category)
                guard let bins = placements[prototypeID] else { continue }
                let architectural = prototypeID >= library.prototypes.count
                var prototypeLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var prototypeHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                if architectural {
                    for p in prototype.full.positions {
                        let v = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                        prototypeLow = simd_min(prototypeLow, v)
                        prototypeHigh = simd_max(prototypeHigh, v)
                    }
                }
                for bin in bins.keys.sorted() {
                    guard let list = bins[bin], !list.isEmpty else { continue }
                    var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                    var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                    for item in list {
                        if architectural, prototypeLow.x.isFinite, prototypeLow.x <= prototypeHigh.x {
                            // A ring band may span a whole building. A radius about its first corner
                            // grossly inflates shadow/culling bounds; transform its actual box instead.
                            let c = cos(item.placement.w), s = sin(item.placement.w)
                            for x in [prototypeLow.x, prototypeHigh.x] {
                                for y in [prototypeLow.y, prototypeHigh.y] {
                                    for z in [prototypeLow.z, prototypeHigh.z] {
                                        let sx = x * item.scale.x, sy = y * item.scale.y
                                        let p = SIMD3(sx * c - sy * s, sx * s + sy * c, z * item.scale.z) + item.centre
                                        low = simd_min(low, p - SIMD3(repeating: 2))
                                        high = simd_max(high, p + SIMD3(repeating: 2))
                                    }
                                }
                            }
                        } else {
                            low = simd_min(low, item.centre - SIMD3(repeating: item.radius))
                            high = simd_max(high, item.centre + SIMD3(repeating: item.radius))
                        }
                    }
                    groups.append(DioramaInstanceGroup(category: category, fullStart: fullStart, fullCount: fullCount,
                                                       lightStart: lightStart, lightCount: lightCount,
                                                       doubleSided: prototype.full.hasDoubleSidedTriangles, instances: list,
                                                       firstInstance: allInstances.count, minimum: low, maximum: high))
                    allInstances.append(contentsOf: list)
                    instanceCount += list.count
                }
            }
            parts.append(.init(category: category, triangles: indexCount / 3, instances: instanceCount))
        }

        guard !indices.isEmpty else {
            throw NSError(domain: "Diorama", code: 1, userInfo: [NSLocalizedDescriptionKey: "tile produced no geometry"])
        }

        let image = painter.image()
        try timing("packing + image export")
        for (category, mesh) in meshes {
            audit?.record(mesh, category: category)
            print("[Diorama geometry] \(category): \(mesh.triangleCount) baked triangles, \(mesh.instances.count) instances")
        }
        let artifacts = DioramaTileArtifacts(
            tile: data.tile, vertices: vertices, indices: indices, ranges: ranges, groups: groups, allInstances: allInstances,
            parts: parts, lights: lights, lightGrid: lightGrid,
            waterHeight: terrain.waterLevel, shorelineReport: DioramaShoreline.report(data.shorelines), generationSeconds: Date().timeIntervalSince(started),
            groundImage: image,
            buildingLabels: DioramaBuildingLabel.makeAll(built, data: data, terrain: terrain, config: config),
            hasMapboxCoverage: data.hasMapboxCoverage,
            optimizationReport: registry.report, stageTimings: stageTimings
        )
        try Task.checkCancellation()
        if audit == nil {
            cacheLock.lock()
            // A whole-city dictionary retained hundreds of MB per visited tile indefinitely.
            // Disk holds revisits; keep only the most recent CPU artifact in memory.
            cache.removeAll(keepingCapacity: true)
            cache[cacheKey(data.tile, config: config, reduced: reduced)] = artifacts
            cacheLock.unlock()
        }
        return artifacts
    }
}
