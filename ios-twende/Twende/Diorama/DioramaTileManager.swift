import Foundation
@_spi(Experimental) import MapboxMaps
import UIKit

/// Observable diorama state shared by the map coordinator and the debug panel.
@Observable
@MainActor
final class DioramaState {
    static let shared = DioramaState()

    var isEnabled: Bool = UserDefaults.standard.object(forKey: "zuri.diorama.enabled") as? Bool ?? true {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: "zuri.diorama.enabled")
            notifyRenderer()
        }
    }
    static let renderSettingsChanged = Notification.Name("zuri.diorama.renderSettingsChanged")
    var timeOfDay: DioramaTimeOfDay = DioramaTimeOfDay.from(preset: UserDefaults.standard.string(forKey: "zuri.diorama.timeOfDay") ?? "day") {
        didSet {
            guard timeOfDay != oldValue else { return }
            UserDefaults.standard.set(timeOfDay.rawValue, forKey: "zuri.diorama.timeOfDay")
            notifyRenderer()
        }
    }
    var visibleCategories: Set<DioramaCategory> = Set(DioramaCategory.allCases.filter { $0 != .shorelineDebug }) { didSet { notifyRenderer() } }
    var showsDebugOverlay: Bool = false { didSet { notifyRenderer() } }
    var showsWireframe: Bool = false { didSet { notifyRenderer() } }
    var isBasemapOnly: Bool = false { didSet { notifyRenderer() } }

    private func notifyRenderer() {
        NotificationCenter.default.post(name: Self.renderSettingsChanged, object: self)
    }
    var inspectionTarget: DioramaShoreline.Kind? = nil
    var loadedTiles: [DioramaTileID: DioramaTileSummary] = [:]
    var status: String = ""
    var frameReport: String = "Frame measurements begin after the tile is visible."
    var passReport: String = "Per-pass GPU timings appear once a full-detail tile draws."
    var regenerateRequest: Int = 0
    var cameraFlyRequest: Int = 0

    func toggle(_ category: DioramaCategory) {
        if visibleCategories.contains(category) { visibleCategories.remove(category) } else { visibleCategories.insert(category) }
    }
    var isToggled: (DioramaCategory) -> Bool { { [visibleCategories] in visibleCategories.contains($0) } }
    func isVisible(_ category: DioramaCategory) -> Bool {
        switch category {
        case .windowGlow: visibleCategories.contains(.buildings) && timeOfDay.showsLights
        case .propGlow: visibleCategories.contains(.props) && timeOfDay.showsLights
        default: visibleCategories.contains(category)
        }
    }
}

/// Zoom/projected-scale gated, bounded visible scenery with coarse fallback and joined HD reveals.
@MainActor
final class DioramaTileManager {
    let config: DioramaConfig
    var setBasemapTerrainEnabled: ((Bool) -> Void)?
    /// Turns Standard's native 3D buildings/trees/landmarks off while saved scenery covers the whole view.
    var setNative3DEnabled: ((Bool) -> Void)?
    private var native3DSuppressed: Bool = false
    var viewportBounds: (() -> CGRect)?
    var viewport = DioramaViewport()
    private let state: DioramaState
    private let styling: DioramaMapStyling
    private let contextTiles = DioramaContextTiles()
    private let hdTiles = DioramaHDTiles()
    private let residency: DioramaResidencyBudget
    private var sceneryWasVisible: Bool = false
    private var hdWasRequested: Bool = false
    private var lastOutputPixels: Double = 0
    private weak var map: MapboxMap?
    private var installed: Bool = false
    private var basemapTerrainSuppressed: Bool = false
    private var viewportFocus: DioramaTileID?
    private var visibleTilePriority: [DioramaTileID] = []
    private var pendingUpdate: Task<Void, Never>?
    private var pendingUpdateDeadline: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var exitRequested: Bool = false
    private var reloadRequested: Bool = false
    private var retractionCompletion: (() -> Void)?
    private var debugWasShown: Bool = false
    private var tile: DioramaTileID { viewportFocus ?? DioramaMasakiSource.slipway }
    private var reducesEffects: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
    private var motion: Bool {
        !reducesEffects && !UIAccessibility.isReduceMotionEnabled && UIApplication.shared.applicationState == .active
    }

