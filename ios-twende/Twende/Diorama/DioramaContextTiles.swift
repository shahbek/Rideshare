import Foundation
@_spi(Experimental) import MapboxMaps
import UIKit

/// Persistent saved low-detail coverage of all Masaki tiles; HD masks select complementary pixels.
@MainActor
final class DioramaContextTiles {
    private final class Resident {
        let host: DioramaRenderLayer
        let bytes: Int
        let triangles: Int
        var isReady: Bool
        init(host: DioramaRenderLayer, artifacts: DioramaTileArtifacts) {
            self.host = host; bytes = artifacts.decodedBytes; triangles = artifacts.totalTriangles
            isReady = host.diagnostic.hasPrefix("ready")
        }
    }
    private struct HDMask {
        let reveal: SIMD4<Float>
        let edges: SIMD4<Float>
        let shape: DioramaUnionShape?
        let union: SIMD4<Float>
    }
    var viewport: DioramaViewport?
    private var residents: [DioramaTileID: Resident] = [:]
    private var hdMasks: [DioramaTileID: HDMask] = [:]
    private var task: Task<Void, Never>?
    private var revision: UInt = 0
    private var retryAfter: [DioramaTileID: Date] = [:]
    private var wantedTiles: [DioramaTileID] = []
    private weak var map: MapboxMap?
    private var visible: Set<DioramaCategory> = []
    private var time: DioramaTimeOfDay = .day
    private var wireframe: Bool = false
    private var reducedEffects: Bool = false
    private var waterMotion: Bool = true
    var onReady: ((DioramaTileID) -> Void)?
    var onUnavailable: ((DioramaTileID) -> Void)?

