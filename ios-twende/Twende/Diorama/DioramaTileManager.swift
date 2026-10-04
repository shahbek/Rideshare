import Foundation
@_spi(Experimental) import MapboxMaps

/// Observable diorama state shared by the map coordinator and the debug panel.
@Observable
@MainActor
final class DioramaState {
    static let shared = DioramaState()

    var isEnabled: Bool = false
    var timeOfDay: DioramaTimeOfDay = .dusk
    var visibleCategories: Set<DioramaCategory> = Set(DioramaCategory.allCases)
    var showsDebugOverlay: Bool = false
    /// Set after a successful tile load so the panel can report numbers.
    var loadedTiles: [DioramaTileID: DioramaTileArtifacts] = [:]
    var status: String = ""
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

/// Lifecycle of the single Slipway tile on one map. The whole thing is built from the bundled OSM
/// extract on a background thread, then shown through one custom Metal layer, exactly like the
/// destination buildings and city landmarks. Mapbox is only asked for two things: a custom layer
/// slot and a clip layer that hides Standard's own 3D buildings under the toy town.
@MainActor
final class DioramaTileManager {
    let config: DioramaConfig
    private let state: DioramaState
    private let styling: DioramaMapStyling
    private let library: DioramaPropLibrary
    private weak var map: MapboxMap?

    private enum Status {
        case idle
        case generating
        case loaded(DioramaTileArtifacts)
        case failed
    }

    private let tile: DioramaTileID
    private var status: Status = .idle
    private var shown: Bool = false
    private var installed: Bool = false
    private var pendingUpdate: Task<Void, Never>? = nil
    private var appliedCategories: Set<DioramaCategory> = []
    private var appliedTimeOfDay: DioramaTimeOfDay? = nil
    private var appliedDebug: Bool = false
    private var thermalReduced: Bool = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    private var thermalObserver: NSObjectProtocol? = nil
    private var renderLayer: DioramaRenderLayer? = nil

    private var layerID: String { "zuri-diorama-\(tile.key)" }
    private var clipLayerID: String { "zuri-diorama-clip-\(tile.key)" }
    private var clipSourceID: String { "zuri-diorama-clip-src-\(tile.key)" }

    init(config: DioramaConfig = .slipway, state: DioramaState = .shared) {
        self.config = config
        self.state = state
        tile = DioramaTileID(latitude: config.seedLatitude, longitude: config.seedLongitude, zoom: config.tileZoom)
        styling = DioramaMapStyling(config: config)
        library = DioramaPropLibrary(config: config)
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reduced = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                guard reduced != self.thermalReduced else { return }
                self.thermalReduced = reduced
                self.regenerate()
            }
        }
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
        renderLayer = nil
        appliedCategories = []
        appliedTimeOfDay = nil
        appliedDebug = false
    }

    func remove() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        guard let map else { return }
        hide(on: map)
        styling.remove(from: map)
        state.loadedTiles.removeAll()
        installed = false
    }

    // MARK: Camera

    /// Camera options for the opening shot over the tile.
    func introCamera() -> CameraOptions {
        CameraOptions(center: tile.centre, zoom: config.cameraZoom, bearing: config.cameraBearing, pitch: config.cameraPitch)
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
        applyCategoryVisibility()
        applyDebug()

        let camera = map.cameraState
        let centreTile = DioramaTileID(latitude: camera.center.latitude, longitude: camera.center.longitude, zoom: config.tileZoom)
        let near = abs(centreTile.x - tile.x) <= config.visibilityRadiusTiles && abs(centreTile.y - tile.y) <= config.visibilityRadiusTiles
        guard near, camera.zoom >= config.minimumZoom else {
            hide(on: map)
            state.status = near ? "Zoom in to \(Int(config.minimumZoom)) to build the diorama" : "Fly to Slipway to see the diorama"
            return
        }

        switch status {
        case .idle:
            generate()
        case .generating:
            state.status = "Generating Slipway…"
        case .loaded(let artifacts):
            if !shown { show(artifacts, on: map) }
        case .failed:
            state.status = "Diorama generation failed"
        }
    }

    // MARK: Generation

    private func generate() {
        status = .generating
        state.status = "Generating Slipway…"
        let config = self.config
        let library = self.library
        let reduced = thermalReduced
        Task.detached(priority: .userInitiated) {
            let artifacts: DioramaTileArtifacts?
            if let data = DioramaBundledTile.load(config: config), !data.isEmpty {
                do {
                    artifacts = try DioramaTileGenerator.generate(data, config: config, library: library, reduced: reduced)
                } catch {
                    print("[Diorama] generate failed: \(error)")
                    artifacts = nil
                }
            } else {
                artifacts = nil
            }
            await MainActor.run {
                guard case .generating = self.status else { return }
                guard let artifacts else {
                    self.status = .failed
                    self.state.status = "Diorama generation failed"
                    return
                }
                self.status = .loaded(artifacts)
                print("[Diorama] \(artifacts.tile): \(artifacts.totalTriangles) tris, \(artifacts.totalBytes / 1024) KB in \(String(format: "%.2f", artifacts.generationSeconds))s")
                self.scheduleUpdate(delay: 0.05)
            }
        }
    }

    /// Drops the cached geometry and rebuilds it.
    func regenerate() {
        guard let map else { return }
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
            let host = DioramaRenderLayer(
                origin: tile.centre, vertices: artifacts.vertices, indices: artifacts.indices, ranges: artifacts.ranges,
                lights: artifacts.lights, visible: state.visibleCategories, timeOfDay: state.timeOfDay
            )
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
            renderLayer = host
            shown = true
            state.loadedTiles[tile] = artifacts
            state.status = "Slipway loaded" + (thermalReduced ? " · reduced detail (thermal)" : "")
            map.triggerRepaint()
        } catch {
            print("[Diorama] show failed: \(error)")
            hide(on: map)
            status = .failed
        }
    }

    private func hide(on map: MapboxMap) {
        for id in [clipLayerID, layerID] where map.layerExists(withId: id) { try? map.removeLayer(withId: id) }
        if map.sourceExists(withId: clipSourceID) { try? map.removeSource(withId: clipSourceID) }
        renderLayer = nil
        shown = false
    }

    // MARK: Style state

    private func applyCategoryVisibility() {
        guard let map, let renderLayer else { return }
        guard appliedCategories != state.visibleCategories || appliedTimeOfDay != state.timeOfDay else { return }
        appliedCategories = state.visibleCategories
        appliedTimeOfDay = state.timeOfDay
        renderLayer.setVisible(state.visibleCategories, timeOfDay: state.timeOfDay)
        map.triggerRepaint()
    }

    private func applyDebug() {
        guard let map else { return }
        let show = state.showsDebugOverlay
        if show || appliedDebug {
            styling.setTileBounds(shown ? [tile] : [], visible: show, on: map)
        }
        appliedDebug = show
    }
}
