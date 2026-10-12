import Foundation
import Observation
import UIKit
import MapboxMaps

/// Explicit foreground preparation; no downloading or meshing is started by the map camera.
@Observable @MainActor
final class DioramaDownloadService {
    static let shared = DioramaDownloadService()
    static let harbour = DioramaDownloadService(region: .harbour)
    static let golf = DioramaDownloadService(region: .golf)
    static let all: [DioramaDownloadService] = [shared, harbour, golf]
    static func service(for region: DioramaRegion) -> DioramaDownloadService {
        switch region {
        case .masaki: shared
        case .harbour: harbour
        case .golf: golf
        }
    }
    let region: DioramaRegion
    /// Masaki-only behaviours (pre-baked catalogue, publisher, fly-to) key off this.
    var isHarbour: Bool { region != .masaki }
    var regionName: String { region.displayName }
    private var store: DioramaOfflineStore { DioramaOfflineStore.store(for: region) }
    private var tiles: [DioramaTileID] { region.tiles }
    static var isProcessing: Bool { all.contains { $0.isRunning } }
    /// Prepared regions plus streamed tiles whose surroundings package has arrived.
    static var viewableTiles: [DioramaTileID] {
        let prepared = all.flatMap { $0.canView ? $0.region.tiles : [] }
        let streamed = DioramaSceneryStreamer.shared.readyTiles.subtracting(prepared).sorted { $0.key < $1.key }
        return prepared + streamed
    }
    init(region: DioramaRegion = .masaki) {
        self.region = region
        if region != .masaki { message = "Download and prepare \(region.displayName) before viewing." }
    }
    private(set) var isPrepared: Bool = false
    private(set) var isRunning: Bool = false
    private(set) var completed: Int = 0
    private(set) var bytes: Int64 = 0
    private(set) var message: String = "Download and prepare Masaki before viewing."
    private(set) var stage: String = ""
    var failureMessage: String?
    private(set) var isDownloadingBasemap: Bool = false
    private(set) var isPausing: Bool = false
    private(set) var optimized: Int = 0
    private(set) var joined: Int = 0
    private(set) var isPublishing: Bool = false
    private(set) var publishMessage: String = ""
    var isFullyOptimized: Bool { optimized == total }
    @ObservationIgnored private var pauseReason: String?
    var total: Int { tiles.count }
    var progress: Double { Double(completed) / Double(max(1, total)) }
    var canView: Bool { isPrepared && !isRunning && maps?.isReady(area) == true }
    var basemapReady: Bool { maps?.isReady(area) == true }
    private weak var maps: OfflineMapService?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var policyTimer: Timer?
    private var area: OfflineMapArea {
        switch region {
        case .masaki: OfflineMapArea.areas[1]
        case .harbour: OfflineMapArea.harbour
        case .golf: OfflineMapArea.golf
        }
    }

