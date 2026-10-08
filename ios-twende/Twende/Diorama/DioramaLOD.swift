import Compression
import CryptoKit
import Foundation
import Metal
import simd

/// Screen-space-error level of detail. Each saved tile may carry an additive "lod-l1" sidecar of
/// simplified index lists that reference the original vertices (no new vertices, no archive change).
/// Every level stores the exact maximum distance any vertex moved, so a renderer can pick the
/// lightest level whose projected error stays under a pixel tolerance: visually lossless by construction.
nonisolated final class DioramaLODTable: @unchecked Sendable {
    nonisolated struct Level: Codable, Sendable {
        let start: Int
        let count: Int
        let error: Float
    }
    let indexBuffer: MTLBuffer
    let indexCount: Int
    /// Indexed by `Range.lodSlot`.
    let rangeLevels: [[Level]]
    /// Indexed by `DioramaInstanceGroup.lodSlot`; errors are in prototype units.
    let prototypeLevels: [[Level]]
    var bytes: Int { indexBuffer.length }

    init(indexBuffer: MTLBuffer, indexCount: Int, rangeLevels: [[Level]], prototypeLevels: [[Level]]) {
        self.indexBuffer = indexBuffer; self.indexCount = indexCount
        self.rangeLevels = rangeLevels; self.prototypeLevels = prototypeLevels
    }
}

/// Picks levels for one pass. `tolerance` is in drawable pixels for perspective passes;
/// `worldTolerance` (metres) replaces it for orthographic passes such as the sun shadow map.
nonisolated struct DioramaLODSelector: Sendable {
    typealias Level = DioramaLODTable.Level
    let table: DioramaLODTable
    let eye: SIMD3<Float>
    let focalPixels: Float
    let tolerance: Float
    var worldTolerance: Float?

    /// Pass-specific copy: half-resolution AO and quarter-resolution reflections accept
    /// proportionally larger full-resolution error (still about one of their own pixels).
    func scaled(_ factor: Float) -> DioramaLODSelector {
        DioramaLODSelector(table: table, eye: eye, focalPixels: focalPixels, tolerance: tolerance * factor, worldTolerance: worldTolerance)
    }
    func orthographic(_ metres: Float) -> DioramaLODSelector {
        DioramaLODSelector(table: table, eye: eye, focalPixels: focalPixels, tolerance: tolerance, worldTolerance: metres)
    }

    private func allowedError(minimum: SIMD3<Float>, maximum: SIMD3<Float>) -> Float {
        if let worldTolerance { return worldTolerance }
        guard minimum.x > -.greatestFiniteMagnitude, minimum.x.isFinite, maximum.x.isFinite, focalPixels > 0 else { return 0 }
        let closest = simd_clamp(eye, minimum, maximum)
        let distance = simd_distance(eye, closest)
        guard distance > 1 else { return 0 }
        return tolerance * distance / focalPixels
    }

    private func pick(_ levels: [Level], allowed: Float, scale: Float = 1) -> Level? {
        var chosen: Level?
        for level in levels where level.error * scale <= allowed { chosen = level }
        return chosen
    }

    func range(_ range: DioramaRenderLayer.Range) -> DioramaRenderLayer.Range {
        guard range.lodSlot >= 0, Int(range.lodSlot) < table.rangeLevels.count,
              let level = pick(table.rangeLevels[Int(range.lodSlot)], allowed: allowedError(minimum: range.minimum, maximum: range.maximum)) else { return range }
        var lighter = DioramaRenderLayer.Range(category: range.category, start: level.start, count: level.count,
            minimum: range.minimum, maximum: range.maximum, doubleSided: range.doubleSided, landmarkPlaceholder: range.landmarkPlaceholder)
        lighter.usesLODBuffer = true
        return lighter
    }

    func prototype(_ group: DioramaInstanceGroup) -> Level? {
        guard group.lodSlot >= 0, Int(group.lodSlot) < table.prototypeLevels.count else { return nil }
        return pick(table.prototypeLevels[Int(group.lodSlot)], allowed: allowedError(minimum: group.minimum, maximum: group.maximum), scale: group.lodScale)
    }
}

