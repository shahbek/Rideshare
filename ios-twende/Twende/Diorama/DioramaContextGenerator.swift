import Foundation
import simd

/// Deliberately coarse surrounding scenery, never stored under a full-detail archive/cache key.
/// Terrain stays on the shared heightfield; the savings come from paint resolution and omitted detail.
nonisolated enum DioramaContextGenerator {
    static func generate(_ data: DioramaTileData, config: DioramaConfig) throws -> DioramaTileArtifacts {
        try Task.checkCancellation()
        let started = Date()
        let terrain = (data.sourceTerrain ?? DioramaTerrain.load(rect: data.rect, config: config)).resolvingSurfaces(in: data)
        // Context tiles use the same exact vector roads as full tiles (no raster is ever sampled).
        guard let painter = DioramaGroundPainter(rect: data.rect, size: 512, config: config, hybridFinishes: config.vectorFinishes) else { throw CancellationError() }
        let roads = DioramaRoadIndex(roads: data.roads, pavementWidth: config.pavementWidth)
        var ground = DioramaMesh(), water = DioramaMesh(), buildings = DioramaMesh(), unusedGlow = DioramaMesh()
        DioramaGroundGenerator(config: config, data: data, roads: roads, terrain: terrain, painter: painter)
            .generateContext(into: &ground, water: &water)
        let kit = DioramaBuildingKit(config: config)
        let district = DioramaDistrict.of(data.tile)
        let classifier = DioramaBuildingGenerator(config: config, roads: roads, terrain: terrain, district: district)
        // Harbour: only the stylized-map-renderer skill's LOD2 shells (placed during packing below).
        let skill = DioramaRegion.of(data.tile) == .harbour ? DioramaSkillBuildings.load() : nil
        let harbour = DioramaRegion.of(data.tile) == .harbour
        for feature in data.buildings where !harbour {
            try Task.checkCancellation()
            if feature.id == DioramaSeaCliffSite.buildingID {
                _ = DioramaSeaCliffGenerator(data: data, terrain: terrain, config: config)
                    .build(feature, mesh: &buildings, glow: &unusedGlow, detailed: false)
                continue
            }
            if !feature.occupiedPieces.isEmpty {
                _ = DioramaClippedBuilding.build(feature, terrain: terrain, config: config, mesh: &buildings,
                    glow: &unusedGlow, lights: false, includesWindows: false)
                continue
            }
            let (kind, floors) = classifier.classify(feature)
            let height = max(2.8, feature.height ?? Double(floors) * config.floorHeight)
            var rng = DioramaRandom(seed: feature.id, salt: 2)
            _ = rng.range(-1...1)
            // Same draws as the full-detail generator so wall and roof colours match across the LOD handoff.
            let override = config.buildingOverrides[feature.id]
            let picked = rng.pick(district.wallColors(kind, config: config))
            let color = override?.wallColor ?? picked
            let towerRecipe: DarSkylineSite? = floors >= 4 && height >= 12 && override == nil && !feature.clipped.contains(true) && feature.area > 60
                ? classifier.architecturalRecipe(feature, kind: kind, floors: floors, height: height, wallColor: color) : nil
            if DioramaConfig.shaderFacades {
                // Stylised kit LOD2: the repaired outline as a plain prism under a flat deck or the
                // same pitched roof as full detail. No rounding, trims or props at this distance.
                prism(feature, kind: kind, floors: floors, height: height, color: color, override: override,
                      tower: towerRecipe, district: district, rng: &rng, terrain: terrain, config: config, into: &buildings)
                continue
            }
            if let recipe = towerRecipe {
                var generator = DarTowerGenerator(site: recipe)
                let base = terrain.buildingHeight(feature)
                terrain.foundation(feature.ring, top: base, swatch: color, into: &buildings)
                buildings.baseZ = base; buildings.recordsHeight = true
                let built = generator.buildContext(feature.ring, into: &buildings)
                buildings.baseZ = 0; buildings.recordsHeight = false
                if built { continue }
            }
            var pitched = kind == .villa
            if kind == .villa, rng.chance(1 - config.hipRoofShare) { pitched = false }
            if district == .masaki, kind == .apartments, floors <= 10, rng.chance(0.5) { pitched = true }
            if district == .city, kind == .villa, floors >= 2 { pitched = rng.chance(0.25) }
            let roofColor = override?.roofColor ?? rng.pick(district.pitchedRoofColors)
            let deck: DioramaSwatch = pitched && !(override?.flatRoof ?? false) && !feature.clipped.contains(true) ? roofColor : (override?.roofColor ?? .roofConcrete)
            let rounded = DioramaPolygon.rounded(feature.ring, flags: feature.clipped, radius: config.cornerRadius)
            let base = terrain.buildingHeight(feature)
            terrain.foundation(rounded.points, top: base, swatch: color, into: &buildings)
            buildings.baseZ = base
            buildings.recordsHeight = true
            buildings.extrude(rounded.points, z0: 0, z1: height, color)
            // Same roof-kit choice as full detail (same per-building roll), so silhouettes match at handoff.
            var roofRoll = DioramaRandom(seed: feature.id, salt: 0x52_4F_4F_46)
            let roll = roofRoll.unit()
            if !pitched, override == nil, kind != .villa, floors <= 2, roofRoll.chance(district == .masaki ? 0.25 : 0.6) { pitched = true }
            var kitRoofed = false
            if pitched, !(override?.flatRoof ?? false), !rounded.flags.contains(true) {
                let shape = DioramaRoofKit.shape(of: feature.ring)
                for form in DioramaRoofKit.candidates(for: shape, roll: roll, modern: district == .masaki && kind == .villa) {
                    if DioramaRoofKit.build(form, ring: rounded.points, flags: rounded.flags, z: height,
                                            pitch: config.roofPitchDegrees * Double.pi / 180, overhang: 0.4,
                                            maxRise: config.hipRoofMaxRise, color: roofColor, fascia: .trimWhite,
                                            gable: color, into: &buildings) {
                        kitRoofed = true
                        break
                    }
                }
            }
            // No stamped square windows at any LOD. A soft roof edge preserves the model language.
            if !kitRoofed, kit.roofEdge(rounded.points, flags: rounded.flags, z: height, bevel: config.roofBevel,
                            deck: deck, into: &buildings) == nil {
                buildings.polygon(rounded.points, z: height, deck)
            }
            buildings.baseZ = 0; buildings.recordsHeight = false
        }
        for pool in data.landuse where pool.kind == "pool" {
            guard let ring = pool.rings.first else { continue }
            let z = terrain.foundationHeight(ring) + 0.59
            for piece in DioramaGroundCutouts(polygons: Array(pool.rings.dropFirst())).subtract(from: ring) {
                ground.polygon(piece, z: z, .poolBlue, attribute: -1)
            }
        }
        try Task.checkCancellation()
        var vertices: [BuildingRenderVertex] = [], indices: [UInt32] = []
        var ranges: [DioramaRenderLayer.Range] = [], parts: [DioramaTileArtifacts.Part] = []
        var groups: [DioramaInstanceGroup] = [], instances: [DioramaInstanceData] = []
        for (category, mesh) in [(DioramaCategory.ground, ground), (.buildings, buildings), (.water, water)] {
            if let skill, category == .water {
                _ = skill.place(in: data, terrain: terrain, config: config, detail: .context, binSize: DioramaTileGenerator.binSize,
                                vertices: &vertices, indices: &indices, ranges: &ranges, groups: &groups,
                                allInstances: &instances, parts: &parts)
            }
            guard !mesh.indices.isEmpty else { continue }
            let base = UInt32(vertices.count), start = indices.count
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in mesh.positions.indices {
                let p = mesh.positions[i], n = mesh.normals[i]
                let position = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                low = simd_min(low, position); high = simd_max(high, position)
                let cell = DioramaAtlas.lookup(mesh.uvs[i])
                var color = cell.map { DioramaAtlas.color($0.swatch, dark: $0.dark, config: config) } ?? SIMD4<Float>(1, 1, 1, 1)
                if i < mesh.tints.count {
                    let tint = mesh.tints[i]
                    color = SIMD4(min(1, color.x * tint.x), min(1, color.y * tint.y), min(1, color.z * tint.z), color.w)
                }
                let texture: Float = cell?.swatch == .painted ? 9 : (cell?.swatch == .poolBlue ? 5 : 0)
                vertices.append(BuildingRenderVertex(position: SIMD4(position, 1), normal: SIMD4(Float(n.x), Float(n.y), Float(n.z), 0),
                    color: color, appearance: SIMD4(0.85, texture, mesh.attributes[i], category == .water ? 1 : 0)))
            }
            indices.append(contentsOf: mesh.indices.map { base + $0 })
            ranges.append(.init(category: category, start: start, count: mesh.indices.count, minimum: low, maximum: high))
            parts.append(.init(category: category, triangles: mesh.indices.count / 3, instances: 0))
        }
        return DioramaTileArtifacts(tile: data.tile, vertices: vertices, indices: indices, ranges: ranges, groups: [], allInstances: [],
            parts: parts, lights: [], lightGrid: DioramaLightGrid.build([], rect: data.rect, cells: 1, perCell: 1),
            waterHeight: terrain.waterLevel, shorelineReport: [], generationSeconds: Date().timeIntervalSince(started),
            groundImage: painter.image(), hasMapboxCoverage: data.hasMapboxCoverage)
    }

    private static func prism(_ feature: DioramaBuildingFeature, kind: DioramaBuildingKind, floors: Int, height: Double,
                              color: DioramaSwatch, override: DioramaBuildingOverride?, tower: DarSkylineSite?,
                              district: DioramaDistrict, rng: inout DioramaRandom, terrain: DioramaTerrain,
                              config: DioramaConfig, into buildings: inout DioramaMesh) {
        let isCut = feature.clipped.contains(true)
        let ring = isCut ? feature.ring : DioramaFennKit.repair(feature.ring)
        let flags = isCut ? feature.clipped : Array(repeating: false, count: ring.count)
        var pitched = kind == .villa
        if kind == .villa, rng.chance(1 - config.hipRoofShare) { pitched = false }
        if district == .masaki, kind == .apartments, floors <= 10, rng.chance(0.5) { pitched = true }
        if district == .city, kind == .villa, floors >= 2 { pitched = rng.chance(0.25) }
        var roofColor = override?.roofColor ?? rng.pick(district.pitchedRoofColors)
        var roofRoll = DioramaRandom(seed: feature.id, salt: 0x52_4F_4F_46)
        let roll = roofRoll.unit()
        if !pitched, override == nil, kind != .villa, floors <= 2, roofRoll.chance(district == .masaki ? 0.25 : 0.6) { pitched = true }
        var wall = color
        let savedTint = buildings.tint
        defer { buildings.tint = savedTint; buildings.baseZ = 0; buildings.recordsHeight = false }
        if let tower {
            let hip = tower.crown == "hip" && ["teal", "terracotta"].contains(tower.roof)
            pitched = hip
            roofColor = tower.roof == "teal" ? .roofTeal : .roofTerracotta
            let design = DarBuildingDesign(site: tower)
            wall = .whitewash
            buildings.tint = DioramaFennKit.tint(DarTowerGenerator.rgb(design.family == .glass ? tower.glass : tower.wall), over: .whitewash)
        }
        let base = terrain.buildingHeight(feature)
        if DioramaFennKit.needsSkirt(ring, terrain: terrain) {
            terrain.foundation(ring, top: base, swatch: color, into: &buildings)
        }
        buildings.baseZ = base
        buildings.recordsHeight = true
        buildings.extrude(ring, z0: -0.25, z1: height, wall, skip: flags)
        buildings.tint = savedTint
        var roofed = false
        if pitched, !(override?.flatRoof ?? false), !isCut {
            let shape = DioramaRoofKit.shape(of: ring)
            for form in DioramaRoofKit.candidates(for: shape, roll: roll, modern: district == .masaki && kind == .villa) {
                if DioramaRoofKit.build(form, ring: ring, flags: flags, z: height,
                                        pitch: config.roofPitchDegrees * Double.pi / 180, overhang: 0.4,
                                        maxRise: config.hipRoofMaxRise, color: roofColor, fascia: .trimWhite,
                                        gable: color, into: &buildings) {
                    roofed = true
                    break
                }
            }
        }
        if !roofed { buildings.polygon(ring, z: height, override?.roofColor ?? .roofConcrete) }
    }
}
