import Foundation
@_spi(Experimental) import MapboxMaps
import UIKit

/// Bounded visible coarse coverage; attached/retiring HD pins its complementary base.
@MainActor
final class DioramaContextTiles {
    private final class Resident {
        let host: DioramaRenderLayer
        let bytes: Int
        let triangles: Int
        let reservation: UUID
        var isReady: Bool
        var arrival: Task<Void, Never>?
        init(host: DioramaRenderLayer, artifacts: DioramaTileArtifacts, reservation: UUID) {
            self.host = host; bytes = artifacts.decodedBytes; triangles = artifacts.totalTriangles
            self.reservation = reservation
            isReady = host.isRendererReady
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
    var budget: DioramaResidencyBudget?
    var outputSize: CGSize = .zero
    private var loadingTile: DioramaTileID?
    private var deferredTiles: Set<DioramaTileID> = []
    private var allowance: Int = 0
    private var task: Task<Void, Never>?
    private var revision: UInt = 0
    private var retryAfter: [DioramaTileID: Date] = [:]
    private var wantedTiles: [DioramaTileID] = []
    private var visibleTiles: Set<DioramaTileID> = []
    private weak var map: MapboxMap?
    private var visible: Set<DioramaCategory> = []
    private var time: DioramaTimeOfDay = .day
    private var wireframe: Bool = false
    private var reducedEffects: Bool = false
    private var waterMotion: Bool = true
    var onReady: ((DioramaTileID) -> Void)?
    var onUnavailable: ((DioramaTileID) -> Void)?
    var onHDFrameCompleted: ((DioramaTileID) -> Void)?

    func groundHeight(at point: GeoPoint) -> Double? {
        let tile = DioramaTileID(latitude: point.latitude, longitude: point.longitude, zoom: 16)
        return residents[tile]?.host.groundHeight(at: point)
    }
    func isReady(_ tile: DioramaTileID) -> Bool {
        guard let resident = residents[tile] else { return false }
        return resident.isReady && resident.host.isRendererReady && resident.arrival == nil
    }
    func readinessReport(_ tile: DioramaTileID) -> String {
        guard let resident = residents[tile] else {
            return retryAfter[tile] == nil ? "waiting for saved base" : "base awaiting local retry/repair"
        }
        if !resident.isReady { return "waiting for base GPU initialization · \(resident.host.diagnostic)" }
        return resident.arrival == nil ? "base ready" : "base reveal in progress"
    }
    func hasCompletedHDReveal(tile: DioramaTileID, state: SIMD4<Float>) -> Bool {
        residents[tile]?.host.hasCompleted(reveal: state) == true
    }
    func hasCompletedHDUnion(tile: DioramaTileID, state: SIMD4<Float>) -> Bool {
        residents[tile]?.host.hasCompletedUnion(state) == true
    }
    func hasReadyCoverage(in tiles: [DioramaTileID]) -> Bool {
        tiles.contains { residents[$0]?.isReady == true && residents[$0]?.host.isRendererReady == true }
    }
    var retryDelay: TimeInterval? {
        return wantedTiles.filter { residents[$0] == nil }.compactMap { retryAfter[$0] }
            .filter { $0 > Date() }.min().map { max(0.1, $0.timeIntervalSinceNow) }
    }
    var report: String {
        let missing = retryAfter.count
        return "Visible base: \(residents.count)/\(budget?.contextLimit ?? 4) low-detail tiles · \(residents.values.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB decoded payload"
            + (deferredTiles.isEmpty ? "" : " · lower-priority tiles use native map within memory allowance")
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
                priorityTiles: [DioramaTileID] = [], pinnedTiles: [DioramaTileID] = [], allowsLoading: Bool = true) {
        self.map = map
        let pins = Set(pinnedTiles)
        visibleTiles = Set(priorityTiles)
        var seen: Set<DioramaTileID> = []
        let next = Array((pinnedTiles + priorityTiles)
            .filter { DioramaOfflineStore.tiles.contains($0) && seen.insert($0).inserted }
            .prefix(budget?.contextLimit ?? 4))
        if wantedTiles != next || allowance != budget?.limit {
            deferredTiles.removeAll(); allowance = budget?.limit ?? 0
        }
        wantedTiles = next
        if let loadingTile, !wantedTiles.contains(loadingTile) { pauseLoading() }
        for tile in Array(residents.keys) where !wantedTiles.contains(tile) && !pins.contains(tile) {
            remove(tile); refreshNeighbours(of: tile)
        }
        for (tile, resident) in residents where resident.arrival != nil && !visibleTiles.contains(tile) {
            resident.arrival?.cancel(); resident.arrival = nil; resident.host.setLifecycleReveal(.zero)
            refreshNeighbours(of: tile)
            if isReady(tile) { onReady?(tile) }
            map.triggerRepaint()
        }
        if self.visible != visible || self.time != time || self.wireframe != wireframe {
            self.visible = visible; self.time = time; self.wireframe = wireframe
            for resident in residents.values {
                resident.host.setVisible(visible, timeOfDay: time); resident.host.setWireframe(wireframe)
            }
            map.triggerRepaint()
        }
        guard allowsLoading, task == nil, budget?.isLoading != true,
              wantedTiles.contains(where: { residents[$0] == nil && !deferredTiles.contains($0) && (retryAfter[$0] ?? .distantPast) <= Date() }) else { return }
        let expected = revision
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == expected { self.task = nil; self.loadingTile = nil } }
            while let tile = self.wantedTiles.first(where: { self.residents[$0] == nil && !self.deferredTiles.contains($0) && (self.retryAfter[$0] ?? .distantPast) <= Date() }) {
                guard !Task.isCancelled, self.revision == expected, UIApplication.shared.applicationState == .active,
                      let budget = self.budget else { return }
                self.loadingTile = tile
                guard var cost = await DioramaOfflineStore.shared.residencyCost(tile, context: true, size: self.outputSize) else {
                    self.markUnavailable(tile); continue
                }
                guard !Task.isCancelled, self.revision == expected, self.wantedTiles.contains(tile) else { return }
                guard let reservation = budget.reserve(cost, context: true) else {
                    if budget.isLoading { return }
                    self.deferredTiles.insert(tile); continue
                }
                defer { if self.residents[tile]?.reservation != reservation { budget.release(reservation) } }
                let job = Task.detached(priority: .utility) { await DioramaOfflineStore.shared.read(tile, context: true) }
                let artifacts = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, self.revision == expected, UIApplication.shared.applicationState == .active else { return }
                guard let artifacts else { self.markUnavailable(tile); continue }
                guard self.wantedTiles.contains(tile) else { continue }
                let actual = DioramaResidencyBudget.cost(artifacts, context: true, size: self.outputSize)
                cost = .init(retained: max(cost.retained, actual.retained), peak: max(cost.peak, actual.peak))
                guard budget.revise(reservation, cost: cost) else { self.deferredTiles.insert(tile); continue }
                await self.install(artifacts, config: config, revision: expected, reservation: reservation)
                if self.residents[tile]?.reservation == reservation { budget.commit(reservation, cost: cost) }
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
    func pauseLoading() { revision &+= 1; task?.cancel(); task = nil; loadingTile = nil }
    func retryAdmission() { deferredTiles.removeAll() }
    /// Foreground detail wins over lower-priority coarse hosts, but never loses a paired base.
    func makeRoomForHD(_ tile: DioramaTileID, cost: DioramaResidencyBudget.Cost, pinned: [DioramaTileID]) {
        guard let budget, !budget.isLoading else { return }
        let protected = Set(pinned + [tile])
        let candidates = wantedTiles.reversed().filter { !protected.contains($0) && residents[$0] != nil }
        guard budget.canFitAfterReleasing(candidates.compactMap { residents[$0]?.reservation }, cost: cost) else { return }
        var evicted: Set<DioramaTileID> = []
        for candidate in candidates {
            if budget.canReserve(cost, context: false) { break }
            remove(candidate); refreshNeighbours(of: candidate); evicted.insert(candidate)
        }
        // Releases notify admission synchronously. Restore all deferrals only after that batch.
        deferredTiles.formUnion(evicted)
    }
    func trimForMemoryWarning() {
        pauseLoading(); deferredTiles.removeAll()
        for tile in Array(residents.keys) where !visibleTiles.contains(tile) || tile != wantedTiles.first { remove(tile) }
        for tile in residents.keys { refreshNeighbours(of: tile) }
    }
    func clear() {
        pauseLoading()
        for tile in Array(residents.keys) { remove(tile) }
        hdMasks.removeAll(); retryAfter.removeAll(); wantedTiles.removeAll(); visibleTiles.removeAll(); deferredTiles.removeAll()
    }
    private func id(_ tile: DioramaTileID) -> String { "zuri-context-\(tile.key)" }
    private func remove(_ tile: DioramaTileID) {
        residents[tile]?.arrival?.cancel()
        if let map {
            for layer in [id(tile) + "-clip", id(tile)] where map.layerExists(withId: layer) { try? map.removeLayer(withId: layer) }
            if map.sourceExists(withId: id(tile) + "-source") { try? map.removeSource(withId: id(tile) + "-source") }
        }
        if let resident = residents.removeValue(forKey: tile) { budget?.release(resident.reservation) }
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
    private func startArrival(_ tile: DioramaTileID, resident: Resident) {
        let host = resident.host
        let extent = max(abs(host.revealBounds.minimum.x), abs(host.revealBounds.maximum.x),
            abs(host.revealBounds.minimum.y), abs(host.revealBounds.maximum.y)) + DioramaRevealStyle.support + 50
        resident.arrival = Task { [weak self, weak resident] in
            guard let self, let resident else { return }
            let finished = await DioramaTileTransition.run(host: host, from: -DioramaRevealStyle.support - 2, to: extent) {
                [weak self] _, _ in self?.map?.triggerRepaint()
            }
            guard !Task.isCancelled, self.residents[tile] === resident else { return }
            resident.arrival = nil
            // A stopped SDK drawable must not strand healthy saved base geometry behind an empty mask.
            host.setLifecycleReveal(.zero)
            if !finished { print("[Diorama base] reveal did not complete \(tile.key); base retained · \(host.diagnostic)") }
            self.refreshNeighbours(of: tile); self.onReady?(tile); self.map?.triggerRepaint()
        }
    }
    private func setSlot(_ id: String, on map: MapboxMap) throws {
        try map.setLayerProperty(for: id, property: "slot", value: "middle")
    }
    private func install(_ artifacts: DioramaTileArtifacts, config: DioramaConfig, revision expected: UInt, reservation: UUID) async {
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
        guard !Task.isCancelled, revision == expected, self.map === map, wantedTiles.contains(tile),
              UIApplication.shared.applicationState == .active else { return }
        if host.diagnostic.contains("failed") || host.diagnostic.contains("missing") { markUnavailable(tile); return }
        host.viewport = viewport
        host.onInitialized = { [weak self, weak host] in
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, let resident = self.residents[tile], resident.host === host, !resident.isReady else { return }
                resident.isReady = host.isRendererReady
                guard resident.isReady else { return }
                self.refreshNeighbours(of: tile); self.onReady?(tile); self.map?.triggerRepaint()
            }
        }
        host.onRevealCompleted = { [weak self, weak host] _ in
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, self.residents[tile]?.host === host, self.hdMasks[tile] != nil else { return }
                self.onHDFrameCompleted?(tile)
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
        let resident = Resident(host: host, artifacts: artifacts, reservation: reservation)
        let revealsArrival = visibleTiles.contains(tile) && !UIAccessibility.isReduceMotionEnabled
            && ProcessInfo.processInfo.thermalState != .critical
        if revealsArrival { host.setLifecycleReveal(SIMD4(0, 0, -DioramaRevealStyle.support - 2, 1)) }
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
            retryAfter[tile] = nil
            if revealsArrival { startArrival(tile, resident: resident) }
            refreshNeighbours(of: tile)
            print("[Diorama base] installed \(tile.key) working-set=\(residents.count) decoded=\(resident.bytes)")
            if isReady(tile) { onReady?(tile) }
            map.triggerRepaint()
        } catch {
            remove(tile); refreshNeighbours(of: tile); markUnavailable(tile)
        }
    }
}