/// Builds, saves and loads LOD sidecars next to the original user-owned packages.
nonisolated enum DioramaLODStore {
    static let format = 1
    static let prefix = "lod-l1-"
    static let blockSize = 4 * 1024 * 1024

    nonisolated struct Prototype: Codable, Sendable {
        let fullStart: Int
        let fullCount: Int
        let levels: [DioramaLODTable.Level]
    }
    nonisolated struct Block: Codable, Sendable {
        let file: String
        let bytes: Int
        let stored: Int
        let sha256: String
        let compressed: Bool
    }
    nonisolated struct Metadata: Codable, Sendable {
        let format: Int
        let baseDigest: String
        let patched: Bool
        let signature: String
        let vertexCount: Int
        let indexCount: Int
        let ranges: [[DioramaLODTable.Level]]
        let prototypes: [Prototype]
        let blocks: [Block]
        let report: String
    }

    static func manifestDigest(_ directory: URL) -> String? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func directoryName(package: String, digest: String, patched: Bool) -> String {
        "\(prefix)\(package)-\(digest.prefix(16))\(patched ? "-p" : "")"
    }
    static func sidecar(for package: URL, patched: Bool) -> URL? {
        guard let digest = manifestDigest(package) else { return nil }
        return package.deletingLastPathComponent().appendingPathComponent(directoryName(package: package.lastPathComponent, digest: digest, patched: patched), isDirectory: true)
    }

    /// Stable fingerprint of the final decoded layout (after r3 edits and landmark ownership).
    static func signature(vertexCount: Int, indexCount: Int, ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup]) -> String {
        var hasher = SHA256()
        func add(_ values: [Int]) { values.withUnsafeBytes { hasher.update(bufferPointer: $0) } }
        add([vertexCount, indexCount, ranges.count, groups.count])
        for r in ranges { add([DioramaCategory.allCases.firstIndex(of: r.category) ?? 0, r.start, r.count, r.doubleSided ? 1 : 0, r.landmarkPlaceholder ? 1 : 0]) }
        for g in groups { add([g.fullStart, g.fullCount, g.lightStart, g.lightCount, g.firstInstance, g.instances.count]) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func readMetadata(_ directory: URL) -> Metadata? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("lod.json")), bytes.count < 16 * 1_048_576,
              let checksum = try? Data(contentsOf: directory.appendingPathComponent("lod.sha")),
              checksum == Data(SHA256.hash(data: bytes)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: bytes), metadata.format == format else { return nil }
        return metadata
    }

    /// Bytes the LOD index buffer adds to a resident tile (for admission), or zero.
    static func indexBytes(package: URL, patched: Bool) -> Int {
        guard let directory = sidecar(for: package, patched: patched), let m = readMetadata(directory) else { return 0 }
        return max(16, m.indexCount * 4)
    }

    /// Validates against the decoded layout and uploads the simplified indices to shared Metal storage.
    /// Returns nil (full detail, exactly as before) on any mismatch.
    static func load(package: URL, patched: Bool, device: MTLDevice, vertexCount: Int, indexCount: Int,
                     ranges: inout [DioramaRenderLayer.Range], groups: inout [DioramaInstanceGroup]) -> DioramaLODTable? {
        guard let directory = sidecar(for: package, patched: patched), let m = readMetadata(directory),
              m.baseDigest == manifestDigest(package), m.patched == patched,
              m.vertexCount == vertexCount, m.ranges.count == ranges.count,
              m.signature == signature(vertexCount: vertexCount, indexCount: indexCount, ranges: ranges, groups: groups),
              m.indexCount >= 0, m.indexCount <= 256 * 1_048_576 else { return nil }
        func valid(_ l: DioramaLODTable.Level) -> Bool {
            l.start >= 0 && l.count >= 0 && l.count % 3 == 0 && l.start <= m.indexCount && l.count <= m.indexCount - l.start && l.error.isFinite && l.error >= 0
        }
        guard m.ranges.allSatisfy({ $0.allSatisfy(valid) }), m.prototypes.allSatisfy({ $0.levels.allSatisfy(valid) }),
              let buffer = device.makeBuffer(length: max(16, m.indexCount * 4), options: .storageModeShared) else { return nil }
        do {
            var offset = 0
            for (i, block) in m.blocks.enumerated() {
                guard block.file == "lod-\(i).bin", block.bytes > 0, block.bytes <= blockSize, block.bytes <= m.indexCount * 4 - offset else { return nil }
                let data = try Data(contentsOf: directory.appendingPathComponent(block.file), options: .mappedIfSafe)
                guard data.count == block.stored, DioramaTileArchive.digestHex(data) == block.sha256 else { return nil }
                let target = buffer.contents().advanced(by: offset)
                let ok: Bool = data.withUnsafeBytes { source in
                    guard let address = source.baseAddress else { return false }
                    if block.compressed {
                        return compression_decode_buffer(target.assumingMemoryBound(to: UInt8.self), block.bytes,
                            address.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_LZFSE) == block.bytes
                    }
                    guard data.count == block.bytes else { return false }
                    target.copyMemory(from: address, byteCount: block.bytes); return true
                }
                guard ok else { return nil }
                offset += block.bytes
            }
            guard offset == m.indexCount * 4 else { return nil }
        } catch { return nil }
        let indices = buffer.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<m.indexCount where Int(indices[i]) >= vertexCount { return nil }
        for i in ranges.indices where !m.ranges[i].isEmpty { ranges[i].lodSlot = Int32(i) }
        let slots = Dictionary(m.prototypes.enumerated().map { (SIMD2($0.element.fullStart, $0.element.fullCount), $0.offset) }, uniquingKeysWith: { a, _ in a })
        for i in groups.indices {
            guard let slot = slots[SIMD2(groups[i].fullStart, groups[i].fullCount)], !m.prototypes[slot].levels.isEmpty else { continue }
            groups[i].lodSlot = Int32(slot)
            groups[i].lodScale = groups[i].instances.reduce(Float(0)) { max($0, max($1.scale.x, max($1.scale.y, $1.scale.z))) }
        }
        return DioramaLODTable(indexBuffer: buffer, indexCount: m.indexCount, rangeLevels: m.ranges, prototypeLevels: m.prototypes.map(\.levels))
    }

    static func write(_ metadata: (signature: String, ranges: [[DioramaLODTable.Level]], prototypes: [Prototype], report: String),
                      indices: [UInt32], vertexCount: Int, package: URL, patched: Bool) throws {
        guard let digest = manifestDigest(package), let destination = sidecar(for: package, patched: patched) else { throw DioramaTileArchive.ArchiveError.invalid }
        let staging = package.deletingLastPathComponent().appendingPathComponent("lod-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var blocks: [Block] = []
        try indices.withUnsafeBytes { bytes in
            for start in stride(from: 0, to: bytes.count, by: blockSize) {
                try Task.checkCancellation()
                let length = min(blockSize, bytes.count - start)
                guard let base = bytes.baseAddress else { throw DioramaTileArchive.ArchiveError.invalid }
                let raw = Data(bytes: base.advanced(by: start), count: length)
                var encoded = Data(count: length + 65536)
                let capacity = encoded.count
                let written = encoded.withUnsafeMutableBytes { out in
                    raw.withUnsafeBytes { input in
                        compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                            input.bindMemory(to: UInt8.self).baseAddress!, length, nil, COMPRESSION_LZFSE)
                    }
                }
                encoded.count = written
                let compressed = written > 0 && written < length
                let stored = compressed ? encoded : raw
                let file = "lod-\(blocks.count).bin"
                try stored.write(to: staging.appendingPathComponent(file), options: .atomic)
                blocks.append(Block(file: file, bytes: length, stored: stored.count, sha256: DioramaTileArchive.digestHex(stored), compressed: compressed))
            }
        }
        let m = Metadata(format: format, baseDigest: digest, patched: patched, signature: metadata.signature, vertexCount: vertexCount,
                         indexCount: indices.count, ranges: metadata.ranges, prototypes: metadata.prototypes, blocks: blocks, report: metadata.report)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(m)
        try json.write(to: staging.appendingPathComponent("lod.json"), options: .atomic)
        try Data(SHA256.hash(data: json)).write(to: staging.appendingPathComponent("lod.sha"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}

/// Offline simplification by error-bounded vertex clustering on a tile-anchored grid.
/// Every cluster collapses to one of its own original vertices (the one nearest the cluster mean),
/// clusters never merge different surface materials, colour bands or facing directions, and the
/// stored error is the measured maximum displacement, not an estimate.
nonisolated enum DioramaLODBuilder {
    /// Grid cell sizes (metres) for static scenery levels 1…4.
    static let cells: [Float] = [0.3, 0.9, 2.7, 8.1]
    /// Prototype cells as a fraction of each prototype's diagonal.
    static let prototypeCells: [Float] = [0.04, 0.1, 0.25]
    static let simplified: Set<DioramaCategory> = [.ground, .roads, .buildings, .walls, .vegetation, .props]

    nonisolated struct Result: Sendable {
        let signature: String
        let ranges: [[DioramaLODTable.Level]]
        let prototypes: [DioramaLODStore.Prototype]
        let indices: [UInt32]
        let report: String
    }

    private struct VertexView {
        let base: UnsafeMutablePointer<DioramaPackedVertex>
        let count: Int
        func p(_ i: UInt32) -> SIMD3<Float> { let v = base[Int(i)].position; return SIMD3(v.x, v.y, v.z) }
        func attributes(_ i: UInt32, materials: inout [UInt32: UInt64]) -> UInt64 {
            let v = base[Int(i)]
            let n = SIMD3(DioramaHalf.float(v.normal.x), DioramaHalf.float(v.normal.y), DioramaHalf.float(v.normal.z))
            let a = abs(n)
            let axis: UInt64 = a.x >= a.y && a.x >= a.z ? (n.x >= 0 ? 0 : 1) : (a.y >= a.z ? (n.y >= 0 ? 2 : 3) : (n.z >= 0 ? 4 : 5))
            let code = UInt32(v.color.w) | (UInt32(v.normal.w) << 16)
            let material: UInt64
            if let known = materials[code] { material = known } else { material = UInt64(materials.count & 63); materials[code] = material }
            func q(_ bits: UInt16) -> UInt64 { UInt64(max(0, min(3, Int((DioramaHalf.float(bits) * 3).rounded())))) }
            // Bits 0-2 facing, 3-8 material, 9-14 colour band; grid cell occupies bits 15-60.
            return axis | (material << 3) | (q(v.color.x) << 9) | (q(v.color.y) << 11) | (q(v.color.z) << 13)
        }
    }

    static func build(_ tile: DioramaResidentTile) throws -> Result {
        let started = Date()
        let view = VertexView(base: tile.vertexBuffer.contents().assumingMemoryBound(to: DioramaPackedVertex.self), count: tile.vertexCount)
        let indices = UnsafeBufferPointer(start: tile.indexBuffer.contents().assumingMemoryBound(to: UInt32.self), count: tile.indexCount)
        var materials: [UInt32: UInt64] = [:]
        var output: [UInt32] = []
        let eligible = tile.ranges.indices.filter { simplified.contains(tile.ranges[$0].category) && tile.ranges[$0].count > 0 }
        var levels: [[DioramaLODTable.Level]] = Array(repeating: [], count: tile.ranges.count)
        var previousCounts = tile.ranges.map(\.count)
        var previousErrors = [Float](repeating: 0, count: tile.ranges.count)
        var active = Set(eligible)

        // Referenced vertices and their static attributes.
        var referenced = [UInt32]()
        var seen = [Bool](repeating: false, count: view.count)
        for r in eligible {
            let range = tile.ranges[r]
            for i in range.start..<(range.start + range.count) where !seen[Int(indices[i])] {
                seen[Int(indices[i])] = true; referenced.append(indices[i])
            }
        }
        seen = []
        let attributes = referenced.map { view.attributes($0, materials: &materials) }
        var representative = [UInt32](repeating: 0, count: view.count)
        for i in representative.indices { representative[i] = UInt32(i) }

        var baseTriangles = 0, levelTriangles = [Int](repeating: 0, count: cells.count)
        for r in eligible { baseTriangles += tile.ranges[r].count / 3 }
        for (level, cell) in cells.enumerated() where !active.isEmpty {
            try Task.checkCancellation()
            // 1. Cluster all referenced vertices on one grid so neighbouring bins agree.
            var keyed = [(UInt64, UInt32)](); keyed.reserveCapacity(referenced.count)
            for (k, v) in referenced.enumerated() {
                let p = view.p(v)
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                let cx = UInt64(max(0, min(65535, Int(floor(p.x / cell)) + 32768)))
                let cy = UInt64(max(0, min(65535, Int(floor(p.y / cell)) + 32768)))
                let cz = UInt64(max(0, min(16383, Int(floor(p.z / cell)) + 8192)))
                keyed.append(((cx << 45) | (cy << 29) | (cz << 15) | attributes[k], v))
            }
            keyed.sort { $0.0 < $1.0 }
            var start = 0
            while start < keyed.count {
                var end = start + 1
                while end < keyed.count && keyed[end].0 == keyed[start].0 { end += 1 }
                if end - start == 1 { representative[Int(keyed[start].1)] = keyed[start].1 } else {
                    var mean = SIMD3<Float>.zero
                    for k in start..<end { mean += view.p(keyed[k].1) }
                    mean /= Float(end - start)
                    var best = keyed[start].1, bestDistance = Float.greatestFiniteMagnitude
                    for k in start..<end {
                        let d = simd_distance_squared(view.p(keyed[k].1), mean)
                        if d < bestDistance || (d == bestDistance && keyed[k].1 < best) { best = keyed[k].1; bestDistance = d }
                    }
                    for k in start..<end { representative[Int(keyed[k].1)] = best }
                }
                start = end
            }
            keyed = []
            // 2. Rewrite each bin; drop collapsed and duplicate triangles, measure displacement.
            for r in eligible where active.contains(r) {
                let range = tile.ranges[r]
                var unique = Set<SIMD3<UInt32>>()
                var simplifiedIndices: [UInt32] = []
                var error = previousErrors[r]
                for t in stride(from: range.start, to: range.start + range.count, by: 3) {
                    let a = indices[t], b = indices[t + 1], c = indices[t + 2]
                    let ra = representative[Int(a)], rb = representative[Int(b)], rc = representative[Int(c)]
                    error = max(error, simd_distance(view.p(a), view.p(ra)), simd_distance(view.p(b), view.p(rb)), simd_distance(view.p(c), view.p(rc)))
                    guard ra != rb, rb != rc, ra != rc else { continue }
                    // Rotation-invariant key keeps winding: opposite-facing thin sheets stay distinct.
                    let m = min(ra, rb, rc)
                    let key = m == ra ? SIMD3(ra, rb, rc) : (m == rb ? SIMD3(rb, rc, ra) : SIMD3(rc, ra, rb))
                    guard unique.insert(key).inserted else { continue }
                    simplifiedIndices.append(contentsOf: [ra, rb, rc])
                }
                // Keep a level only when it saves at least a quarter of the previous level.
                guard simplifiedIndices.count <= previousCounts[r] * 3 / 4 else {
                    if level > 0 { active.remove(r) }
                    continue
                }
                levels[r].append(.init(start: output.count, count: simplifiedIndices.count, error: error))
                output.append(contentsOf: simplifiedIndices)
                previousCounts[r] = simplifiedIndices.count; previousErrors[r] = error
                levelTriangles[level] += simplifiedIndices.count / 3
                if simplifiedIndices.isEmpty { active.remove(r) }
            }
        }
        representative = []

        // Instanced prototypes (trees, props, architectural parts) in their own local units.
        var prototypes: [DioramaLODStore.Prototype] = []
        var done = Set<SIMD2<Int>>()
        for group in tile.groups where simplified.contains(group.category) && group.fullCount >= 36 {
            let key = SIMD2(group.fullStart, group.fullCount)
            guard done.insert(key).inserted, group.fullStart + group.fullCount <= indices.count else { continue }
            try Task.checkCancellation()
            let local = Array(indices[group.fullStart..<(group.fullStart + group.fullCount)])
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
            for v in local { low = simd_min(low, view.p(v)); high = simd_max(high, view.p(v)) }
            let diagonal = simd_distance(low, high)
            guard diagonal.isFinite, diagonal > 0 else { continue }
            var protoLevels: [DioramaLODTable.Level] = []
            var previous = local.count, previousError: Float = 0
            for fraction in prototypeCells {
                let cell = diagonal * fraction
                var clusters: [SIMD4<Int32>: [UInt32]] = [:]
                for v in Set(local) {
                    let p = (view.p(v) - low) / cell
                    let attr = view.attributes(v, materials: &materials)
                    clusters[SIMD4(Int32(p.x), Int32(p.y), Int32(p.z), Int32(truncatingIfNeeded: attr)), default: []].append(v)
                }
                var rep: [UInt32: UInt32] = [:]
                for members in clusters.values {
                    let mean = members.reduce(SIMD3<Float>.zero) { $0 + view.p($1) } / Float(members.count)
                    let best = members.min { (simd_distance_squared(view.p($0), mean), $0) < (simd_distance_squared(view.p($1), mean), $1) } ?? members[0]
                    for m in members { rep[m] = best }
                }
                var unique = Set<SIMD3<UInt32>>(), simplifiedIndices: [UInt32] = []
                var error = previousError
                for t in stride(from: 0, to: local.count, by: 3) {
                    let tri = (local[t], local[t + 1], local[t + 2])
                    let ra = rep[tri.0] ?? tri.0, rb = rep[tri.1] ?? tri.1, rc = rep[tri.2] ?? tri.2
                    error = max(error, simd_distance(view.p(tri.0), view.p(ra)), simd_distance(view.p(tri.1), view.p(rb)), simd_distance(view.p(tri.2), view.p(rc)))
                    guard ra != rb, rb != rc, ra != rc else { continue }
                    let m = min(ra, rb, rc)
                    let key = m == ra ? SIMD3(ra, rb, rc) : (m == rb ? SIMD3(rb, rc, ra) : SIMD3(rc, ra, rb))
                    guard unique.insert(key).inserted else { continue }
                    simplifiedIndices.append(contentsOf: [ra, rb, rc])
                }
                guard simplifiedIndices.count <= previous * 3 / 4 else { break }
                protoLevels.append(.init(start: output.count, count: simplifiedIndices.count, error: error))
                output.append(contentsOf: simplifiedIndices)
                previous = simplifiedIndices.count; previousError = error
                if simplifiedIndices.isEmpty { break }
            }
            if !protoLevels.isEmpty { prototypes.append(.init(fullStart: group.fullStart, fullCount: group.fullCount, levels: protoLevels)) }
        }
        let summary = levelTriangles.enumerated().map { "L\($0.offset + 1) \($0.element.formatted())" }.joined(separator: " · ")
        let report = "Pixel-error LOD: \(baseTriangles.formatted()) static tris → \(summary); \(prototypes.count) prototype chains; built in \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
        return Result(signature: DioramaLODStore.signature(vertexCount: tile.vertexCount, indexCount: tile.indexCount, ranges: tile.ranges, groups: tile.groups),
                      ranges: levels, prototypes: prototypes, indices: output, report: report)
    }
}
