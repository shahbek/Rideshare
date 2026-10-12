import Compression
import CryptoKit
import Foundation
import simd

/// Local tile package. Small independently compressed blocks avoid a second whole-tile
/// uncompressed serialization allocation.
/// Format 1: raw 64-byte vertices and arrays (every package saved before the compact format).
/// Format 2: 32-byte `DioramaArchiveVertex` (millimetre positions, the GPU's own half-precision
/// attributes) and delta/byte-plane reordering before LZFSE (`DioramaArchiveCodec`). Both read.
nonisolated enum DioramaTileArchive {
    static let format = 2
    static let legacyFormat = 1

    /// True for any package layout this build can read.
    static func supports(_ m: Manifest) -> Bool {
        m.instanceStride == MemoryLayout<DioramaInstanceData>.stride && (
            (m.format == legacyFormat && m.vertexStride == MemoryLayout<BuildingRenderVertex>.stride)
            || (m.format == format && m.vertexStride == MemoryLayout<DioramaArchiveVertex>.stride))
    }
    /// Vertex count recorded by a manifest, whichever vertex record it stores.
    static func vertexCount(_ m: Manifest) -> Int {
        let bytes = m.sections.first(where: { $0.name == "vertices" })?.bytes ?? 0
        return m.vertexStride > 0 ? bytes / m.vertexStride : 0
    }
    static let blockSize = 4 * 1024 * 1024
    static let maxBytes = 768 * 1024 * 1024

    nonisolated enum ArchiveError: Error { case invalid, incompatible, compression }

    nonisolated struct Block: Codable {
        let file: String
        let bytes: Int
        let stored: Int
        let sha256: String
        let compressed: Bool
    }
    nonisolated struct Section: Codable {
        let name: String
        let bytes: Int
        let blocks: [Block]
    }
    nonisolated struct DrawRange: Codable {
        let category: DioramaCategory
        let start: Int
        let count: Int
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
        let doubleSided: Bool
        let translucent: Bool?
    }
    nonisolated struct Group: Codable {
        let category: DioramaCategory
        let fullStart: Int
        let fullCount: Int
        let lightStart: Int
        let lightCount: Int
        let first: Int
        let count: Int
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
        let doubleSided: Bool
    }
    nonisolated struct Label: Codable {
        let id: UInt64
        let title: String
        let anchor: SIMD3<Float>
        let footprint: [SIMD2<Double>]
        let isNamed: Bool
    }
    nonisolated struct Light: Codable {
        let position: SIMD3<Double>
        let color: SIMD3<Float>
        let radius: Double
        let intensity: Float
    }
    nonisolated struct Manifest: Codable {
        let format: Int
        let key: String
        let z: Int
        let x: Int
        let y: Int
        let vertexStride: Int
        let instanceStride: Int
        let ranges: [DrawRange]
        let groups: [Group]
        let labels: [Label]
        let sources: [Light]
        let waterHeight: Double
        let imageSize: Int
        let lightCells: Int
        let lightMinX: Float
        let lightMinY: Float
        let lightCellSize: Float
        let generationSeconds: Double
        let shorelineReport: [String]
        let optimizationReport: [String]
        let stageTimings: [String]
        let coverage: Bool
        let sections: [Section]
    }

    /// Writes the blocks of one format-2 package, section by section (used by `write` and by the
    /// streamed-package decoder, which produces vertex records without building whole-tile arrays).
    struct Writer {
        let directory: URL
        private(set) var sections: [Section] = []
        private(set) var storedBytes = 0

        init(directory: URL) throws {
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        private mutating func emit(_ name: String, _ raw: Data, into blocks: inout [Block]) throws {
            let encoded = try compress(raw)
            let compressed = encoded.count < raw.count
            let stored = compressed ? encoded : raw
            let file = "\(name)-\(blocks.count).bin"
            try stored.write(to: directory.appendingPathComponent(file), options: .atomic)
            blocks.append(Block(file: file, bytes: raw.count, stored: stored.count, sha256: digest(stored), compressed: compressed))
            storedBytes += stored.count
        }

        mutating func section<T>(_ name: String, _ values: [T]) throws {
            try values.withUnsafeBytes { try section(name, bytes: $0) }
        }

        mutating func section(_ name: String, bytes: UnsafeRawBufferPointer) throws {
            var blocks: [Block] = []
            let layout = DioramaArchiveCodec.layout(section: name, format: format)
            let chunk = layout?.chunkBytes(blockSize) ?? blockSize
            for start in stride(from: 0, to: bytes.count, by: chunk) {
                try Task.checkCancellation()
                let length = min(chunk, bytes.count - start)
                guard let address = bytes.baseAddress else { throw ArchiveError.invalid }
                var raw = Data(count: length)
                raw.withUnsafeMutableBytes { output in
                    let input = UnsafeRawBufferPointer(start: address.advanced(by: start), count: length)
                    if let layout { DioramaArchiveCodec.encode(input, layout: layout, into: output.baseAddress!) }
                    else { output.baseAddress!.copyMemory(from: input.baseAddress!, byteCount: length) }
                }
                try emit(name, raw, into: &blocks)
            }
            sections.append(Section(name: name, bytes: bytes.count, blocks: blocks))
        }

        /// 32-byte archive records, produced one block at a time.
        mutating func vertices(count: Int, record: (Range<Int>, inout [DioramaArchiveVertex]) throws -> Void) throws {
            var blocks: [Block] = []
            let layout = DioramaArchiveCodec.vertices
            let perBlock = layout.chunkBytes(blockSize) / layout.record
            var records: [DioramaArchiveVertex] = []
            for start in stride(from: 0, to: count, by: perBlock) {
                try Task.checkCancellation()
                records.removeAll(keepingCapacity: true)
                try record(start..<min(count, start + perBlock), &records)
                var raw = Data(count: records.count * layout.record)
                records.withUnsafeBytes { input in
                    raw.withUnsafeMutableBytes { DioramaArchiveCodec.encode(input, layout: layout, into: $0.baseAddress!) }
                }
                try emit("vertices", raw, into: &blocks)
            }
            sections.append(Section(name: "vertices", bytes: count * layout.record, blocks: blocks))
        }

        /// Writes manifest.json; returns the package's stored size.
        func finish(_ manifest: Manifest) throws -> Int {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = try encoder.encode(manifest)
            try json.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            return storedBytes + json.count
        }
    }

    /// Writes a new package directory; callers publish it atomically after completion.
    static func write(_ a: DioramaTileArtifacts, key: String, to directory: URL) throws -> Int {
        var writer = try Writer(directory: directory)
        // Vertices: 64-byte generator records become 32-byte archive records one block at a time.
        try writer.vertices(count: a.vertices.count) { range, records in
            records.append(contentsOf: a.vertices[range].map { DioramaArchiveVertex($0) })
        }
        try writer.section("indices", a.indices)
        try writer.section("instances", a.allInstances)
        try writer.section("ground", a.groundImage?.rgba ?? [])
        try writer.section("paint", a.groundImage?.paint.triangles ?? [])
        try writer.section("paintTable", a.groundImage?.paint.table ?? [])
        try writer.section("paintIndices", a.groundImage?.paint.indices ?? [])
        try writer.section("lights", a.lightGrid.lights)
        try writer.section("lightTable", a.lightGrid.table)
        try writer.section("lightIndices", a.lightGrid.indices)
        let manifest = Manifest(format: format, key: key, z: a.tile.z, x: a.tile.x, y: a.tile.y,
            vertexStride: MemoryLayout<DioramaArchiveVertex>.stride, instanceStride: MemoryLayout<DioramaInstanceData>.stride,
            ranges: a.ranges.map { DrawRange(category: $0.category, start: $0.start, count: $0.count, minimum: $0.minimum, maximum: $0.maximum, doubleSided: $0.doubleSided, translucent: $0.translucent) },
            groups: a.groups.map { Group(category: $0.category, fullStart: $0.fullStart, fullCount: $0.fullCount, lightStart: $0.lightStart, lightCount: $0.lightCount, first: $0.firstInstance, count: $0.instances.count, minimum: $0.minimum, maximum: $0.maximum, doubleSided: $0.doubleSided) },
            labels: a.buildingLabels.map { Label(id: $0.id, title: $0.title, anchor: $0.anchor, footprint: $0.footprint.map { SIMD2($0.x, $0.y) }, isNamed: $0.isNamed) },
            sources: a.lights.map { Light(position: SIMD3($0.position.x, $0.position.y, $0.position.z), color: $0.color, radius: $0.radius, intensity: $0.intensity) },
            waterHeight: a.waterHeight, imageSize: a.groundImage?.size ?? 0, lightCells: a.lightGrid.cells,
            lightMinX: a.lightGrid.minX, lightMinY: a.lightGrid.minY, lightCellSize: a.lightGrid.cellSize,
            generationSeconds: a.generationSeconds, shorelineReport: a.shorelineReport, optimizationReport: a.optimizationReport,
            stageTimings: a.stageTimings, coverage: a.hasMapboxCoverage, sections: writer.sections)
        return try writer.finish(manifest)
    }

    static func read(from directory: URL, key: String) throws -> DioramaTileArtifacts {
        let json = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard json.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalid }
        let m = try JSONDecoder().decode(Manifest.self, from: json)
        guard supports(m), m.key == key else { throw ArchiveError.incompatible }
        guard m.sections.count == 10, Set(m.sections.map(\.name)).count == 10,
              m.z >= 0, m.z <= 22, m.x >= 0, m.x < (1 << m.z), m.y >= 0, m.y < (1 << m.z),
              m.imageSize >= 0, m.imageSize <= 4096, m.lightCells > 0, m.lightCells <= 128,
              m.waterHeight.isFinite, m.lightCellSize.isFinite, m.lightCellSize > 0 else { throw ArchiveError.invalid }
        try checkBlockAlignment(m)
        var budget = maxBytes
        for s in m.sections {
            guard s.bytes >= 0, s.bytes <= budget else { throw ArchiveError.invalid }
            budget -= s.bytes
        }
        func section<T>(_ name: String, default value: T) throws -> [T] {
            guard let s = m.sections.first(where: { $0.name == name }), s.bytes % MemoryLayout<T>.stride == 0 else { throw ArchiveError.invalid }
            let layout = DioramaArchiveCodec.layout(section: name, format: m.format)
            var values = Array(repeating: value, count: s.bytes / MemoryLayout<T>.stride)
            try values.withUnsafeMutableBytes { output in
                var offset = 0
                for (index, block) in s.blocks.enumerated() {
                    try Task.checkCancellation()
                    guard block.file == "\(name)-\(index).bin", block.bytes > 0, block.bytes <= blockSize,
                          block.bytes <= output.count - offset, block.stored > 0, block.stored <= blockSize + 65536 else { throw ArchiveError.invalid }
                    let data = try Data(contentsOf: directory.appendingPathComponent(block.file), options: .mappedIfSafe)
                    guard data.count == block.stored, digest(data) == block.sha256 else { throw ArchiveError.invalid }
                    guard let destination = output.baseAddress?.advanced(by: offset) else { throw ArchiveError.invalid }
                    try data.withUnsafeBytes { source in
                        guard let address = source.baseAddress else { throw ArchiveError.invalid }
                        if block.compressed {
                            let decoded = compression_decode_buffer(destination.assumingMemoryBound(to: UInt8.self), block.bytes,
                                address.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_LZFSE)
                            guard decoded == block.bytes else { throw ArchiveError.invalid }
                        } else {
                            guard data.count == block.bytes else { throw ArchiveError.invalid }
                            destination.copyMemory(from: address, byteCount: block.bytes)
                        }
                    }
                    if let layout { try DioramaArchiveCodec.decodeInPlace(destination, bytes: block.bytes, layout: layout) }
                    offset += block.bytes
                }
                guard offset == output.count else { throw ArchiveError.invalid }
            }
            return values
        }
        let vertices: [BuildingRenderVertex] = m.format == legacyFormat
            ? try section("vertices", default: BuildingRenderVertex(position: .zero, normal: .zero, color: .zero, appearance: .zero))
            : try section("vertices", default: DioramaArchiveVertex.zero).map(\.vertex)
        let indices = try section("indices", default: UInt32(0))
        let instances = try section("instances", default: DioramaInstanceData.identity)
        guard indices.count % 3 == 0, indices.allSatisfy({ Int($0) < vertices.count }) else { throw ArchiveError.invalid }
        func validRange(_ start: Int, _ count: Int) -> Bool { start >= 0 && count >= 0 && start <= indices.count && count <= indices.count - start && count % 3 == 0 }
        let ranges: [DioramaRenderLayer.Range] = try m.ranges.map {
            guard validRange($0.start, $0.count) else { throw ArchiveError.invalid }
            return .init(category: $0.category, start: $0.start, count: $0.count, minimum: $0.minimum, maximum: $0.maximum, doubleSided: $0.doubleSided, translucent: $0.translucent ?? false)
        }
        let groups: [DioramaInstanceGroup] = try m.groups.map {
            guard validRange($0.fullStart, $0.fullCount), validRange($0.lightStart, $0.lightCount),
                  $0.first >= 0, $0.count >= 0, $0.first <= instances.count, $0.count <= instances.count - $0.first else { throw ArchiveError.invalid }
            return .init(category: $0.category, fullStart: $0.fullStart, fullCount: $0.fullCount, lightStart: $0.lightStart,
                lightCount: $0.lightCount, doubleSided: $0.doubleSided, instances: Array(instances[$0.first..<($0.first + $0.count)]),
                firstInstance: $0.first, minimum: $0.minimum, maximum: $0.maximum)
        }
        let rgba = try section("ground", default: UInt8(0))
        guard rgba.count == m.imageSize * m.imageSize * 4 else { throw ArchiveError.invalid }
        var paint = DioramaVectorPaint()
        paint.triangles = try section("paint", default: DioramaPaintTriangle.empty)
        paint.table = try section("paintTable", default: SIMD2<UInt32>.zero)
        paint.indices = try section("paintIndices", default: UInt32(0))
        let lights = try section("lights", default: DioramaShaderLight(position: .zero, color: .zero))
        let lightTable = try section("lightTable", default: SIMD2<UInt32>.zero)
        let lightIndices = try section("lightIndices", default: UInt32(0))
        func validTable(_ table: [SIMD2<UInt32>], _ list: [UInt32], count: Int) -> Bool {
            list.allSatisfy { Int($0) < count } && table.allSatisfy { Int($0.x) <= list.count && Int($0.y) <= list.count - Int($0.x) }
        }
        guard lightTable.count == m.lightCells * m.lightCells, validTable(lightTable, lightIndices, count: lights.count),
              (m.imageSize == 0 || paint.table.count == DioramaVectorPaint.cells * DioramaVectorPaint.cells),
              validTable(paint.table, paint.indices, count: paint.triangles.count) else { throw ArchiveError.invalid }
        let grid = DioramaLightGrid(cells: m.lightCells, minX: m.lightMinX, minY: m.lightMinY, cellSize: m.lightCellSize,
                                   lights: lights, table: lightTable, indices: lightIndices)
        return DioramaTileArtifacts(tile: .init(z: m.z, x: m.x, y: m.y), vertices: vertices, indices: indices, ranges: ranges,
            groups: groups, allInstances: instances,
            parts: DioramaCategory.allCases.map { category in
                .init(category: category, triangles: ranges.filter { $0.category == category }.reduce(0) { $0 + $1.count / 3 },
                      instances: groups.filter { $0.category == category }.reduce(0) { $0 + $1.instances.count })
            }, lights: m.sources.map { .init(position: DV3($0.position.x, $0.position.y, $0.position.z), color: $0.color, radius: $0.radius, intensity: $0.intensity) }, lightGrid: grid, waterHeight: m.waterHeight, shorelineReport: m.shorelineReport,
            generationSeconds: m.generationSeconds, groundImage: m.imageSize > 0 ? .init(size: m.imageSize, rgba: rgba, paint: paint) : nil,
            buildingLabels: m.labels.map { .init(id: $0.id, title: $0.title, anchor: $0.anchor, footprint: $0.footprint.map { DV2($0.x, $0.y) }, isNamed: $0.isNamed) },
            hasMapboxCoverage: m.coverage, optimizationReport: m.optimizationReport, stageTimings: m.stageTimings)
    }

    /// Reordered blocks must hold whole records so each decodes on its own.
    static func checkBlockAlignment(_ m: Manifest) throws {
        for s in m.sections {
            guard let layout = DioramaArchiveCodec.layout(section: s.name, format: m.format) else { continue }
            guard s.bytes % layout.record == 0, s.blocks.allSatisfy({ $0.bytes % layout.record == 0 }) else { throw ArchiveError.invalid }
        }
    }

    static func digestHex(_ data: Data) -> String { digest(data) }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func compress(_ data: Data) throws -> Data {
        var result = Data(count: data.count + 65536)
        let capacity = result.count
        let count = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0 else { throw ArchiveError.compression }
        result.count = count
        return result
    }
    private static func decompress(_ data: Data, count: Int) throws -> Data {
        var result = Data(count: count)
        let decoded = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, count,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == count else { throw ArchiveError.invalid }
        return result
    }
}
