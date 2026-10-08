import CryptoKit
import Foundation
import Metal

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
    private var readFailures: [ReadKey: String] = [:]
    private var inFlight: [ReadKey: Task<DioramaTileArtifacts?, Never>] = [:]
    private var readIdentities: [ReadKey: UUID] = [:]
    private var decoded: [ReadKey: CachedRead] = [:]
    private var access: UInt = 0
    private var readConsumers: [UUID: Set<UUID>] = [:]
    private var dataRevision: UInt = 0
    private var activeReads: Int = 0
    private var waiters: [ReadWaiter] = []
    // The mounted renderers own their artifacts. Do not retain a second evicted-tile working set.
    private let decodedBudget: Int = 0

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
    /// Inspect compatible local manifests (and any verified r3 sidecar) before any decode or GPU allocation.
    func residencyCost(_ tile: DioramaTileID, context: Bool, size: CGSize, scale: Float) async -> DioramaResidencyBudget.Cost? {
        var costs: [DioramaResidencyBudget.Cost] = []
        for name in candidateNames(tile, context: context) {
            let directory = root.appendingPathComponent(name)
            guard let m = try? DioramaTileArchive.validatedManifest(at: directory, key: name),
                  m.z == tile.z, m.x == tile.x, m.y == tile.y else { continue }
            let ranges = DioramaTileArchive.baseRanges(m), shells = DioramaTileArchive.baseGroupShells(m)
            let indexCount = (m.sections.first { $0.name == "indices" }?.bytes ?? 0) / 4
            let patch = await DioramaVisualUpgrade.shared.cachedPatch(directory: directory, tile: tile, indexCount: indexCount, ranges: ranges, groups: shells)
            let affected = patch.map { p in
                let removed = Set(p.metadata.removedTriangles)
                return ranges.filter { r in r.category == .buildings && stride(from: r.start, to: r.start + r.count, by: 3).contains { removed.contains($0) } }
                    .reduce(0) { $0 + $1.count }
            } ?? 0
            var plan = DioramaTileArchive.residentPlan(m, origin: tile.centre, patchVertices: patch?.additions.vertices.count ?? 0,
                patchIndices: patch?.additions.indices.count ?? 0, affectedIndices: affected)
            plan.lodBytes = DioramaLODStore.indexBytes(package: directory, patched: patch != nil)
            var cost = DioramaResidencyBudget.residentCost(plan, labelTitles: m.labels.map(\.title), context: context, size: size, scale: scale)
            // The sidecar's float vertices/indices are held while it is merged.
            if let patch { cost = .init(retained: cost.retained, peak: cost.peak + patch.additions.totalBytes) }
            costs.append(cost)
        }
        // A rejected newer candidate may fall back to an older, larger compatible archive.
        guard !costs.isEmpty else { return nil }
        return .init(retained: costs.map(\.retained).max() ?? 0, peak: costs.map(\.peak).max() ?? 0)
    }

    /// Decodes a saved package straight into shared Metal storage; no CPU duplicate, no network.
    /// Tries older compatible packages when a newer one is rejected; user bytes are never deleted.
    func readResident(_ tile: DioramaTileID, context: Bool) async -> DioramaResidentTile? {
        let request = ReadKey(tile: tile, context: context)
        readFailures[request] = nil
        guard let device = DioramaGPUPreparation.shared.device else {
            readFailures[request] = "Metal device unavailable"; return nil
        }
        let names = candidateNames(tile, context: context)
        let directory = root
        let revision = dataRevision
        let started = Date()
        await acquireReadSlot(focus: !context)
        defer { releaseReadSlot() }
        guard !Task.isCancelled else { return nil }
        let job = Task.detached(priority: context ? .utility : .userInitiated) { () -> (DioramaResidentTile?, String) in
            var failure = "Saved \(context ? "low-detail" : "full-detail") package is missing"
            for name in names {
                if Task.isCancelled { return (nil, failure) }
                let location = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: location.appendingPathComponent("manifest.json").path) else { continue }
                do {
                    let m = try DioramaTileArchive.validatedManifest(at: location, key: name)
                    guard m.z == tile.z, m.x == tile.x, m.y == tile.y else { continue }
                    let indexCount = (m.sections.first { $0.name == "indices" }?.bytes ?? 0) / 4
                    let patch = await DioramaVisualUpgrade.shared.cachedPatch(directory: location, tile: tile, indexCount: indexCount,
                        ranges: DioramaTileArchive.baseRanges(m), groups: DioramaTileArchive.baseGroupShells(m))
                    let result = try autoreleasepool {
                        try DioramaTileArchive.readResident(from: location, key: name, manifest: m, device: device, patch: patch, origin: tile.centre)
                    }
                    if patch == nil { print("[Diorama load] \(tile.key) context=\(context): no verified r3 sidecar; original v36 roofs/trees shown") }
                    return (result, failure)
                } catch {
                    if Task.isCancelled || error is CancellationError { return (nil, failure) }
                    switch error {
                    case DioramaTileArchive.ArchiveError.incompatible: failure = "Saved package layout is incompatible"
                    case DioramaTileArchive.ArchiveError.invalid: failure = "Saved package failed geometry/checksum validation or GPU allocation"
                    case DioramaTileArchive.ArchiveError.compression: failure = "Saved package could not be decompressed"
                    default: failure = "Saved package could not be read/decoded"
                    }
                    print("[Diorama load] \(tile.key) context=\(context) candidate=\(name) rejected: \(failure)")
                    continue
                }
            }
            return (nil, failure)
        }
        let (result, failure) = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard revision == dataRevision, !Task.isCancelled else { return nil }
        if result == nil { readFailures[request] = failure }
        print("[Diorama load] \(tile.key) context=\(context) resident-ready=\(String(format: "%.3f", Date().timeIntervalSince(started)))s gpu=\((result?.gpuBytes ?? 0) / 1_048_576)MiB")
        return result
    }

    /// Whether the newest readable package for this tile already has a matching LOD sidecar.
    func isOptimized(_ tile: DioramaTileID, context: Bool) -> Bool {
        for name in candidateNames(tile, context: context) {
            let location = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: location.appendingPathComponent("manifest.json").path) else { continue }
            return [false, true].contains { patched in
                DioramaLODStore.sidecar(for: location, patched: patched).flatMap(DioramaLODStore.readMetadata) != nil
            }
        }
        return false
    }

    /// One-time local bake: decode the saved package exactly as viewing does, simplify, publish the
    /// sidecar atomically. Original packages and r3 sidecars are untouched; no network.
    func optimize(_ tile: DioramaTileID, context: Bool) async throws -> String? {
        guard let device = DioramaGPUPreparation.shared.device ?? MTLCreateSystemDefaultDevice() else { return nil }
        for name in candidateNames(tile, context: context) {
            try Task.checkCancellation()
            let location = root.appendingPathComponent(name)
            guard let m = try? DioramaTileArchive.validatedManifest(at: location, key: name), m.z == tile.z, m.x == tile.x, m.y == tile.y else { continue }
            let indexCount = (m.sections.first { $0.name == "indices" }?.bytes ?? 0) / 4
            let patch = await DioramaVisualUpgrade.shared.cachedPatch(directory: location, tile: tile, indexCount: indexCount,
                ranges: DioramaTileArchive.baseRanges(m), groups: DioramaTileArchive.baseGroupShells(m))
            if let sidecar = DioramaLODStore.sidecar(for: location, patched: patch != nil), DioramaLODStore.readMetadata(sidecar) != nil {
                return "already optimized"
            }
            let job = Task.detached(priority: .utility) { () throws -> String in
                let resident = try autoreleasepool {
                    try DioramaTileArchive.readResident(from: location, key: name, manifest: m, device: device, patch: patch, origin: tile.centre)
                }
                // Build from the original layout, never from a stale LOD-tagged copy.
                guard resident.lod == nil else { return "already optimized" }
                let result = try DioramaLODBuilder.build(resident)
                try DioramaLODStore.write((result.signature, result.ranges, result.prototypes, result.report), indices: result.indices,
                                          vertexCount: resident.vertexCount, package: location, patched: patch != nil)
                return result.report
            }
            let report = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            invalidateReads()
            return report
        }
        return nil
    }

    /// Every file of every current package and sidecar, for publishing pre-baked scenery.
    func publishableFiles() -> [(directory: String, file: String, url: URL)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [(String, String, URL)] = []
        for directory in entries where directory.hasDirectoryPath || (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let name = directory.lastPathComponent
            guard name.hasPrefix("v") || name.hasPrefix("visual-r") || name.hasPrefix(DioramaLODStore.prefix) else { continue }
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                result.append((name, file.lastPathComponent, file))
            }
        }
        return result.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    /// Installs one directory downloaded from the pre-baked catalogue after every file was verified.
    func install(directory name: String, staged: URL) throws {
        invalidateReads()
        try prepareRoot()
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.hasPrefix(".") else { throw Failure.package }
        let destination = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staged, to: destination)
    }
    func hasDirectory(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("manifest.json").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("lod.json").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("patch.json").path)
    }
    var stagingRoot: URL { root.appendingPathComponent("prebaked-stage", isDirectory: true) }

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
        readFailures[request] = nil
        let names = candidateNames(tile, context: context)
        let directory = root
        let revision = dataRevision
        let started = Date()
        let job = Task.detached(priority: context ? .utility : .userInitiated) { [weak self] () -> DioramaTileArtifacts? in
            guard let self else { return nil }
            await self.acquireReadSlot(focus: !context)
            guard !Task.isCancelled else { await self.releaseReadSlot(); return nil }
            let decode = Task.detached(priority: context ? .utility : .userInitiated) { () -> DioramaTileArtifacts? in
                var failure: String = "Saved full-detail package is missing"
                for name in names {
                    if Task.isCancelled { return nil }
                    let location = directory.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: location.appendingPathComponent("manifest.json").path) else { continue }
                    do {
                        let artifact = try DioramaTileArchive.read(from: location, key: name)
                        guard artifact.tile == tile else { continue }
                        var result = await DioramaVisualUpgrade.shared.apply(artifact, directory: location, context: context)
                        guard !Task.isCancelled else { return nil }
                        result.prepareForRendering()
                        return result
                    } catch {
                        if Task.isCancelled { return nil }
                        switch error {
                        case DioramaTileArchive.ArchiveError.incompatible:
                            failure = "Saved package layout is incompatible"
                        case DioramaTileArchive.ArchiveError.invalid:
                            failure = "Saved package failed geometry/checksum validation"
                        case DioramaTileArchive.ArchiveError.compression:
                            failure = "Saved package could not be decompressed"
                        default:
                            failure = "Saved package could not be read/decoded"
                        }
                        print("[Diorama load] \(tile.key) context=\(context) candidate=\(name) rejected: \(failure)")
                        // Keep user-owned bytes and try an older compatible copy.
                        continue
                    }
                }
                await self.recordReadFailure(request, message: failure, revision: revision)
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

    func readFailure(_ tile: DioramaTileID, context: Bool = false) -> String {
        readFailures[ReadKey(tile: tile, context: context)] ?? "Saved package unavailable"
    }
    private func recordReadFailure(_ request: ReadKey, message: String, revision: UInt) {
        guard revision == dataRevision else { return }
        readFailures[request] = message
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
        decoded.removeAll(); candidates.removeAll(); readFailures.removeAll(); directoryNames = nil
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
