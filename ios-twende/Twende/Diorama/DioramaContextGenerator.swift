import Foundation
import simd

/// Deliberately coarse surrounding scenery, never stored under a full-detail archive/cache key.
/// Terrain stays on the shared heightfield; the savings come from paint resolution and omitted detail.
nonisolated enum DioramaContextGenerator {
    static func generate(_ data: DioramaTileData, config: DioramaConfig) throws -> DioramaTileArtifacts {
        try Task.checkCancellation()
        let started = Date()
        let terrain = (data.sourceTerrain ?? DioramaTerrain.load(rect: data.rect, config: config)).resolvingSurfaces(in: data)
        guard let painter = DioramaGroundPainter(rect: data.rect, size: 512, config: config) else { throw CancellationError() }
        let roads = DioramaRoadIndex(roads: data.roads, pavementWidth: config.pavementWidth)
        var ground = DioramaMesh(), water = DioramaMesh(), buildings = DioramaMesh(), unusedGlow = DioramaMesh()
        DioramaGroundGenerator(config: config, data: data, roads: roads, terrain: terrain, painter: painter)
            .generateContext(into: &ground, water: &water)
        let kit = DioramaBuildingKit(config: config)
        let classifier = DioramaBuildingGenerator(config: config, roads: roads, terrain: terrain)
        for feature in data.buildings {
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
            let colors = kind == .villa ? config.wallColors : (kind == .apartments ? config.apartmentWallColors : config.commercialWallColors)
            let color = config.buildingOverrides[feature.id]?.wallColor ?? rng.pick(colors)
            let rounded = DioramaPolygon.rounded(feature.ring, flags: feature.clipped, radius: config.cornerRadius, segments: 6)
            let base = terrain.buildingHeight(feature)
            terrain.foundation(rounded.points, top: base, swatch: color, into: &buildings)
            buildings.baseZ = base
            buildings.recordsHeight = true
            buildings.extrude(rounded.points, z0: 0, z1: height, color)
            // No stamped square windows at any LOD. A soft roof edge preserves the model language.
            if kit.roofEdge(rounded.points, flags: rounded.flags, z: height, bevel: config.roofBevel,
                            deck: .roofConcrete, into: &buildings) == nil {
                buildings.polygon(rounded.points, z: height, .roofConcrete)
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
        for (category, mesh) in [(DioramaCategory.ground, ground), (.buildings, buildings), (.water, water)] where !mesh.indices.isEmpty {
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
}
