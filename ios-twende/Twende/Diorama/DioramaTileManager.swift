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
    /// Incremented by the debug panel to request a regenerate of the centre tile.
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

/// Lifecycle of generated tiles on one map: decides which z16 tiles are needed for the camera, loads
/// their vector data, generates .glb models off-main, registers style models and model layers, and
/// unloads tiles that leave the buffer. Owns no UI.
@MainActor
final class DioramaTileManager {
    let config: DioramaConfig
    private let state: DioramaState
    private let loader: DioramaDataLoader
    private let styling: DioramaMapStyling
    private let library: DioramaPropLibrary
    private weak var map: MapboxMap?

    private enum TileStatus {
        case waitingForData(attempts: Int)
        case generating
        case loaded(DioramaTileArtifacts, reduced: Bool)
        case empty
        case failed
    }

    private var tiles: [DioramaTileID: TileStatus] = [:]
    private var installed: Bool = false
    private var pendingUpdate: Task<Void, Never>? = nil
    private var sourceLoaded: Bool = false
    private var cancelables: Set<AnyCancelable> = []
    private var appliedTimeOfDay: DioramaTimeOfDay? = nil
    private var appliedCategories: Set<DioramaCategory> = []
    private var appliedDebug: Bool = false
    private var thermalReduced: Bool = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    private var thermalObserver: NSObjectProtocol? = nil

