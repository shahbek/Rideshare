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
    var timeOfDay: DioramaTimeOfDay = DioramaTimeOfDay(rawValue: UserDefaults.standard.string(forKey: "zuri.diorama.timeOfDay") ?? "") ?? .day {
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
    /// Set after a successful tile load so the panel can report numbers.
    var loadedTiles: [DioramaTileID: DioramaTileArtifacts] = [:]
    var status: String = ""
    var frameReport: String = "Frame measurements begin after the tile is visible."
    /// Incremented by the debug panel to request a regenerate of the tile.
    var regenerateRequest: Int = 0
    var cameraFlyRequest: Int = 0

    func toggle(_ category: DioramaCategory) {
        if visibleCategories.contains(category) { visibleCategories.remove(category) } else { visibleCategories.insert(category) }
    }

    var isToggled: (DioramaCategory) -> Bool { { [visibleCategories] in visibleCategories.contains($0) } }

    /// Walls/vegetation/props/buildings toggles; the glow categories follow buildings and props.
    func isVisible(_ category: DioramaCategory) -> Bool {
        switch category {
        case .windowGlow: visibleCategories.contains(.buildings) && timeOfDay.showsLights
        case .propGlow: visibleCategories.contains(.props) && timeOfDay.showsLights
        default: visibleCategories.contains(category)
        }
    }
}

/// Lifecycle of a camera-following full-detail tile across the Masaki peninsula. The whole thing is built from the bundled OSM
/// extract and height snapshot on a background thread, then shown through one custom Metal layer,
/// exactly like the destination buildings and city landmarks. Mapbox is asked for three things: a
/// custom layer slot, a clip layer that hides Standard's own 3D buildings under the toy town, and to
/// switch its 3D terrain off while the tile is shown so the diorama is the only ground renderer.
@MainActor
final class DioramaTileManager {
    let config: DioramaConfig
    /// Owned by the map coordinator: `false` removes the basemap terrain, `true` restores it.
    var setBasemapTerrainEnabled: ((Bool) -> Void)? = nil
    /// Live map bounds in the same coordinate space as Mapbox's screen-to-ground conversion.
    var viewportBounds: (() -> CGRect)?
    private let viewport = DioramaViewport.shared
    private var viewportFocus: DioramaTileID?
    private var visibleTilePriority: [DioramaTileID] = []
    private var pendingUpdateDeadline: CFTimeInterval = 0
    private var basemapTerrainSuppressed: Bool = false
    private let state: DioramaState
    private let styling: DioramaMapStyling
    private weak var map: MapboxMap?

    private enum Status {
        case idle
        case generating
        case loaded(DioramaTileArtifacts)
        case failed
    }

    private var tile: DioramaTileID
    private var requestedTile: DioramaTileID?
    private var selectionTask: Task<Void, Never>?
    private var packageTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var areaName: String { tile == DioramaMasakiSource.slipway ? "Slipway" : "Masaki" }
    private var status: Status = .idle
    private var shown: Bool = false
    private var installed: Bool = false
    private var pendingUpdate: Task<Void, Never>? = nil
    private var generationTask: Task<Void, Never>? = nil
    private var installationTask: Task<Void, Never>?
    private var installationRevision: UInt = 0
    private var installingTile: DioramaTileID?
    private var generationRevision: UInt = 0
    private var appliedCategories: Set<DioramaCategory> = []
    private var appliedTimeOfDay: DioramaTimeOfDay? = nil
    private var appliedDebug: Bool = false
    private var appliedWireframe: Bool? = nil
    private var thermalReduced: Bool = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    private var thermalObserver: NSObjectProtocol? = nil
    private var renderLayer: DioramaRenderLayer? = nil
    private let contextTiles = DioramaContextTiles()
    private var powerObserver: NSObjectProtocol? = nil
    private var settingsObserver: NSObjectProtocol? = nil
    private var revealClock: Timer? = nil
    private var revealStarted: CFTimeInterval? = nil
    private var revealRequested: CFTimeInterval = 0
    private var revealElapsed: Double = 0
    private var lastRevealTick: CFTimeInterval = 0
    private var outgoingCleanup: (() -> Void)?
    private var outgoingTile: DioramaTileID?
    private var outgoingHost: DioramaRenderLayer?
    private var outgoingRetiring: Bool = false
    private var isRetracting: Bool = false
    /// Pan arrivals sweep in world space from the previously focused tile, unlike initial focus.
    private var arrivalDirection: DV2? = nil
    private var currentExtent: Double = -Double(DioramaRevealStyle.support)
    private var transitionFrom: Double = -Double(DioramaRevealStyle.support)
    private var revealEndpointPending: Bool = false
    private var retractionCompletion: (() -> Void)?
    private var fullExtent: Double {
        let rect = DioramaProjection(origin: tile.centre).rect(of: tile)
        let low = renderLayer?.revealBounds.minimum ?? SIMD3(Float(rect.minX), Float(rect.minY), 0)
        let high = renderLayer?.revealBounds.maximum ?? SIMD3(Float(rect.maxX), Float(rect.maxY), 0)
        let x = Double(max(abs(low.x), abs(high.x)))
        let y = Double(max(abs(low.y), abs(high.y)))
        let overrun = Double(DioramaRevealStyle.support) + 50
        if let direction = arrivalDirection {
            return x * abs(direction.x) + y * abs(direction.y) + overrun
        }
        return max(x, y) + overrun
    }
    private var labelClipID: String { layerID + "-label-clip" }
    private var labelSourceID: String { layerID + "-label-mask" }

