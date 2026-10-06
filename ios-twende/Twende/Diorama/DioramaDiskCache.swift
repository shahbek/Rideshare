import CryptoKit
import Foundation

/// Disk I/O is confined to this actor's executor, never the main actor. Only complete packages get
/// published; stale/corrupt entries are cache misses. This cache does not substitute terrain sources.
actor DioramaDiskCache {
    static let shared = DioramaDiskCache()
    private let budget = 512 * 1024 * 1024

    nonisolated static func key(tile: DioramaTileID, config: DioramaConfig, reduced: Bool) -> String {
        "v\(config.generatorVersion)-\(tile.key)-\(reduced ? "reduced" : "full")-\(config.instancesArchitecture ? "instances" : "baked")-a\(DioramaTileArchive.format)"
    }

    private var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DioramaTiles", isDirectory: true)
    }

    func read(tile: DioramaTileID, config: DioramaConfig, reduced: Bool) -> DioramaTileArtifacts? {
        let key = Self.key(tile: tile, config: config, reduced: reduced)
        let directory = root.appendingPathComponent(key, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            var artifact = try DioramaTileArchive.read(from: directory, key: key)
            guard artifact.tile == tile else { throw DioramaTileArchive.ArchiveError.invalid }
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
            artifact.stageTimings.append("disk decode (not generation): \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s")
            return artifact
        } catch {
            if !Task.isCancelled { try? FileManager.default.removeItem(at: directory) }
            return nil
        }
    }

    func write(_ artifact: DioramaTileArtifacts, config: DioramaConfig, reduced: Bool) -> Int? {
        // A bundled-only transient fallback must not suppress the next online source fetch.
        guard artifact.hasMapboxCoverage, !Task.isCancelled else { return nil }
        let key = Self.key(tile: artifact.tile, config: config, reduced: reduced)
        let staging = root.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent(key, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bytes = try DioramaTileArchive.write(artifact, key: key, to: staging)
            try Task.checkCancellation()
            guard bytes <= budget else {
                try FileManager.default.removeItem(at: staging)
                return nil
            }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staging, to: destination)
            prune(keeping: destination)
            return bytes
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return nil
        }
    }

    func remove(tile: DioramaTileID, config: DioramaConfig) {
        for reduced in [false, true] {
            let key = Self.key(tile: tile, config: config, reduced: reduced)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(key, isDirectory: true))
        }
    }

    private func prune(keeping current: URL) {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var entries: [(url: URL, date: Date, bytes: Int)] = []
        for directory in directories {
            if directory.lastPathComponent.hasPrefix("stage-") { try? fm.removeItem(at: directory); continue }
            let date = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = children.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            entries.append((directory, date, bytes))
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > budget && entry.url != current {
            do { try fm.removeItem(at: entry.url); total -= entry.bytes } catch { continue }
        }
    }
}
