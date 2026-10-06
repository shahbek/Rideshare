import Foundation
@_spi(Experimental) import MapboxMaps
import UIKit

/// Observable diorama state shared by the map coordinator and the debug panel.
@Observable
@MainActor
final class DioramaState {
    static let shared = DioramaState()

    var isEnabled: Bool = false
    static let renderSettingsChanged = Notification.Name("zuri.diorama.renderSettingsChanged")
    var timeOfDay: DioramaTimeOfDay = .dusk { didSet { notifyRenderer() } }
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
    private var generationRevision: UInt = 0
    private var appliedCategories: Set<DioramaCategory> = []
    private var appliedTimeOfDay: DioramaTimeOfDay? = nil
    private var appliedDebug: Bool = false
    private var appliedWireframe: Bool? = nil
    private var thermalReduced: Bool = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    private var thermalObserver: NSObjectProtocol? = nil
    private var renderLayer: DioramaRenderLayer? = nil
    private var powerObserver: NSObjectProtocol? = nil
    private var settingsObserver: NSObjectProtocol? = nil
    /// Low-rate clock for the gentle water drift. Runs only while the tile is shown, the app is
    /// active and effects are not reduced; Mapbox otherwise sleeps between camera changes.
    private var waterClock: Timer? = nil
    private var revealClock: Timer? = nil
    private var revealStarted: CFTimeInterval? = nil
    private var revealRequested: CFTimeInterval = 0
    private var isRetracting: Bool = false
    private var currentExtent: Double = 0.8
    private var transitionFrom: Double = 0.8
    private var retractionCompletion: (() -> Void)?
    private var fullExtent: Double {
        let rect = DioramaProjection(origin: tile.centre).rect(of: tile)
        return max(rect.width, rect.height) * 0.5 + 12
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
                self.updateWaterClock()
                self.map?.triggerRepaint()
            }
        }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderLayer?.setReducedEffects(self.reducesEffects)
                self.updateEffectStatus()
                self.updateWaterClock()
                self.map?.triggerRepaint()
            }
        }
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWaterClock() }
            })
        }
    }

    private func updateWaterClock() {
        let wanted = shown && !reducesEffects && !UIAccessibility.isReduceMotionEnabled
            && UIApplication.shared.applicationState == .active
        if !wanted {
            waterClock?.invalidate()
            waterClock = nil
            return
        }
        guard waterClock == nil else { return }
        // Bounded 12 Hz wave updates only while the diorama is visible and the app is active.
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.map?.triggerRepaint() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        waterClock = timer
    }

    // MARK: Install / remove

    /// Call once per style load. Nothing is added to the style until the tile is actually shown.
    func install(on map: MapboxMap) {
        self.map = map
        installed = true
        scheduleUpdate(delay: 0.2)
    }

    /// Called when the style reloads: Mapbox drops every runtime layer and source.
    func styleDidReload() {
        installed = false
        shown = false
        revealClock?.invalidate()
        revealClock = nil
        isRetracting = false
        let completion = retractionCompletion
        retractionCompletion = nil
        updateWaterClock()
        renderLayer = nil
        basemapTerrainSuppressed = false
        appliedCategories = []
        appliedTimeOfDay = nil
        appliedDebug = false
        completion?()
    }

    func remove() {
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
        if shown { beginReveal() }
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

    // MARK: Updates

    func scheduleUpdate(delay: Double) {
        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.update()
        }
    }

    /// Shows the tile while the camera is near it and zoomed in; hides it otherwise.
    func update() {
        guard installed, let map else { return }
        guard retractionCompletion == nil else { return }
        applyCategoryVisibility()
        applyDebug()

        if state.isBasemapOnly {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
            if shown { beginRetraction() }
            state.status = "Basemap-only comparison · custom shoreline hidden"
            return
        }
        let camera = map.cameraState
        let centreTile = DioramaTileID(latitude: camera.center.latitude, longitude: camera.center.longitude, zoom: config.tileZoom)
        let withinCoverage = DioramaMasakiSource.contains(latitude: camera.center.latitude, longitude: camera.center.longitude)
        guard withinCoverage else {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
            beginRetraction()
            state.status = "Masaki coverage · pan back to the peninsula"
            return
        }
        guard camera.zoom >= config.minimumZoom else {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
            beginRetraction()
            state.status = "Zoom in to \(Int(config.minimumZoom)) to build the diorama"
            return
        }
        // Hysteresis avoids rebuilding when a resting camera straddles an exact tile boundary.
        let local = DioramaProjection(origin: tile.centre)
        let inside = local.rect(of: tile).expanded(by: 45).contains(local.local(longitude: camera.center.longitude, latitude: camera.center.latitude))
        if centreTile != tile, !inside {
            requestTile(centreTile)
        } else {
            selectionTask?.cancel(); selectionTask = nil; requestedTile = nil
        }
        switch status {
        case .idle:
            generate()
        case .generating:
            state.status = "Generating \(areaName)… · full detail"
        case .loaded(let artifacts):
            if !shown { show(artifacts, on: map) }
            else if isRetracting { beginReveal(fromCurrent: true) }
        case .failed:
            state.status = "Tile unavailable · basemap retained. Regenerate online to retry."
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

    /// Bounded full-detail residency: visit any covered tile without retaining the whole city.
    /// This is a one-tile preview, not yet a seamless multi-tile renderer.
    private func requestTile(_ next: DioramaTileID) {
        guard requestedTile != next else { return }
        selectionTask?.cancel()
        requestedTile = next
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.65)) } catch { return }
            guard let self, let map = self.map, self.installed, self.retractionCompletion == nil,
                  self.requestedTile == next, !self.state.isBasemapOnly,
                  map.cameraState.zoom >= self.config.minimumZoom,
                  DioramaTileID(latitude: map.cameraState.center.latitude, longitude: map.cameraState.center.longitude, zoom: self.config.tileZoom) == next else { return }
            self.generationRevision &+= 1
            self.generationTask?.cancel(); self.generationTask = nil
            self.packageTask?.cancel(); self.packageTask = nil
            self.hide(on: map)
            DioramaTileGenerator.clearCache(for: self.tile, config: self.config)
            self.state.loadedTiles.removeAll()
            self.state.frameReport = "Waiting for the new tile's frame measurements."
            self.tile = next
            self.bypassDiskOnNextGeneration = false
            self.status = .idle
            self.requestedTile = nil
            self.selectionTask = nil
            self.generate()
        }
    }

    // MARK: Generation

    /// Bundled terrain remains authoritative; one whole Mapbox tile supplements coverage and names.
    private var bypassDiskOnNextGeneration: Bool = false

    private func generate() {
        status = .generating
        state.status = "Generating \(areaName)… · full detail"
        generationRevision &+= 1
        let revision = generationRevision
        let config = self.config
        // Power policy may disable effects, but never change the city's generated detail.
        let reduced = false
        let tile = self.tile
        let bypassDisk = bypassDiskOnNextGeneration
        bypassDiskOnNextGeneration = false
        let token = MapboxOptions.accessToken
        let offline = UserDefaults.standard.bool(forKey: "maps.downloadedOnly")
        generationTask = Task.detached(priority: .userInitiated) {
            let artifacts: DioramaTileArtifacts?
            var needsPackage = false
            let started = Date()
            if bypassDisk { await DioramaDiskCache.shared.remove(tile: tile, config: config) }
            if let cached = DioramaTileGenerator.cached(tile, config: config, reduced: reduced) {
                artifacts = cached
            } else if let disk = await DioramaDiskCache.shared.read(tile: tile, config: config, reduced: reduced) {
                artifacts = disk
            } else if let data = await DioramaMasakiSource.load(tile: tile, config: config, token: token, offline: offline), !data.isEmpty {
                guard !Task.isCancelled else { return }
                do {
                    artifacts = try await DioramaGenerationQueue.shared.generate(data, config: config)
                    needsPackage = true
                } catch {
                    print("[Diorama] generate failed: \(error)")
                    artifacts = nil
                }
            } else {
                artifacts = nil
            }
            guard !Task.isCancelled else { return }
            let shouldWrite = needsPackage
            let readySeconds = Date().timeIntervalSince(started)
            await MainActor.run {
                guard self.generationRevision == revision, case .generating = self.status else { return }
                self.generationTask = nil
                guard var artifacts else {
                    self.status = .failed
                    self.state.status = "Tile unavailable · basemap retained. Regenerate online to retry."
                    return
                }
                artifacts.stageTimings.append("source/cache → renderer-ready: \(String(format: "%.3f", readySeconds))s (not first visible)")
                if tile != DioramaMasakiSource.slipway {
                    artifacts.stageTimings.append("Masaki camera-follow preview · one resident tile · mapped footprints/water/land use + Terrain-RGB")
                }
                self.status = .loaded(artifacts)
                if shouldWrite { self.persistAfterPresentation(artifacts, revision: revision) }
                print("[Diorama] \(artifacts.tile): \(artifacts.totalTriangles) unique tris, \(artifacts.lightDrawnTriangles)–\(artifacts.drawnTriangles) drawn (light–full LOD), \(artifacts.totalInstances) instances, \(artifacts.totalBytes / 1024) KB in \(String(format: "%.2f", artifacts.generationSeconds))s")
                self.scheduleUpdate(delay: 0.05)
            }
        }
    }

    /// Publication no longer waits for compression. Writes still run off-main and carry the
    /// generation revision so a late completion cannot replace a newer tile's diagnostics.
    private func persistAfterPresentation(_ artifacts: DioramaTileArtifacts, revision: UInt) {
        packageTask?.cancel()
        let config = self.config
        packageTask = Task.detached(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            let started = ProcessInfo.processInfo.systemUptime
            guard let bytes = await DioramaDiskCache.shared.write(artifacts, config: config, reduced: false), !Task.isCancelled else { return }
            let line = "background lossless package write: \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s · \(String(format: "%.2f", Double(bytes) / 1_048_576)) MiB on disk"
            await MainActor.run { [weak self] in
                guard let self, self.generationRevision == revision, case .loaded(var current) = self.status else { return }
                current.stageTimings.append(line)
                self.status = .loaded(current)
                if self.shown { self.state.loadedTiles[current.tile] = current }
                self.packageTask = nil
            }
        }
    }

    /// Drops the cached geometry and rebuilds it.
    func regenerate() {
        guard let map else { return }
        bypassDiskOnNextGeneration = true
        packageTask?.cancel(); packageTask = nil
        generationRevision &+= 1
        generationTask?.cancel(); generationTask = nil
        DioramaTileGenerator.clearCache(for: tile, config: config)
        hide(on: map)
        status = .idle
        state.loadedTiles[tile] = nil
        scheduleUpdate(delay: 0.05)
    }

    // MARK: Showing

    /// Adds the custom Metal layer and a clip layer over the tile so Standard's own buildings disappear
    /// under the toy town. Same calls, same order, as `DarCityLandmarks.install`.
    private func show(_ artifacts: DioramaTileArtifacts, on map: MapboxMap) {
        do {
            hide(on: map)
            let animates = !UIAccessibility.isReduceMotionEnabled
            let host = DioramaRenderLayer(
                origin: tile.centre, vertices: artifacts.vertices, indices: artifacts.indices, ranges: artifacts.ranges,
                groups: artifacts.groups, instances: artifacts.allInstances, lightGrid: artifacts.lightGrid, waterHeight: artifacts.waterHeight, groundImage: artifacts.groundImage,
                groundRect: DioramaProjection(origin: tile.centre).rect(of: tile), visible: state.visibleCategories, timeOfDay: state.timeOfDay,
                animates: animates, config: config, labels: artifacts.buildingLabels, displayScale: Float(UIScreen.main.scale)
            )
            host.onFrameReport = { [weak self, weak host] report in
                Task { @MainActor [weak self, weak host] in
                    guard let self, let host, self.renderLayer === host, self.shown else { return }
                    self.state.frameReport = report
                }
            }
            try map.addCustomLayer(withId: layerID, layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: layerID, property: "slot", value: "middle")
            var source = GeoJSONSource(id: clipSourceID)
            source.data = .geometry(.polygon(Polygon([tile.outline])))
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
            beginReveal()
            suppressBasemapTerrain(true)
            host.setReducedEffects(reducesEffects)
            host.setWireframe(state.showsWireframe)
            appliedWireframe = state.showsWireframe
            state.loadedTiles[tile] = artifacts
            updateEffectStatus()
            updateWaterClock()
            map.triggerRepaint()
        } catch {
            print("[Diorama] show failed: \(error)")
            hide(on: map)
            status = .failed
        }
    }

    private func hide(on map: MapboxMap) {
        revealClock?.invalidate()
        revealClock = nil
        for id in [labelClipID, clipLayerID, layerID] where map.layerExists(withId: id) { try? map.removeLayer(withId: id) }
        if map.sourceExists(withId: clipSourceID) { try? map.removeSource(withId: clipSourceID) }
        if map.sourceExists(withId: labelSourceID) { try? map.removeSource(withId: labelSourceID) }
        renderLayer = nil
        appliedWireframe = nil
        shown = false
        isRetracting = false
        suppressBasemapTerrain(false)
        updateWaterClock()
        let completion = retractionCompletion
        retractionCompletion = nil
        completion?()
    }

    /// One finite 30 Hz reveal, including cached tiles and explicit focus requests.
    private func beginReveal(fromCurrent: Bool = false) {
        isRetracting = false
        transitionFrom = fromCurrent ? currentExtent : 0.8
        currentExtent = transitionFrom
        revealClock?.invalidate()
        revealClock = nil
        guard shown, let renderLayer else { return }
        revealStarted = nil
        revealRequested = CACurrentMediaTime()
        renderLayer.setReveal(SIMD4(0, 0, Float(currentExtent), 1))
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
        guard shown, !isRetracting else { return }
        guard !UIAccessibility.isReduceMotionEnabled, !reducesEffects, UIApplication.shared.applicationState == .active,
              renderLayer?.diagnostic.hasPrefix("ready") == true else {
            if let map { hide(on: map) }; return
        }
        revealClock?.invalidate()
        isRetracting = true
        transitionFrom = currentExtent
        revealStarted = CACurrentMediaTime()
        revealRequested = revealStarted ?? 0
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
        let finish = UIApplication.shared.applicationState != .active || UIAccessibility.isReduceMotionEnabled || reducesEffects
        let diagnostic = renderLayer.diagnostic
        guard diagnostic.hasPrefix("ready") else {
            if diagnostic.contains("failed") || diagnostic.contains("missing") || now - revealRequested > 8 || UIApplication.shared.applicationState != .active {
                if let map { hide(on: map) }
                status = .failed
                state.status = "Diorama unavailable · basemap restored. Try Regenerate."
            } else { map?.triggerRepaint() }
            return
        }
        if revealStarted == nil { revealStarted = now }
        let progress = finish ? 1 : min(1, max(0, (now - (revealStarted ?? now)) / 1.8))
        let eased = progress * progress * (3 - 2 * progress)
        currentExtent = transitionFrom + ((isRetracting ? 0 : fullExtent) - transitionFrom) * eased
        if isRetracting, progress >= 1 {
            if let map { hide(on: map); map.triggerRepaint() }
            return
        }
        renderLayer.setReveal(progress >= 1 ? .zero : SIMD4(0, 0, Float(currentExtent), 1))
        setRevealClip(halfExtent: progress >= 1 ? nil : max(0.001, currentExtent))
        map?.triggerRepaint()
        if progress >= 1 { revealClock?.invalidate(); revealClock = nil }
    }

    /// The native buildings disappear behind the same growing square, not all at once.
    private func setRevealClip(halfExtent: Double?) {
        guard let map, map.sourceExists(withId: clipSourceID) else { return }
        let projection = DioramaProjection(origin: tile.centre)
        let rect = projection.rect(of: tile)
        let coordinates: [CLLocationCoordinate2D]
        if let e = halfExtent {
            let points = [DV2(max(rect.minX, -e), max(rect.minY, -e)), DV2(min(rect.maxX, e), max(rect.minY, -e)),
                          DV2(min(rect.maxX, e), min(rect.maxY, e)), DV2(max(rect.minX, -e), min(rect.maxY, e))]
            coordinates = (points + [points[0]]).map { p in
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
