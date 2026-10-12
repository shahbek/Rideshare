import CoreLocation
import Foundation
import Network
import Observation
import UIKit

/// Fenn-style on-demand scenery for streamed regions (harbour first). Nothing is downloaded up front:
/// when the camera comes near a tile, its small compact package is fetched from the region's
/// published catalogue — surroundings (coarse) before full detail, nearest tile first — verified by
/// SHA-256, installed into the region's saved folder and then drawn by the normal saved-tile path.
/// Installed packages are the disk cache; the native map shows until a piece arrives.
@Observable @MainActor
final class DioramaSceneryStreamer {
    static let shared = DioramaSceneryStreamer()

    nonisolated struct TileSize: Sendable, Equatable {
        var coarse: Int64 = 0
        var full: Int64 = 0
        var total: Int64 { coarse + full }
    }

    let region: DioramaRegion = .harbour
    /// Tiles whose surroundings package is saved, streamed or prepared.
    private(set) var readyTiles: Set<DioramaTileID> = []
    private(set) var status: String = ""
    private(set) var isStreaming: Bool = false
    /// The camera is within reach of a streamed tile (drives the on-map status pill).
    private(set) var isNearby: Bool = false
    /// Streaming is stopped only by the “Downloaded maps only” switch; the map offers to turn it off.
    private(set) var isBlockedByDownloadedOnly: Bool = false
    /// Both tiles' surroundings and at least one full-detail piece are on the phone.
    var hasEverything: Bool { region.tiles.allSatisfy { readyTiles.contains($0) } }
    /// Bytes this device actually downloaded per tile.
    private(set) var downloaded: [DioramaTileID: Int64] = [:]
    /// What each tile costs to stream, from the published catalogue.
    private(set) var catalogSizes: [DioramaTileID: TileSize] = [:]
    private(set) var catalogRevision: Int = 0

    @ObservationIgnored var onInstall: ((DioramaTileID) -> Void)?
    /// Map network policy (offline viewing / Low Data Mode). Streaming never runs when this is false.
    @ObservationIgnored var allowsNetwork: () -> Bool = { true }