    init(config: DioramaConfig = .slipway, state: DioramaState? = nil, residencyBudget: DioramaResidencyBudget? = nil) {
        self.residency = residencyBudget ?? DioramaResidencyBudget()
        self.config = config; self.state = state ?? .shared
        styling = DioramaMapStyling(config: config)
        contextTiles.budget = residency; hdTiles.budget = residency
        residency.onAvailable = { [weak self] releasedResident in
            if releasedResident { self?.contextTiles.retryAdmission(); self?.hdTiles.retryAdmission() }
            self?.scheduleUpdate(delay: 0.2)
        }
        contextTiles.onReady = { [weak self] _ in self?.scheduleUpdate(delay: 0) }
        contextTiles.onChanged = { [weak self] in self?.scheduleUpdate(delay: 0.1) }
        contextTiles.onUnavailable = { [weak self] _ in self?.scheduleUpdate(delay: 30) }
        contextTiles.onHDFrameCompleted = { [weak self] tile in self?.hdTiles.resumeArrivalIfStalled(tile) }
        hdTiles.onChanged = { [weak self] in self?.scheduleUpdate(delay: 0.1) }
        hdTiles.onArtifact = { [weak self] tile, artifacts in self?.state.loadedTiles[tile] = artifacts }
        hdTiles.onFrameReport = { [weak self] report in
            guard let self else { return }
            self.state.frameReport = report + "\n" + self.contextTiles.report + "\n" + self.hdTiles.report
        }
        let names: [Notification.Name] = [DioramaState.renderSettingsChanged, UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification, UIApplication.didReceiveMemoryWarningNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification, ProcessInfo.thermalStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if DioramaDownloadService.isProcessing {
                        // Explicit local maintenance needs CPU mesh memory, not offscreen GPU
                        // residents waiting indefinitely for retirement frames behind Settings.
                        self.hdTiles.clear(); self.contextTiles.clear(); self.state.loadedTiles.removeAll()
                        self.suppressBasemapTerrain(false)
                        self.exitRequested = false; self.reloadRequested = false
                        let completion = self.retractionCompletion; self.retractionCompletion = nil; completion?()
                    } else if name == UIApplication.willResignActiveNotification {
                        self.hdTiles.clear(); self.contextTiles.clear(); self.suppressBasemapTerrain(false); self.suppressNative3D(false)
                        DioramaPieceStreamer.shared.pause()
                        Task { for region in DioramaRegion.allCases { await DioramaOfflineStore.store(for: region).releaseDecodedMemory() } }
                    } else if name == UIApplication.didReceiveMemoryWarningNotification {
                        self.residency.constrain()
                        self.hdTiles.clear(); self.contextTiles.trimForMemoryWarning(); self.suppressNative3D(false)
                        DioramaPieceStreamer.shared.trimForMemoryWarning()
                        self.suppressBasemapTerrain(self.contextTiles.hasReadyCoverage(in: self.visibleTilePriority))
                        Task { for region in DioramaRegion.allCases { await DioramaOfflineStore.store(for: region).releaseDecodedMemory() } }
                        self.hdSuspendedUntil = Date().addingTimeInterval(30)
                        print("[Diorama HD] memory warning; HD released, base trimmed to focus; conservative allowance; loading paused 30s")
                    }
                    self.applyPolicy(); self.scheduleUpdate(delay: 0)
                }
            })
        }
    }
    private var hdSuspendedUntil: Date = .distantPast

    func install(on map: MapboxMap) {
        self.map = map; installed = true
        DioramaSceneryStreamer.shared.onInstall = { [weak self] tile in
            self?.contextTiles.packageArrived(tile); self?.hdTiles.packageArrived(tile)
            self?.scheduleUpdate(delay: 0)
        }
        DioramaBakedLandmarks.shared.setTileCompletion { tile in
            Task { @MainActor [weak self] in self?.hdTiles.landmarksReady(tile) }
        }
        DioramaPieceStreamer.shared.onChanged = { [weak self] in self?.scheduleUpdate(delay: 0.1) }
        scheduleUpdate(delay: 0)
    }
    func styleDidReload() {
        hdTiles.clear(); contextTiles.clear(); state.loadedTiles.removeAll()
        DioramaPieceStreamer.shared.clear()
        installed = false; basemapTerrainSuppressed = false; exitRequested = false; reloadRequested = false
        native3DSuppressed = false
        let completion = retractionCompletion; retractionCompletion = nil; completion?()
    }
    func remove() {
        pendingUpdate?.cancel(); pendingUpdate = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        hdTiles.clear(); contextTiles.clear(); state.loadedTiles.removeAll()
        DioramaPieceStreamer.shared.clear()
        if let map { styling.remove(from: map) }
        suppressBasemapTerrain(false); suppressNative3D(false); installed = false
    }
    private func suppressBasemapTerrain(_ suppress: Bool) {
        guard suppress != basemapTerrainSuppressed else { return }
        basemapTerrainSuppressed = suppress; setBasemapTerrainEnabled?(!suppress)
    }
    private func suppressNative3D(_ suppress: Bool) {
        guard suppress != native3DSuppressed else { return }
        native3DSuppressed = suppress; setNative3DEnabled?(!suppress)
    }

    /// True only when every ground point of the view, plus a band beyond its top edge (tall native
    /// buildings just past it still project into view), lies on ready saved scenery. Native 3D there is
    /// fully clipped anyway, so the SDK's model/extrusion work is pure waste. Any doubt keeps native 3D.
    private func viewIsFullyOwned(on map: MapboxMap) -> Bool {
        let bounds = viewportBounds?() ?? .zero
        guard bounds.width > 1, bounds.height > 1, map.cameraState.pitch <= 62 else { return false }
        let steps = 9, hd = Set(hdTiles.tiles)
        for row in 0...steps {
            for column in 0...steps {
                let screen = CGPoint(x: bounds.minX + bounds.width * Double(column) / Double(steps),
                    y: bounds.minY - bounds.height * 0.2 + bounds.height * 1.2 * Double(row) / Double(steps))
                let c = map.coordinate(for: screen)
                guard c.latitude.isFinite, c.longitude.isFinite, abs(c.latitude) <= 85 else { return false }
                let back = map.point(for: c)
                guard back.x.isFinite, back.y.isFinite, hypot(back.x - screen.x, back.y - screen.y) < 4 else { return false }
                let tile = DioramaTileID(latitude: c.latitude, longitude: c.longitude, zoom: 16)
                guard contextTiles.isReady(tile) || hd.contains(tile) || DioramaPieceStreamer.shared.covers(tile) else { return false }
            }
        }
        return true
    }
    private func applyPolicy() {
        hdTiles.setPolicy(categories: state.visibleCategories, time: state.timeOfDay,
            wireframe: state.showsWireframe, reduced: reducesEffects, motion: motion)
        contextTiles.setReducedEffects(reducesEffects, waterMotion: motion)
        map?.triggerRepaint()
    }
    func introCamera() -> CameraOptions {
        if let kind = state.inspectionTarget, let data = DioramaBundledTile.load(config: config),
           let segment = data.shorelines.filter({ $0.kind == kind }).max(by: { $0.length < $1.length }) {
            let p = segment.points[segment.points.count / 2], coordinate = data.projection.coordinate(p)
            return CameraOptions(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                zoom: 18, bearing: config.cameraBearing, pitch: config.cameraPitch)
        }
        return CameraOptions(center: DioramaMasakiSource.slipway.centre, zoom: config.cameraZoom,
            bearing: config.cameraBearing, pitch: config.cameraPitch)
    }
    func groundHeight(at point: GeoPoint) -> Double? {
        guard state.isEnabled, !state.isBasemapOnly, !exitRequested else { return nil }
        return hdTiles.groundHeight(at: point) ?? contextTiles.groundHeight(at: point) ?? DioramaPieceStreamer.shared.groundHeight(at: point)
    }
    func scheduleUpdate(delay: Double) {
        let deadline = CACurrentMediaTime() + max(0, delay)
        if pendingUpdate != nil, pendingUpdateDeadline <= deadline { return }
        pendingUpdate?.cancel(); pendingUpdateDeadline = deadline
        pendingUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
            guard let self else { return }
            self.pendingUpdate = nil; self.update()
        }
    }
    func update() {
        guard installed, let map, UIApplication.shared.applicationState == .active else { return }
        let pieces = DioramaPieceStreamer.shared
        if state.isEnabled, !state.isBasemapOnly {
            // Streamed regions fetch nearby pieces on demand; the native map shows until they arrive.
            DioramaSceneryStreamer.shared.request(center: map.cameraState.center, zoom: map.cameraState.zoom,
                minimumZoom: config.minimumZoom, fullDetailZoom: config.fullDetailMinimumZoom)
            // Finished harbour pieces: view-dependent, drawn as received, independent of saved tiles.
            if !DioramaDownloadService.isProcessing {
                pieces.update(map: map, viewport: viewport, config: config, categories: state.visibleCategories, time: state.timeOfDay,
                              wireframe: state.showsWireframe, reduced: reducesEffects, motion: motion)
            }
        } else if pieces.hasResidents {
            pieces.clear()
        }
        guard state.isEnabled, !state.isBasemapOnly, !DioramaDownloadService.viewableTiles.isEmpty && !DioramaDownloadService.isProcessing,
              retractionCompletion == nil else {
            beginExit()
            // No saved tiles: streamed pieces may still own the ground under the camera.
            if state.isEnabled, !state.isBasemapOnly, retractionCompletion == nil, !DioramaDownloadService.isProcessing {
                let anchor = DioramaTileID(latitude: map.cameraState.center.latitude, longitude: map.cameraState.center.longitude, zoom: config.tileZoom)
                let owned = pieces.covers(anchor)
                suppressNative3D(owned); suppressBasemapTerrain(owned)
            }
            state.status = state.isBasemapOnly ? "Basemap-only comparison" :
                (state.isEnabled ? (pieces.isNearby && pieces.isPublished ? pieces.report + "\n" + pieces.status
                    : DioramaSceneryStreamer.shared.isStreaming ? "Streaming nearby scenery · native map until it arrives"
                    : !DioramaSceneryStreamer.shared.status.isEmpty ? DioramaSceneryStreamer.shared.status
                    : "Download and prepare Masaki before viewing · open Offline maps") : "Masaki diorama disabled")
            return
        }
        let threshold = config.minimumZoom - (sceneryWasVisible ? 0.25 : 0)
        guard map.cameraState.zoom >= threshold else {
            sceneryWasVisible = false; hdWasRequested = false
            beginExit()
            state.status = "Native map only at this distance · custom scenery starts at z\(config.minimumZoom)\n" + residency.report
            return
        }
        sceneryWasVisible = true; exitRequested = false
        let bounds = viewportBounds?() ?? .zero
        let outputSize = CGSize(width: bounds.width * UIScreen.main.scale, height: bounds.height * UIScreen.main.scale)
        let pixels = outputSize.width * outputSize.height
        // A larger drawable only re-runs admission (effect targets are re-estimated); clearing HD here
        // made panel/rotation changes drop and re-read every full-detail tile.
        if lastOutputPixels > 0, pixels > lastOutputPixels * 1.2 { hdTiles.retryAdmission() }
        lastOutputPixels = pixels
        contextTiles.outputSize = outputSize; hdTiles.outputSize = outputSize
        let validViewport = refreshViewportInterest(on: map)
        // Invalid layout retains only the bounded existing working set; never preloads the region.
        guard validViewport else {
            state.status = "Waiting for map layout\n" + residency.report
            scheduleUpdate(delay: 0.1); return
        }
        let wanted: [DioramaTileID]
        let hdThreshold = config.fullDetailMinimumZoom - (hdWasRequested ? 0.25 : 0)
        if map.cameraState.zoom >= hdThreshold, let focus = hdFocus(on: map), Date() >= hdSuspendedUntil {
            // What you are looking at: the tile under the camera's focal point first, then the
            // visible tiles closest to it on the ground. No screen-area ranking or projected-size
            // test, so HD follows focus immediately instead of after a deliberation.
            let centre = map.cameraState.center
            let ranked = Set(visibleTilePriority + [focus]).filter {
                DioramaDownloadService.viewableTiles.contains($0) && abs($0.x - focus.x) <= 1 && abs($0.y - focus.y) <= 1
            }.map { ($0, groundDistance(from: centre, to: $0)) }
                .filter { $0.0 == focus || $0.1 <= 900 }
                .sorted { ($0.0 == focus ? -1 : $0.1, $0.0.key) < ($1.0 == focus ? -1 : $1.1, $1.0.key) }
            wanted = Array(ranked.map(\.0).prefix(residency.hdLimit))
            hdTiles.setRequestState(wanted.isEmpty ? "Distant/horizon scenery uses coarse detail" : "Close foreground HD requested")
        } else {
            wanted = []
            if Date() < hdSuspendedUntil { hdTiles.setRequestState("Memory recovery · base trimmed; conservative HD retry after cooldown") }
            else if map.cameraState.zoom < hdThreshold {
                hdTiles.setRequestState("Coarse distance view · HD starts at z\(config.fullDetailMinimumZoom)")
            } else { hdTiles.setRequestState("No prepared scenery tile intersects the current view") }
        }
        // Resolve HD interest before coarse admission. Its prerequisite bases must be in the
        // bounded working set even when viewport-area ranking/hysteresis chooses a different order.
        let basePriority = wanted + visibleTilePriority.filter { !wanted.contains($0) }
        contextTiles.hdPriority = Set(wanted)
        contextTiles.viewport = viewport
        contextTiles.update(focus: wanted.first ?? tile, config: config, map: map, visible: state.visibleCategories,
            time: state.timeOfDay, wireframe: state.showsWireframe, priorityTiles: basePriority,
            pinnedTiles: hdTiles.tiles, allowsLoading: Date() >= hdSuspendedUntil)
        contextTiles.setReducedEffects(reducesEffects, waterMotion: motion)
        suppressBasemapTerrain(contextTiles.hasReadyCoverage(in: visibleTilePriority) || pieces.hasResidents)
        suppressNative3D(viewIsFullyOwned(on: map))
        hdWasRequested = !wanted.isEmpty
        hdTiles.update(wanted: wanted, visibleTiles: visibleTilePriority, map: map, base: contextTiles, viewport: viewport, config: config,
            categories: state.visibleCategories, time: state.timeOfDay, wireframe: state.showsWireframe,
            reduced: reducesEffects, motion: motion)
        state.status = contextTiles.report + "\n" + hdTiles.report + "\n" + residency.report
        if state.showsDebugOverlay || debugWasShown {
            styling.setTileBounds(hdTiles.tiles, visible: state.showsDebugOverlay, on: map)
        }
        debugWasShown = state.showsDebugOverlay
        if let retry = contextTiles.retryDelay { scheduleUpdate(delay: retry) }
        if let retry = hdTiles.retryDelay { scheduleUpdate(delay: retry) }
        if hdSuspendedUntil > Date() { scheduleUpdate(delay: hdSuspendedUntil.timeIntervalSinceNow) }
    }

    /// The saved tile under the camera's focal point (the centre the camera, chase and padding
    /// target), falling back to the largest visible tile when the focus lies outside saved scenery.
    private func hdFocus(on map: MapboxMap) -> DioramaTileID? {
        let c = map.cameraState.center
        let tile = DioramaTileID(latitude: c.latitude, longitude: c.longitude, zoom: config.tileZoom)
        if DioramaDownloadService.viewableTiles.contains(tile) { return tile }
        return viewportFocus
    }
    /// Ground metres from the camera focus to the nearest point of a tile (0 inside it). Distance,
    /// not pitch, keeps a far horizon out of HD.
    private func groundDistance(from centre: CLLocationCoordinate2D, to tile: DioramaTileID) -> Double {
        let rect = DioramaProjection(origin: centre).rect(of: tile)
        return hypot(min(rect.maxX, max(rect.minX, 0)), min(rect.maxY, max(rect.minY, 0)))
    }

    private func beginExit() {
        suppressNative3D(false)
        if let map, refreshViewportInterest(on: map) {
            contextTiles.updateRetirementVisibility(visibleTilePriority)
            hdTiles.updateRetirementVisibility(visibleTilePriority)
        }
        if !exitRequested {
            exitRequested = true; contextTiles.pauseLoading(); hdTiles.demoteAll()
        }
        if !hdTiles.hasResidents {
            contextTiles.retireAll()
            if !contextTiles.hasResidents {
                suppressBasemapTerrain(false)
                let completion = retractionCompletion; retractionCompletion = nil; completion?()
            }
        }
    }
    func retract(completion: @escaping () -> Void) {
        guard retractionCompletion == nil else { return }
        retractionCompletion = completion; beginExit()
    }
    func cancelRetraction() {
        guard !reloadRequested, !state.isBasemapOnly, state.isEnabled,
              retractionCompletion != nil || exitRequested else { return }
        retractionCompletion = nil; exitRequested = false; scheduleUpdate(delay: 0)
    }
    /// Explicit local reload, with joined HD retirement first. Never regenerate or redownload scenery.
    func regenerate() {
        guard !reloadRequested else { return }
        reloadRequested = true
        retract { [weak self] in
            guard let self else { return }
            self.hdTiles.clear(); self.contextTiles.clear(); self.exitRequested = false; self.reloadRequested = false
            self.scheduleUpdate(delay: 0)
        }
    }

    @discardableResult private func refreshViewportInterest(on map: MapboxMap) -> Bool {
        let camera = map.cameraState, bounds = viewportBounds?() ?? .zero
        var weights: [DioramaTileID: Double] = [:]
        guard bounds.width > 1, bounds.height > 1 else { return false }
        let current = viewport.snapshot().flatMap { value -> DioramaViewport.Snapshot? in
            guard abs(value.zoom - camera.zoom) < 0.0001,
                  abs(value.latitude - camera.center.latitude) < 0.000001,
                  abs(value.longitude - camera.center.longitude) < 0.000001,
                  abs(value.bearing - camera.bearing) < 0.0001, abs(value.pitch - camera.pitch) < 0.0001,
                  value.size.height > 1,
                  abs(value.size.width / value.size.height - bounds.width / bounds.height) < 0.001 else { return nil }
            return value
        }
        if let current {
            for candidate in DioramaDownloadService.viewableTiles {
                let ground = DioramaViewport.area(tile: candidate, snapshot: current, viewport: bounds)
                let upper = DioramaViewport.area(tile: candidate, snapshot: current, viewport: bounds, height: 60)
                let area = max(ground, upper * 0.15)
                if area > 1 { weights[candidate] = area }
            }
        }
        let samples = current == nil ? 9 : 5
        let sampleWeight = Double(bounds.width * bounds.height) / Double(samples * samples)
        var observedWeights: [DioramaTileID: Double] = [:]
        for row in 0..<samples {
            for column in 0..<samples {
                let screen = CGPoint(x: bounds.minX + bounds.width * (Double(column) + 0.5) / Double(samples),
                    y: bounds.minY + bounds.height * (Double(row) + 0.5) / Double(samples))
                let coordinate = map.coordinate(for: screen)
                guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                      abs(coordinate.latitude) <= 85, abs(coordinate.longitude) <= 180 else { continue }
                let projected = map.point(for: coordinate)
                guard projected.x.isFinite, projected.y.isFinite, hypot(projected.x - screen.x, projected.y - screen.y) < 4 else { continue }
                let observed = DioramaTileID(latitude: coordinate.latitude, longitude: coordinate.longitude, zoom: 16)
                guard DioramaDownloadService.viewableTiles.contains(observed) else { continue }
                observedWeights[observed, default: 0] += sampleWeight
            }
        }
        for (observed, area) in observedWeights { weights[observed] = max(weights[observed] ?? 0, area) }
        if current == nil {
            for candidate in observedWeights.keys {
                let corners = Array(candidate.outline.dropLast()), points = corners.map { map.point(for: $0) }
                let valid = zip(corners, points).allSatisfy { coordinate, screen in
                    guard screen.x.isFinite, screen.y.isFinite else { return false }
                    let restored = map.coordinate(for: screen)
                    return abs(restored.latitude - coordinate.latitude) < 0.00001 && abs(restored.longitude - coordinate.longitude) < 0.00001
                }
                if valid { weights[candidate] = max(weights[candidate] ?? 0, DioramaViewport.screenArea(points, viewport: bounds)) }
            }
        }
        if weights.isEmpty, camera.center.latitude.isFinite, camera.center.longitude.isFinite {
            // The camera anchor remains authoritative when SDK horizon/roundtrip probes yield no ground.
            // Only admit that one known viewed tile, never a speculative ring or the entire HD region.
            let anchor = DioramaTileID(latitude: camera.center.latitude, longitude: camera.center.longitude, zoom: 16)
            if DioramaDownloadService.viewableTiles.contains(anchor) {
                weights[anchor] = sampleWeight
            }
        }
        visibleTilePriority = weights.keys.sorted {
            let a = weights[$0] ?? 0, b = weights[$1] ?? 0
            return a == b ? $0.key < $1.key : a > b
        }
        var target = visibleTilePriority.first
        if let previous = viewportFocus, let first = target, let weight = weights[previous],
           weight >= (weights[first] ?? 0) * 0.85 { target = previous }
        if target != viewportFocus {
            viewportFocus = target
            if let target { print("[Diorama viewport] focus=\(target.key) visible=\(visibleTilePriority.count) matrix=\(current != nil)") }
        }
        return true
    }
}
