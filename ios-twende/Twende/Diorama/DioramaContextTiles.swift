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
    private weak var map: MapboxMap?
    private var visible: Set<DioramaCategory> = []
    private var time: DioramaTimeOfDay = .dusk
    private var wireframe: Bool = false
    private var reducedEffects: Bool = false
    var onReady: ((DioramaTileID) -> Void)?
    var onUnavailable: ((DioramaTileID) -> Void)?
    var onFocusFallback: ((DioramaTileID, Bool) -> Void)?
    var onWaterVisibilityChanged: (() -> Void)?

    func groundHeight(at point: GeoPoint) -> Double? {
        let tile = DioramaTileID(latitude: point.latitude, longitude: point.longitude, zoom: 16)
        return residents[tile]?.host.groundHeight(at: point)
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
                visible: Set<DioramaCategory>, time: DioramaTimeOfDay, wireframe: Bool) {
        self.map = map; self.visible = visible; self.time = time; self.wireframe = wireframe
        for resident in residents.values {
            resident.host.setVisible(visible, timeOfDay: time)
            resident.host.setWireframe(wireframe)
        }
        let sameFocus = focus == next
        guard !sameFocus || task == nil else { return }
        cancelPendingInstallations()
        focus = next
        let expected = revision
        let tiles = (-1...1).flatMap { y in (-1...1).compactMap { x -> DioramaTileID? in
            let tile = DioramaTileID(z: next.z, x: next.x + x, y: next.y + y)
            return DioramaOfflineStore.tiles.contains(tile) ? tile : nil
        }}.sorted {
            // Actual neighbours have priority over the optional same-tile fallback.
            let a = $0 == next ? 10 : abs($0.x - next.x) + abs($0.y - next.y)
            let b = $1 == next ? 10 : abs($1.x - next.x) + abs($1.y - next.y)
            return a == b ? $0.key < $1.key : a < b
        }
        let wanted = Set(tiles)
        if sameFocus && tiles.allSatisfy({ residents[$0] != nil || (retryAfter[$0] ?? .distantPast) > Date() }) { return }
        for (tile, resident) in residents {
            if !wanted.contains(tile) { removeAnimated(tile) }
            else if resident.isRemoving {
                resident.transition?.cancel(); resident.isRemoving = false
                animateArrival(tile, resident: resident)
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == expected { self.task = nil } }
            // Keep departing hosts inside the same packed/resident admission budget until invisible.
            let departures = self.residents.values.filter(\.isRemoving).compactMap(\.transition)
            for departure in departures { await departure.value }
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
                guard !Task.isCancelled, self.revision == expected else { return }
                guard let artifacts else {
                    self.retryAfter[tile] = Date().addingTimeInterval(30)
                    self.availability = " · saved context read unavailable"
                    print("[Diorama context] \(tile.key): saved read unavailable; retained scenery, retry on camera update")
                    self.onUnavailable?(tile); continue
                }
                if tile != next, self.residents[next] != nil,
                   self.residents.values.reduce(0, { $0 + $1.bytes }) + artifacts.totalBytes > 64 * 1_048_576 {
                    self.removeAnimated(next)
                    if let departure = self.residents[next]?.transition { await departure.value }
                    guard !Task.isCancelled, self.revision == expected else { return }
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
            }
        }
    }

    /// Full detail retains its inward feather at rest; coarse coverage fills its complementary pixels.
    func setFocusMask(tile: DioramaTileID, reveal: SIMD4<Float>) {
        fullMasks[tile] = reveal
        if let resident = residents[tile] {
            applyCoverage(tile, resident: resident)
            onFocusFallback?(tile, resident.connection >= 1)
        }
    }

    func pauseLoading() { cancelPendingInstallations(); focus = nil }
    func prepareForFocus() { pauseLoading() }

    private func cancelPendingInstallations() { task?.cancel(); task = nil; revision &+= 1 }

    /// Immediate teardown is reserved for a style/screen destruction; visible exits use retractAll.
    func clear() {
        cancelPendingInstallations()
        for retirement in retirements.values { retirement.cancel() }
        retirements.removeAll()
        for tile in Array(residents.keys) { removeNow(tile) }
        fullMasks.removeAll(); retryAfter.removeAll(); availability = ""; focus = nil
    }

    func retractAll() {
        cancelPendingInstallations(); focus = nil
        for tile in Array(residents.keys) { removeAnimated(tile) }
    }

    func retire(host: DioramaRenderLayer, tile: DioramaTileID, completion: @escaping () -> Void) {
        guard retirements[tile] == nil else { return }
        let extent = max(abs(host.revealBounds.minimum.x), abs(host.revealBounds.maximum.x),
                         abs(host.revealBounds.minimum.y), abs(host.revealBounds.maximum.y))
            + DioramaRevealStyle.support + 50
        let paired = residents[tile]?.connection == 1
        host.setTileCoverage(edges: SIMD4(repeating: 1), role: 1, paired: paired)
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
            if let resident = self.residents[tile] { self.applyCoverage(tile, resident: resident) }
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
        onFocusFallback?(tile, false)
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

    private func applyCoverage(_ tile: DioramaTileID, resident: Resident) {
        func boundary(_ resident: Resident, side: Int) -> Float {
            let rect = resident.rect
            let point: SIMD3<Float>
            switch side {
            case 0: point = SIMD3(Float(rect.minX), 0, 0)
            case 1: point = SIMD3(0, Float(rect.minY), 0)
            case 2: point = SIMD3(Float(rect.maxX), 0, 0)
            default: point = SIMD3(0, Float(rect.maxY), 0)
            }
            return DioramaRevealStyle.coverage(point, reveal: SIMD4(0, 0, resident.currentExtent, 1))
        }
        func connection(_ x: Int, _ y: Int, side: Int) -> Float {
            guard let neighbour = residents[DioramaTileID(z: tile.z, x: tile.x + x, y: tile.y + y)] else { return 0 }
            return min(boundary(resident, side: side), boundary(neighbour, side: (side + 2) % 4))
        }
        let edges = SIMD4(1 - connection(-1, 0, side: 0), 1 - connection(0, 1, side: 1),
                          1 - connection(1, 0, side: 2), 1 - connection(0, -1, side: 3))
        let paired = fullMasks[tile] != nil
        resident.host.setTileCoverage(edges: edges, role: paired ? 2 : 0, paired: paired)
        resident.host.setReveal(fullMasks[tile] ?? .zero)
    }

    private func refreshConnections() {
        for (tile, resident) in residents { applyCoverage(tile, resident: resident) }
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
            self.onFocusFallback?(tile, self.fullMasks[tile] != nil)
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
        let host = DioramaRenderLayer(origin: tile.centre, vertices: artifacts.vertices, indices: artifacts.indices,
            ranges: artifacts.ranges, groups: artifacts.groups, instances: artifacts.allInstances, lightGrid: artifacts.lightGrid, waterHeight: artifacts.waterHeight,
            groundImage: artifacts.groundImage, groundRect: DioramaProjection(origin: tile.centre).rect(of: tile),
            visible: visible, timeOfDay: time, animates: true, config: config, contextOnly: true)
        host.onWaterVisibilityChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.onWaterVisibilityChanged?() }
        }
        host.onLifecycleCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let resident = self.residents[tile], resident.transition == nil,
                      !resident.isRemoving, resident.connection < 1, self.focus != nil else { return }
                self.animateArrival(tile, resident: resident)
            }
        }
        host.setReducedEffects(reducedEffects); host.setWireframe(wireframe)
        host.setWaterMotion(!UIAccessibility.isReduceMotionEnabled)
        let resident = Resident(host: host, artifacts: artifacts)
        host.setLifecycleReveal(SIMD4(0, 0, resident.currentExtent, 1))
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
            animateArrival(tile, resident: resident)
            map.triggerRepaint()
        } catch {
            retryAfter[tile] = Date().addingTimeInterval(30)
            availability = " · context layer installation unavailable"
            print("[Diorama context] \(tile.key): layer installation unavailable; retry deferred")
            removeNow(tile); onUnavailable?(tile)
        }
    }
}