    func groundHeight(at point: GeoPoint) -> Double? {
        let tile = DioramaTileID(latitude: point.latitude, longitude: point.longitude, zoom: 16)
        return residents[tile]?.host.groundHeight(at: point)
    }
    func isReady(_ tile: DioramaTileID) -> Bool { residents[tile]?.isReady == true }
    func hasCompletedHDUnion(tile: DioramaTileID, state: SIMD4<Float>) -> Bool {
        residents[tile]?.host.hasCompletedUnion(state) == true
    }
    func hasReadyCoverage(in tiles: [DioramaTileID]) -> Bool { tiles.contains { isReady($0) } }
    var retryDelay: TimeInterval? {
        return wantedTiles.filter { residents[$0] == nil }.compactMap { retryAfter[$0] }
            .filter { $0 > Date() }.min().map { max(0.1, $0.timeIntervalSinceNow) }
    }
    var report: String {
        let missing = retryAfter.count
        return "Masaki base: \(residents.count)/\(DioramaOfflineStore.tiles.count) low-detail tiles · \(residents.values.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB decoded payload (not total memory)"
            + (missing > 0 ? " · \(missing) saved tiles awaiting retry/repair" : "")
    }
    func setReducedEffects(_ reduced: Bool, waterMotion: Bool) {
        guard reducedEffects != reduced || self.waterMotion != waterMotion else { return }
        reducedEffects = reduced; self.waterMotion = waterMotion
        for resident in residents.values {
            resident.host.setReducedEffects(reduced); resident.host.setWaterMotion(waterMotion)
        }
    }
    func update(focus: DioramaTileID, config: DioramaConfig, map: MapboxMap,
                visible: Set<DioramaCategory>, time: DioramaTimeOfDay, wireframe: Bool,
                priorityTiles: [DioramaTileID] = [], allowsLoading: Bool = true) {
        self.map = map
        if self.visible != visible || self.time != time || self.wireframe != wireframe {
            self.visible = visible; self.time = time; self.wireframe = wireframe
            for resident in residents.values {
                resident.host.setVisible(visible, timeOfDay: time); resident.host.setWireframe(wireframe)
            }
            map.triggerRepaint()
        }
        var seen: Set<DioramaTileID> = []
        wantedTiles = (priorityTiles + DioramaOfflineStore.tiles)
            .filter { DioramaOfflineStore.tiles.contains($0) && seen.insert($0).inserted }
        guard allowsLoading, task == nil, wantedTiles.contains(where: { residents[$0] == nil && (retryAfter[$0] ?? .distantPast) <= Date() }) else { return }
        let expected = revision
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == expected { self.task = nil } }
            // Preload the complete local set serially; camera changes only reorder remaining work.
            while let tile = self.wantedTiles.first(where: { self.residents[$0] == nil && (self.retryAfter[$0] ?? .distantPast) <= Date() }) {
                guard !Task.isCancelled, self.revision == expected, UIApplication.shared.applicationState == .active else { return }
                let job = Task.detached(priority: .utility) { await DioramaOfflineStore.shared.read(tile, context: true) }
                let artifacts = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, self.revision == expected, UIApplication.shared.applicationState == .active else { return }
                guard let artifacts else { self.markUnavailable(tile); continue }
                await self.install(artifacts, config: config, revision: expected)
                await Task.yield()
            }
        }
    }
    func setHDMask(tile: DioramaTileID, reveal: SIMD4<Float>, edges: SIMD4<Float>,
                   shape: DioramaUnionShape?, union: SIMD4<Float>) {
        hdMasks[tile] = HDMask(reveal: reveal, edges: edges, shape: shape, union: union)
        if let resident = residents[tile] { applyCoverage(tile, resident: resident) }
    }
    func removeFocusMask(_ tile: DioramaTileID) {
        hdMasks[tile] = nil
        if let resident = residents[tile] { applyCoverage(tile, resident: resident) }
    }
    func pauseLoading() { revision &+= 1; task?.cancel(); task = nil }
    func clear() {
        pauseLoading()
        for tile in Array(residents.keys) { remove(tile) }
        hdMasks.removeAll(); retryAfter.removeAll(); wantedTiles.removeAll()
    }
    private func id(_ tile: DioramaTileID) -> String { "zuri-context-\(tile.key)" }
    private func remove(_ tile: DioramaTileID) {
        if let map {
            for layer in [id(tile) + "-clip", id(tile)] where map.layerExists(withId: layer) { try? map.removeLayer(withId: layer) }
            if map.sourceExists(withId: id(tile) + "-source") { try? map.removeSource(withId: id(tile) + "-source") }
        }
        residents[tile] = nil
    }
    private func markUnavailable(_ tile: DioramaTileID) {
        retryAfter[tile] = Date().addingTimeInterval(30)
        print("[Diorama base] saved tile unavailable \(tile.key); retained downloads, retry in 30s")
        onUnavailable?(tile)
    }
    private func connectedEdges(for tile: DioramaTileID) -> SIMD4<Float> {
        SIMD4(isReady(tile.offset(dx: -1, dy: 0)) ? 0 : 1,
            isReady(tile.offset(dx: 0, dy: 1)) ? 0 : 1,
            isReady(tile.offset(dx: 1, dy: 0)) ? 0 : 1,
            isReady(tile.offset(dx: 0, dy: -1)) ? 0 : 1)
    }
    private func applyCoverage(_ tile: DioramaTileID, resident: Resident) {
        let mask = hdMasks[tile]
        resident.host.setTileCoverage(edges: connectedEdges(for: tile), role: mask == nil ? 0 : 2,
            paired: mask != nil, focusEdges: mask?.edges ?? .zero)
        resident.host.setReveal(mask?.reveal ?? .zero)
        resident.host.setUnionCoverage(mask?.shape, state: mask?.union ?? .zero)
    }
    private func refreshNeighbours(of tile: DioramaTileID) {
        for t in [tile, tile.offset(dx: -1, dy: 0), tile.offset(dx: 0, dy: 1), tile.offset(dx: 1, dy: 0), tile.offset(dx: 0, dy: -1)] {
            if let resident = residents[t] { applyCoverage(t, resident: resident) }
        }
    }
    private func setSlot(_ id: String, on map: MapboxMap) throws {
        try map.setLayerProperty(for: id, property: "slot", value: "middle")
    }
    private func install(_ artifacts: DioramaTileArtifacts, config: DioramaConfig, revision expected: UInt) async {
        guard let map else { return }
        let tile = artifacts.tile
        let host = DioramaRenderLayer(origin: tile.centre, vertices: artifacts.vertices, indices: artifacts.indices,
            ranges: artifacts.ranges, groups: artifacts.groups, instances: artifacts.allInstances,
            lightGrid: artifacts.lightGrid, waterHeight: artifacts.waterHeight, groundImage: artifacts.groundImage,
            groundRect: DioramaProjection(origin: tile.centre).rect(of: tile), visible: visible, timeOfDay: time,
            animates: true, config: config, contextOnly: true, materialsPrepared: artifacts.renderMaterialsPrepared,
            materialCounts: artifacts.renderMaterialCounts, preparedPoolBounds: artifacts.renderPoolBounds)
        let upload = Task.detached(priority: .utility) { await DioramaGPUUploadQueue.shared.prepare(host) }
        await withTaskCancellationHandler { await upload.value } onCancel: { upload.cancel() }
        guard !Task.isCancelled, revision == expected, self.map === map,
              UIApplication.shared.applicationState == .active else { return }
        if host.diagnostic.contains("failed") || host.diagnostic.contains("missing") { markUnavailable(tile); return }
        host.viewport = viewport
        host.onLifecycleCompleted = { [weak self, weak host] in
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, let resident = self.residents[tile], resident.host === host, !resident.isReady else { return }
                resident.isReady = true
                self.refreshNeighbours(of: tile); self.onReady?(tile); self.map?.triggerRepaint()
            }
        }
        host.onInitializationFailed = { [weak self, weak host] in
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, self.residents[tile]?.host === host else { return }
                self.remove(tile); self.refreshNeighbours(of: tile); self.markUnavailable(tile)
            }
        }
        host.setVisible(visible, timeOfDay: time); host.setReducedEffects(reducedEffects)
        host.setWireframe(wireframe); host.setWaterMotion(waterMotion)
        let resident = Resident(host: host, artifacts: artifacts)
        residents[tile] = resident; applyCoverage(tile, resident: resident)
        do {
            try map.addCustomLayer(withId: id(tile), layerHost: host, layerPosition: nil)
            try setSlot(id(tile), on: map)
            var source = GeoJSONSource(id: id(tile) + "-source")
            source.data = .geometry(.polygon(Polygon([tile.outline])))
            try map.addSource(source)
            var clip = ClipLayer(id: id(tile) + "-clip", source: source.id)
            clip.slot = .top; clip.clipLayerScope = .constant(["basemap"]); clip.clipLayerTypes = .constant([.model])
            try map.addLayer(clip)
            retryAfter[tile] = nil; refreshNeighbours(of: tile)
            print("[Diorama base] installed \(tile.key) preload=\(residents.count)/\(DioramaOfflineStore.tiles.count) decoded=\(resident.bytes)")
            if resident.isReady { onReady?(tile) }
            map.triggerRepaint()
        } catch {
            remove(tile); refreshNeighbours(of: tile); markUnavailable(tile)
        }
    }
}
