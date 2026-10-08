import Foundation
@_spi(Experimental) import MapboxMaps
import UIKit

/// Saved 3×3 coarse coverage, including a same-tile fallback beneath the feathered full-detail focus.
@MainActor
final class DioramaContextTiles {
    private final class Resident {
        let host: DioramaRenderLayer
        let bytes: Int
        let triangles: Int
        let extent: Float
        let rect: DioramaRect
        var currentExtent: Float = -DioramaRevealStyle.support - 2
        var connection: Float = 0
        var isRemoving: Bool = false
        var transition: Task<Void, Never>?

        init(host: DioramaRenderLayer, artifacts: DioramaTileArtifacts) {
            self.host = host
            rect = DioramaProjection(origin: artifacts.tile.centre).rect(of: artifacts.tile)
            bytes = artifacts.totalBytes; triangles = artifacts.totalTriangles
            extent = max(abs(host.revealBounds.minimum.x), abs(host.revealBounds.maximum.x),
                         abs(host.revealBounds.minimum.y), abs(host.revealBounds.maximum.y))
                + DioramaRevealStyle.support + 50
        }
    }
    private var residents: [DioramaTileID: Resident] = [:]
    private var focus: DioramaTileID?
    private var fullMasks: [DioramaTileID: SIMD4<Float>] = [:]
    private var retirements: [DioramaTileID: Task<Void, Never>] = [:]
    private var task: Task<Void, Never>?
    private var revision: UInt = 0
    private var retryAfter: [DioramaTileID: Date] = [:]
    private var availability: String = ""
    private var wantedTiles: [DioramaTileID] = []
    private weak var map: MapboxMap?
    private var visible: Set<DioramaCategory> = []
    private var time: DioramaTimeOfDay = .dusk
    private var wireframe: Bool = false
    private var reducedEffects: Bool = false
    var onReady: ((DioramaTileID) -> Void)?
    var onUnavailable: ((DioramaTileID) -> Void)?
    var onFocusCoverage: ((DioramaTileID, SIMD4<Float>, Bool) -> Void)?
    var onWaterVisibilityChanged: (() -> Void)?

    func groundHeight(at point: GeoPoint) -> Double? {
        let tile = DioramaTileID(latitude: point.latitude, longitude: point.longitude, zoom: 16)
        return residents[tile]?.host.groundHeight(at: point)
    }

    func isReady(_ tile: DioramaTileID) -> Bool { residents[tile]?.connection == 1 && residents[tile]?.isRemoving != true }
    var retryDelay: TimeInterval? {
        let now = Date()
        return wantedTiles.filter { residents[$0] == nil }.compactMap { retryAfter[$0] }
            .filter { $0 > now }.min().map { max(0.1, $0.timeIntervalSince(now)) }
    }
    var isTransitioning: Bool { residents.values.contains { $0.isRemoving } || !retirements.isEmpty }
    var hasWaterInView: Bool { residents.values.contains { $0.host.hasWaterInView } }
    var report: String {
        "Context: \(residents.count) coarse/fallback tiles · \(residents.values.reduce(0) { $0 + $1.triangles }) stored tris · \(residents.values.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB packed (not total memory)\(availability)"
    }

    func setReducedEffects(_ reduced: Bool, waterMotion: Bool) {
        reducedEffects = reduced
        for resident in residents.values {
            resident.host.setReducedEffects(reduced)
            resident.host.setWaterMotion(waterMotion)
        }
    }

