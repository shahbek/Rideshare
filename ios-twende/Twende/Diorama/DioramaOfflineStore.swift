import CryptoKit
import Foundation
import Metal

/// Independently prepared offline 3D regions. Each has its own folder, readiness and basemap area.
nonisolated enum DioramaRegion: String, CaseIterable, Sendable {
    case masaki, harbour, golf
    var folder: String {
        switch self {
        case .masaki: "MasakiOffline"
        case .harbour: "HarbourOffline"
        case .golf: "GolfOffline"
        }
    }
    var displayName: String {
        switch self {
        case .masaki: "Masaki"
        case .harbour: "Harbour"
        case .golf: "Golf courses"
        }
    }
    var tiles: [DioramaTileID] {
        switch self {
        case .masaki: DioramaOfflineStore.tiles
        case .harbour: DioramaOfflineStore.harbourTiles
        case .golf: DioramaOfflineStore.golfTiles
        }
    }
    /// Harbour is streamed: pieces arrive into a fresh HarbourStreamZ folder and stay there, so each
    /// piece downloads once. Older HarbourOffline/HarbourStream folders are left untouched but ignored.
    var isStreamed: Bool { self == .harbour }
    /// Server catalogue holding this region's compact ZPK1 stream packages (`DioramaStreamPackage`).
    var compactCatalogName: String? { self == .harbour ? "harbour-z1" : nil }
    var rootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isStreamed ? "HarbourStreamZ" : folder, isDirectory: true)
    }
    /// True when a lon/lat ring's centroid lies in a harbour tile. Harbour buildings come only from the
    /// stylized-map-renderer skill, so bespoke landmark and skyline recipes there are retired.
    static func isHarbour(ring: [[Double]]) -> Bool {
        let points = ring.filter { $0.count == 2 }
        guard !points.isEmpty else { return false }
        let lon = points.reduce(0) { $0 + $1[0] } / Double(points.count)
        let lat = points.reduce(0) { $0 + $1[1] } / Double(points.count)
        return DioramaOfflineStore.harbourTiles.contains(DioramaTileID(latitude: lat, longitude: lon, zoom: 16))
    }
    static func of(_ tile: DioramaTileID) -> DioramaRegion {
        if DioramaOfflineStore.harbourTiles.contains(tile) { return .harbour }
        if DioramaOfflineStore.golfTiles.contains(tile) { return .golf }
        return .masaki
    }
}

