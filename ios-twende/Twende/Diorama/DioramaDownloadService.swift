import Foundation
import Observation
import UIKit
import MapboxMaps

/// Explicit foreground preparation; no downloading or meshing is started by the map camera.
@Observable @MainActor
final class DioramaDownloadService {
    static let shared = DioramaDownloadService()
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
    private(set) var isPublishing: Bool = false
    private(set) var publishMessage: String = ""
    var isFullyOptimized: Bool { optimized == total }
    @ObservationIgnored private var pauseReason: String?
    var total: Int { DioramaOfflineStore.tiles.count }
    var progress: Double { Double(completed) / Double(max(1, total)) }
    var canView: Bool { isPrepared && !isRunning && maps?.isReady(Self.area) == true && maps?.downloadedOnly == true }
    var basemapReady: Bool { maps?.isReady(Self.area) == true }
    private weak var maps: OfflineMapService?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var policyTimer: Timer?
    private static var area: OfflineMapArea { OfflineMapArea.areas[1] }

    func configure(maps: OfflineMapService) {
        self.maps = maps
        refresh()
    }
    func refresh() {
        guard !isRunning else { return }
        Task {
            let inventory = await DioramaOfflineStore.shared.inventory()
            guard !isRunning else { return }
            completed = inventory.complete; bytes = inventory.bytes
            isPrepared = completed == total
            var count = 0
            for tile in DioramaOfflineStore.tiles where await DioramaOfflineStore.shared.isOptimized(tile, context: false) { count += 1 }
            optimized = count
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
        message = "Masaki ready · map network disabled · prepared geometry only"
        notify()
        DioramaState.shared.cameraFlyRequest += 1
    }
    func invalidate() {
        isPrepared = false
        message = "A saved tile is missing or damaged. Resume preparation to repair it."
        notify()
    }
    func start() {
        print("[MasakiDownload] Start requested")
        guard task == nil else {
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
        isRunning = true; isPrepared = false; message = "Preparing Masaki. Keep the app open; charging is recommended."
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
                if ownsBasemapDownload && maps.activeID == Self.area.id { maps.pause() }
                self.isRunning = false; self.task = nil
                self.isDownloadingBasemap = false; self.isPausing = false
                self.policyTimer?.invalidate(); self.policyTimer = nil
                self.notify()
            }
            do {
                try await DioramaOfflineStore.shared.checkSpace()
                try Task.checkCancellation()
                if !maps.isReady(Self.area) {
                    isDownloadingBasemap = true
                    stage = "Step 1 of 2 · Downloading peninsula basemap and style…"
                    print("[MasakiDownload] Basemap download starting")
                    try Task.checkCancellation()
                    ownsBasemapDownload = true
                    maps.download(Self.area)
                    let deadline = Date().addingTimeInterval(1800)
                    while !maps.isReady(Self.area) {
                        try Task.checkCancellation()
                        guard Date() < deadline else { throw DioramaOfflineStore.Failure.source }
                        if maps.activeID == nil {
                            // Completion refresh is asynchronous; allow its local inventory callback.
                            try await Task.sleep(for: .seconds(1))
                            guard maps.isReady(Self.area) else { throw DioramaOfflineStore.Failure.source }
                        } else { try await Task.sleep(for: .milliseconds(300)) }
                    }
                }
                isDownloadingBasemap = false
                // Pre-baked packages from the project backend replace slow on-device preparation.
                do {
                    stage = "Checking for pre-baked scenery…"
                    let catalog = try await DioramaPrebakedScenery.catalog()
                    let installed = try await DioramaPrebakedScenery.download(catalog) { [weak self] done, all in
                        self?.stage = "Downloading pre-baked scenery · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: all, countStyle: .file))"
                    }
                    print("[MasakiDownload] Pre-baked catalogue r\(catalog.revision): \(installed) directories installed")
                } catch is CancellationError { throw CancellationError() }
                catch { print("[MasakiDownload] Pre-baked scenery unavailable; preparing on device") }
                print("[MasakiDownload] Basemap ready; preparing geometry")
                completed = 0
                for tile in DioramaOfflineStore.tiles {
                    try Task.checkCancellation()
                    stage = "Preparing tile \(completed + 1) of \(total) · full detail + surroundings"
                    let job = Task.detached(priority: .utility) {
                        try await Self.prepare(tile, token: token)
                    }
                    try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                    completed += 1
                    if completed % 10 == 0 || completed == total {
                        let inventory = await DioramaOfflineStore.shared.inventory()
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
                reportFailure(isDownloadingBasemap ? "The peninsula basemap download did not finish. Check your connection and retry. Saved progress is kept." : detail)
            }
        }
    }
    /// One-time pixel-error LOD bake for every saved tile, serial and resumable.
    private func optimizeAll() async throws {
        optimized = 0
        for (i, tile) in DioramaOfflineStore.tiles.enumerated() {
            try Task.checkCancellation()
            stage = "Optimizing tile \(i + 1) of \(total) · pixel-accurate detail levels"
            for context in [false, true] {
                let job = Task.detached(priority: .utility) { try await DioramaOfflineStore.shared.optimize(tile, context: context) }
                let report = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                if !context, let report, report != "already optimized" { print("[MasakiDownload] \(tile.key) \(report)") }
            }
            optimized += 1
            notify()
        }
    }

    /// Runs only the optimize step on already-prepared scenery (no network).
    func optimizeOnly() {
        guard task == nil, isPrepared else { return }
        if UIApplication.shared.applicationState != .active || ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            reportFailure("Optimizing needs the app open, Low Power Mode off and a cool device. Saved scenery is unchanged."); return
        }
        isRunning = true; failureMessage = nil
        message = "Optimizing saved scenery. Keep the app open; originals are untouched."
        notify()
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.task = nil; self.notify() }
            do {
                try await self.optimizeAll()
                self.message = "Optimized: distant scenery now draws only detail you can see."
                self.stage = "All \(self.total) tiles optimized"
                DioramaState.shared.regenerateRequest += 1
            } catch is CancellationError {
                self.message = "Paused. Optimized tiles are kept; resume when ready."
            } catch {
                self.reportFailure("Optimization stopped: a saved tile could not be read. Originals are untouched.")
            }
        }
    }

    /// Publisher only: upload this device's prepared + optimized scenery as the pre-baked catalogue.
    func publish() {
        guard task == nil, isPrepared, !isPublishing else { return }
        isPublishing = true; publishMessage = "Uploading…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isPublishing = false; self.task = nil }
            do {
                let count = try await DioramaPrebakedScenery.publish { [weak self] done, all in
                    self?.publishMessage = "Uploading \(done) of \(all) files…"
                }
                self.publishMessage = "Published \(count) files. New installs download this instead of preparing."
            } catch {
                self.publishMessage = (error as? LocalizedError)?.errorDescription ?? "Upload failed. Check the connection and key, then retry."
            }
        }
    }

    nonisolated private static func prepare(_ tile: DioramaTileID, token: String) async throws {
        let store = DioramaOfflineStore.shared
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
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return "Preparation paused because the device is too warm. Let it cool, then resume."
        }
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
        if maps?.activeID == Self.area.id { maps?.pause() }
    }
    func remove() {
        guard task == nil else { return }
        isPrepared = false; notify()
        task = Task {
            defer { task = nil }
            do {
                try await DioramaOfflineStore.shared.removeAll()
                completed = 0; bytes = 0
                message = "Masaki 3D files removed. Shared basemap downloads are managed separately."
            } catch { message = "Could not remove saved files. Try again." }
            notify()
        }
    }
    private func notify() {
        NotificationCenter.default.post(name: DioramaState.renderSettingsChanged, object: DioramaState.shared)
    }
}