    func update(focus next: DioramaTileID, config: DioramaConfig, map: MapboxMap,
                visible: Set<DioramaCategory>, time: DioramaTimeOfDay, wireframe: Bool,
                priorityTiles: [DioramaTileID] = []) {
        self.map = map; self.visible = visible; self.time = time; self.wireframe = wireframe
        for resident in residents.values {
            resident.host.setVisible(visible, timeOfDay: time)
            resident.host.setWireframe(wireframe)
        }
        let sameFocus = focus == next
        let ring = (-1...1).flatMap { y in (-1...1).compactMap { x -> DioramaTileID? in
            let tile = DioramaTileID(z: next.z, x: next.x + x, y: next.y + y)
            return DioramaOfflineStore.tiles.contains(tile) ? tile : nil
        }}.sorted {
            // Actual neighbours have priority over the optional same-tile fallback.
            let a = $0 == next ? 10 : abs($0.x - next.x) + abs($0.y - next.y)
            let b = $1 == next ? 10 : abs($1.x - next.x) + abs($1.y - next.y)
            return a == b ? $0.key < $1.key : a < b
        }
        var seen: Set<DioramaTileID> = []
        let ordered = (priorityTiles.filter { $0 != next || fullMasks[next] == nil } + ring.filter { $0 != next }
            + fullMasks.keys.filter { $0 != next }.sorted { $0.key < $1.key } + [next])
            .filter { DioramaOfflineStore.tiles.contains($0) && seen.insert($0).inserted }
        let tiles = Array(ordered.prefix(9))
        let wanted = Set(tiles).union(fullMasks.keys)
        if sameFocus && Set(wantedTiles) == Set(tiles) && task != nil { return }
        if sameFocus && wantedTiles == tiles && tiles.allSatisfy({
            (residents[$0] != nil && residents[$0]?.isRemoving != true) || (retryAfter[$0] ?? .distantPast) > Date()
        }) { return }
        cancelPendingInstallations()
        wantedTiles = tiles; focus = next
        let expected = revision
        for (tile, resident) in residents {
            // Streaming eviction has no animated offscreen wait; explicit whole-scene exits still retract.
            if !wanted.contains(tile) { removeNow(tile) }
            else if resident.isRemoving {
                resident.transition?.cancel(); resident.isRemoving = false
                animateArrival(tile, resident: resident)
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == expected { self.task = nil } }
            // Each installation yields to UI work; saved reads run off-main in the bounded store.
            for tile in tiles {
                guard !Task.isCancelled, self.revision == expected else { return }
                if let resident = self.residents[tile] {
                    self.applyCoverage(tile, resident: resident)
                    if resident.connection >= 1 { self.onReady?(tile) }
                    continue
                }
                guard (self.retryAfter[tile] ?? .distantPast) <= Date() else { continue }
                let job = Task.detached(priority: .utility) { () -> DioramaTileArtifacts? in
                    guard !Task.isCancelled else { return nil }
                    return await DioramaOfflineStore.shared.read(tile, context: true)
                }
                let artifacts = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, self.revision == expected,
                      UIApplication.shared.applicationState == .active else { return }
                guard let artifacts else {
                    self.retryAfter[tile] = Date().addingTimeInterval(30)
                    self.availability = " · saved context read unavailable"
                    print("[Diorama context] \(tile.key): saved read unavailable; retained scenery, retry on camera update")
                    self.onUnavailable?(tile); continue
                }
                if tile != next, self.fullMasks[next] != nil, self.residents[next] != nil,
                   self.residents.values.reduce(0, { $0 + $1.bytes }) + artifacts.totalBytes > 64 * 1_048_576 {
                    self.removeNow(next)
                    guard !Task.isCancelled, self.revision == expected else { return }
                }
                if priorityTiles.contains(tile) {
                    // Visible scenery outranks speculative ring residents, not merely read order.
                    let victims = self.residents.keys.filter {
                        $0 != tile && self.fullMasks[$0] == nil && !priorityTiles.contains($0)
                    }.sorted { (tiles.firstIndex(of: $0) ?? Int.max) > (tiles.firstIndex(of: $1) ?? Int.max) }
                    for victim in victims {
                        if self.residents.count < 9,
                           self.residents.values.reduce(0, { $0 + $1.bytes }) + artifacts.totalBytes <= 64 * 1_048_576 { break }
                        self.removeNow(victim)
                    }
                }
                guard self.residents.count < 9,
                      self.residents.values.reduce(0, { $0 + $1.bytes }) + artifacts.totalBytes <= 64 * 1_048_576 else {
                    self.retryAfter[tile] = Date().addingTimeInterval(30)
                    self.availability = " · context packed-budget limit"
                    print("[Diorama context] \(tile.key): admission deferred bytes=\(artifacts.totalBytes) residents=\(self.residents.count)")
                    self.onUnavailable?(tile); continue
                }
                self.retryAfter[tile] = nil
                self.install(artifacts, config: config)
                await Task.yield()
            }
        }
    }

    /// Full detail retains its inward feather at rest; coarse coverage fills its complementary pixels.
    func setFocusMask(tile: DioramaTileID, reveal: SIMD4<Float>) {
        fullMasks[tile] = reveal
        if let resident = residents[tile] {
            applyCoverage(tile, resident: resident)
            onFocusCoverage?(tile, connectedEdges(for: tile), resident.connection >= 1)
        }
        refreshConnections()
    }

    func pauseLoading() { cancelPendingInstallations(); focus = nil }
    func prepareForFocus() { pauseLoading() }

    private func cancelPendingInstallations() { task?.cancel(); task = nil; revision &+= 1 }

    /// Whole-scene exits retract; offscreen streaming eviction and style destruction remove directly.
    func clear() {
        cancelPendingInstallations()
        for retirement in retirements.values { retirement.cancel() }
        retirements.removeAll()
        for tile in Array(residents.keys) { removeNow(tile) }
        fullMasks.removeAll(); retryAfter.removeAll(); wantedTiles.removeAll(); availability = ""; focus = nil
    }

    func retractAll() {
        cancelPendingInstallations(); focus = nil
        for tile in Array(residents.keys) { removeAnimated(tile) }
    }