/// User-owned packages live outside purgeable caches. Local visual patches never fetch or rebuild a tile.
actor DioramaOfflineStore {
    static let shared = DioramaOfflineStore()
    nonisolated static let tiles: [DioramaTileID] = {
        let nw = DioramaTileID(latitude: -6.730, longitude: 39.260, zoom: 16)
        let se = DioramaTileID(latitude: -6.785, longitude: 39.305, zoom: 16)
        return (nw.y...se.y).flatMap { y in (nw.x...se.x).map { DioramaTileID(z: 16, x: $0, y: y) } }
    }()

    nonisolated static let harbourTiles: [DioramaTileID] = {
        guard let data = HarbourLandmarkData.bundled else { return [] }
        var result: Set<DioramaTileID> = []
        for ring in data.sites.map(\.ring) + data.parts.map(\.ring) {
            let addresses = ring.map { DioramaTileID(latitude: $0[1], longitude: $0[0], zoom: 16) }
            guard let minX = addresses.map(\.x).min(), let maxX = addresses.map(\.x).max(),
                  let minY = addresses.map(\.y).min(), let maxY = addresses.map(\.y).max() else { continue }
            for y in minY...maxY { for x in minX...maxX { result.insert(.init(z: 16, x: x, y: y)) } }
        }
        return result.sorted { $0.key < $1.key }
    }()
    /// Gymkhana Club and TPDF Lugalo, outside the Masaki envelope and the harbour tiles.
    nonisolated static let golfTiles: [DioramaTileID] = {
        let taken = Set(tiles + harbourTiles)
        return DarGolf.tiles.filter { !taken.contains($0) }
    }()
    static let harbour = DioramaOfflineStore(region: .harbour)
    /// First harbour generator in the current look: skill buildings with the designed landmarks'
    /// footprints left free, solid puff trees and palms, mitred roads and lane paint, no raster.
    nonisolated static let harbourSkillGenerator = 42
    static let golf = DioramaOfflineStore(region: .golf)
    nonisolated static func store(for tile: DioramaTileID) -> DioramaOfflineStore {
        store(for: DioramaRegion.of(tile))
    }
    nonisolated static func store(for region: DioramaRegion) -> DioramaOfflineStore {
        switch region {
        case .masaki: shared
        case .harbour: harbour
        case .golf: golf
        }
    }
    nonisolated static var allTiles: [DioramaTileID] { tiles + harbourTiles + golfTiles }

    private nonisolated final class PackageListing: @unchecked Sendable {
        let lock = NSLock()
        var names: [DioramaRegion: (Date, [String])] = [:]
    }
    private nonisolated static let listing = PackageListing()
    /// Cheap synchronous check (15 s cached directory listing) for any saved package of `tile`.
    nonisolated static func hasSavedPackage(_ tile: DioramaTileID) -> Bool {
        hasSavedPackage(tile, context: nil)
    }
    /// Same cached listing, restricted to one detail mode (`true` surroundings, `false` full detail).
    nonisolated static func hasSavedPackage(_ tile: DioramaTileID, context: Bool?) -> Bool {
        let region = DioramaRegion.of(tile)
        guard region.tiles.contains(tile) else { return false }
        listing.lock.lock(); defer { listing.lock.unlock() }
        var names = listing.names[region]
        if names == nil || Date().timeIntervalSince(names?.0 ?? .distantPast) > 15 {
            let root = region.rootURL
            names = (Date(), (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            listing.names[region] = names
        }
        let marker = "-\(tile.key)-"
        let suffix = context.map { $0 ? "-context1" : "-focus" }
        return names?.1.contains { name in
            guard name.hasPrefix("v"), name.contains(marker), suffix.map(name.hasSuffix) ?? true else { return false }
            guard region == .harbour else { return true }
            let version = name.split(separator: "-").first.flatMap { Int($0.dropFirst()) } ?? 0
            return version >= harbourSkillGenerator
        } ?? false
    }
    nonisolated let region: DioramaRegion
    nonisolated var regionTiles: [DioramaTileID] { region.tiles }
    init(region: DioramaRegion = .masaki) { self.region = region }

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

    private var root: URL { region.rootURL }


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
            let landmarks = DioramaBakedLandmarks.shared.counts(for: tile)
            var plan = DioramaTileArchive.residentPlan(m, origin: tile.centre, patchVertices: (patch?.additions.vertices.count ?? 0) + landmarks.vertices,
                patchIndices: (patch?.additions.indices.count ?? 0) + landmarks.indices, affectedIndices: affected)
            // Computed landmark levels add an index-only buffer (typically well under half the source indices).
            plan.lodBytes = DioramaLODStore.indexBytes(package: directory, patched: patch != nil) + landmarks.indices * 2
            var cost = DioramaResidencyBudget.residentCost(plan, labelTitles: context ? [] : m.labels.map(\.title), context: context, size: size, scale: scale)
            // The sidecar's float vertices/indices are held while it is merged.
            if let patch { cost = .init(retained: cost.retained, peak: cost.peak + patch.additions.totalBytes) }
            costs.append(cost)
        }
        // A rejected newer candidate may fall back to an older, larger compatible archive.
        guard !costs.isEmpty else { return nil }
        return .init(retained: costs.map(\.retained).max() ?? 0, peak: costs.map(\.peak).max() ?? 0)
    }

    /// Decodes once in the background so the GPU-ready snapshot exists before the first visit.
    /// Returns false when a current snapshot already exists or nothing could be decoded.
    func warmSnapshot(_ tile: DioramaTileID, context: Bool) async -> Bool {
        guard DioramaGPUPreparation.shared.device != nil else { return false }
        let directory = root
        guard let firstName = candidateNames(tile, context: context).first(where: {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("manifest.json").path)
        }) else { return false }
        let landmarks = DioramaBakedLandmarks.shared.snapshotIdentity(for: tile)
        if let identity = DioramaResidentSnapshot.identity(package: directory.appendingPathComponent(firstName), landmarks: landmarks),
           DioramaResidentSnapshot.isCurrent(tile: tile, context: context, identity: identity) { return false }
        return await readResident(tile, context: context) != nil
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
        // Fast path: a GPU-ready snapshot of this exact decode maps straight into Metal.
        let firstName = names.first { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("manifest.json").path) }
        let landmarkIdentity = DioramaBakedLandmarks.shared.snapshotIdentity(for: tile)
        var identity: String?
        if let firstName {
            await acquireReadSlot(focus: !context)
            let package = directory.appendingPathComponent(firstName)
            let fast = Task.detached(priority: context ? .utility : .userInitiated) { () -> (String?, DioramaResidentSnapshot.Loaded?) in
                guard let identity = DioramaResidentSnapshot.identity(package: package, landmarks: landmarkIdentity) else { return (nil, nil) }
                return (identity, autoreleasepool { DioramaResidentSnapshot.read(tile: tile, context: context, identity: identity, device: device) })
            }
            let (found, loaded) = await withTaskCancellationHandler { await fast.value } onCancel: { fast.cancel() }
            releaseReadSlot()
            identity = found
            guard revision == dataRevision, !Task.isCancelled else { return nil }
            if let loaded {
                print("[Diorama load] \(tile.key) context=\(context) snapshot-ready=\(String(format: "%.3f", loaded.seconds))s gpu=\(loaded.tile.gpuBytes / 1_048_576)MiB")
                return loaded.tile
            }
        }
        // Bespoke landmarks inside this tile are drawn by it (Slipway/Sea Cliff method). The read
        // never waits for recipes that are not baked yet: the tile is drawn now with its saved
        // shells, the missing recipes build in the background and the tile reloads when they exist.
        let (landmarks, landmarksComplete) = DioramaBakedLandmarks.shared.cachedMeshes(for: tile)
        if !landmarksComplete {
            DioramaBakedLandmarks.shared.buildMissing(for: tile)
            print("[Diorama load] \(tile.key) context=\(context): \(landmarks.count) baked landmark(s) ready; others build in background")
        }
        await acquireReadSlot(focus: !context)
        defer { releaseReadSlot() }
        guard !Task.isCancelled else { return nil }
        let job = Task.detached(priority: context ? .utility : .userInitiated) { () -> (DioramaResidentTile?, String, String?) in
            var failure = "Saved \(context ? "low-detail" : "full-detail") package is missing"
            for name in names {
                if Task.isCancelled { return (nil, failure, nil) }
                let location = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: location.appendingPathComponent("manifest.json").path) else { continue }
                do {
                    let m = try DioramaTileArchive.validatedManifest(at: location, key: name)
                    guard m.z == tile.z, m.x == tile.x, m.y == tile.y else { continue }
                    let indexCount = (m.sections.first { $0.name == "indices" }?.bytes ?? 0) / 4
                    let patch = await DioramaVisualUpgrade.shared.cachedPatch(directory: location, tile: tile, indexCount: indexCount,
                        ranges: DioramaTileArchive.baseRanges(m), groups: DioramaTileArchive.baseGroupShells(m))
                    let result = try autoreleasepool {
                        try DioramaTileArchive.readResident(from: location, key: name, manifest: m, device: device, patch: patch, origin: tile.centre,
                                                            landmarks: landmarks)
                    }
                    if patch == nil { print("[Diorama load] \(tile.key) context=\(context): no verified r3 sidecar; original v36 roofs/trees shown") }
                    return (result, failure, name)
                } catch {
                    if Task.isCancelled || error is CancellationError { return (nil, failure, nil) }
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
            return (nil, failure, nil)
        }
        let (result, failure, usedName) = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard revision == dataRevision, !Task.isCancelled else { return nil }
        if result == nil { readFailures[request] = failure }
        // Cache this exact decode for the next visit (background, purgeable, never user data).
        let expected = DioramaBakedLandmarks.ids(for: tile)
        let baked = DioramaBakedLandmarks.shared
        if let result, let identity, usedName == firstName,
           expected.allSatisfy({ id in landmarks.contains { $0.id == id } || baked.isUnavailable(id) }) {
            let drawn = landmarks.map(\.id)
            var floors: [String: Double] = [:]
            for id in drawn { if let floor = baked.knownFloor(id) { floors[id] = floor } }
            let snapshotFloors = floors
            Task.detached(priority: .utility) {
                DioramaResidentSnapshot.write(result, context: context, identity: identity, drawn: drawn, expected: expected, floors: snapshotFloors)
            }
        }
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
                    try DioramaTileArchive.readResident(from: location, key: name, manifest: m, device: device, patch: patch, origin: tile.centre,
                                                        roofs: false)
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

    /// Every file of every current package and sidecar, for publishing pre-baked scenery. `compactOnly`
    /// keeps format-2 packages (and sidecars naming them), so streamed regions never serve old 64-byte
    /// vertex / 4096 px ground packages.
    func publishableFiles(compactOnly: Bool = false) -> [(directory: String, file: String, url: URL)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let directories = entries.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let compact = Set(directories.compactMap { directory -> String? in
            let name = directory.lastPathComponent
            guard name.hasPrefix("v"), let m = try? DioramaTileArchive.validatedManifest(at: directory, key: name),
                  m.format >= DioramaTileArchive.format else { return nil }
            return name
        })
        var result: [(String, String, URL)] = []
        for directory in directories {
            let name = directory.lastPathComponent
            guard name.hasPrefix("v") || name.hasPrefix("visual-r") || name.hasPrefix(DioramaLODStore.prefix) else { continue }
            if compactOnly {
                guard compact.contains(name) || (!name.hasPrefix("v") && compact.contains { name.contains("-\($0)-") }) else { continue }
            }
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
        Self.invalidateListing()
    }
    /// Stored (download) bytes of the package each tile would read, per detail mode, plus whether it is
    /// a compact format-2 package. Sidecars (LOD levels, r3 roofs) of that package are included.
    func packageSizes() -> [(tile: DioramaTileID, coarse: Int64, full: Int64, compact: Bool)] {
        func size(_ url: URL) -> Int64 {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let file = enumerator?.nextObject() as? URL { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            return total
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return regionTiles.map { tile in
            var bytes: [Int64] = [0, 0], compact = true
            for (i, context) in [true, false].enumerated() {
                guard let name = candidateNames(tile, context: context).first(where: { validFiles(name: $0) }) else { compact = false; continue }
                let m = try? DioramaTileArchive.validatedManifest(at: root.appendingPathComponent(name), key: name)
                if (m?.format ?? 0) < DioramaTileArchive.format { compact = false }
                bytes[i] = size(root.appendingPathComponent(name))
                    + names.filter { !$0.hasPrefix("v") && $0.contains("-\(name)-") }.reduce(0) { $0 + size(root.appendingPathComponent($1)) }
            }
            return (tile, bytes[0], bytes[1], compact)
        }
    }
    /// Directory listing changed outside the actor's own reads (streamed install).
    nonisolated static func invalidateListing() {
        listing.lock.lock(); listing.names.removeAll(); listing.lock.unlock()
    }
    func hasDirectory(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("manifest.json").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("lod.json").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("patch.json").path)
    }
    var stagingRoot: URL { root.appendingPathComponent("prebaked-stage", isDirectory: true) }
    var streamStagingRoot: URL { root.appendingPathComponent("stream-stage", isDirectory: true) }

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
    /// Joined packages are additive replacements; original downloads remain a readable fallback.
    func isJoined(_ tile: DioramaTileID, context: Bool) -> Bool {
        validFiles(name: joinedKey(tile, context: context))
    }
    /// Publish the region switch only after every detail mode is present. A paused repair never
    /// mixes elevated repaired tiles with the old valley-shaped neighbouring packages.
    func activateJoins() throws {
        guard regionTiles.allSatisfy({ isJoined($0, context: false) && isJoined($0, context: true) }) else { throw Failure.package }
        try Data("joined\(Self.joinRevision)".utf8).write(to: root.appendingPathComponent("joined\(Self.joinRevision).ready"), options: .atomic)
        invalidateReads()
    }
    /// Rebuild revisions: 1 terrain/roads, 2 district colours, 3 shared architecture, 4 distinct typologies,
    /// 5 sand landuse, 6 roof kit, 7 windows/doors, 8 compact packages (1024 px natural raster plus vector
    /// hard finishes, 32-byte millimetre vertices). Older revisions stay readable until the newer region
    /// rebuild is complete and activated.
    nonisolated static let joinRevision = 8
    private func joinedKey(_ tile: DioramaTileID, context: Bool, revision: Int = DioramaOfflineStore.joinRevision) -> String {
        DioramaDiskCache.key(tile: tile, config: .slipway, reduced: false) + "-joined\(revision)" + (context ? "-context1" : "-focus")
    }
    func save(_ artifact: DioramaTileArtifacts, context: Bool) throws {
        invalidateReads()
        try checkSpace()
        let name = joinedKey(artifact.tile, context: context)
        let destination = root.appendingPathComponent(name)
        let staging = root.appendingPathComponent("stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try DioramaTileArchive.write(artifact, key: name, to: staging)
        try Task.checkCancellation()
        // Verify every compressed block before publishing this tile.
        guard verifiedFiles(directory: staging, name: name) else { throw Failure.package }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        // Never delete the original downloaded v36 package or its r3/LOD sidecars.
    }
    func isVerified(_ tile: DioramaTileID, context: Bool) -> Bool {
        candidateNames(tile, context: context).contains { name in
            verifiedFiles(directory: root.appendingPathComponent(name), name: name)
        }
    }
    private func verifiedFiles(directory: URL, name: String) -> Bool {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(DioramaTileArchive.Manifest.self, from: bytes),
              manifest.key == name, DioramaTileArchive.supports(manifest),
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
        for tile in regionTiles {
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
            // Harbour packages before generator 40 hold retired procedural buildings, not the skill's.
            return version <= DioramaConfig.slipway.generatorVersion && (region != .harbour || version >= Self.harbourSkillGenerator)
        }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let revisions = Array((1...Self.joinRevision).reversed())
        let joinedNames = revisions.map { joinedKey(tile, context: context, revision: $0) }
        let originals = [current] + older.filter { !joinedNames.contains($0) }
        let directories = Set(directoryNames ?? [])
        // A published catalogue contains package directories, not the local activation marker.
        func complete(_ revision: Int) -> Bool {
            regionTiles.allSatisfy {
                directories.contains(joinedKey($0, context: false, revision: revision))
                    && directories.contains(joinedKey($0, context: true, revision: revision))
            }
        }
        let active = revisions.filter { directories.contains("joined\($0).ready") || complete($0) }
        let activeNames = active.map { joinedKey(tile, context: context, revision: $0) }
        let pendingNames = joinedNames.filter { !activeNames.contains($0) }
        // Preserve every completed older revision and originals until the new region is complete.
        // Partial revisions are recovery-only, never the leading choice for a healthy old region.
        let names = activeNames + originals + pendingNames
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
              manifest.key == name, DioramaTileArchive.supports(manifest),
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
        DioramaResidentSnapshot.removeAll()
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