    func configure(maps: OfflineMapService) {
        self.maps = maps
        refresh()
    }
    func refresh() {
        guard !isRunning else { return }
        if pauseReason?.contains("warm") == true || message.contains("too warm") {
            pauseReason = nil; message = "Ready to resume."
        }
        Task {
            let inventory = await store.inventory()
            guard !isRunning else { return }
            completed = inventory.complete; bytes = inventory.bytes
            isPrepared = total > 0 && completed == total
            var count = 0
            for tile in tiles where await store.isOptimized(tile, context: false) { count += 1 }
            optimized = count
            defer { autoOptimizeIfSuitable(); contributeIfCatalogueEmpty() }
            var repaired = 0
            for tile in tiles {
                if await store.isJoined(tile, context: false),
                   await store.isJoined(tile, context: true) { repaired += 1 }
            }
            joined = repaired
            if !isPrepared && bytes > 0 && message == "Download and prepare Masaki before viewing." {
                message = "Your saved scenery is kept across app updates. Resume only to finish missing tiles; completed tiles and saved sources are reused."
            }
            notify()
        }
    }
    func viewOffline() {
        guard isPrepared, basemapReady, let maps else { return }
        maps.downloadedOnly = true
        DioramaState.shared.isEnabled = true
        message = "\(regionName) ready · map network disabled · prepared geometry only"
        notify()
        if !isHarbour { DioramaState.shared.cameraFlyRequest += 1 }
    }
    func invalidate() {
        isPrepared = false
        message = "A saved tile is missing or damaged. Resume preparation to repair it."
        notify()
    }
    func start() {
        print("[MasakiDownload] Start requested")
        guard !Self.isProcessing, task == nil, total > 0 else {
            reportFailure("Masaki files are already being processed. Wait for the current operation to finish."); return
        }
        guard let maps else {
            reportFailure("Map downloads are not ready. Close and reopen this screen, then try again."); return
        }
        guard maps.activeID == nil else {
            reportFailure("Another map download is running. Pause it in Offline maps or wait for it to finish, then try again."); return
        }
        guard maps.removingIDs.isEmpty else {
            reportFailure("Saved maps are being removed. Wait for removal to finish, then try again."); return
        }
        if let restriction = preparationRestriction {
            reportFailure(restriction); return
        }
        failureMessage = nil; pauseReason = nil; isPausing = false
        stage = "Checking available storage…"
        isRunning = true; isPrepared = false; message = "Preparing \(regionName). Keep the app open; charging is recommended."
        print("[MasakiDownload] Preparation started")
        notify()
        policyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let reason = self.preparationRestriction {
                    self.pause(reason: reason)
                }
            }
        }
        let token = MapboxOptions.accessToken
        task = Task { [weak self] in
            guard let self else { return }
            var ownsBasemapDownload = false
            defer {
                if ownsBasemapDownload && maps.activeID == area.id { maps.pause() }
                self.isRunning = false; self.task = nil
                self.isDownloadingBasemap = false; self.isPausing = false
                self.policyTimer?.invalidate(); self.policyTimer = nil
                self.notify()
            }
            do {
                try await store.checkSpace()
                try Task.checkCancellation()
                if !maps.isReady(area) {
                    isDownloadingBasemap = true
                    stage = "Step 1 of 2 · Downloading \(regionName) basemap and style…"
                    print("[MasakiDownload] Basemap download starting")
                    try Task.checkCancellation()
                    ownsBasemapDownload = true
                    maps.download(area)
                    let deadline = Date().addingTimeInterval(1800)
                    while !maps.isReady(area) {
                        try Task.checkCancellation()
                        guard Date() < deadline else { throw DioramaOfflineStore.Failure.source }
                        if maps.activeID == nil {
                            // Completion refresh is asynchronous; allow its local inventory callback.
                            try await Task.sleep(for: .seconds(1))
                            guard maps.isReady(area) else { throw DioramaOfflineStore.Failure.source }
                        } else { try await Task.sleep(for: .milliseconds(300)) }
                    }
                }
                isDownloadingBasemap = false
                // Pre-baked packages from the project backend replace slow on-device preparation.
                do {
                    stage = "Checking for pre-baked scenery…"
                    if !isHarbour {
                        let catalog = try await DioramaPrebakedScenery.catalog()
                        let installed = try await DioramaPrebakedScenery.download(catalog) { [weak self] done, all in
                            self?.stage = "Downloading pre-baked scenery · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: all, countStyle: .file))"
                        }
                        print("[MasakiDownload] Pre-baked catalogue r\(catalog.revision): \(installed) directories installed")
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { print("[MasakiDownload] Pre-baked scenery unavailable; preparing on device") }
                print("[MasakiDownload] Basemap ready; preparing geometry")
                completed = 0
                for tile in tiles {
                    try Task.checkCancellation()
                    stage = "Preparing tile \(completed + 1) of \(total) · full detail + surroundings"
                    let job = Task.detached(priority: .utility) {
                        try await Self.prepare(tile, token: token)
                    }
                    try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                    completed += 1
                    if completed % 10 == 0 || completed == total {
                        let inventory = await store.inventory()
                        bytes = inventory.bytes
                    }
                }
                try Task.checkCancellation()
                try await optimizeAll()
                isPrepared = true
                maps.downloadedOnly = true
                message = "Ready offline. No downloads or geometry generation while viewing."
                stage = "All \(total) tiles prepared"
            } catch is CancellationError {
                message = pauseReason ?? "Paused. Completed tiles are kept; resume when ready."
                print("[MasakiDownload] Preparation paused")
            } catch {
                let detail = (error as? DioramaOfflineStore.Failure)?.errorDescription ?? "Preparation could not finish. Check connection and free storage, then resume."
                reportFailure(isDownloadingBasemap ? (maps.failureDetails[area.id] ?? "The \(regionName) basemap could not finish or confirm readiness. Resume to retry; saved progress is kept.") : detail)
            }
        }
    }
    /// One-time pixel-error LOD bake for every saved tile, serial and resumable.
    private func optimizeAll() async throws {
        optimized = 0
        let store = self.store
        for (i, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            stage = "Optimizing tile \(i + 1) of \(total) · pixel-accurate detail levels"
            for context in [false, true] {
                let job = Task.detached(priority: .utility) { try await store.optimize(tile, context: context) }
                let report = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                if !context, let report, report != "already optimized" { print("[MasakiDownload] \(tile.key) \(report)") }
            }
            optimized += 1
            notify()
        }
    }

    private var warmTask: Task<Void, Never>?
    private var warmFinished: Bool = false
    private var warmObserver: NSObjectProtocol?

    /// Decodes each saved tile once, serially and read-only, so first visits map a GPU-ready snapshot
    /// instead of decompressing, checking and tagging the whole package while the user waits. Runs on
    /// every device without pausing visible scenery; one decoded tile at a time, stopped for the session
    /// by a memory warning, cancelled in the background and resumed (skipping finished tiles) later.
    private func warmSnapshotsIfSuitable() {
        guard isPrepared, optimized >= total, !warmFinished, warmTask == nil, !Self.isProcessing,
              UIApplication.shared.applicationState == .active,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue else { return }
        if warmObserver == nil {
            warmObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.warmFinished = true; self?.warmTask?.cancel() }
            }
            for name in [UIApplication.willResignActiveNotification, .NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if UIApplication.shared.applicationState != .active || ProcessInfo.processInfo.isLowPowerModeEnabled
                            || ProcessInfo.processInfo.thermalState.rawValue > ProcessInfo.ThermalState.fair.rawValue {
                            self.warmTask?.cancel()
                        }
                    }
                }
            }
        }
        warmTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.warmSnapshots()
                self.warmFinished = true
                print("[MasakiDownload] \(self.regionName): fast-loading snapshots ready")
            } catch {}
            self.warmTask = nil
        }
    }

    private func warmSnapshots() async throws {
        let store = self.store
        for tile in tiles {
            for context in [true, false] {
                try Task.checkCancellation()
                // Never decode alongside explicit maintenance, which rewrites packages.
                while Self.isProcessing { try await Task.sleep(for: .seconds(1)) }
                let job = Task.detached(priority: .utility) { await store.warmSnapshot(tile, context: context) }
                let wrote = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                // Hold at most one decoded tile at a time: let its snapshot write finish first.
                var waited = 0
                while wrote, DioramaResidentSnapshot.hasPendingWrites, waited < 600 {
                    try await Task.sleep(for: .milliseconds(100)); waited += 1
                }
            }
        }
    }

    /// Runs the one-time optimize step automatically, so detail levels are active without a
    /// Settings visit. Only in the foreground, off Low Power, cool, and charging or above 40%.
    private func autoOptimizeIfSuitable() {
        if optimized >= total { warmSnapshotsIfSuitable(); return }
        guard isPrepared, !Self.isProcessing, task == nil,
              UIApplication.shared.applicationState == .active,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current
        let powered = battery.batteryState == .charging || battery.batteryState == .full
        guard powered || battery.batteryLevel < 0 || battery.batteryLevel >= 0.4 else { return }
        print("[MasakiDownload] \(regionName): \(optimized)/\(total) tiles optimized; optimizing automatically")
        optimizeOnly()
    }

    /// Runs only the optimize step on already-prepared scenery (no network).
    func optimizeOnly() {
        guard !Self.isProcessing, task == nil, isPrepared else { return }
        if UIApplication.shared.applicationState != .active || ProcessInfo.processInfo.isLowPowerModeEnabled {
            reportFailure("Optimizing needs the app open and Low Power Mode off. Saved scenery is unchanged."); return
        }
        isRunning = true; failureMessage = nil
        message = "Optimizing saved scenery. Keep the app open; originals are untouched."
        notify()
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.isPausing = false; self.task = nil; self.notify() }
            do {
                try await self.optimizeAll()
                self.message = "Optimized: distant scenery now draws only detail you can see."
                self.stage = "All \(self.total) tiles optimized"
                DioramaState.shared.regenerateRequest += 1
                Task { @MainActor [weak self] in self?.warmSnapshotsIfSuitable() }
            } catch is CancellationError {
                self.message = "Paused. Optimized tiles are kept; resume when ready."
            } catch {
                self.reportFailure("Optimization stopped: a saved tile could not be read. Originals are untouched.")
            }
        }
    }

    /// Explicit offline migration. Reconstruct support, geometry and paint together rather than
    /// lifting saved ground underneath unchanged buildings. No catalogue or source network calls.
    func repairJoins() {
        guard !Self.isProcessing, task == nil, isPrepared else { return }
        guard UIApplication.shared.applicationState == .active,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            reportFailure("Repair needs the app open and Low Power Mode off. Originals are unchanged."); return
        }
        isRunning = true; isPausing = false; failureMessage = nil; pauseReason = nil
        message = "Rebuilding architecture, terrain and roads from saved sources. No downloads; original scenery stays saved."
        policyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if UIApplication.shared.applicationState != .active || ProcessInfo.processInfo.isLowPowerModeEnabled {
                    self.pause(reason: "Repair paused. Keep the app open and Low Power Mode off.")
                }
            }
        }
        notify()
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.policyTimer?.invalidate(); self.policyTimer = nil
                self.isRunning = false; self.isPausing = false; self.task = nil
                self.refresh(); self.notify(); DioramaState.shared.regenerateRequest += 1
            }
            do {
                joined = 0
                for (i, tile) in tiles.enumerated() {
                    try Task.checkCancellation()
                    guard UIApplication.shared.applicationState == .active,
                          !ProcessInfo.processInfo.isLowPowerModeEnabled else { throw CancellationError() }
                    stage = "Rebuilding tile \(i + 1) of \(total) · architecture + roads + trees"
                    let job = Task.detached(priority: .utility) { try await Self.repair(tile) }
                    try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                    joined += 1
                }
                try await store.activateJoins()
                try await optimizeAll()
                message = "Architectural detail, terrain and roads rebuilt offline. All previous scenery remains saved as fallback."
            } catch is CancellationError {
                message = "Rebuild paused. Completed tiles and all previous scenery are kept; resume when ready."
            } catch {
                reportFailure("Repair stopped: a saved map/elevation source is missing, unreadable, or storage is low. Original scenery is kept. No download was attempted.")
            }
        }
    }

    nonisolated private static func repair(_ tile: DioramaTileID) async throws {
        let store = DioramaOfflineStore.store(for: tile)
        let fullExists = await store.isJoined(tile, context: false)
        let contextExists = await store.isJoined(tile, context: true)
        if fullExists && contextExists { return }
        try await store.checkSpace()
        guard let data = await DioramaMasakiSource.load(tile: tile, config: .slipway, token: "", offline: true),
              data.hasMapboxCoverage, data.sourceTerrain != nil else { throw DioramaOfflineStore.Failure.source }
        try Task.checkCancellation()
        if !contextExists {
            let artifact = try await DioramaGenerationQueue.shared.generateContext(data, config: .slipway)
            try await store.save(artifact, context: true)
        }
        if !fullExists {
            DioramaTileGenerator.clearCache(for: tile, config: .slipway)
            defer { DioramaTileGenerator.clearCache(for: tile, config: .slipway) }
            let artifact = try await DioramaGenerationQueue.shared.generate(data, config: .slipway)
            try await store.save(artifact, context: false)
        }
    }

    @ObservationIgnored private var contributionAttempted: Bool = false
    /// The streaming service seeds itself: once this phone holds the region's compact, optimized
    /// packages and the server catalogue is still empty, they are uploaded once (no key needed;
    /// the server locks the region after the first complete publish). Unmetered connections only.
    func contributeIfCatalogueEmpty() {
        guard region == .harbour, !contributionAttempted, isPrepared, optimized == total, task == nil,
              !isPublishing, !Self.isProcessing, UIApplication.shared.applicationState == .active else { return }
        contributionAttempted = true
        Task { [weak self] in
            guard let self else { return }
            guard await DioramaSceneryStreamer.isUnmetered() else { self.contributionAttempted = false; return }
            guard let catalog = try? await DioramaPrebakedScenery.catalog(region: self.region), catalog.revision == 0 else { return }
            guard !(await DioramaOfflineStore.store(for: self.region).publishableFiles(compactOnly: true)).isEmpty else {
                self.publishMessage = "Run Rebuild once to make compact packages; they then upload automatically for streaming."
                return
            }
            print("[Stream] contributing \(self.regionName) to the empty streaming catalogue")
            self.publish()
        }
    }

    /// Upload this device's prepared + optimized scenery as the region's catalogue.
    func publish() {
        guard region != .golf, task == nil, isPrepared, !isPublishing else { return }
        isPublishing = true; publishMessage = "Uploading…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isPublishing = false; self.task = nil }
            do {
                let count = try await DioramaPrebakedScenery.publish(region: self.region) { [weak self] done, all in
                    self?.publishMessage = "Uploading \(done) of \(all) files…"
                }
                self.publishMessage = self.region == .masaki
                    ? "Published \(count) files. New installs download this instead of preparing."
                    : "Published \(count) compact files. Phones now stream these tiles on demand."
                if self.region != .masaki { DioramaSceneryStreamer.shared.loadCatalogSizes() }
            } catch {
                self.publishMessage = (error as? LocalizedError)?.errorDescription ?? "Upload failed. Check the connection, then retry."
            }
        }
    }

    nonisolated private static func prepare(_ tile: DioramaTileID, token: String) async throws {
        let store = DioramaOfflineStore.store(for: tile)
        let fullExists = await store.isVerified(tile, context: false)
        let contextExists = await store.isVerified(tile, context: true)
        if fullExists && contextExists { return }
        try Task.checkCancellation()
        guard let data = await DioramaMasakiSource.load(tile: tile, config: .slipway, token: token, offline: false), data.hasMapboxCoverage else {
            try Task.checkCancellation()
            throw DioramaOfflineStore.Failure.source
        }
        if !contextExists {
            let context = try await DioramaGenerationQueue.shared.generateContext(data, config: .slipway)
            try await store.save(context, context: true)
        }
        if !fullExists {
            defer { DioramaTileGenerator.clearCache(for: tile, config: .slipway) }
            let full = try await DioramaGenerationQueue.shared.generate(data, config: .slipway)
            try await store.save(full, context: false)
        }
    }
    private var preparationRestriction: String? {
        guard let maps else { return "Map downloads are not ready. Reopen this screen and try again." }
        if let restriction = maps.restriction { return L(restriction) }
        if UIApplication.shared.applicationState != .active { return "Keep the app open to prepare Masaki, then tap Resume." }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Turn off Low Power Mode in iPhone Settings → Battery, then resume preparation." }
        return nil
    }
    private func reportFailure(_ detail: String) {
        message = detail
        failureMessage = detail
        print("[MasakiDownload] \(detail)")
    }
    func pause(reason: String? = nil) {
        guard isRunning, !isPausing else { return }
        isPausing = true
        pauseReason = reason
        message = reason ?? "Pausing preparation… Completed tiles will be kept."
        task?.cancel()
        if maps?.activeID == area.id { maps?.pause() }
    }
    func remove() {
        guard task == nil else { return }
        isPrepared = false; notify()
        task = Task {
            defer { task = nil }
            do {
                try await store.removeAll()
                completed = 0; bytes = 0
                message = "\(regionName) 3D files removed. Shared basemap downloads are managed separately."
            } catch { message = "Could not remove saved files. Try again." }
            notify()
        }
    }
    private func notify() {
        NotificationCenter.default.post(name: DioramaState.renderSettingsChanged, object: DioramaState.shared)
    }
}
