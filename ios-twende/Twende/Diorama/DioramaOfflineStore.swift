import CryptoKit
import Foundation

/// User-owned packages live outside purgeable caches. Local visual patches never fetch or rebuild a tile.
actor DioramaOfflineStore {
    static let shared = DioramaOfflineStore()
    nonisolated static let tiles: [DioramaTileID] = {
        let nw = DioramaTileID(latitude: -6.730, longitude: 39.260, zoom: 16)
        let se = DioramaTileID(latitude: -6.785, longitude: 39.305, zoom: 16)
        return (nw.y...se.y).flatMap { y in (nw.x...se.x).map { DioramaTileID(z: 16, x: $0, y: y) } }
    }()

    private struct ReadKey: Hashable, Sendable {
        let tile: DioramaTileID
        let context: Bool
    }
    private struct CachedRead {
        let artifact: DioramaTileArtifacts
        var access: UInt
    }
    private struct ReadWaiter {
        let focus: Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var directoryNames: [String]?
    private var candidates: [ReadKey: [String]] = [:]
    private var inFlight: [ReadKey: Task<DioramaTileArtifacts?, Never>] = [:]
    private var readIdentities: [ReadKey: UUID] = [:]
    private var decoded: [ReadKey: CachedRead] = [:]
    private var access: UInt = 0
    private var readConsumers: [UUID: Set<UUID>] = [:]
    private var dataRevision: UInt = 0
    private var activeReads: Int = 0
    private var waiters: [ReadWaiter] = []
    private let decodedBudget: Int = 64 * 1_048_576

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
    /// Deduplicated local reads; at most two decompressions run, with focus ahead of queued context.
    func read(_ tile: DioramaTileID, context: Bool = false) async -> DioramaTileArtifacts? {
        guard !Task.isCancelled else { return nil }
        let request = ReadKey(tile: tile, context: context)
        access &+= 1
        if var cached = decoded[request] {
            cached.access = access; decoded[request] = cached
            print("[Diorama load] \(tile.key) context=\(context) decoded-cache hit")
            return cached.artifact
        }
        if let pending = inFlight[request], !pending.isCancelled, let identity = readIdentities[request] {
            return await consume(pending, identity: identity)
        }
        let identity = UUID()
        let names = candidateNames(tile, context: context)
        let directory = root
        let revision = dataRevision
        let started = Date()
        let job = Task.detached(priority: context ? .utility : .userInitiated) { [weak self] () -> DioramaTileArtifacts? in
            guard let self else { return nil }
            await self.acquireReadSlot(focus: !context)
            guard !Task.isCancelled else { await self.releaseReadSlot(); return nil }
            let decode = Task.detached(priority: context ? .utility : .userInitiated) { () -> DioramaTileArtifacts? in
                for name in names {
                    if Task.isCancelled { return nil }
                    let location = directory.appendingPathComponent(name)
                    do {
                        let artifact = try DioramaTileArchive.read(from: location, key: name)
                        guard artifact.tile == tile else { continue }
                        var result = await DioramaVisualUpgrade.shared.apply(artifact, directory: location, context: context)
                        guard !Task.isCancelled else { return nil }
                        result.prepareForRendering()
                        return result
                    } catch {
                        // Keep user-owned bytes and try an older compatible copy.
                        continue
                    }
                }
                return nil
            }
            let result = await withTaskCancellationHandler { await decode.value } onCancel: { decode.cancel() }
            await self.releaseReadSlot()
            return result
        }
        inFlight[request] = job; readIdentities[request] = identity
        let result = await consume(job, identity: identity)
        guard revision == dataRevision, readIdentities[request] == identity else { return nil }
        inFlight[request] = nil; readIdentities[request] = nil
        if let result, result.decodedBytes <= decodedBudget {
            access &+= 1
            decoded[request] = CachedRead(artifact: result, access: access)
            while decoded.values.reduce(0, { $0 + $1.artifact.decodedBytes }) > decodedBudget,
                  let oldest = decoded.min(by: { $0.value.access < $1.value.access })?.key {
                decoded[oldest] = nil
            }
        }
        print("[Diorama load] \(tile.key) context=\(context) saved-to-ready=\(String(format: "%.3f", Date().timeIntervalSince(started)))s bytes=\(result?.totalBytes ?? 0)")
        return Task.isCancelled ? nil : result
    }

    private func consume(_ job: Task<DioramaTileArtifacts?, Never>, identity: UUID) async -> DioramaTileArtifacts? {
        let consumer = UUID()
        readConsumers[identity, default: []].insert(consumer)
        let result = await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            Task { await self.cancelConsumer(consumer, identity: identity, job: job) }
        }
        cancelConsumer(consumer, identity: identity, job: job)
        return Task.isCancelled ? nil : result
    }

    private func cancelConsumer(_ consumer: UUID, identity: UUID, job: Task<DioramaTileArtifacts?, Never>) {
        guard readConsumers[identity]?.remove(consumer) != nil else { return }
        if readConsumers[identity]?.isEmpty == true {
            readConsumers[identity] = nil
            job.cancel()
        }
    }

    private func acquireReadSlot(focus: Bool) async {
        if activeReads < 2 { activeReads += 1; return }
        await withCheckedContinuation { waiters.append(ReadWaiter(focus: focus, continuation: $0)) }
    }

    private func releaseReadSlot() {
        if let index = waiters.firstIndex(where: \.focus) ?? waiters.indices.first {
            waiters.remove(at: index).continuation.resume()
        } else { activeReads -= 1 }
    }

    func releaseDecodedMemory() { decoded.removeAll() }

    private func invalidateReads() {
        dataRevision &+= 1
        for job in inFlight.values { job.cancel() }
        inFlight.removeAll(); readIdentities.removeAll(); readConsumers.removeAll()
        decoded.removeAll(); candidates.removeAll(); directoryNames = nil
    }
    func save(_ artifact: DioramaTileArtifacts, context: Bool) throws {
        invalidateReads()
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
        // Retire only superseded generated packages for this tile/detail after its replacement
        // has been verified and published. Keep source downloads and every other tile intact.
        let suffix = context ? "-context1" : "-focus"
        let marker = "-\(artifact.tile.key)-"
        if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for old in entries where old.lastPathComponent != name && old.lastPathComponent.hasPrefix("v")
                && old.lastPathComponent.contains(marker) && old.lastPathComponent.hasSuffix(suffix) {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }
    func isVerified(_ tile: DioramaTileID, context: Bool) -> Bool {
        candidateNames(tile, context: context).contains { name in
            verifiedFiles(directory: root.appendingPathComponent(name), name: name)
        }
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
    // Generator revisions change scenery, not archive compatibility. Never require a region-wide
    // download/rebuild just because the installed app has a newer generator.
    private func candidateNames(_ tile: DioramaTileID, context: Bool) -> [String] {
        let current = key(tile, context: context)
        let suffix = String(current.drop(while: { $0 != "-" }))
        let request = ReadKey(tile: tile, context: context)
        if let cached = candidates[request] { return cached }
        if directoryNames == nil {
            directoryNames = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
        }
        let older = (directoryNames ?? []).filter { name in
            guard name != current, name.hasPrefix("v"), name.hasSuffix(suffix),
                  let prefix = name.split(separator: "-").first,
                  let version = Int(prefix.dropFirst()) else { return false }
            return version <= DioramaConfig.slipway.generatorVersion
        }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let names = [current] + older
        candidates[request] = names
        return names
    }
    private func validFiles(_ tile: DioramaTileID, context: Bool) -> Bool {
        candidateNames(tile, context: context).contains { validFiles(name: $0) }
    }
    private func validFiles(name: String) -> Bool {
        let directory = root.appendingPathComponent(name)
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
        invalidateReads()
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
