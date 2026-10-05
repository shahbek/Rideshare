import CryptoKit
import Foundation

/// Lossless local render-artifact archive. Large GPU arrays are stored verbatim, not as JSON numbers.
/// Schema, source/config fingerprints, strides and a checksum guard every read; invalid files rebuild.
nonisolated enum DioramaTileArchive {
    private static let schema = 1
    private static let magic = Data("ZURITILE".utf8)
    private static let queue = DispatchQueue(label: "zuri.diorama.archive", qos: .userInitiated)
    private static let writer = DispatchQueue(label: "zuri.diorama.archive.writer", qos: .utility)

    private struct Header: Codable {
        let schema: Int
        let key: String
        let tile: DioramaTileID
        let vertexStride: Int
        let vertexCount: Int
        let indexCount: Int
        let imageSize: Int
        let ranges: [DioramaRenderLayer.Range]
        let groups: [DioramaInstanceGroup]
        let parts: [DioramaTileArtifacts.Part]
        let lights: [DioramaLight]
        let lightGrid: DioramaLightGrid
        let waterHeight: Double
        let shorelineReport: [String]
        let generationSeconds: Double
        let labels: [DioramaBuildingLabel]
    }

    private static let sourceDigest: String = {
        var hash = SHA256()
        for name in ["slipway_tile", "slipway_terrain", "slipway_shoreline_overrides"] {
            hash.update(data: Data(name.utf8))
            if let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) {
                hash.update(data: data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }()

    /// Dictionary order must not change cache identity between process launches.
    static func key(_ tile: DioramaTileID, config: DioramaConfig, reduced: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var base = config
        base.palette = [:]
        base.buildingOverrides = [:]
        var hash = SHA256()
        hash.update(data: Data("archive\(schema)/\(sourceDigest)/\(tile.key)/\(reduced)".utf8))
        hash.update(data: (try? encoder.encode(base)) ?? Data())
        for swatch in config.palette.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            hash.update(data: Data("/\(swatch.rawValue):\(config.palette[swatch] ?? 0)".utf8))
        }
        for id in config.buildingOverrides.keys.sorted() {
            hash.update(data: Data("/building:\(id):".utf8))
            hash.update(data: (try? encoder.encode(config.buildingOverrides[id])) ?? Data())
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func directory() throws -> URL {
        var url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DioramaArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    /// A serial work queue coalesces repeat requests via the memory cache and orders regeneration
    /// after pending writes. Disk I/O and construction never execute on the main actor.
    static func load(config: DioramaConfig, reduced: Bool, force: Bool = false) async -> DioramaTileArtifacts? {
        await withCheckedContinuation { continuation in
            queue.async {
                let started = Date()
                let tile = DioramaTileID(latitude: config.seedLatitude, longitude: config.seedLongitude, zoom: config.tileZoom)
                let key = key(tile, config: config, reduced: reduced)
                let url = try? directory().appendingPathComponent(key).appendingPathExtension("zuritile")
                if force {
                    DioramaTileGenerator.clearCache(for: tile, config: config)
                    writer.sync {
                        if let url { try? FileManager.default.removeItem(at: url) }
                    }
                }
                if let cached = DioramaTileGenerator.cached(tile, config: config, reduced: reduced) {
                    print("[Diorama load] memory hit")
                    continuation.resume(returning: cached)
                    return
                }
                if !force, let url, let cached = read(url: url, key: key, tile: tile) {
                    DioramaTileGenerator.remember(cached, config: config, reduced: reduced)
                    print("[Diorama load] disk hit: \(String(format: "%.3f", Date().timeIntervalSince(started)))s, \(cached.totalBytes / 1024) KB")
                    continuation.resume(returning: cached)
                    return
                }
                guard let data = DioramaBundledTile.load(config: config), !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let library = DioramaPropLibrary(config: config)
                    print("[Diorama timing] bundle + prototypes: \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
                    let artifacts = try DioramaTileGenerator.generate(data, config: config, library: library, reduced: reduced)
                    print("[Diorama load] generated: \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
                    // Present immediately; persistence is not on the first-frame critical path.
                    continuation.resume(returning: artifacts)
                    if let url {
                        writer.async {
                            do {
                                try write(artifacts, key: key, to: url)
                                print("[Diorama load] lossless archive saved")
                                // The production scene has one active configuration; do not accumulate old versions.
                                let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                                for file in files where file != url && ["zuritile", "partial"].contains(file.pathExtension) {
                                    try? FileManager.default.removeItem(at: file)
                                }
                            } catch {
                                print("[Diorama load] archive write unavailable; current scene remains usable")
                            }
                        }
                    }
                } catch {
                    print("[Diorama load] generation failed")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func write(_ a: DioramaTileArtifacts, key: String, to url: URL) throws {
        let header = Header(schema: schema, key: key, tile: a.tile, vertexStride: MemoryLayout<BuildingRenderVertex>.stride,
                            vertexCount: a.vertices.count, indexCount: a.indices.count, imageSize: a.groundImage?.size ?? 0,
                            ranges: a.ranges, groups: a.groups, parts: a.parts, lights: a.lights, lightGrid: a.lightGrid,
                            waterHeight: a.waterHeight, shorelineReport: a.shorelineReport, generationSeconds: a.generationSeconds, labels: a.buildingLabels)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let metadata = try encoder.encode(header)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        var hash = SHA256()
        func append(_ bytes: UnsafeRawBufferPointer) throws {
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
            // FileHandle consumes synchronously; the borrowed bytes never escape this scope.
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
            hash.update(bufferPointer: bytes)
            try file.write(contentsOf: data)
        }
        try magic.withUnsafeBytes { try append($0) }
        var length = UInt64(metadata.count).littleEndian
        try withUnsafeBytes(of: &length) { try append($0) }
        try metadata.withUnsafeBytes { try append($0) }
        try a.vertices.withUnsafeBytes { try append($0) }
        try a.indices.withUnsafeBytes { try append($0) }
        if let image = a.groundImage { try image.rgba.withUnsafeBytes { try append($0) } }
        try file.write(contentsOf: Data(hash.finalize()))
        try file.synchronize()
        try file.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func read(url: URL, key: String, tile: DioramaTileID) -> DioramaTileArtifacts? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count >= 48, data.prefix(8) == magic else { throw CocoaError(.fileReadCorruptFile) }
            let payloadEnd = data.count - 32
            let digest = data.withUnsafeBytes { bytes -> SHA256.Digest in
                var hash = SHA256()
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<payloadEnd]))
                return hash.finalize()
            }
            guard Data(digest) == data.suffix(32) else { throw CocoaError(.fileReadCorruptFile) }
            let length = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
            guard length > 0, length <= 16_777_216, length <= UInt64(payloadEnd - 16) else { throw CocoaError(.fileReadCorruptFile) }
            let end = 16 + Int(length)
            let h = try PropertyListDecoder().decode(Header.self, from: data.subdata(in: 16..<end))
            guard h.schema == schema, h.key == key, h.tile == tile,
                  h.vertexStride == MemoryLayout<BuildingRenderVertex>.stride,
                  h.vertexCount > 0, h.vertexCount <= 20_000_000,
                  h.indexCount > 0, h.indexCount <= 60_000_000, h.indexCount % 3 == 0,
                  h.imageSize == 0 || (64...8192).contains(h.imageSize) else { throw CocoaError(.fileReadCorruptFile) }
            let vertexBytes = h.vertexCount * h.vertexStride
            let indexBytes = h.indexCount * MemoryLayout<UInt32>.stride
            let imageBytes = h.imageSize * h.imageSize * 4
            guard end + vertexBytes + indexBytes + imageBytes == payloadEnd else { throw CocoaError(.fileReadCorruptFile) }
            func validRange(_ start: Int, _ count: Int, _ limit: Int) -> Bool {
                start >= 0 && count >= 0 && start <= limit && count <= limit - start
            }
            guard h.ranges.allSatisfy({ validRange($0.start, $0.count, h.indexCount) }),
                  h.groups.allSatisfy({ validRange($0.fullStart, $0.fullCount, h.indexCount) && validRange($0.lightStart, $0.lightCount, h.indexCount) }),
                  h.labels.allSatisfy({ $0.footprint.count >= 3 }), h.waterHeight.isFinite,
                  h.lightGrid.cells > 0, h.lightGrid.cells <= 1024,
                  h.lightGrid.table.count == h.lightGrid.cells * h.lightGrid.cells,
                  h.lightGrid.table.allSatisfy({ validRange(Int($0.x), Int($0.y), h.lightGrid.indices.count) }),
                  h.lightGrid.indices.allSatisfy({ Int($0) < h.lightGrid.lights.count }) else { throw CocoaError(.fileReadCorruptFile) }
            let allInstances = h.groups.flatMap(\.instances)
            var expectedFirst = 0
            for group in h.groups {
                guard group.firstInstance == expectedFirst else { throw CocoaError(.fileReadCorruptFile) }
                expectedFirst += group.instances.count
            }
            // Only fixed-layout trivial GPU structs/integers enter this copier. Never use it with
            // reference-containing values. Allocate aligned arrays instead of binding mapped file bytes.
            func copy<T>(_ type: T.Type, offset: Int, count: Int) -> [T] {
                Array(unsafeUninitializedCapacity: count) { buffer, initialized in
                    if count > 0, let target = buffer.baseAddress {
                        data.withUnsafeBytes { source in
                            if let base = source.baseAddress { UnsafeMutableRawPointer(target).copyMemory(from: base.advanced(by: offset), byteCount: count * MemoryLayout<T>.stride) }
                        }
                    }
                    initialized = count
                }
            }
            let indices = copy(UInt32.self, offset: end + vertexBytes, count: h.indexCount)
            guard indices.allSatisfy({ $0 < UInt32(h.vertexCount) }) else { throw CocoaError(.fileReadCorruptFile) }
            let vertices = copy(BuildingRenderVertex.self, offset: end, count: h.vertexCount)
            let image = h.imageSize == 0 ? nil : DioramaGroundImage(size: h.imageSize, rgba: copy(UInt8.self, offset: end + vertexBytes + indexBytes, count: imageBytes))
            return DioramaTileArtifacts(tile: tile, vertices: vertices, indices: indices, ranges: h.ranges, groups: h.groups,
                                       allInstances: allInstances, parts: h.parts, lights: h.lights, lightGrid: h.lightGrid,
                                       waterHeight: h.waterHeight, shorelineReport: h.shorelineReport, generationSeconds: h.generationSeconds,
                                       groundImage: image, buildingLabels: h.labels)
        } catch {
            print("[Diorama load] archive invalid or incompatible; rebuilding")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