    func retire(host: DioramaRenderLayer, tile: DioramaTileID, completion: @escaping () -> Void) {
        guard retirements[tile] == nil else { return }
        if residents[tile]?.connection == 1 {
            fullMasks[tile] = nil
            refreshConnections()
            completion()
            map?.triggerRepaint()
            return
        }
        let extent = max(abs(host.revealBounds.minimum.x), abs(host.revealBounds.maximum.x),
                         abs(host.revealBounds.minimum.y), abs(host.revealBounds.maximum.y))
            + DioramaRevealStyle.support + 50
        let paired = residents[tile]?.connection == 1
        host.setTileCoverage(edges: connectedEdges(for: tile), role: 1, paired: paired)
        retirements[tile] = Task { [weak self, weak host] in
            guard let self, let host else { return }
            let finished = await DioramaTileTransition.run(host: host, from: extent,
                to: -DioramaRevealStyle.support - 2, lifecycle: false) { [weak self] field, _ in
                    self?.setFocusMask(tile: tile, reveal: field)
                    self?.map?.triggerRepaint()
                }
            guard !Task.isCancelled else { return }
            self.retirements[tile] = nil
            self.fullMasks[tile] = nil
            self.refreshConnections()
            if !finished { print("[Diorama context] retirement unavailable; basemap fallback") }
            completion()
            self.map?.triggerRepaint()
        }
    }

    private func id(_ tile: DioramaTileID) -> String { "zuri-context-\(tile.key)" }

    private func removeNow(_ tile: DioramaTileID) {
        residents[tile]?.transition?.cancel()
        if let map {
            for name in [id(tile) + "-clip", id(tile)] where map.layerExists(withId: name) { try? map.removeLayer(withId: name) }
            if map.sourceExists(withId: id(tile) + "-source") { try? map.removeSource(withId: id(tile) + "-source") }
        }
        residents[tile] = nil
        refreshConnections()
    }

    private func removeAnimated(_ tile: DioramaTileID) {
        guard let resident = residents[tile], !resident.isRemoving else { return }
        resident.transition?.cancel(); resident.isRemoving = true
        let connection = resident.connection
        resident.transition = Task { [weak self, weak resident] in
            guard let self, let resident else { return }
            _ = await DioramaTileTransition.run(host: resident.host, from: resident.currentExtent,
                to: -DioramaRevealStyle.support - 2) { [weak self, weak resident] field, progress in
                    guard let self, let resident else { return }
                    resident.currentExtent = field.z; resident.connection = connection * (1 - progress)
                    self.updateClip(tile, extent: field.z)
                    self.refreshConnections(); self.map?.triggerRepaint()
                }
            guard !Task.isCancelled, self.residents[tile] === resident else { return }
            self.removeNow(tile); self.map?.triggerRepaint()
        }
    }

    private func connectedEdges(for tile: DioramaTileID) -> SIMD4<Float> {
        func exposed(_ x: Int, _ y: Int) -> Float {
            let neighbour = tile.offset(dx: x, dy: y)
            if fullMasks[neighbour] != nil { return 0 }
            if let resident = residents[neighbour], resident.connection >= 1, !resident.isRemoving { return 0 }
            return 1
        }
        return SIMD4(exposed(-1, 0), exposed(0, 1), exposed(1, 0), exposed(0, -1))
    }

    private func applyCoverage(_ tile: DioramaTileID, resident: Resident) {
        let paired = fullMasks[tile] != nil
        resident.host.setTileCoverage(edges: connectedEdges(for: tile), role: paired ? 2 : 0, paired: paired)
        resident.host.setReveal(fullMasks[tile] ?? .zero)
    }

    private func refreshConnections() {
        for (tile, resident) in residents { applyCoverage(tile, resident: resident) }
        for tile in fullMasks.keys {
            onFocusCoverage?(tile, connectedEdges(for: tile), residents[tile]?.connection == 1)
        }
    }

    private func animateArrival(_ tile: DioramaTileID, resident: Resident) {
        resident.transition?.cancel()
        let initialConnection = resident.connection
        resident.transition = Task { [weak self, weak resident] in
            guard let self, let resident else { return }
            let success = await DioramaTileTransition.run(host: resident.host, from: resident.currentExtent, to: resident.extent) {
                [weak self, weak resident] field, progress in
                guard let self, let resident else { return }
                resident.currentExtent = field.z
                resident.connection = initialConnection + (1 - initialConnection) * progress
                self.updateClip(tile, extent: field.z); self.refreshConnections(); self.map?.triggerRepaint()
            }
            guard !Task.isCancelled, self.residents[tile] === resident else { return }
            resident.transition = nil
            guard success else {
                if resident.host.diagnostic.contains("failed") || resident.host.diagnostic.contains("missing") {
                    self.retryAfter[tile] = Date().addingTimeInterval(30)
                    self.removeNow(tile); self.onUnavailable?(tile)
                } else {
                    // The SDK need not invoke an offscreen host. Keep its mask and resume on its
                    // next completed frame rather than deleting it and permanently losing context.
                    self.availability = " · arrival awaiting render frame"
                    print("[Diorama context] \(tile.key): arrival deferred; resident retained")
                }
                return
            }
            resident.host.setLifecycleReveal(.zero)
            resident.connection = 1
            self.refreshConnections()
            self.onFocusCoverage?(tile, self.connectedEdges(for: tile), self.fullMasks[tile] != nil)
            self.onReady?(tile)
            self.map?.triggerRepaint()
        }
    }

