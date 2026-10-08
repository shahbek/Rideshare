import CryptoKit
import Foundation
import simd

/// Serial, cancellable visual migration. Only local sources and small sidecars are used.
actor DioramaVisualUpgrade {
    static let shared = DioramaVisualUpgrade()
    private let revision = 3
    private var legacyLibrary: DioramaPropLibrary?
    private var currentLibrary: DioramaPropLibrary?

    func apply(_ base: DioramaTileArtifacts, directory: URL, context: Bool) async -> DioramaTileArtifacts {
        let started = Date()
        guard !Task.isCancelled,
              let manifest = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return base }
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        let key = "visual-r\(revision)-\(directory.lastPathComponent)-\(digest.prefix(16))"
        let destination = directory.deletingLastPathComponent().appendingPathComponent(key, isDirectory: true)
        let patch: DioramaVisualPatch
        if let cached = readPatch(destination, key: key, digest: digest, base: base) {
            patch = cached
        } else {
            guard let built = await build(base, digest: digest, context: context), !Task.isCancelled else { return base }
            patch = built.patch
            if built.sourcesReady {
                let staging = destination.deletingLastPathComponent().appendingPathComponent("visual-stage-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                do {
                    _ = try DioramaTileArchive.write(patch.additions, key: key, to: staging)
                    let bytes = try JSONEncoder().encode(patch.metadata)
                    try bytes.write(to: staging.appendingPathComponent("patch.json"), options: .atomic)
                    try Data(SHA256.hash(data: bytes)).write(to: staging.appendingPathComponent("patch.sha"), options: .atomic)
                    guard readPatch(staging, key: key, digest: digest, base: base) != nil else { return base }
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: staging, to: destination)
                } catch {
                    if Task.isCancelled { return base }
                    print("[Diorama visual] Sidecar not saved; original package retained")
                }
            }
        }
        guard !Task.isCancelled else { return base }
        var result = patch.applying(to: base)
        result.stageTimings.append("local visual patch: \(String(format: "%.3f", Date().timeIntervalSince(started)))s · no network")
        print("[Diorama visual] \(base.tile.key): \(patch.metadata.trees.count) tree prototypes, \(patch.metadata.roofCount) roofs updated, \(patch.metadata.skippedRoofs) roof candidates retained")
        return result
    }

    private func readPatch(_ directory: URL, key: String, digest: String, base: DioramaTileArtifacts) -> DioramaVisualPatch? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("patch.json")), bytes.count < 4_194_304,
              let checksum = try? Data(contentsOf: directory.appendingPathComponent("patch.sha")),
              checksum == Data(SHA256.hash(data: bytes)),
              let metadata = try? JSONDecoder().decode(DioramaVisualPatch.Metadata.self, from: bytes),
              metadata.revision == revision, metadata.baseDigest == digest,
              Set(metadata.trees.map(\.originalStart)).count == metadata.trees.count,
              let additions = try? DioramaTileArchive.read(from: directory, key: key), additions.totalBytes <= 16 * 1_048_576,
              additions.tile == base.tile, additions.groups.isEmpty, additions.allInstances.isEmpty,
              additions.ranges.allSatisfy({ $0.category == .buildings }),
              metadata.trees.allSatisfy({ tree in
                  base.groups.contains { $0.category == .vegetation && $0.fullStart == tree.originalStart }
                      && tree.fullStart >= 0 && tree.fullStart <= additions.indices.count && tree.fullStart % 3 == 0
                      && tree.fullCount > 0 && tree.fullCount % 3 == 0 && tree.fullCount <= additions.indices.count - tree.fullStart
                      && tree.lightStart >= 0 && tree.lightStart <= additions.indices.count && tree.lightStart % 3 == 0
                      && tree.lightCount > 0 && tree.lightCount % 3 == 0 && tree.lightCount <= additions.indices.count - tree.lightStart
                      && tree.radius.isFinite && tree.radius > 0 && tree.radius < 30
              }), metadata.removedTriangles.allSatisfy({ index in
                  index >= 0 && index <= base.indices.count && 3 <= base.indices.count - index && base.ranges.contains {
                      $0.category == .buildings && index >= $0.start && index <= $0.start + $0.count
                          && 3 <= $0.start + $0.count - index && (index - $0.start) % 3 == 0
                  }
              }) else { return nil }
        return DioramaVisualPatch(additions: additions, metadata: metadata)
    }

    private func build(_ base: DioramaTileArtifacts, digest: String, context: Bool) async -> (patch: DioramaVisualPatch, sourcesReady: Bool)? {
        let config = DioramaConfig.slipway
        if legacyLibrary == nil { legacyLibrary = DioramaPropLibrary(config: config, structuredTrees: false) }
        if currentLibrary == nil { currentLibrary = DioramaPropLibrary(config: config) }
        guard let legacy = legacyLibrary, let current = currentLibrary else { return nil }
        var vertices: [BuildingRenderVertex] = []
        var indices: [UInt32] = []
        var ranges: [DioramaRenderLayer.Range] = []
        var trees: [DioramaVisualPatch.Tree] = []
        var seen: Set<Int> = []
        let oldTrees = legacy.trees + [legacy.cypress]
        let newTrees = current.trees + [current.cypress]
        func append(_ mesh: DioramaMesh, category: DioramaCategory) -> (Int, Int) {
            let offset = UInt32(vertices.count), start = indices.count
            vertices.append(contentsOf: DioramaMeshPacking.vertices(mesh, category: category, config: config))
            indices.append(contentsOf: mesh.indices.map { $0 + offset })
            return (start, indices.count - start)
        }
        for group in base.groups where group.category == .vegetation && seen.insert(group.fullStart).inserted {
            if Task.isCancelled { return nil }
            guard let match = oldTrees.firstIndex(where: { matches($0.full, group: group, base: base) }) else { continue }
            let tree = newTrees[match]
            guard tree.full.indices.count <= oldTrees[match].full.indices.count,
                  tree.light.indices.count <= oldTrees[match].light.indices.count else { continue }
            let full = append(tree.full, category: .vegetation), light = append(tree.light, category: .vegetation)
            trees.append(.init(originalStart: group.fullStart, fullStart: full.0, fullCount: full.1,
                               lightStart: light.0, lightCount: light.1, radius: Float(tree.radius)))
        }

        let roofIndexStart = indices.count
        var removed: Set<Int> = []
        var roofCount = 0, skippedRoofs = 0
        // offline=true is unconditional: even a missing source must never turn into a download.
        let data = context ? nil : await DioramaMasakiSource.load(tile: base.tile, config: config, token: "", offline: true)
        if let data {
            let terrain = (data.sourceTerrain ?? DioramaTerrain.load(rect: data.rect, config: config)).resolvingSurfaces(in: data)
            let builder = DioramaBuildingGenerator(config: config,
                roads: DioramaRoadIndex(roads: data.roads, pavementWidth: config.pavementWidth), terrain: terrain)
            let mosqueIDs = DioramaMosqueGenerator.buildingIDs(in: data)
            var lookup: [TriangleKey: [Int]] = [:]
            for range in base.ranges where range.category == .buildings {
                for index in stride(from: range.start, to: range.start + range.count, by: 3) {
                    if index % 3072 == 0, Task.isCancelled { return nil }
                    let triangle = [base.vertices[Int(base.indices[index])], base.vertices[Int(base.indices[index + 1])], base.vertices[Int(base.indices[index + 2])]]
                    // Only height-recording generic architecture is eligible, not authored landmarks.
                    guard triangle.allSatisfy({ $0.appearance.z > 100 && $0.appearance.w < 0.5 }) else { continue }
                    if let key = TriangleKey(triangle) { lookup[key, default: []].append(index) }
                }
            }
            for feature in data.buildings {
                if Task.isCancelled { return nil }
                guard feature.occupiedPieces.isEmpty, !feature.clipped.contains(true), feature.id != 165_397_124,
                      !DioramaHotelGenerator.ids.contains(feature.id), !DioramaSlipwayPavilion.buildingIDs.contains(feature.id),
                      feature.id != DioramaSeaCliffSite.buildingID, !mosqueIDs.contains(feature.id),
                      builder.classify(feature).0 == .villa, config.buildingOverrides[feature.id] == nil else { continue }
                var rng = DioramaRandom(seed: feature.id, salt: 2)
                let shift = Float(rng.range(-1...1)) * config.hueShift
                _ = rng.pick(config.wallColors)
                guard !rng.chance(1 - config.hipRoofShare) else { continue }
                let color: DioramaSwatch = rng.chance(config.terracottaRoofShare) ? .roofTerracotta : rng.pick(config.metalRoofColors)
                let floors = builder.classify(feature).1
                let height = max(feature.height ?? Double(floors) * config.floorHeight, 2.8)
                let rounded = DioramaPolygon.rounded(feature.ring, flags: feature.clipped, radius: config.cornerRadius, segments: 6)
                var original = DioramaMesh()
                original.baseZ = terrain.buildingHeight(feature); original.recordsHeight = true
                original.tint = SIMD3(1 + shift, 1 + shift * 0.35, 1 - shift)
                guard DioramaLegacyRoofBuilder.hip(rounded.points, flags: rounded.flags, z: height,
                    pitch: config.roofPitchDegrees * .pi / 180, overhang: config.roofOverhang, maxRise: config.hipRoofMaxRise,
                    color: color, fascia: .trimWhite, into: &original) else { continue }
                let packed = DioramaMeshPacking.vertices(original, category: .buildings, config: config, legacyMaterials: true)
                var required: [TriangleKey: Int] = [:]
                for index in stride(from: 0, to: original.indices.count, by: 3) {
                    let triangle = (0..<3).map { packed[Int(original.indices[index + $0])] }
                    if let key = TriangleKey(triangle) { required[key, default: 0] += 1 }
                }
                guard required.values.reduce(0, +) == original.indices.count / 3 else { skippedRoofs += 1; continue }
                var matches: [Int] = []
                let complete = required.allSatisfy { key, count in
                    guard let found = lookup[key], found.count == count, found.allSatisfy({ !removed.contains($0) }) else { return false }
                    matches.append(contentsOf: found)
                    return true
                }
                guard complete, !matches.isEmpty else { skippedRoofs += 1; continue }
                var replacement = DioramaMesh()
                replacement.baseZ = original.baseZ; replacement.recordsHeight = true; replacement.tint = original.tint
                guard DioramaRoofBuilder.hip(rounded.points, flags: rounded.flags, z: height,
                    pitch: config.roofPitchDegrees * .pi / 180, overhang: config.roofOverhang, maxRise: config.hipRoofMaxRise,
                    color: color, fascia: .trimWhite, into: &replacement, footprint: feature.ring),
                    replacement.indices.count <= original.indices.count,
                    vertices.count * MemoryLayout<BuildingRenderVertex>.stride + replacement.positions.count * MemoryLayout<BuildingRenderVertex>.stride
                        + (indices.count + replacement.indices.count) * 4 < 16 * 1_048_576 else { skippedRoofs += 1; continue }
                let range = append(replacement, category: .buildings)
                let bounds = DioramaRect.bounding(replacement.positions.map { DV2($0.x, $0.y) })
                let lowZ = replacement.positions.map(\.z).min() ?? 0, highZ = replacement.positions.map(\.z).max() ?? 0
                ranges.append(.init(category: .buildings, start: range.0, count: range.1,
                    minimum: SIMD3(Float(bounds.minX - 2), Float(bounds.minY - 2), Float(lowZ - 2)),
                    maximum: SIMD3(Float(bounds.maxX + 2), Float(bounds.maxY + 2), Float(highZ + 2))))
                removed.formUnion(matches)
                roofCount += 1
            }
        }
        // Keep the existing 60 m batch grammar instead of adding one draw call per house.
        if !ranges.isEmpty {
            var bins: [Int: [UInt32]] = [:]
            for range in ranges {
                for i in stride(from: range.start, to: range.start + range.count, by: 3) {
                    let triangle = Array(indices[i..<(i + 3)])
                    let positions = triangle.map { vertices[Int($0)].position }
                    let x = positions.reduce(Float(0)) { $0 + $1.x } / 3
                    let y = positions.reduce(Float(0)) { $0 + $1.y } / 3
                    let bin = Int(floor(Double(x) / DioramaTileGenerator.binSize))
                        + Int(floor(Double(y) / DioramaTileGenerator.binSize)) * 10000
                    bins[bin, default: []].append(contentsOf: triangle)
                }
            }
            indices.removeSubrange(roofIndexStart..<indices.count)
            ranges.removeAll(keepingCapacity: true)
            for key in bins.keys.sorted() {
                if Task.isCancelled { return nil }
                guard let batch = bins[key] else { continue }
                var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for index in batch {
                    let p = vertices[Int(index)].position, point = SIMD3(p.x, p.y, p.z)
                    minimum = simd_min(minimum, point); maximum = simd_max(maximum, point)
                }
                ranges.append(.init(category: .buildings, start: indices.count, count: batch.count,
                    minimum: minimum - SIMD3(repeating: 2), maximum: maximum + SIMD3(repeating: 2)))
                indices.append(contentsOf: batch)
            }
        }
        let lightGrid = DioramaLightGrid(cells: 1, minX: 0, minY: 0, cellSize: 1,
            lights: [], table: [SIMD2(0, 0)], indices: [])
        let additions = DioramaTileArtifacts(tile: base.tile, vertices: vertices, indices: indices, ranges: ranges,
            groups: [], allInstances: [], parts: [], lights: [], lightGrid: lightGrid, waterHeight: base.waterHeight,
            shorelineReport: [], generationSeconds: 0, groundImage: nil)
        let metadata = DioramaVisualPatch.Metadata(revision: revision, baseDigest: digest, trees: trees,
            removedTriangles: removed.sorted(), roofCount: roofCount, skippedRoofs: skippedRoofs)
        return (DioramaVisualPatch(additions: additions, metadata: metadata), context || data != nil)
    }

    private func matches(_ mesh: DioramaMesh, group: DioramaInstanceGroup, base: DioramaTileArtifacts) -> Bool {
        guard mesh.indices.count == group.fullCount else { return false }
        for i in mesh.indices.indices {
            let p = mesh.positions[Int(mesh.indices[i])]
            let saved = base.vertices[Int(base.indices[group.fullStart + i])].position
            if saved.x != Float(p.x) || saved.y != Float(p.y) || saved.z != Float(p.z) { return false }
        }
        return true
    }

    private nonisolated struct VertexKey: Hashable, Comparable {
        let values: [UInt32]
        init?(_ v: BuildingRenderVertex) {
            let components = [v.position, v.normal, v.color, v.appearance].flatMap { [$0.x, $0.y, $0.z, $0.w] }
            guard components.allSatisfy(\.isFinite) else { return nil }
            values = components.map { $0 == 0 ? 0 : $0.bitPattern }
        }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.values.lexicographicallyPrecedes(rhs.values) }
    }
    private nonisolated struct TriangleKey: Hashable {
        let vertices: [VertexKey]
        init?(_ source: [BuildingRenderVertex]) {
            let keys = source.compactMap(VertexKey.init)
            guard keys.count == 3 else { return nil }
            let first = keys.indices.min { keys[$0] < keys[$1] } ?? 0
            vertices = [keys[first], keys[(first + 1) % 3], keys[(first + 2) % 3]]
        }
    }
}