    init(config: DioramaConfig = .masaki, state: DioramaState = .shared) {
        self.config = config
        self.state = state
        loader = DioramaDataLoader(config: config)
        styling = DioramaMapStyling(config: config)
        library = DioramaPropLibrary(config: config)
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reduced = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                guard reduced != self.thermalReduced else { return }
                self.thermalReduced = reduced
                self.reloadAll()
            }
        }
    }

    // MARK: Install / remove

    /// Adds the data source, the styled layers and Standard config overrides. Call once per style load.
    func install(on map: MapboxMap) {
        self.map = map
        guard !installed else { return }
        do {
            try loader.install(on: map)
            try styling.install(on: map)
            try map.setStyleImportConfigProperty(for: "basemap", config: "show3dObjects", value: false)
            try map.setStyleImportConfigProperty(for: "basemap", config: "showRoadLabels", value: false)
            try map.setStyleImportConfigProperty(for: "basemap", config: "show3dLandmarks", value: false)
            installed = true
            applyTimeOfDay(force: true)
            map.onSourceDataLoaded.observe { [weak self] event in
                guard let self, event.sourceId == DioramaDataLoader.sourceID, event.type == .tile else { return }
                self.sourceLoaded = true
                self.scheduleUpdate(delay: 0.25)
            }.store(in: &cancelables)
            map.onMapIdle.observe { [weak self] _ in self?.scheduleUpdate(delay: 0.05) }.store(in: &cancelables)
            scheduleUpdate(delay: 0.5)
        } catch {
            print("[Diorama] install failed: \(error)")
        }
    }

    /// Called when the style reloads: Mapbox drops every runtime layer, source and model.
    func styleDidReload() {
        installed = false
        sourceLoaded = false
        appliedTimeOfDay = nil
        appliedCategories = []
        appliedDebug = false
        tiles.removeAll()
        state.loadedTiles.removeAll()
        cancelables.removeAll()
    }

    func remove() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        cancelables.removeAll()
        guard let map else { return }
        for tile in tiles.keys { unload(tile, from: map) }
        tiles.removeAll()
        state.loadedTiles.removeAll()
        if installed {
            styling.remove(from: map)
            loader.remove(from: map)
            try? map.setStyleImportConfigProperty(for: "basemap", config: "show3dObjects", value: true)
            try? map.setStyleImportConfigProperty(for: "basemap", config: "showRoadLabels", value: true)
            try? map.setStyleImportConfigProperty(for: "basemap", config: "show3dLandmarks", value: true)
            try? map.setStyleImportConfigProperty(for: "basemap", config: "lightPreset", value: AppSettings.shared.mapStyle.lightPreset)
        }
        installed = false
        appliedTimeOfDay = nil
    }

    // MARK: Camera

    /// Camera options for the opening shot over the seed tile.
    func introCamera() -> CameraOptions {
        let tile = DioramaTileID(latitude: config.seedLatitude, longitude: config.seedLongitude, zoom: config.tileZoom)
        return CameraOptions(center: tile.centre, zoom: config.cameraZoom, bearing: config.cameraBearing, pitch: config.cameraPitch)
    }

    // MARK: Updates

    func scheduleUpdate(delay: Double) {
        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.update()
        }
    }

    /// Reconciles the loaded tiles with the camera and applies pending style changes.
    func update() {
        guard installed, let map else { return }
        applyTimeOfDay(force: false)
        applyCategoryVisibility(force: false)
        applyDebug()

        let camera = map.cameraState
        guard camera.zoom >= config.minimumZoom else {
            for tile in tiles.keys { unload(tile, from: map) }
            tiles.removeAll()
            state.loadedTiles.removeAll()
            state.status = "Zoom in to \(Int(config.minimumZoom)) to build the diorama"
            return
        }

        let needed = neededTiles(map: map, camera: camera)
        for tile in tiles.keys where !needed.contains(tile) {
            unload(tile, from: map)
            tiles[tile] = nil
            state.loadedTiles[tile] = nil
        }
        for tile in needed where tiles[tile] == nil {
            guard tiles.count < config.maxLoadedTiles else { break }
            tiles[tile] = .waitingForData(attempts: 0)
            load(tile)
        }
        for (tile, status) in tiles {
            if case .waitingForData = status { load(tile) }
        }
        updateStatus()
    }

    /// Visible z16 tiles sorted by distance from the centre, plus a one-tile buffer, capped.
    private func neededTiles(map: MapboxMap, camera: CameraState) -> [DioramaTileID] {
        let bounds = map.coordinateBounds(for: CameraOptions(cameraState: camera))
        let centreTile = DioramaTileID(latitude: camera.center.latitude, longitude: camera.center.longitude, zoom: config.tileZoom)
        let sw = DioramaTileID(latitude: bounds.southwest.latitude, longitude: bounds.southwest.longitude, zoom: config.tileZoom)
        let ne = DioramaTileID(latitude: bounds.northeast.latitude, longitude: bounds.northeast.longitude, zoom: config.tileZoom)
        // A pitched camera sees to the horizon; never let the visible rectangle exceed the buffer ring.
        let reach = config.bufferTiles + 1
        let minX = max(sw.x, centreTile.x - reach), maxX = min(ne.x, centreTile.x + reach)
        let minY = max(ne.y, centreTile.y - reach), maxY = min(sw.y, centreTile.y + reach)
        var result: [DioramaTileID] = []
        guard minX <= maxX, minY <= maxY else { return [centreTile] }
        for x in (minX - config.bufferTiles)...(maxX + config.bufferTiles) {
            for y in (minY - config.bufferTiles)...(maxY + config.bufferTiles) {
                result.append(DioramaTileID(z: config.tileZoom, x: x, y: y))
            }
        }
        result.sort { lhs, rhs in
            let dl = abs(lhs.x - centreTile.x) + abs(lhs.y - centreTile.y)
            let dr = abs(rhs.x - centreTile.x) + abs(rhs.y - centreTile.y)
            return dl != dr ? dl < dr : (lhs.x, lhs.y) < (rhs.x, rhs.y)
        }
        return Array(result.prefix(config.maxLoadedTiles))
    }

    // MARK: Loading

    private func load(_ tile: DioramaTileID) {
        guard let map, case .waitingForData(let attempts) = tiles[tile] else { return }
        let reduced = thermalReduced
        if let cached = DioramaTileGenerator.cached(tile, config: config, reduced: reduced) {
            tiles[tile] = .loaded(cached, reduced: reduced)
            show(cached, on: map)
            return
        }
        guard sourceLoaded else { return }
        tiles[tile] = .generating
        loader.load(tile, on: map) { [weak self] data in
            guard let self, let map = self.map, case .generating = self.tiles[tile] else { return }
            guard let data, !data.isEmpty else {
                // Tiles still streaming in come back empty; retry a few times before giving up.
                if attempts < 6 {
                    self.tiles[tile] = .waitingForData(attempts: attempts + 1)
                    self.scheduleUpdate(delay: 0.8)
                } else {
                    self.tiles[tile] = .empty
                }
                return
            }
            let config = self.config
            let library = self.library
            Task.detached(priority: .userInitiated) {
                let artifacts: DioramaTileArtifacts?
                do {
                    artifacts = try DioramaTileGenerator.generate(data, config: config, library: library, reduced: reduced)
                } catch {
                    print("[Diorama] generate \(tile) failed: \(error)")
                    artifacts = nil
                }
                await MainActor.run {
                    guard case .generating = self.tiles[tile] else { return }
                    guard let artifacts else { self.tiles[tile] = .failed; return }
                    self.tiles[tile] = .loaded(artifacts, reduced: reduced)
                    print("[Diorama] tile \(tile): \(artifacts.totalTriangles) tris, \(artifacts.totalBytes / 1024) KB in \(String(format: "%.2f", artifacts.generationSeconds))s")
                    self.show(artifacts, on: map)
                }
            }
        }
    }

    private func modelID(_ tile: DioramaTileID, _ category: DioramaCategory) -> String { "zuri-diorama-\(tile.key)-\(category.rawValue)" }
    private func sourceID(_ tile: DioramaTileID) -> String { "zuri-diorama-src-\(tile.key)" }
    private func layerID(_ tile: DioramaTileID, _ category: DioramaCategory) -> String { "zuri-diorama-\(tile.key)-\(category.rawValue)" }

    /// Registers each .glb as a style model and shows it with a `ModelLayer` anchored at the tile centre.
    private func show(_ artifacts: DioramaTileArtifacts, on map: MapboxMap) {
        let tile = artifacts.tile
        do {
            if !map.sourceExists(withId: sourceID(tile)) {
                var source = GeoJSONSource(id: sourceID(tile))
                source.data = .feature(Feature(geometry: .point(Point(tile.centre))))
                try map.addSource(source)
            }
            for part in artifacts.parts {
                let id = modelID(tile, part.category)
                if map.hasStyleModel(modelId: id) { try map.removeStyleModel(modelId: id) }
                try map.addStyleModel(modelId: id, modelUri: part.url.absoluteString)
                if map.layerExists(withId: layerID(tile, part.category)) { try map.removeLayer(withId: layerID(tile, part.category)) }
                var layer = ModelLayer(id: layerID(tile, part.category), source: sourceID(tile))
                layer.slot = .middle
                layer.minZoom = config.minimumZoom
                layer.modelId = .constant(id)
                layer.modelType = .constant(.common3d)
                layer.modelScale = .constant([1, 1, 1])
                layer.modelRotation = .constant([0, 0, 0])
                layer.modelTranslation = .constant([0, 0, 0])
                layer.modelRoughness = .constant(1)
                layer.modelCastShadows = .constant(!part.category.isEmissive)
                layer.modelReceiveShadows = .constant(!part.category.isEmissive)
                layer.modelAmbientOcclusionIntensity = .constant(0.6)
                layer.modelCutoffFadeRange = .constant(0)
                layer.modelEmissiveStrength = .constant(part.category.isEmissive ? state.timeOfDay.emissiveStrength : 0)
                layer.visibility = .constant(state.isVisible(part.category) ? .visible : .none)
                try map.addLayer(layer)
            }
            state.loadedTiles[tile] = artifacts
            updateStatus()
            map.triggerRepaint()
        } catch {
            print("[Diorama] show \(tile) failed: \(error)")
            tiles[tile] = .failed
        }
    }

    private func unload(_ tile: DioramaTileID, from map: MapboxMap) {
        for category in DioramaCategory.allCases {
            if map.layerExists(withId: layerID(tile, category)) { try? map.removeLayer(withId: layerID(tile, category)) }
            if map.hasStyleModel(modelId: modelID(tile, category)) { try? map.removeStyleModel(modelId: modelID(tile, category)) }
        }
        if map.sourceExists(withId: sourceID(tile)) { try? map.removeSource(withId: sourceID(tile)) }
    }

    /// Drops the cache for the tile under the camera and rebuilds it.
    func regenerateCentreTile() {
        guard let map else { return }
        let camera = map.cameraState
        let tile = DioramaTileID(latitude: camera.center.latitude, longitude: camera.center.longitude, zoom: config.tileZoom)
        DioramaTileGenerator.clearCache(for: tile, config: config)
        unload(tile, from: map)
        tiles[tile] = nil
        state.loadedTiles[tile] = nil
        scheduleUpdate(delay: 0.05)
    }

    private func reloadAll() {
        guard let map else { return }
        for tile in tiles.keys { unload(tile, from: map) }
        tiles.removeAll()
        state.loadedTiles.removeAll()
        scheduleUpdate(delay: 0.05)
    }

    // MARK: Style state

    private func applyTimeOfDay(force: Bool) {
        guard let map, installed, force || appliedTimeOfDay != state.timeOfDay else { return }
        appliedTimeOfDay = state.timeOfDay
        try? map.setStyleImportConfigProperty(for: "basemap", config: "lightPreset", value: state.timeOfDay.lightPreset)
        for (tile, status) in tiles {
            guard case .loaded(let artifacts, _) = status else { continue }
            for part in artifacts.parts where part.category.isEmissive {
                try? map.setLayerProperty(for: layerID(tile, part.category), property: "model-emissive-strength", value: state.timeOfDay.emissiveStrength)
            }
        }
        applyCategoryVisibility(force: true)
    }

    private func applyCategoryVisibility(force: Bool) {
        guard let map, installed, force || appliedCategories != state.visibleCategories else { return }
        appliedCategories = state.visibleCategories
        for (tile, status) in tiles {
            guard case .loaded(let artifacts, _) = status else { continue }
            for part in artifacts.parts {
                try? map.setLayerProperty(for: layerID(tile, part.category), property: "visibility", value: state.isVisible(part.category) ? "visible" : "none")
            }
        }
    }

    private func applyDebug() {
        guard let map, installed else { return }
        let show = state.showsDebugOverlay
        let loaded = tiles.keys.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        if show || appliedDebug {
            styling.setTileBounds(loaded, visible: show, on: map)
            loader.setFootprintsVisible(show, on: map)
        }
        appliedDebug = show
    }

    private func updateStatus() {
        let loaded = tiles.values.filter { if case .loaded = $0 { return true } else { return false } }.count
        let generating = tiles.values.filter { if case .generating = $0 { return true } else { return false } }.count
        let waiting = tiles.values.filter { if case .waitingForData = $0 { return true } else { return false } }.count
        var text = "\(loaded) tiles loaded"
        if generating > 0 { text += ", \(generating) generating" }
        if waiting > 0 { text += ", \(waiting) waiting for data" }
        if thermalReduced { text += " · reduced detail (thermal)" }
        state.status = text
    }
}