    private var reducesEffects: Bool {
        thermalReduced || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var layerID: String { "zuri-diorama-\(tile.key)" }
    private var clipLayerID: String { "zuri-diorama-clip-\(tile.key)" }
    private var clipSourceID: String { "zuri-diorama-clip-src-\(tile.key)" }

    init(config: DioramaConfig = .slipway, state: DioramaState? = nil) {
        self.config = config
        self.state = state ?? .shared
        tile = DioramaTileID(latitude: config.seedLatitude, longitude: config.seedLongitude, zoom: config.tileZoom)
        styling = DioramaMapStyling(config: config)
        settingsObserver = NotificationCenter.default.addObserver(forName: DioramaState.renderSettingsChanged, object: self.state, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleUpdate(delay: 0) }
        }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reduced = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                guard reduced != self.thermalReduced else { return }
                self.thermalReduced = reduced
                self.renderLayer?.setReducedEffects(self.reducesEffects)
                self.updateEffectStatus()
                self.applyMotionPolicy()
                self.map?.triggerRepaint()
            }
        }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderLayer?.setReducedEffects(self.reducesEffects)
                self.updateEffectStatus()
                self.applyMotionPolicy()
                self.map?.triggerRepaint()
            }
        }
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didReceiveMemoryWarningNotification, UIAccessibility.reduceMotionStatusDidChangeNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyMotionPolicy()
                    if name == UIApplication.willResignActiveNotification || name == UIApplication.didReceiveMemoryWarningNotification {
                        if name == UIApplication.willResignActiveNotification { self?.contextTiles.pauseLoading() }
                        Task { await DioramaOfflineStore.shared.releaseDecodedMemory() }
                    } else { self?.scheduleUpdate(delay: 0) }
                }
            })
        }
    }

    private func applyMotionPolicy() {
        let motion = shown && !reducesEffects && !UIAccessibility.isReduceMotionEnabled
            && UIApplication.shared.applicationState == .active
        renderLayer?.setWaterMotion(motion)
        outgoingHost?.setWaterMotion(motion)
        outgoingHost?.setReducedEffects(reducesEffects)
        outgoingHost?.setVisible(state.visibleCategories, timeOfDay: state.timeOfDay)
        contextTiles.setReducedEffects(reducesEffects, waterMotion: motion)
        // No idle repaint source. Water phase advances only on a changed camera transform.
    }

    // MARK: Install / remove

    /// Call once per style load. Nothing is added to the style until the tile is actually shown.
    func install(on map: MapboxMap) {
        self.map = map
        installed = true
        scheduleUpdate(delay: 0)
    }

    /// Called when the style reloads: Mapbox drops every runtime layer and source.
    func styleDidReload() {
        contextTiles.clear()
        installationRevision &+= 1
        installationTask?.cancel(); installationTask = nil
        selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
        outgoingCleanup = nil; outgoingTile = nil; outgoingHost = nil; outgoingRetiring = false
        installed = false
        shown = false
        revealClock?.invalidate()
        revealClock = nil
        isRetracting = false
        let completion = retractionCompletion
        retractionCompletion = nil
        applyMotionPolicy()
        renderLayer = nil
        basemapTerrainSuppressed = false
        appliedCategories = []
        appliedTimeOfDay = nil
        appliedDebug = false
        completion?()
    }

    func remove() {
        installationRevision &+= 1
        installationTask?.cancel(); installationTask = nil
        generationRevision &+= 1
        generationTask?.cancel(); generationTask = nil
        packageTask?.cancel(); packageTask = nil
        selectionTask?.cancel(); selectionTask = nil
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers.removeAll()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        thermalObserver = nil; powerObserver = nil
        pendingUpdate?.cancel()
        pendingUpdate = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        guard let map else { return }
        hide(on: map)
        styling.remove(from: map)
        state.loadedTiles.removeAll()
        installed = false
    }

    /// The diorama owns the ground while shown; Standard's terrain returns as soon as it hides.
    private func suppressBasemapTerrain(_ suppress: Bool) {
        guard suppress != basemapTerrainSuppressed else { return }
        basemapTerrainSuppressed = suppress
        setBasemapTerrainEnabled?(!suppress)
    }

    // MARK: Camera

    /// Camera options for the opening shot over the tile.
    func introCamera() -> CameraOptions {
        if shown, isRetracting { beginReveal(fromCurrent: true) }
        if let kind = state.inspectionTarget,
           let data = DioramaBundledTile.load(config: config),
           let segment = data.shorelines.filter({ $0.kind == kind }).max(by: { $0.length < $1.length }) {
            let p = segment.points[segment.points.count / 2]
            let coordinate = data.projection.coordinate(p)
            return CameraOptions(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                 zoom: 18, bearing: config.cameraBearing, pitch: config.cameraPitch)
        }
        return CameraOptions(center: DioramaMasakiSource.slipway.centre, zoom: config.cameraZoom, bearing: config.cameraBearing, pitch: config.cameraPitch)
    }

    /// Ground beneath the vehicle is read from resident geometry, including coarse handoff neighbours.
    func groundHeight(at point: GeoPoint) -> Double? {
        guard shown, !state.isBasemapOnly else { return nil }
        return renderLayer?.groundHeight(at: point) ?? contextTiles.groundHeight(at: point)
    }

    // MARK: Updates

    func scheduleUpdate(delay: Double) {
        // Throttle, not debounce. An idle retry must never hold a newer camera event behind it.
        let deadline = CACurrentMediaTime() + max(0, delay)
        if pendingUpdate != nil, pendingUpdateDeadline <= deadline { return }
        pendingUpdate?.cancel()
        pendingUpdateDeadline = deadline
        pendingUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.pendingUpdate = nil
            self.update()
        }
    }

    /// Shows the tile while the camera is near it and zoomed in; hides it otherwise.
    func update() {
        guard installed, let map, UIApplication.shared.applicationState == .active else { return }
        guard retractionCompletion == nil else { return }
        guard state.isEnabled else { beginRetraction(); return }
        guard DioramaDownloadService.shared.canView else {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
            generationTask?.cancel(); generationTask = nil; generationRevision &+= 1
            beginRetraction()
            status = .idle
            state.loadedTiles.removeAll()
            state.status = "Download and prepare all Masaki tiles before viewing · open Offline maps"
            return
        }
        applyCategoryVisibility()
        applyDebug()

        if state.isBasemapOnly {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
            if shown { beginRetraction() }
            state.status = "Basemap-only comparison · custom shoreline hidden"
            return
        }
        let camera = map.cameraState
        refreshViewportInterest(on: map)
        guard let target = viewportFocus else {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
            beginRetraction()
            state.status = "Masaki coverage · pan back to the peninsula"
            return
        }
        // Speculative full decodes compete with actually visible coverage and can exceed 128 MiB
        // before the old admission check. Demand reads take priority; no centre-vector prediction.
        guard camera.zoom >= config.minimumZoom else {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
            beginRetraction()
            state.status = "Zoom in to \(Int(config.minimumZoom)) to build the diorama"
            return
        }
        if !shown {
            switch status {
            case .idle, .failed:
                if tile != target { tile = target; status = .idle }
            case .generating:
                if tile != target {
                    generationRevision &+= 1
                    generationTask?.cancel(); generationTask = nil
                    tile = target; status = .idle
                }
            case .loaded: break
            }
        }
        // Coarse visible coverage is independent of the full-detail reveal or replacement read.
        updateContextTiles()
        if target != tile {
            requestTile(target)
        } else {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
        }
        switch status {
        case .idle:
            generate()
        case .generating:
            state.status = "Loading saved \(areaName)… · full detail"
        case .loaded(let artifacts):
            if !shown, target == tile, installationTask == nil, installingTile == nil {
                installationRevision &+= 1
                let expected = installationRevision
                installationTask = Task { [weak self] in
                    guard let self else { return }
                    await self.show(artifacts, on: map)
                    if self.installationRevision == expected { self.installationTask = nil }
                }
            }
            else if shown, isRetracting { beginReveal(fromCurrent: true) }
        case .failed:
            state.status = "Saved tile unavailable · resume Masaki preparation to repair"
        }
        if requestedTile != nil {
            state.status = selectionTask == nil ? "Adjacent tile unavailable · current area retained. Try Regenerate online." : "Preparing adjacent tile… · current area stays visible"
        }
        applyMotionPolicy()
    }

    private func refreshViewportInterest(on map: MapboxMap) {
        let camera = map.cameraState
        let bounds = viewportBounds?() ?? .zero
        var weights: [DioramaTileID: Double] = [:]
        guard bounds.width > 1, bounds.height > 1 else { return }
        let snapshot = viewport.snapshot()
        let current = snapshot.flatMap { value -> DioramaViewport.Snapshot? in
            guard abs(value.zoom - camera.zoom) < 0.0001,
                  abs(value.latitude - camera.center.latitude) < 0.000001,
                  abs(value.longitude - camera.center.longitude) < 0.000001,
                  abs(value.bearing - camera.bearing) < 0.0001,
                  abs(value.pitch - camera.pitch) < 0.0001 else { return nil }
            return value
        }
        // Padding positions the camera; it does not make the padded map pixels invisible.
        // Intersect every prepared tile, not a sparse grid or a guessed camera-centre ring.
        for candidate in DioramaOfflineStore.tiles {
            let area: Double
            if let current {
                let ground = DioramaViewport.area(tile: candidate, snapshot: current, viewport: bounds)
                let upper = DioramaViewport.area(tile: candidate, snapshot: current, viewport: bounds, height: 60)
                area = max(ground, upper * 0.15)
            } else {
                // Bootstrap before the first custom frame; SDK projection uses the actual camera.
                area = DioramaViewport.screenArea(candidate.outline.dropLast().map { map.point(for: $0) }, viewport: bounds)
            }
            if area > 1 { weights[candidate] = area }
        }
        visibleTilePriority = weights.keys.sorted {
            let a = weights[$0] ?? 0, b = weights[$1] ?? 0
            return a == b ? $0.key < $1.key : a > b
        }
        var target = visibleTilePriority.first
        // Screen-area hysteresis only: keep a near-tie, never wait to cross a metre threshold.
        if let first = target, let currentWeight = weights[tile],
           currentWeight >= (weights[first] ?? 0) * 0.85 { target = tile }
        if target != viewportFocus {
            viewportFocus = target
            if let target { print("[Diorama viewport] focus=\(target.key) visible=\(visibleTilePriority.count)") }
        }
    }

    private func updateEffectStatus() {
        guard shown else { return }
        if thermalReduced {
            state.status = "\(areaName) loaded · bloom/AO off (thermal)"
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            state.status = "\(areaName) loaded · bloom/AO off (Low Power)"
        } else {
            if case .loaded(let artifacts) = status, !artifacts.hasMapboxCoverage {
                state.status = "Full effects · bundled coverage only. Regenerate online for Mapbox names/geometry."
            } else {
                state.status = "\(areaName) loaded · full effects · Mapbox coverage"
            }
        }
    }

    /// Keep the current tile displayed while preparing its replacement off-main. This bounds GPU
    /// residency to one full-detail tile plus the bounded low-detail neighbour ring.
    private func requestTile(_ next: DioramaTileID) {
        // Finish the current finite handoff before accepting the latest settled camera target.
        guard !isRetracting, requestedTile != next else { return }
        selectionTask?.cancel()
        requestedTile = next
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.18)) } catch { return }
            guard let self, let map = self.map, self.installed, self.retractionCompletion == nil,
                  self.requestedTile == next, self.state.isEnabled, !self.state.isBasemapOnly,
                  map.cameraState.zoom >= self.config.minimumZoom,
                  self.viewportFocus == next else { return }
            let started = CACurrentMediaTime()
            let config = self.config
            let job = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as DioramaTileArtifacts? }
                return await DioramaOfflineStore.shared.read(next)
            }
            let prepared = await withTaskCancellationHandler {
                await job.value
            } onCancel: { job.cancel() }
            // Decode overlaps the current GPU handoff; only installation waits for its completion.
            while prepared != nil, self.revealClock != nil || self.outgoingTile != nil || self.installingTile != nil {
                guard !Task.isCancelled, self.viewportFocus == next, CACurrentMediaTime() - started < 25 else {
                    if self.requestedTile == next { self.requestedTile = nil; self.selectionTask = nil }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled, self.installed, self.requestedTile == next,
                  self.retractionCompletion == nil, self.state.isEnabled, !self.state.isBasemapOnly,
                  map.cameraState.zoom >= config.minimumZoom, self.viewportFocus == next else { return }
            guard let prepared else {
                // Retain the old tile and suppress automatic repeated source requests until the
                // camera leaves this request or the user explicitly chooses Regenerate.
                self.selectionTask = nil
                self.state.status = "Saved tile needs repair · resume Masaki preparation"
                return
            }
            await self.show(prepared, on: map, replacing: true)
            // Prepared archives are never recompressed or regenerated during viewing.
        }
    }

    // MARK: Generation

    /// Bundled terrain remains authoritative; one whole Mapbox tile supplements coverage and names.
    private var bypassDiskOnNextGeneration: Bool = false

    private func generate() {
        status = .generating
        state.status = "Loading saved \(areaName)… · full detail"
        generationRevision &+= 1
        let revision = generationRevision
        let tile = self.tile
        bypassDiskOnNextGeneration = false
        generationTask = Task.detached(priority: .userInitiated) {
            let artifacts: DioramaTileArtifacts?
            let started = Date()
            artifacts = await DioramaOfflineStore.shared.read(tile)
            guard !Task.isCancelled else { return }
            let readySeconds = Date().timeIntervalSince(started)
            await MainActor.run {
                guard self.generationRevision == revision, case .generating = self.status else { return }
                self.generationTask = nil
                guard var artifacts else {
                    self.status = .failed
                    self.state.status = "Saved tile needs repair · resume Masaki preparation"
                    return
                }
                artifacts.stageTimings.append("source/cache → renderer-ready: \(String(format: "%.3f", readySeconds))s (not first visible)")
                if tile != DioramaMasakiSource.slipway {
                    artifacts.stageTimings.append("Masaki camera-follow preview · one full-detail tile + bounded coarse neighbours · mapped sources + Terrain-RGB")
                }
                self.status = .loaded(artifacts)
                print("[Diorama] \(artifacts.tile): \(artifacts.totalTriangles) unique tris, \(artifacts.lightDrawnTriangles)–\(artifacts.drawnTriangles) drawn (light–full LOD), \(artifacts.totalInstances) instances, \(artifacts.totalBytes / 1024) KB in \(String(format: "%.2f", artifacts.generationSeconds))s")
                self.scheduleUpdate(delay: 0.05)
            }
        }
    }

    /// Reloads the saved package without network access or geometry generation.
    func regenerate() {
        guard let map else { return }
        selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
        bypassDiskOnNextGeneration = true
        packageTask?.cancel(); packageTask = nil
        generationRevision &+= 1
        generationTask?.cancel(); generationTask = nil
        DioramaTileGenerator.clearCache(for: tile, config: config)
        retract { [weak self, weak map] in
            guard let self, map != nil else { return }
            self.arrivalDirection = nil
            self.status = .idle
            self.state.loadedTiles[self.tile] = nil
            self.scheduleUpdate(delay: 0.05)
        }
    }

    // MARK: Showing

    /// Adds the custom Metal layer and a clip layer over the tile so Standard's own buildings disappear
    /// under the toy town. Same calls, same order, as `DarCityLandmarks.install`.
    private func retainOutgoing(on map: MapboxMap) {
        outgoingCleanup?()
        let layers = [labelClipID, clipLayerID, layerID]
        let sources = [clipSourceID, labelSourceID]
        let oldHost = renderLayer
        outgoingTile = tile
        outgoingHost = oldHost
        outgoingRetiring = false
        outgoingCleanup = { [weak map, oldHost] in
            _ = oldHost // Retain the renderer until its replacement context is ready.
            guard let map else { return }
            for id in layers where map.layerExists(withId: id) { try? map.removeLayer(withId: id) }
            for id in sources where map.sourceExists(withId: id) { try? map.removeSource(withId: id) }
        }
        revealClock?.invalidate(); revealClock = nil
        renderLayer = nil; shown = false; isRetracting = false
    }

    private func show(_ artifacts: DioramaTileArtifacts, on map: MapboxMap, replacing: Bool = false) async {
        guard installingTile == nil else { return }
        installingTile = artifacts.tile
        defer { installingTile = nil }
        do {
            let animates = true // Water moves on camera frames, never on an idle timer.
            let host = DioramaRenderLayer(
                origin: artifacts.tile.centre, vertices: artifacts.vertices, indices: artifacts.indices, ranges: artifacts.ranges,
                groups: artifacts.groups, instances: artifacts.allInstances, lightGrid: artifacts.lightGrid, waterHeight: artifacts.waterHeight, groundImage: artifacts.groundImage,
                groundRect: DioramaProjection(origin: artifacts.tile.centre).rect(of: artifacts.tile), visible: state.visibleCategories, timeOfDay: state.timeOfDay,
                animates: animates, config: config, labels: artifacts.buildingLabels, displayScale: Float(UIScreen.main.scale),
                materialsPrepared: artifacts.renderMaterialsPrepared, materialCounts: artifacts.renderMaterialCounts,
                preparedPoolBounds: artifacts.renderPoolBounds
            )
            let upload = Task.detached(priority: .userInitiated) { await DioramaGPUUploadQueue.shared.prepare(host) }
            await withTaskCancellationHandler { await upload.value } onCancel: { upload.cancel() }
            // Give an already-pending coarse frame a short chance to finish. It is cheaper to
            // promote ready coverage than run a new full-scene/effect sweep for 1.8 seconds.
            let coverageDeadline = CACurrentMediaTime() + 0.6
            while contextTiles.isPreparing(artifacts.tile), !contextTiles.isReady(artifacts.tile),
                  CACurrentMediaTime() < coverageDeadline, !Task.isCancelled,
                  viewportFocus == artifacts.tile, UIApplication.shared.applicationState == .active {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
            guard !Task.isCancelled, installed, self.map === map,
                  state.isEnabled, !state.isBasemapOnly, viewportFocus == artifacts.tile,
                  map.cameraState.zoom >= config.minimumZoom, retractionCompletion == nil, !isRetracting,
                  replacing ? requestedTile == artifacts.tile : artifacts.tile == tile,
                  UIApplication.shared.applicationState == .active else { return }
            if replacing {
                generationRevision &+= 1
                generationTask?.cancel(); generationTask = nil
                packageTask?.cancel(); packageTask = nil
                let previous = tile
                let projection = DioramaProjection(origin: artifacts.tile.centre)
                let oldCentre = projection.local(longitude: previous.centre.longitude, latitude: previous.centre.latitude)
                retainOutgoing(on: map)
                arrivalDirection = (-oldCentre).normalized
                DioramaTileGenerator.clearCache(for: previous, config: config)
                state.loadedTiles.removeAll()
                state.frameReport = "Waiting for the new tile's frame measurements."
                tile = artifacts.tile
                bypassDiskOnNextGeneration = false
                status = .loaded(artifacts)
                requestedTile = nil; selectionTask = nil
            }
            let hasCoverage = contextTiles.isReady(tile)
            hide(on: map, preservingContext: true)
            host.viewport = viewport
            host.onWaterVisibilityChanged = { [weak self] in
                Task { @MainActor [weak self] in self?.applyMotionPolicy() }
            }
            host.onInitializationFailed = { [weak self, weak host] in
                Task { @MainActor [weak self, weak host] in
                    guard let self, let host, self.renderLayer === host, let map = self.map else { return }
                    self.hide(on: map)
                    self.status = .failed
                    self.state.status = "3D renderer unavailable · basemap restored; saved tiles retained"
                    map.triggerRepaint()
                }
            }
            host.onFrameReport = { [weak self, weak host] report in
                Task { @MainActor [weak self, weak host] in
                    guard let self, let host, self.renderLayer === host, self.shown else { return }
                    self.state.frameReport = report + "\n" + self.contextTiles.report
                }
            }
            renderLayer = host
            currentExtent = hasCoverage ? fullExtent : emptyExtent
            host.setReveal(hasCoverage ? .zero : revealUniform)
            try map.addCustomLayer(withId: layerID, layerHost: host, layerPosition: nil)
            setCustomLayerSlot(layerID, on: map)
            var source = GeoJSONSource(id: clipSourceID)
            source.data = .featureCollection(FeatureCollection(features: []))
            try map.addSource(source)
            var clip = ClipLayer(id: clipLayerID, source: clipSourceID)
            clip.slot = .top
            clip.clipLayerScope = .constant(["basemap"])
            clip.clipLayerTypes = .constant([.model])
            try map.addLayer(clip)
            var labelSource = GeoJSONSource(id: labelSourceID)
            labelSource.data = .featureCollection(FeatureCollection(features: []))
            try map.addSource(labelSource)
            var labelClip = ClipLayer(id: labelClipID, source: labelSourceID)
            labelClip.slot = .top
            labelClip.clipLayerScope = .constant(["basemap"])
            labelClip.clipLayerTypes = .constant([.symbol])
            try map.addLayer(labelClip)
            renderLayer = host
            shown = true
            if hasCoverage { setRevealClip(halfExtent: nil) }
            else { beginReveal() }
            suppressBasemapTerrain(true)
            host.setReducedEffects(reducesEffects)
            host.setWireframe(state.showsWireframe)
            appliedWireframe = state.showsWireframe
            state.loadedTiles[tile] = artifacts
            updateEffectStatus()
            updateContextTiles()
            applyMotionPolicy()
            map.triggerRepaint()
        } catch {
            print("[Diorama] show failed: \(error)")
            hide(on: map)
            status = .failed
        }
    }

    // Use the synchronous overload: registration must remain atomic with coverage bookkeeping.
    private func setCustomLayerSlot(_ id: String, on map: MapboxMap) {
        try? map.setLayerProperty(for: id, property: "slot", value: "middle")
    }

    private func hide(on map: MapboxMap, preservingContext: Bool = false) {
        if !preservingContext {
            contextTiles.clear()
            outgoingCleanup?(); outgoingCleanup = nil; outgoingTile = nil; outgoingHost = nil; outgoingRetiring = false
        }
        revealClock?.invalidate()
        revealClock = nil
        for id in [labelClipID, clipLayerID, layerID] where map.layerExists(withId: id) { try? map.removeLayer(withId: id) }
        if map.sourceExists(withId: clipSourceID) { try? map.removeSource(withId: clipSourceID) }
        if map.sourceExists(withId: labelSourceID) { try? map.removeSource(withId: labelSourceID) }
        renderLayer = nil
        appliedWireframe = nil
        shown = false
        isRetracting = false
        revealEndpointPending = false
        if !preservingContext { suppressBasemapTerrain(false) }
        applyMotionPolicy()
        let completion = retractionCompletion
        retractionCompletion = nil
        completion?()
    }

    /// One finite 30 Hz reveal, including cached tiles and explicit focus requests.
    private func beginReveal(fromCurrent: Bool = false) {
        isRetracting = false
        transitionFrom = fromCurrent ? currentExtent : emptyExtent
        currentExtent = transitionFrom
        revealEndpointPending = false
        revealClock?.invalidate()
        revealClock = nil
        guard shown, let renderLayer else { return }
        revealStarted = nil
        revealElapsed = 0
        lastRevealTick = CACurrentMediaTime()
        revealRequested = lastRevealTick
        renderLayer.setReveal(revealUniform)
        setRevealClip(halfExtent: currentExtent)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceReveal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealClock = timer
        map?.triggerRepaint()
    }

    /// Keep this manager alive until the reverse square reaches zero, including settings-off.
    func retract(completion: @escaping () -> Void) {
        guard retractionCompletion == nil else { return }
        selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
        retractionCompletion = completion
        if shown { beginRetraction() }
        else { retractionCompletion = nil; completion() }
    }

    func cancelRetraction() {
        guard retractionCompletion != nil else { return }
        retractionCompletion = nil
        if isRetracting { beginReveal(fromCurrent: true) }
    }

    private func beginRetraction() {
        guard shown else {
            contextTiles.clear()
            suppressBasemapTerrain(false)
            return
        }
        guard !isRetracting else { return }
        retireOutgoing()
        contextTiles.retractAll()
        guard !UIAccessibility.isReduceMotionEnabled, UIApplication.shared.applicationState == .active,
              renderLayer?.diagnostic.hasPrefix("ready") == true else {
            if let map { hide(on: map) }; return
        }
        let wasAnimating = revealClock != nil
        revealClock?.invalidate(); revealClock = nil
        if arrivalDirection != nil, !wasAnimating {
            arrivalDirection = nil
            currentExtent = fullExtent
        }
        isRetracting = true
        revealEndpointPending = false
        transitionFrom = currentExtent
        revealStarted = nil
        revealElapsed = 0
        lastRevealTick = CACurrentMediaTime()
        revealRequested = lastRevealTick
        renderLayer?.setReveal(revealUniform)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceReveal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealClock = timer
        map?.triggerRepaint()
    }

    private func advanceReveal() {
        guard shown, let renderLayer else { revealClock?.invalidate(); revealClock = nil; return }
        let now = CACurrentMediaTime()
        let finish = UIApplication.shared.applicationState != .active || UIAccessibility.isReduceMotionEnabled
            || ProcessInfo.processInfo.thermalState == .critical
        let diagnostic = renderLayer.diagnostic
        guard diagnostic.hasPrefix("ready") else {
            if diagnostic.contains("failed") || diagnostic.contains("missing") || now - revealRequested > 8 || UIApplication.shared.applicationState != .active {
                if let map { hide(on: map) }
                status = .failed
                state.status = "Diorama unavailable · basemap restored. Try Regenerate."
            } else { map?.triggerRepaint() }
            return
        }
        // Never let a timer skip the entire effect while compilation/upload/frames stall.
        guard finish || renderLayer.hasCompleted(reveal: revealUniform) else {
            lastRevealTick = now
            map?.triggerRepaint()
            if now - revealRequested > 20 {
                if let map { hide(on: map) }
                status = .failed
                state.status = "Renderer stalled · basemap restored"
            }
            return
        }
        if revealEndpointPending || finish {
            completeReveal()
            return
        }
        revealRequested = now
        if revealStarted == nil { revealStarted = now; lastRevealTick = now }
        revealElapsed += min(1.0 / 30.0, max(0, now - lastRevealTick))
        lastRevealTick = now
        let progress = finish ? 1 : min(1, revealElapsed / 1.8)
        let eased = progress * progress * (3 - 2 * progress)
        currentExtent = transitionFrom + ((isRetracting ? emptyExtent : fullExtent) - transitionFrom) * eased
        renderLayer.setReveal(revealUniform)
        setRevealClip(halfExtent: currentExtent)
        revealEndpointPending = progress >= 1
        map?.triggerRepaint()
    }

    private var emptyExtent: Double {
        arrivalDirection == nil ? -Double(DioramaRevealStyle.support) - 2 : -fullExtent
    }

    /// The final active-mask endpoint must finish on the GPU before switching ownership.
    private func completeReveal() {
        revealEndpointPending = false
        if isRetracting {
            if contextTiles.isTransitioning, UIApplication.shared.applicationState == .active,
               !UIAccessibility.isReduceMotionEnabled, ProcessInfo.processInfo.thermalState != .critical {
                revealEndpointPending = true
                map?.triggerRepaint()
                return
            }
            if let map { hide(on: map); map.triggerRepaint() }
            return
        }
        currentExtent = fullExtent
        renderLayer?.setReveal(.zero)
        setRevealClip(halfExtent: nil)
        revealClock?.invalidate(); revealClock = nil
        if let outgoingTile, abs(outgoingTile.x - tile.x) > 1 || abs(outgoingTile.y - tile.y) > 1 {
            retireOutgoing()
        }
        updateContextTiles()
        applyMotionPolicy()
        scheduleUpdate(delay: 0.1)
        map?.triggerRepaint()
    }

    private var revealUniform: SIMD4<Float> {
        if let direction = arrivalDirection {
            return SIMD4(Float(direction.x), Float(direction.y), Float(currentExtent), 2)
        }
        return SIMD4(0, 0, Float(currentExtent), 1)
    }

    /// Native clips are hard polygons: conservatively cover the outer soft support, not its midpoint.
    private func setRevealClip(halfExtent: Double?) {
        contextTiles.setFocusMask(tile: tile, reveal: halfExtent == nil ? .zero : revealUniform)
        guard let map, map.sourceExists(withId: clipSourceID) else { return }
        let projection = DioramaProjection(origin: tile.centre)
        let rect = projection.rect(of: tile)
        let coordinates: [CLLocationCoordinate2D]
        if let e = halfExtent {
            let points: [DV2]
            if let direction = arrivalDirection {
                let outline = [DV2(rect.minX, rect.minY), DV2(rect.maxX, rect.minY), DV2(rect.maxX, rect.maxY), DV2(rect.minX, rect.maxY)]
                let anchor = direction * (e + Double(DioramaRevealStyle.support))
                points = DioramaGroundCutouts.halfPlane(outline, a: anchor, b: anchor + direction.left, inside: true)
            } else {
                let extent = max(0.001, e + Double(DioramaRevealStyle.support))
                points = [DV2(max(rect.minX, -extent), max(rect.minY, -extent)), DV2(min(rect.maxX, extent), max(rect.minY, -extent)),
                          DV2(min(rect.maxX, extent), min(rect.maxY, extent)), DV2(max(rect.minX, -extent), min(rect.maxY, extent))]
            }
            guard let first = points.first, points.count >= 3 else {
                let empty = FeatureCollection(features: [])
                map.updateGeoJSONSource(withId: clipSourceID, geoJSON: .featureCollection(empty))
                if map.sourceExists(withId: labelSourceID) { map.updateGeoJSONSource(withId: labelSourceID, geoJSON: .featureCollection(empty)) }
                return
            }
            coordinates = (points + [first]).map { p in
                let c = projection.coordinate(p)
                return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            }
        } else { coordinates = tile.outline }
        map.updateGeoJSONSource(withId: clipSourceID, geoJSON: .geometry(.polygon(Polygon([coordinates]))))
        // All native symbols inside the active square are suppressed, including unnamed POIs,
        // road/place labels and icons. Outside the tile and on retraction Standard is unchanged.
        if map.sourceExists(withId: labelSourceID) {
            map.updateGeoJSONSource(withId: labelSourceID, geoJSON: .geometry(.polygon(Polygon([coordinates]))))
        }
    }

    private func updateContextTiles() {
        guard !isRetracting, state.isEnabled, DioramaDownloadService.shared.canView,
              !state.isBasemapOnly, let map, map.cameraState.zoom >= config.minimumZoom else { return }
        contextTiles.onReady = { [weak self] ready in
            guard let self else { return }
            if self.state.isEnabled, !self.state.isBasemapOnly, !self.isRetracting,
               self.visibleTilePriority.contains(ready), (self.map?.cameraState.zoom ?? 0) >= self.config.minimumZoom {
                self.suppressBasemapTerrain(true)
            }
            if self.outgoingTile == ready { self.retireOutgoing() }
            self.applyMotionPolicy()
            self.scheduleUpdate(delay: 0.1)
        }
        contextTiles.onUnavailable = { [weak self] missing in
            guard let self else { return }
            if self.outgoingTile == missing { self.retireOutgoing() }
            self.scheduleUpdate(delay: 30)
        }
        contextTiles.onWaterVisibilityChanged = { [weak self] in self?.applyMotionPolicy() }
        contextTiles.onFocusCoverage = { [weak self] ready, edges, paired in
            guard let self else { return }
            if self.tile == ready { self.renderLayer?.setTileCoverage(edges: edges, role: 1, paired: paired) }
            if self.outgoingTile == ready { self.outgoingHost?.setTileCoverage(edges: edges, role: 1, paired: paired) }
        }
        contextTiles.setReducedEffects(reducesEffects, waterMotion: !UIAccessibility.isReduceMotionEnabled)
        if shown { contextTiles.setFocusMask(tile: tile, reveal: revealClock == nil ? .zero : revealUniform) }
        if let outgoingTile, !visibleTilePriority.contains(outgoingTile) { retireOutgoing() }
        contextTiles.viewport = viewport
        contextTiles.update(focus: viewportFocus ?? tile, config: config, map: map, visible: state.visibleCategories,
                            time: state.timeOfDay, wireframe: state.showsWireframe, priorityTiles: visibleTilePriority)
        if let retry = contextTiles.retryDelay { scheduleUpdate(delay: retry) }
    }

    private func retireOutgoing() {
        guard !outgoingRetiring, let host = outgoingHost, let oldTile = outgoingTile else { return }
        if !visibleTilePriority.contains(oldTile) {
            contextTiles.removeFocusMask(oldTile)
            outgoingCleanup?(); outgoingCleanup = nil; outgoingTile = nil; outgoingHost = nil
            scheduleUpdate(delay: 0)
            return
        }
        outgoingRetiring = true
        contextTiles.retire(host: host, tile: oldTile) { [weak self] in
            guard let self, self.outgoingTile == oldTile else { return }
            self.outgoingCleanup?(); self.outgoingCleanup = nil; self.outgoingTile = nil
            self.outgoingHost = nil; self.outgoingRetiring = false
            self.scheduleUpdate(delay: 0.1)
        }
    }

    // MARK: Style state

    private func applyCategoryVisibility() {
        guard let map, let renderLayer else { return }
        guard appliedCategories != state.visibleCategories || appliedTimeOfDay != state.timeOfDay else { return }
        appliedCategories = state.visibleCategories
        appliedTimeOfDay = state.timeOfDay
        renderLayer.setVisible(state.visibleCategories, timeOfDay: state.timeOfDay)
        if revealClock == nil { setRevealClip(halfExtent: nil) }
        map.triggerRepaint()
    }

    private func applyDebug() {
        guard let map else { return }
        if appliedWireframe != state.showsWireframe, let renderLayer {
            renderLayer.setWireframe(state.showsWireframe)
            appliedWireframe = state.showsWireframe
            if revealClock == nil { setRevealClip(halfExtent: nil) }
            map.triggerRepaint()
        }
        let show = state.showsDebugOverlay
        if show || appliedDebug {
            styling.setTileBounds(shown ? [tile] : [], visible: show, on: map)
        }
        appliedDebug = show
    }
}