    private struct Job: Hashable {
        let tile: DioramaTileID
        let context: Bool
    }
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var catalog: DioramaPrebakedScenery.Catalog?
    /// Compact ZPK1 packages (about a quarter of the size); preferred whenever published.
    @ObservationIgnored private var compactCatalog: DioramaPrebakedScenery.Catalog?
    nonisolated static let compactPrefix = "zpk-"
    @ObservationIgnored private var catalogFetched: Date = .distantPast
    @ObservationIgnored private var retryAfter: Date = .distantPast
    @ObservationIgnored private var failed: [Job: Date] = [:]
    /// Detail levels are built after a piece is already on screen, one tile at a time, at background priority.
    @ObservationIgnored private var detailQueue: [Job] = []
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    /// Live download progress of the current piece (bytes received, bytes expected).
    private(set) var progress: (received: Int64, expected: Int64)?
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: c)
    }()

    private init() { refreshSaved() }

    /// Full detail only for the tile the camera is over (or within this distance of its edge).
    /// Neighbours stay on their small surroundings package until the camera moves onto them.
    nonisolated static let fullDetailReach: Double = 120

    func refreshSaved() {
        readyTiles = Set(region.tiles.filter { DioramaOfflineStore.hasSavedPackage($0, context: true) })
    }

    /// Called on each diorama camera update. Builds the nearest-first wanted list and starts the queue.
    func request(center: CLLocationCoordinate2D, zoom: Double, minimumZoom: Double, fullDetailZoom: Double) {
        guard UIApplication.shared.applicationState == .active else { return }
        lastRequest = (center, zoom, minimumZoom, fullDetailZoom)
        resumeDetailLevels()
        let ranked = region.tiles.map { ($0, Self.distance(from: center, to: $0)) }
            .filter { $0.1 <= 1500 }
            .sorted { ($0.1, $0.0.key) < ($1.1, $1.0.key) }
        if isNearby != !ranked.isEmpty { isNearby = !ranked.isEmpty }
        guard !ranked.isEmpty else { return }
        // Near the harbour: say exactly why nothing is downloading instead of failing silently.
        let missing = ranked.contains { !DioramaOfflineStore.hasSavedPackage($0.0, context: true) }
        // A published piece set replaces whole-package streaming: pieces are view-dependent and
        // drawn as received. Until the piece catalogue has been checked, nothing downloads.
        let pieces = DioramaPieceStreamer.shared
        if missing { pieces.refreshCatalog() }
        if missing, pieces.holdsPackageStreaming {
            if pieces.isPublished, !status.isEmpty { status = "" }
            return
        }
        func blocked(_ reason: String) {
            guard missing, status != reason else { return }
            status = reason
            print("[Stream] blocked: \(reason)")
        }
        let networkAllowed = allowsNetwork()
        if isBlockedByDownloadedOnly != (!networkAllowed && missing) { isBlockedByDownloadedOnly = !networkAllowed && missing }
        guard networkAllowed else {
            return blocked("“Downloaded maps only” is on · harbour 3D can't stream")
        }
        guard !DioramaDownloadService.isProcessing else {
            return blocked("Harbour streaming waits for the current preparation/optimizing to finish")
        }
        guard zoom >= minimumZoom - 0.5 else {
            return blocked("Zoom in closer to the harbour to stream its 3D scenery")
        }
        guard Date() >= retryAfter else { return }
        if missing, task == nil, status.isEmpty || status.hasPrefix("Zoom in") || status.hasPrefix("Harbour s") || status.hasPrefix("“Downloaded") {
            status = "Starting harbour stream…"
        }
        var jobs: [Job] = ranked.map { Job(tile: $0.0, context: true) }
        if zoom >= fullDetailZoom - 0.5 {
            jobs += ranked.filter { $0.1 <= Self.fullDetailReach }.map { Job(tile: $0.0, context: false) }
        }
        let now = Date()
        jobs = jobs.filter { !DioramaOfflineStore.hasSavedPackage($0.tile, context: $0.context) && (failed[$0] ?? .distantPast) <= now }
        guard !jobs.isEmpty else { return }
        queue = jobs
        if task == nil { run() }
    }

    @ObservationIgnored private var lastRequest: (CLLocationCoordinate2D, Double, Double, Double)?
    /// Re-runs the last camera request (after the user removes a blocker from the map pill).
    func retryLast() {
        guard let r = lastRequest else { return }
        retryAfter = .distantPast
        request(center: r.0, zoom: r.1, minimumZoom: r.2, fullDetailZoom: r.3)
    }

    /// Explains in Settings why nothing streams when the 3D scenery switch is off.
    func noteDisabled(near center: CLLocationCoordinate2D) {
        guard region.tiles.contains(where: { Self.distance(from: center, to: $0) <= 1500 }) else { return }
        let reason = "3D scenery is turned off · turn on Masaki 3D diorama in Settings to stream the harbour"
        isNearby = true
        if status != reason { status = reason; print("[Stream] blocked: diorama off") }
    }

    func pause() {
        task?.cancel(); task = nil; queue.removeAll()
        isStreaming = false
    }

    /// Catalogue sizes for the settings screen, without downloading any scenery.
    func loadCatalogSizes() {
        Task { try? await refreshCatalogs() }
    }

    private func run() {
        isStreaming = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.isStreaming = false }
            while !Task.isCancelled, !self.queue.isEmpty {
                let job = self.queue.removeFirst()
                guard !DioramaOfflineStore.hasSavedPackage(job.tile, context: job.context) else { continue }
                guard self.allowsNetwork(), !DioramaDownloadService.isProcessing else { return }
                let label = job.context ? "surroundings" : "full detail"
                do {
                    self.status = "Fetching harbour \(label)…"
                    try await self.refreshCatalogs()
                    let expected = job.context ? self.catalogSizes[job.tile]?.coarse : self.catalogSizes[job.tile]?.full
                    self.status = "Downloading harbour \(label)" + (expected.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "") + "…"
                    print("[Stream] start \(job.tile.key) \(label)")
                    let bytes = try await self.stream(job)
                    self.progress = nil
                    self.downloaded[job.tile, default: 0] += bytes
                    // Draw now. Detail levels (the largest part of the old download) are built on the
                    // phone afterwards, in the background, without holding the piece off screen.
                    self.refreshSaved()
                    self.status = "Streamed \(job.tile.key) \(label) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
                    print("[Stream] \(job.tile.key) \(label) installed bytes=\(bytes)")
                    self.onInstall?(job.tile)
                    self.scheduleDetailLevels(job)
                } catch is CancellationError {
                    return
                } catch DioramaPrebakedScenery.Failure.unavailable {
                    self.status = "\(self.region.displayName) scenery is not published yet · native map shown"
                    self.retryAfter = Date().addingTimeInterval(120)
                    self.queue.removeAll(); return
                } catch {
                    self.progress = nil
                    self.failed[job] = Date().addingTimeInterval(60)
                    let offline = (error as? URLError)?.networkUnavailableReason == .constrained
                    self.status = offline ? "Low Data Mode is on · harbour scenery can't stream"
                        : "Could not stream harbour \(label) (\(Self.describe(error))) · retrying in 1 min"
                    print("[Stream] \(job.tile.key) context=\(job.context) failed: \(error)")
                }
            }
        }
    }

    /// Builds the tile's distance detail levels after it is already drawn. Runs one tile at a time at
    /// background priority; the tile keeps drawing full detail until the sidecar exists, then its next
    /// read picks the levels up. Never runs while a preparation is using the stores.
    private func scheduleDetailLevels(_ job: Job) {
        if !detailQueue.contains(job) { detailQueue.append(job) }
        guard detailTask == nil else { return }
        detailTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            defer { self.detailTask = nil }
            while !Task.isCancelled, !self.detailQueue.isEmpty {
                // Let the piece mount and any further pieces download first: finishing a build cancels
                // in-flight reads of the store, which would only delay what is already on its way.
                try? await Task.sleep(for: .seconds(8))
                while self.task != nil, !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled else { return }
                let next = self.detailQueue.removeFirst()
                guard !DioramaDownloadService.isProcessing, UIApplication.shared.applicationState == .active else {
                    self.detailQueue.insert(next, at: 0); return
                }
                let started = Date()
                let report = try? await DioramaOfflineStore.store(for: self.region).optimize(next.tile, context: next.context)
                print("[Stream] detail levels \(next.tile.key) context=\(next.context) \(report ?? "failed") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            }
        }
    }

    /// Resumes any detail-level builds that were interrupted by preparation or background.
    func resumeDetailLevels() {
        guard !detailQueue.isEmpty, detailTask == nil, let first = detailQueue.first else { return }
        scheduleDetailLevels(first)
    }

    private func refreshCatalogs() async throws {
        if catalog != nil || compactCatalog != nil, Date().timeIntervalSince(catalogFetched) < 600 { return }
        var compact: DioramaPrebakedScenery.Catalog?
        if let name = region.compactCatalogName { compact = try? await DioramaPrebakedScenery.catalog(named: name) }
        let full = try? await DioramaPrebakedScenery.catalog(region: region)
        guard full != nil || compact != nil else { throw DioramaPrebakedScenery.Failure.unavailable }
        catalog = full; compactCatalog = compact; catalogFetched = Date()
        catalogRevision = compact?.revision ?? full?.revision ?? 0
        var sizes: [DioramaTileID: TileSize] = [:]
        for tile in region.tiles {
            var size = TileSize()
            for context in [true, false] {
                var bytes = Int64(0)
                if let compact, let file = Self.compactFile(for: tile, context: context, in: compact) {
                    bytes = Int64(file.b)
                } else if let full {
                    bytes = Self.files(for: tile, context: context, in: full).reduce(Int64(0)) { $0 + Int64($1.b) }
                }
                if context { size.coarse = bytes } else { size.full = bytes }
            }
            sizes[tile] = size
        }
        catalogSizes = sizes
    }

    /// The tile's newest compact package for one detail mode (`zpk-<package>/package.zpk`).
    nonisolated static func compactFile(for tile: DioramaTileID, context: Bool,
                                        in catalog: DioramaPrebakedScenery.Catalog) -> DioramaPrebakedScenery.File? {
        let suffix = context ? "-context1" : "-focus"
        let marker = "-\(tile.key)-"
        return catalog.files
            .filter { $0.d.hasPrefix(compactPrefix + "v") && $0.d.contains(marker) && $0.d.hasSuffix(suffix) && $0.f == "package.zpk" }
            .max { $0.d.compare($1.d, options: .numeric) == .orderedAscending }
    }

    /// The tile's newest package directory for one detail mode, then the sidecars that name it.
    /// LOD sidecars are skipped: the phone builds them locally from the package after it arrives.
    nonisolated static func files(for tile: DioramaTileID, context: Bool,
                                  in catalog: DioramaPrebakedScenery.Catalog) -> [DioramaPrebakedScenery.File] {
        let suffix = context ? "-context1" : "-focus"
        let marker = "-\(tile.key)-"
        let packages = Set(catalog.files.map(\.d).filter { $0.hasPrefix("v") && $0.contains(marker) && $0.hasSuffix(suffix) })
        guard let package = packages.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else { return [] }
        let main = catalog.files.filter { $0.d == package }
        let sidecars = catalog.files.filter {
            !$0.d.hasPrefix("v") && !$0.d.hasPrefix(DioramaLODStore.prefix) && $0.d.contains("-\(package)-")
        }
        return main + sidecars
    }

    private func stream(_ job: Job) async throws -> Int64 {
        if let compact = compactCatalog, let name = region.compactCatalogName,
           let file = Self.compactFile(for: job.tile, context: job.context, in: compact) {
            do {
                return try await streamCompact(file, catalog: name)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("[Stream] compact \(file.d) failed (\(type(of: error))), using full package")
            }
        }
        guard let catalog else { throw DioramaPrebakedScenery.Failure.unavailable }
        let files = Self.files(for: job.tile, context: job.context, in: catalog)
        guard !files.isEmpty else { throw DioramaPrebakedScenery.Failure.unavailable }
        let store = DioramaOfflineStore.store(for: region)
        let stage = await store.streamStagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        var bytes: Int64 = 0
        // Package first, sidecars after, each installed atomically once all its files verified.
        var directories: [String] = []
        for file in files where !directories.contains(file.d) { directories.append(file.d) }
        for directory in directories {
            try Task.checkCancellation()
            let staged = stage.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            for file in files where file.d == directory {
                try Task.checkCancellation()
                try await DioramaPrebakedScenery.fetch(file, region: region, into: staged, session: session)
                bytes += Int64(file.b)
            }
            try await store.install(directory: directory, staged: staged)
        }
        return bytes
    }

    /// One verified .zpk download, decoded off the main thread into an ordinary package and installed.
    private func streamCompact(_ file: DioramaPrebakedScenery.File, catalog name: String) async throws -> Int64 {
        let package = String(file.d.dropFirst(Self.compactPrefix.count))
        guard package.hasPrefix("v"), package == URL(fileURLWithPath: package).lastPathComponent else {
            throw DioramaPrebakedScenery.Failure.checksum
        }
        let fetchStarted = Date()
        let data = try await DioramaPrebakedScenery.fetchData(file, catalog: name, session: session) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progress = (received, expected)
                let label = file.d.hasSuffix("-context1") ? "surroundings" : "full detail"
                self.status = "Downloading harbour \(label) · \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
            }
        }
        print("[Stream] \(file.d) downloaded \(file.b) bytes in \(String(format: "%.2f", Date().timeIntervalSince(fetchStarted))) s")
        self.status = "Unpacking harbour \(file.d.hasSuffix("-context1") ? "surroundings" : "full detail")…"
        let store = DioramaOfflineStore.store(for: region)
        let stage = await store.streamStagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let staged = stage.appendingPathComponent(package, isDirectory: true)
        let started = Date()
        // The user is looking at a blank harbour: decode at user-initiated priority, not utility.
        let job = Task.detached(priority: .userInitiated) {
            try DioramaStreamPackage.install(data, expectedPackage: package, into: staged)
        }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        try await store.install(directory: package, staged: staged)
        print("[Stream] \(package) from \(file.b) compact bytes, decoded in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        return Int64(file.b)
    }

    /// Short, safe failure reason for the status line (no URLs or internals).
    nonisolated static func describe(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet: return "no internet"
            case .timedOut: return "timed out"
            case .networkConnectionLost: return "connection lost"
            default: return "network \(url.code.rawValue)"
            }
        }
        if let failure = error as? DioramaPrebakedScenery.Failure {
            switch failure {
            case .checksum: return "download check failed"
            case .unavailable: return "not published"
            case .rejected: return "server refused"
            }
        }
        if error is DioramaTileArchive.ArchiveError { return "package unreadable" }
        return String(describing: type(of: error))
    }

    /// True on Wi-Fi/wired (not expensive, not Low Data Mode).
    nonisolated static func isUnmetered() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            nonisolated(unsafe) var resumed = false
            monitor.pathUpdateHandler = { path in
                guard !resumed else { return }
                resumed = true
                monitor.cancel()
                done.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "zuri.stream.path"))
        }
    }

    nonisolated static func distance(from centre: CLLocationCoordinate2D, to tile: DioramaTileID) -> Double {
        let rect = DioramaProjection(origin: centre).rect(of: tile)
        return hypot(min(rect.maxX, max(rect.minX, 0)), min(rect.maxY, max(rect.minY, 0)))
    }
}