    private func updateClip(_ tile: DioramaTileID, extent: Float) {
        guard let map, map.sourceExists(withId: id(tile) + "-source") else { return }
        let projection = DioramaProjection(origin: tile.centre), rect = projection.rect(of: tile)
        let e = Double(extent + DioramaRevealStyle.support)
        guard e > 0 else {
            map.updateGeoJSONSource(withId: id(tile) + "-source", geoJSON: .featureCollection(FeatureCollection(features: [])))
            return
        }
        let points = [DV2(max(rect.minX, -e), max(rect.minY, -e)), DV2(min(rect.maxX, e), max(rect.minY, -e)),
                      DV2(min(rect.maxX, e), min(rect.maxY, e)), DV2(max(rect.minX, -e), min(rect.maxY, e))]
        let coordinates = (points + [points[0]]).map { p -> CLLocationCoordinate2D in
            let c = projection.coordinate(p)
            return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
        }
        map.updateGeoJSONSource(withId: id(tile) + "-source", geoJSON: .geometry(.polygon(Polygon([coordinates]))))
    }

    private func install(_ artifacts: DioramaTileArtifacts, config: DioramaConfig) {
        guard let map else { return }
        let tile = artifacts.tile
        let installedAt = CACurrentMediaTime()
        let host = DioramaRenderLayer(origin: tile.centre, vertices: artifacts.vertices, indices: artifacts.indices,
            ranges: artifacts.ranges, groups: artifacts.groups, instances: artifacts.allInstances, lightGrid: artifacts.lightGrid, waterHeight: artifacts.waterHeight,
            groundImage: artifacts.groundImage, groundRect: DioramaProjection(origin: tile.centre).rect(of: tile),
            visible: visible, timeOfDay: time, animates: true, config: config, contextOnly: true,
            materialsPrepared: artifacts.renderMaterialsPrepared, materialCounts: artifacts.renderMaterialCounts,
            preparedPoolBounds: artifacts.renderPoolBounds)
        host.onWaterVisibilityChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.onWaterVisibilityChanged?() }
        }
        host.onLifecycleCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let resident = self.residents[tile], !resident.isRemoving,
                      resident.connection < 1, self.focus != nil else { return }
                resident.connection = 1
                print("[Diorama context] \(tile.key): install-to-completed-frame=\(String(format: "%.3f", CACurrentMediaTime() - installedAt))s")
                self.refreshConnections()
                self.onReady?(tile)
                self.map?.triggerRepaint()
            }
        }
        host.onInitializationFailed = { [weak self, weak host] in
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, self.residents[tile]?.host === host else { return }
                self.retryAfter[tile] = Date().addingTimeInterval(30)
                self.removeNow(tile); self.onUnavailable?(tile)
            }
        }
        host.setReducedEffects(reducedEffects); host.setWireframe(wireframe)
        host.setWaterMotion(!UIAccessibility.isReduceMotionEnabled)
        let resident = Resident(host: host, artifacts: artifacts)
        resident.currentExtent = resident.extent
        host.setLifecycleReveal(.zero)
        residents[tile] = resident
        applyCoverage(tile, resident: resident)
        do {
            try map.addCustomLayer(withId: id(tile), layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: id(tile), property: "slot", value: "middle")
            var source = GeoJSONSource(id: id(tile) + "-source")
            source.data = .featureCollection(FeatureCollection(features: []))
            try map.addSource(source)
            var clip = ClipLayer(id: id(tile) + "-clip", source: source.id)
            clip.slot = .top; clip.clipLayerScope = .constant(["basemap"]); clip.clipLayerTypes = .constant([.model])
            try map.addLayer(clip)
            print("[Diorama context] \(tile.key): installed bytes=\(resident.bytes) triangles=\(resident.triangles)")
            updateClip(tile, extent: resident.extent)
            refreshConnections()
            map.triggerRepaint()
        } catch {
            retryAfter[tile] = Date().addingTimeInterval(30)
            availability = " · context layer installation unavailable"
            print("[Diorama context] \(tile.key): layer installation unavailable; retry deferred")
            removeNow(tile); onUnavailable?(tile)
        }
    }
}
