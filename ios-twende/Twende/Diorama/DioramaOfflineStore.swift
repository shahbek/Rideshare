import CryptoKit
import Foundation

/// User-owned packages live outside the purgeable HTTP/LRU caches. Viewing never fetches or builds.
actor DioramaOfflineStore {
    static let shared = DioramaOfflineStore()
    nonisolated static let tiles: [DioramaTileID] = {
        let nw = DioramaTileID(latitude: -6.730, longitude: 39.260, zoom: 16)
        let se = DioramaTileID(latitude: -6.785, longitude: 39.305, zoom: 16)
        return (nw.y...se.y).flatMap { y in (nw.x...se.x).map { DioramaTileID(z: 16, x: $0, y: y) } }
    }()

    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MasakiOffline", isDirectory: true)
    }
    private func key(_ tile: DioramaTileID, context: Bool) -> String {
        DioramaDiskCache.key(tile: tile, config: .slipway, reduced: false) + (context ? "-context1" : "-focus")
    }
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    func checkSpace() throws {
        try prepareRoot()
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > 900 * 1_048_576 else { throw Failure.storage }
    }
    func read(_ tile: DioramaTileID, context: Bool = false) -> DioramaTileArtifacts? {
        let name = key(tile, context: context)
        let directory = root.appendingPathComponent(name)
        do {
            let artifact = try DioramaTileArchive.read(from: directory, key: name)
            guard artifact.tile == tile else { throw Failure.package }
            return artifact
        } catch {
            // Quarantine by removal so inventory/resume cannot resurrect a known-bad package.
            if !Task.isCancelled { try? FileManager.default.removeItem(at: directory) }
            return nil
        }
    }
    func save(_ artifact: DioramaTileArtifacts, context: Bool) throws {
        try checkSpace()
        let name = key(artifact.tile, context: context)
        let destination = root.appendingPathComponent(name)
        let staging = root.appendingPathComponent("stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try DioramaTileArchive.write(artifact, key: name, to: staging)
        try Task.checkCancellation()
        // Verify every compressed block before publishing this tile.
        guard verifiedFiles(directory: staging, name: name) else { throw Failure.package }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
    func isVerified(_ tile: DioramaTileID, context: Bool) -> Bool {
        let name = key(tile, context: context)
        return verifiedFiles(directory: root.appendingPathComponent(name), name: name)
    }
    private func verifiedFiles(directory: URL, name: String) -> Bool {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(DioramaTileArchive.Manifest.self, from: bytes),
              manifest.key == name, manifest.format == DioramaTileArchive.format,
              manifest.vertexStride == MemoryLayout<BuildingRenderVertex>.stride,
              manifest.instanceStride == MemoryLayout<DioramaInstanceData>.stride,
              manifest.sections.count == 10, Set(manifest.sections.map(\.name)).count == 10,
              manifest.sections.allSatisfy({ $0.bytes >= 0 && $0.bytes <= DioramaTileArchive.maxBytes }),
              manifest.sections.reduce(0, { $0 + $1.bytes }) <= DioramaTileArchive.maxBytes,
              manifest.coverage else { return false }
        for block in manifest.sections.flatMap(\.blocks) {
            guard !Task.isCancelled, block.file == URL(fileURLWithPath: block.file).lastPathComponent,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(block.file)),
                  data.count == block.stored,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == block.sha256 else { return false }
        }
        return !manifest.sections.isEmpty
    }
    func inventory() -> (complete: Int, bytes: Int64) {
        var count = 0
        for tile in Self.tiles {
            if Task.isCancelled { break }
            if [false, true].allSatisfy({ validFiles(tile, context: $0) }) { count += 1 }
        }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var bytes: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            if Task.isCancelled { break }
            if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { bytes += Int64(v.fileSize ?? 0) }
        }
        return (count, bytes)
    }
    private func validFiles(_ tile: DioramaTileID, context: Bool) -> Bool {
        let name = key(tile, context: context), directory = root.appendingPathComponent(key(tile, context: context))
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(DioramaTileArchive.Manifest.self, from: bytes),
              manifest.key == name, manifest.format == DioramaTileArchive.format,
              manifest.vertexStride == MemoryLayout<BuildingRenderVertex>.stride,
              manifest.instanceStride == MemoryLayout<DioramaInstanceData>.stride,
              manifest.sections.count == 10, Set(manifest.sections.map(\.name)).count == 10,
              manifest.sections.allSatisfy({ $0.bytes >= 0 && $0.bytes <= DioramaTileArchive.maxBytes }),
              manifest.sections.reduce(0, { $0 + $1.bytes }) <= DioramaTileArchive.maxBytes,
              manifest.coverage else { return false }
        return manifest.sections.flatMap(\.blocks).allSatisfy { block in
            let size = try? directory.appendingPathComponent(block.file).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size == block.stored
        }
    }
    func removeAll() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    nonisolated enum Failure: LocalizedError {
        case storage, source, package
        var errorDescription: String? {
            switch self {
            case .storage: "Not enough free space. Keep at least 900 MB free during preparation, then resume."
            case .source: "A map source could not be downloaded or decoded. Saved tiles are kept; reconnect and resume."
            case .package: "A saved tile needs repair. Resume preparation before viewing."
            }
        }
    }
}
