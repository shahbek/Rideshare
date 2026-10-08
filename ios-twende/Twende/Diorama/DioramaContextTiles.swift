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
        var lifecycle: SIMD4<Float> = .zero
        init(host: DioramaRenderLayer, artifacts: DioramaResidentTile, reservation: UUID) {
            self.host = host; bytes = artifacts.gpuBytes + artifacts.cpuBytes; triangles = artifacts.totalTriangles
            self.reservation = reservation
            isReady = host.isRendererReady
        }
    }
    private final class Retirement {
        let id: UUID = UUID()
        let tiles: Set<DioramaTileID>
        let shape: DioramaUnionShape
        let revision: Float
        var inset: Float = -DioramaRevealStyle.support - 2
        var removing: Bool = true
        var mustRetire: Bool = false
        var isStalled: Bool = false
        var task: Task<Void, Never>?
        init(tiles: Set<DioramaTileID>, revision: Float) {
            self.tiles = tiles; self.shape = DioramaUnionShape(tiles: tiles); self.revision = revision
        }
        var state: SIMD4<Float> { SIMD4(1, Float(shape.cells.count), inset, revision) }
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
    private var retirements: [UUID: Retirement] = [:]
    private var shapeRevision: UInt = 0
    private var yieldedToHD: Set<DioramaTileID> = []
    var hasResidents: Bool { !residents.isEmpty }
    var onChanged: (() -> Void)?
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
            && !retirements.values.contains { $0.tiles.contains(tile) }
    }
    func readinessReport(_ tile: DioramaTileID) -> String {
        guard let resident = residents[tile] else {
            return retryAfter[tile] == nil ? "waiting for saved base" : "base awaiting local retry/repair"
        }
        if retirements.values.contains(where: { $0.tiles.contains(tile) }) { return "base retracting/restoring · GPU-paced" }
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
        return "Visible base: \(residents.count)/\(budget?.contextLimit ?? 4) low-detail tiles · \(residents.values.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB resident GPU-shared"
            + (retirements.isEmpty ? "" : " · \(retirements.count) joined retractions\(retirements.values.contains(where: \.isStalled) ? " waiting for GPU" : "")")
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
            deferredTiles.removeAll(); yieldedToHD.removeAll(); allowance = budget?.limit ?? 0
        }
        wantedTiles = next
        if let loadingTile, !wantedTiles.contains(loadingTile) { pauseLoading() }
        for group in Array(retirements.values) where !group.mustRetire {
            let removing = group.tiles.isDisjoint(with: Set(wantedTiles))
            if group.removing != removing { animate(group, removing: removing) }
        }
        retire(Set(residents.keys.filter { !wantedTiles.contains($0) && !pins.contains($0) }))
        for (tile, resident) in residents where resident.arrival != nil && !visibleTiles.contains(tile) {
            resident.arrival?.cancel(); resident.arrival = nil; resident.lifecycle = .zero; resident.host.setLifecycleReveal(.zero)
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
              wantedTiles.contains(where: { residents[$0] == nil && !deferredTiles.contains($0) && !yieldedToHD.contains($0) && canBeginGrowth($0) && (retryAfter[$0] ?? .distantPast) <= Date() }) else { return }
        let expected = revision
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == expected { self.task = nil; self.loadingTile = nil; self.onChanged?() } }
            while let tile = self.wantedTiles.first(where: { self.residents[$0] == nil && !self.deferredTiles.contains($0) && !self.yieldedToHD.contains($0) && self.canBeginGrowth($0) && (self.retryAfter[$0] ?? .distantPast) <= Date() }) {
                guard !Task.isCancelled, self.revision == expected, UIApplication.shared.applicationState == .active,
                      let budget = self.budget else { return }
                self.loadingTile = tile
                guard let cost = await DioramaOfflineStore.shared.residencyCost(tile, context: true, size: self.outputSize, scale: Float(UIScreen.main.scale)) else {
                    self.markUnavailable(tile); continue
                }
                guard !Task.isCancelled, self.revision == expected, self.wantedTiles.contains(tile) else { return }
                guard let reservation = budget.reserve(cost, context: true) else {
                    if budget.isLoading { return }
                    self.deferredTiles.insert(tile); continue
                }
                defer { if self.residents[tile]?.reservation != reservation { budget.release(reservation) } }
                let job = Task.detached(priority: .utility) { await DioramaOfflineStore.shared.readResident(tile, context: true) }
                let artifacts = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, self.revision == expected, UIApplication.shared.applicationState == .active else { return }
                guard let artifacts else { self.markUnavailable(tile); continue }
                guard self.wantedTiles.contains(tile) else { continue }
                let retained = DioramaResidencyBudget.residentCost(artifacts, context: true, size: self.outputSize, scale: Float(UIScreen.main.scale))
                let settled = DioramaResidencyBudget.Cost(retained: retained, peak: retained)
                guard budget.revise(reservation, cost: settled) else { self.deferredTiles.insert(tile); continue }
                await self.install(artifacts, config: config, revision: expected, reservation: reservation)
                if self.residents[tile]?.reservation == reservation { budget.commit(reservation, cost: settled) }
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
        // Visible candidates keep their ledger entries until their empty GPU endpoint completes.
        // Hold these admissions across release callbacks so base cannot steal the freed HD headroom.
        yieldedToHD.formUnion(candidates)
        deferredTiles.formUnion(candidates)
        retire(Set(candidates), mustRetire: true)
    }
    func trimForMemoryWarning() {
        pauseLoading(); deferredTiles.removeAll(); yieldedToHD.removeAll()
        for group in retirements.values { group.task?.cancel() }
        retirements.removeAll()
        for tile in Array(residents.keys) where !visibleTiles.contains(tile) || tile != wantedTiles.first { remove(tile) }
        for tile in residents.keys { refreshNeighbours(of: tile) }
    }
    func clear() {
        pauseLoading()
        for group in retirements.values { group.task?.cancel() }
        retirements.removeAll(); yieldedToHD.removeAll()
        for tile in Array(residents.keys) { remove(tile) }
        hdMasks.removeAll(); retryAfter.removeAll(); wantedTiles.removeAll(); visibleTiles.removeAll(); deferredTiles.removeAll()
    }
    /// Normal departures keep native clips, terrain ownership and budget until the empty frame.
    func retireAll() {
        pauseLoading(); wantedTiles.removeAll()
        retire(Set(residents.keys))
    }

    func updateRetirementVisibility(_ tiles: [DioramaTileID]) {
        visibleTiles = Set(tiles)
        for group in Array(retirements.values) where group.isStalled && group.tiles.isDisjoint(with: visibleTiles) {
            animate(group, removing: group.removing)
        }
    }

    private func retire(_ tiles: Set<DioramaTileID>, mustRetire: Bool = false) {
        for group in Array(retirements.values) where !group.tiles.isDisjoint(with: tiles) {
            if mustRetire { group.mustRetire = true }
            if (!group.removing && (mustRetire || group.tiles.isDisjoint(with: Set(wantedTiles))))
                || (group.isStalled && group.tiles.isDisjoint(with: visibleTiles)) {
                animate(group, removing: true)
            }
        }
        let grouped = retirements.values.reduce(into: Set<DioramaTileID>()) { $0.formUnion($1.tiles) }
        var remaining = Set(tiles.subtracting(grouped).filter { residents[$0] != nil && hdMasks[$0] == nil })
        for tile in Array(remaining) where !visibleTiles.contains(tile) {
            remove(tile); refreshNeighbours(of: tile); remaining.remove(tile)
        }
        while let seed = remaining.sorted(by: { $0.key < $1.key }).first {
            var component: Set<DioramaTileID> = [seed], frontier: [DioramaTileID] = [seed]
            remaining.remove(seed)
            while let tile = frontier.popLast() {
                for neighbour in [tile.offset(dx: -1, dy: 0), tile.offset(dx: 1, dy: 0),
                    tile.offset(dx: 0, dy: -1), tile.offset(dx: 0, dy: 1)] where remaining.remove(neighbour) != nil {
                    component.insert(neighbour); frontier.append(neighbour)
                }
            }
            shapeRevision &+= 1
            let group = Retirement(tiles: component, revision: Float(shapeRevision))
            group.mustRetire = mustRetire; retirements[group.id] = group
            for tile in component { residents[tile]?.arrival?.cancel(); residents[tile]?.arrival = nil }
            animate(group, removing: true)
        }
    }

    private func apply(_ group: Retirement) {
        for tile in group.tiles { if let resident = residents[tile] { applyCoverage(tile, resident: resident) } }
    }

    private func completed(_ group: Retirement) -> Bool {
        group.tiles.intersection(visibleTiles).allSatisfy { residents[$0] == nil || residents[$0]?.host.hasCompletedUnion(group.state) == true }
    }

    private func resumeRetirementIfStalled() {
        for group in Array(retirements.values) where group.isStalled && completed(group) {
            animate(group, removing: group.removing)
        }
    }

    private func animate(_ group: Retirement, removing: Bool) {
        group.task?.cancel(); group.removing = removing; group.isStalled = false
        let from = group.inset, to = removing ? group.shape.emptyInset : -DioramaRevealStyle.support - 2
        group.task = Task { [weak self, weak group] in
            guard let self, let group else { return }
            var elapsed: Double = 0, previous = CACurrentMediaTime(), requested = previous
            var endpoint: Bool = false
            self.apply(group); self.map?.triggerRepaint()
            while !Task.isCancelled, self.retirements[group.id] === group {
                let now = CACurrentMediaTime()
                let finish = UIAccessibility.isReduceMotionEnabled || UIApplication.shared.applicationState != .active
                    || ProcessInfo.processInfo.thermalState == .critical || group.tiles.isDisjoint(with: self.visibleTiles)
                if finish { group.inset = to; self.apply(group); break }
                if self.completed(group) {
                    if endpoint { break }
                    elapsed += min(1.0 / 30, max(0, now - previous))
                    let progress = Float(min(1, elapsed / 1.8))
                    group.inset = from + (to - from) * progress * progress * (3 - 2 * progress)
                    self.apply(group); self.map?.triggerRepaint(); requested = now; endpoint = progress >= 1
                } else if now - requested > 20 {
                    group.isStalled = true; group.task = nil; self.onChanged?()
                    print("[Diorama base] contraction waiting for GPU; coverage and allowance retained")
                    return
                }
                previous = now
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
            guard !Task.isCancelled, self.retirements[group.id] === group else { return }
            self.retirements[group.id] = nil
            if removing {
                for tile in group.tiles { self.remove(tile); self.refreshNeighbours(of: tile) }
            } else {
                for tile in group.tiles {
                    guard let resident = self.residents[tile] else { continue }
                    self.applyCoverage(tile, resident: resident)
                    if resident.lifecycle.w > 0.5 { self.startArrival(tile, resident: resident) }
                    else { self.onReady?(tile) }
                }
            }
            self.onChanged?(); self.map?.triggerRepaint()
        }
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
    private func hasGrowthNeighbour(_ tile: DioramaTileID) -> Bool { isReady(tile) }

    private func canBeginGrowth(_ tile: DioramaTileID) -> Bool {
        // Wait for an adjacent front rather than starting a detached patch across its hidden edge.
        [tile.offset(dx: -1, dy: 0), tile.offset(dx: 1, dy: 0),
            tile.offset(dx: 0, dy: -1), tile.offset(dx: 0, dy: 1)].allSatisfy { residents[$0]?.arrival == nil }
    }
    private func connectedEdges(for tile: DioramaTileID) -> SIMD4<Float> {
        let joined = retirements.values.first { $0.tiles.contains(tile) }?.tiles ?? []
        func connected(_ neighbour: DioramaTileID) -> Bool {
            if isReady(neighbour) || (joined.contains(neighbour) && residents[neighbour]?.host.isRendererReady == true) { return true }
            guard let resident = residents[neighbour], resident.host.isRendererReady,
                  resident.lifecycle.w > 3.5, resident.lifecycle.z >= DioramaRevealStyle.support else { return false }
            let side = tile.x < neighbour.x ? 0 : tile.x > neighbour.x ? 2 : tile.y > neighbour.y ? 1 : 3
            return Int(resident.lifecycle.x) & (1 << side) != 0
        }
        return SIMD4(connected(tile.offset(dx: -1, dy: 0)) ? 0 : 1,
            connected(tile.offset(dx: 0, dy: 1)) ? 0 : 1,
            connected(tile.offset(dx: 1, dy: 0)) ? 0 : 1,
            connected(tile.offset(dx: 0, dy: -1)) ? 0 : 1)
    }
    private func applyCoverage(_ tile: DioramaTileID, resident: Resident) {
        let mask = hdMasks[tile]
        resident.host.setTileCoverage(edges: connectedEdges(for: tile), role: mask == nil ? 0 : 2,
            paired: mask != nil, focusEdges: mask?.edges ?? .zero)
        resident.host.setReveal(mask?.reveal ?? .zero)
        let retirement = retirements.values.first { $0.tiles.contains(tile) }
        resident.host.setUnionCoverage(mask?.shape ?? retirement?.shape, state: mask?.union ?? retirement?.state ?? .zero)
    }
    private func refreshNeighbours(of tile: DioramaTileID) {
        for t in [tile, tile.offset(dx: -1, dy: 0), tile.offset(dx: 0, dy: 1), tile.offset(dx: 1, dy: 0), tile.offset(dx: 0, dy: -1)] {
            if let resident = residents[t] { applyCoverage(t, resident: resident) }
        }
    }
    private func startArrival(_ tile: DioramaTileID, resident: Resident) {
        let host = resident.host
        let extent = max(abs(host.revealBounds.minimum.x), abs(host.revealBounds.maximum.x),
            abs(host.revealBounds.minimum.y), abs(host.revealBounds.maximum.y)) * (resident.lifecycle.w > 3.5 ? 3 : 1) + DioramaRevealStyle.support + 50
        resident.arrival = Task { [weak self, weak resident] in
            guard let self, let resident else { return }
            let finished = await DioramaTileTransition.run(host: host, from: resident.lifecycle.z, to: extent, field: resident.lifecycle) {
                [weak self, weak resident] field, _ in
                guard let self, let resident else { return }
                let joinedFront = field.w > 3.5 && resident.lifecycle.z < DioramaRevealStyle.support
                    && field.z >= DioramaRevealStyle.support
                resident.lifecycle = field
                if joinedFront { self.refreshNeighbours(of: tile) }
                self.map?.triggerRepaint()
            }
            guard !Task.isCancelled, self.residents[tile] === resident else { return }
            resident.arrival = nil
            // A stopped SDK drawable must not strand healthy saved base geometry behind an empty mask.
            resident.lifecycle = .zero; host.setLifecycleReveal(.zero)
            if !finished { print("[Diorama base] reveal did not complete \(tile.key); base retained · \(host.diagnostic)") }
            self.refreshNeighbours(of: tile); self.onReady?(tile); self.map?.triggerRepaint()
        }
    }
    private func setSlot(_ id: String, on map: MapboxMap) throws {
        try map.setLayerProperty(for: id, property: "slot", value: "middle")
    }
    private func install(_ artifacts: DioramaResidentTile, config: DioramaConfig, revision expected: UInt, reservation: UUID) async {
        guard let map else { return }
        let tile = artifacts.tile
        let host = DioramaRenderLayer(resident: artifacts, groundRect: DioramaProjection(origin: tile.centre).rect(of: tile),
            visible: visible, timeOfDay: time, config: config, labels: [], displayScale: Float(UIScreen.main.scale), contextOnly: true)
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
        host.onUnionCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.resumeRetirementIfStalled(); self?.onHDFrameCompleted?(tile)
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
        if revealsArrival {
            let connected = SIMD4<Float>(hasGrowthNeighbour(tile.offset(dx: -1, dy: 0)) ? 0 : 1,
                hasGrowthNeighbour(tile.offset(dx: 0, dy: 1)) ? 0 : 1,
                hasGrowthNeighbour(tile.offset(dx: 1, dy: 0)) ? 0 : 1,
                hasGrowthNeighbour(tile.offset(dx: 0, dy: -1)) ? 0 : 1)
            resident.lifecycle = DioramaRevealStyle.growthSeed(edges: connected)
            host.setLifecycleReveal(resident.lifecycle)
        }
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
