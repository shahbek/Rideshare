import Foundation
@_spi(Experimental) import MapboxMaps
import UIKit

/// Demand-loaded HD overlays. Connected residents are retained and demoted as one union footprint.
@MainActor
final class DioramaHDTiles {
    private final class Resident {
        let host: DioramaRenderLayer
        let bytes: Int
        var reveal: SIMD4<Float>
        var arrival: Task<Void, Never>?
        var isRevealStalled: Bool = false
        init(host: DioramaRenderLayer, bytes: Int) {
            self.host = host; self.bytes = bytes
            reveal = SIMD4(0, 0, -DioramaRevealStyle.support - 2, 1)
        }
    }
    private final class Group {
        let id: UUID = UUID()
        let tiles: Set<DioramaTileID>
        let shape: DioramaUnionShape
        let revision: Float
        var inset: Float = -DioramaRevealStyle.support - 2
        var isRemoving: Bool = true
        var mustRetire: Bool = false
        var task: Task<Void, Never>?
        init(tiles: Set<DioramaTileID>, revision: Float) {
            self.tiles = tiles; shape = DioramaUnionShape(tiles: tiles); self.revision = revision
        }
    }
    private var residents: [DioramaTileID: Resident] = [:]
    private var groups: [UUID: Group] = [:]
    private var wanted: [DioramaTileID] = []
    private var visibleTiles: Set<DioramaTileID> = []
    private var deferredTiles: Set<DioramaTileID> = []
    private var retries: [DioramaTileID: Date] = [:]
    private var readTask: Task<Void, Never>?
    private var loadingTile: DioramaTileID?
    private var revision: UInt = 0
    private var shapeRevision: UInt = 0
    private var admissionRetry: Date = .distantPast
    private let payloadBudget: Int = 384 * 1_048_576
    private weak var map: MapboxMap?
    private weak var base: DioramaContextTiles?
    private var viewport: DioramaViewport?
    private var config: DioramaConfig = .slipway
    private var categories: Set<DioramaCategory> = []
    private var time: DioramaTimeOfDay = .day
    private var wireframe: Bool = false
    private var reduced: Bool = false
    private var motion: Bool = false
    private var loadingPhase: String = ""
    private var requestState: String = "Waiting for viewport"
    private var failures: [DioramaTileID: String] = [:]
    var onChanged: (() -> Void)?
    var onFrameReport: ((String) -> Void)?
    var onArtifact: ((DioramaTileID, DioramaTileArtifacts?) -> Void)?

    var hasResidents: Bool { !residents.isEmpty }
    var hasTransitions: Bool { !groups.isEmpty || residents.values.contains { $0.arrival != nil } }
    var tiles: [DioramaTileID] { residents.keys.sorted { $0.key < $1.key } }
    var report: String {
        let summary = "HD: \(residents.count) tiles · \(groups.count) joined transitions · \(residents.values.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB decoded payload (not total memory)"
        if !loadingPhase.isEmpty { return summary + "\n" + loadingPhase }
        guard let focus = wanted.first else { return summary + "\n" + requestState }
        if let failure = failures[focus] { return summary + "\n" + focus.key + ": " + failure }
        if residents[focus]?.arrival != nil { return summary + "\nHD expanding reveal · " + focus.key }
        if residents[focus] != nil { return summary + "\nFull-detail focus ready · " + focus.key }
        if deferredTiles.contains(focus) { return summary + "\nHD payload allowance reached · base retained" }
        return summary + "\n" + focus.key + ": " + (base?.readinessReport(focus) ?? "waiting for base")
    }
    func setRequestState(_ value: String) {
        guard requestState != value else { return }
        requestState = value
        print("[Diorama HD] \(value)")
    }
    var retryDelay: TimeInterval? {
        let dates = wanted.filter { residents[$0] == nil }.compactMap { retries[$0] } + [admissionRetry]
        return dates.filter { $0 > Date() }.min().map { max(0.1, $0.timeIntervalSinceNow) }
    }
    func groundHeight(at point: GeoPoint) -> Double? {
        let tile = DioramaTileID(latitude: point.latitude, longitude: point.longitude, zoom: 16)
        return residents[tile]?.host.groundHeight(at: point)
    }

    func update(wanted: [DioramaTileID], visibleTiles: [DioramaTileID], map: MapboxMap, base: DioramaContextTiles,
                viewport: DioramaViewport, config: DioramaConfig, categories: Set<DioramaCategory>,
                time: DioramaTimeOfDay, wireframe: Bool, reduced: Bool, motion: Bool) {
        self.map = map; self.base = base; self.viewport = viewport; self.config = config
        self.categories = categories; self.time = time; self.wireframe = wireframe
        self.reduced = reduced; self.motion = motion
        let next = Array(wanted.prefix(DioramaUnionShape.capacity))
        if self.wanted != next { deferredTiles.removeAll(); admissionRetry = .distantPast }
        self.wanted = next; self.visibleTiles = Set(visibleTiles)
        setPolicy(categories: categories, time: time, wireframe: wireframe, reduced: reduced, motion: motion)
        if let loadingTile, !self.wanted.contains(loadingTile) { pauseLoading() }
        reconcileGroups()
        startLoading()
    }

    func setPolicy(categories: Set<DioramaCategory>, time: DioramaTimeOfDay,
                   wireframe: Bool, reduced: Bool, motion: Bool) {
        for resident in residents.values {
            resident.host.setVisible(categories, timeOfDay: time)
            resident.host.setWireframe(wireframe); resident.host.setReducedEffects(reduced)
            resident.host.setWaterMotion(motion)
        }
    }

    func pauseLoading() {
        revision &+= 1; readTask?.cancel(); readTask = nil; loadingTile = nil; loadingPhase = ""
    }

    func demoteAll() {
        pauseLoading(); wanted.removeAll()
        reconcileGroups()
    }

    func clear() {
        pauseLoading()
        for group in groups.values { group.task?.cancel() }
        groups.removeAll()
        for tile in Array(residents.keys) { remove(tile) }
        wanted.removeAll(); visibleTiles.removeAll(); retries.removeAll(); failures.removeAll(); deferredTiles.removeAll(); admissionRetry = .distantPast
    }

    private func id(_ tile: DioramaTileID) -> String { "zuri-diorama-\(tile.key)" }
    private func remove(_ tile: DioramaTileID) {
        residents[tile]?.arrival?.cancel()
        if let map {
            for layer in [id(tile) + "-labels", id(tile)] where map.layerExists(withId: layer) { try? map.removeLayer(withId: layer) }
            if map.sourceExists(withId: id(tile) + "-source") { try? map.removeSource(withId: id(tile) + "-source") }
        }
        residents[tile] = nil; base?.removeFocusMask(tile); onArtifact?(tile, nil)
    }

    private func nextLoadableTile() -> DioramaTileID? {
        wanted.first { residents[$0] == nil && !deferredTiles.contains($0)
            && (retries[$0] ?? .distantPast) <= Date() && base?.isReady($0) == true }
    }
    private func startLoading() {
        guard readTask == nil, Date() >= admissionRetry, let map, nextLoadableTile() != nil else { return }
        let expected = revision
        readTask = Task { [weak self, weak map] in
            guard let self, let map else { return }
            defer {
                if self.revision == expected {
                    self.readTask = nil; self.loadingTile = nil; self.loadingPhase = ""; self.onChanged?()
                }
            }
            while let tile = self.nextLoadableTile() {
                guard !Task.isCancelled, self.revision == expected, UIApplication.shared.applicationState == .active else { return }
                // All low-detail packages preload; HD waits only for its own already-installed base.
                self.loadingTile = tile
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard self.wanted.contains(tile) else { continue }
                self.loadingPhase = "Reading saved HD · \(tile.key)"; self.onChanged?()
                print("[Diorama HD] reading \(tile.key)")
                let job = Task.detached(priority: .userInitiated) { await DioramaOfflineStore.shared.read(tile) }
                let artifact = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, self.revision == expected, self.wanted.contains(tile),
                      UIApplication.shared.applicationState == .active else { return }
                guard let artifact else {
                    let reason = await DioramaOfflineStore.shared.readFailure(tile)
                    guard !Task.isCancelled, self.revision == expected else { return }
                    self.retries[tile] = Date().addingTimeInterval(30)
                    self.failures[tile] = reason + " · retry in 30 s; downloads retained"
                    print("[Diorama HD] saved read unavailable \(tile.key): \(reason); low-detail retained")
                    continue
                }
                let bytes = self.residents.values.reduce(0) { $0 + $1.bytes }
                if self.residents.count >= DioramaUnionShape.capacity || (!self.residents.isEmpty && bytes + artifact.decodedBytes > self.payloadBudget) {
                    // Never evict just one member of an attached island to make room.
                    let retiring = self.groups.values.contains { $0.isRemoving }
                    if retiring { self.admissionRetry = Date().addingTimeInterval(2); return }
                    let priority = self.wanted.firstIndex(of: tile) ?? Int.max
                    if let victim = self.components().max(by: { self.priority(of: $0) < self.priority(of: $1) }),
                       self.priority(of: victim) > priority {
                        self.beginGroup(victim, mustRetire: true)
                        self.admissionRetry = Date().addingTimeInterval(2)
                        return
                    }
                    // A visible focus-containing island wins over another overlay. Do not churn
                    // the same island forever when the settled view exceeds the payload allowance.
                    self.deferredTiles.insert(tile)
                    print("[Diorama HD] overlay deferred by payload allowance \(tile.key); base retained")
                    continue
                }
                if self.groups.values.contains(where: { group in
                    self.neighbours(tile).contains(where: { group.tiles.contains($0) })
                }) {
                    self.admissionRetry = Date().addingTimeInterval(2)
                    return
                }
                self.retries[tile] = nil; self.failures[tile] = nil
                self.loadingPhase = "Preparing full-detail GPU resources · \(tile.key)"; self.onChanged?()
                await self.install(artifact, map: map, revision: expected)
                await Task.yield()
            }
        }
    }

    private func priority(of component: Set<DioramaTileID>) -> Int {
        component.compactMap { wanted.firstIndex(of: $0) }.min() ?? Int.max
    }

    private func install(_ artifacts: DioramaTileArtifacts, map: MapboxMap, revision expected: UInt) async {
        let tile = artifacts.tile
        let host = DioramaRenderLayer(origin: tile.centre, vertices: artifacts.vertices, indices: artifacts.indices,
            ranges: artifacts.ranges, groups: artifacts.groups, instances: artifacts.allInstances,
            lightGrid: artifacts.lightGrid, waterHeight: artifacts.waterHeight, groundImage: artifacts.groundImage,
            groundRect: DioramaProjection(origin: tile.centre).rect(of: tile), visible: categories, timeOfDay: time,
            animates: true, config: config, labels: artifacts.buildingLabels, displayScale: Float(UIScreen.main.scale),
            materialsPrepared: artifacts.renderMaterialsPrepared, materialCounts: artifacts.renderMaterialCounts,
            preparedPoolBounds: artifacts.renderPoolBounds)
        let upload = Task.detached(priority: .userInitiated) { await DioramaGPUUploadQueue.shared.prepare(host) }
        await withTaskCancellationHandler { await upload.value } onCancel: { upload.cancel() }
        guard !Task.isCancelled, revision == expected, self.map === map, wanted.contains(tile),
              UIApplication.shared.applicationState == .active, residents[tile] == nil else { return }
        if host.diagnostic.contains("failed") || host.diagnostic.contains("missing") {
            retries[tile] = Date().addingTimeInterval(30)
            failures[tile] = host.diagnostic + " · GPU setup retry in 30 s"
            print("[Diorama HD] GPU setup unavailable \(tile.key): \(host.diagnostic)")
            return
        }
        host.viewport = viewport
        host.setVisible(categories, timeOfDay: time); host.setWireframe(wireframe)
        host.setReducedEffects(reduced); host.setWaterMotion(motion)
        let resident = Resident(host: host, bytes: artifacts.decodedBytes)
        host.setReveal(resident.reveal)
        host.onInitializationFailed = { [weak self, weak host] in
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, self.residents[tile]?.host === host else { return }
                self.retries[tile] = Date().addingTimeInterval(30)
                self.failures[tile] = host.diagnostic + " · GPU initialization retry in 30 s"
                if let group = self.groups.values.first(where: { $0.tiles.contains(tile) }) {
                    group.task?.cancel(); self.groups[group.id] = nil
                    for member in group.tiles { self.remove(member) }
                } else { self.remove(tile) }
                self.refreshMasks(); self.onChanged?()
            }
        }
        host.onInitialized = { [weak self] in
            Task { @MainActor [weak self] in self?.onChanged?(); self?.map?.triggerRepaint() }
        }
        host.onLifecycleCompleted = { [weak self, weak host] in
            Task { @MainActor [weak self, weak host] in
                guard let self, let host, self.residents[tile]?.host === host else { return }
                print("[Diorama HD] first GPU-completed frame \(tile.key)")
                self.onChanged?()
            }
        }
        host.onRevealCompleted = { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeArrivalIfStalled(tile) }
        }
        host.onFrameReport = { [weak self] report in
            Task { @MainActor [weak self] in self?.onFrameReport?(report) }
        }
        do {
            residents[tile] = resident
            refreshMasks()
            try map.addCustomLayer(withId: id(tile), layerHost: host, layerPosition: nil)
            try setSlot(id(tile), on: map)
            var source = GeoJSONSource(id: id(tile) + "-source")
            source.data = .geometry(.polygon(Polygon([tile.outline])))
            try map.addSource(source)
            var clip = ClipLayer(id: id(tile) + "-labels", source: source.id)
            clip.slot = .top; clip.clipLayerScope = .constant(["basemap"]); clip.clipLayerTypes = .constant([.symbol])
            try map.addLayer(clip)
            onArtifact?(tile, artifacts)
            startArrival(tile, resident: resident)
            print("[Diorama HD] installed \(tile.key); residents=\(residents.count) decoded=\(resident.bytes)")
            map.triggerRepaint()
        } catch {
            retries[tile] = Date().addingTimeInterval(30); remove(tile); refreshMasks()
            failures[tile] = "Full-detail layer registration failed · retry in 30 s"
            print("[Diorama HD] installation unavailable \(tile.key): \(error.localizedDescription); low-detail retained")
        }
    }

    /// Resume only once both sides have acknowledged the retained coverage; never erase the base on a timer.
    func resumeArrivalIfStalled(_ tile: DioramaTileID) {
        guard let resident = residents[tile], resident.isRevealStalled,
              resident.host.hasCompleted(reveal: resident.reveal),
              base?.hasCompletedHDReveal(tile: tile, state: resident.reveal) == true,
              !groups.values.contains(where: { $0.tiles.contains(tile) }) else { return }
        resident.isRevealStalled = false; failures[tile] = nil
        startArrival(tile, resident: resident); onChanged?()
    }
    private func startArrival(_ tile: DioramaTileID, resident: Resident) {
        let host = resident.host
        let extent = max(abs(host.revealBounds.minimum.x), abs(host.revealBounds.maximum.x),
            abs(host.revealBounds.minimum.y), abs(host.revealBounds.maximum.y)) + DioramaRevealStyle.support + 50
        resident.arrival = Task { [weak self, weak resident] in
            guard let self, let resident else { return }
            let finished = await DioramaTileTransition.run(host: host, from: resident.reveal.z, to: extent, lifecycle: false,
                pairedCompletion: { [weak self] field in self?.base?.hasCompletedHDReveal(tile: tile, state: field) == true }) {
                [weak self, weak resident] field, _ in
                guard let self, let resident else { return }
                resident.reveal = field; self.applyMask(tile); self.map?.triggerRepaint()
            }
            guard !Task.isCancelled, self.residents[tile] === resident else { return }
            resident.arrival = nil
            if finished {
                resident.reveal = .zero; host.setReveal(.zero); self.applyMask(tile)
                self.failures[tile] = nil
                print("[Diorama HD] expanding reveal complete \(tile.key)")
            } else if host.isRendererReady {
                resident.isRevealStalled = true
                self.failures[tile] = "Reveal waiting for GPU frame · HD and coarse fallback retained"
                print("[Diorama HD] reveal stalled \(tile.key); retained coverage awaiting paired GPU frame")
                self.resumeArrivalIfStalled(tile)
            } else {
                self.retries[tile] = Date().addingTimeInterval(30)
                self.failures[tile] = host.diagnostic + " · render retry in 30 s"
                self.remove(tile); self.refreshMasks()
            }
            self.reconcileGroups(); self.onChanged?(); self.map?.triggerRepaint()
        }
    }
    private func setSlot(_ id: String, on map: MapboxMap) throws {
        try map.setLayerProperty(for: id, property: "slot", value: "middle")
    }

    /// Edge-connected components; diagonal contact alone is not a continuous island.
    private func components() -> [Set<DioramaTileID>] {
        var remaining = Set(residents.keys).subtracting(groups.values.reduce(into: Set<DioramaTileID>()) { $0.formUnion($1.tiles) })
        var result: [Set<DioramaTileID>] = []
        while let seed = remaining.first {
            var component: Set<DioramaTileID> = [seed]
            var frontier: [DioramaTileID] = [seed]
            remaining.remove(seed)
            while let tile = frontier.popLast() {
                for adjacent in neighbours(tile) where remaining.remove(adjacent) != nil {
                    component.insert(adjacent); frontier.append(adjacent)
                }
            }
            result.append(component)
        }
        return result
    }
    private func neighbours(_ tile: DioramaTileID) -> [DioramaTileID] {
        [tile.offset(dx: -1, dy: 0), tile.offset(dx: 0, dy: 1), tile.offset(dx: 1, dy: 0), tile.offset(dx: 0, dy: -1)]
    }
    private func reconcileGroups() {
        let desired: Set<DioramaTileID> = wanted.isEmpty ? [] : visibleTiles
        for group in groups.values {
            let shouldRemove = group.mustRetire || group.tiles.isDisjoint(with: desired)
            if group.isRemoving != shouldRemove { animate(group, removing: shouldRemove) }
        }
        for component in components() where component.isDisjoint(with: desired) { beginGroup(component) }
    }
    private func beginGroup(_ tiles: Set<DioramaTileID>, mustRetire: Bool = false) {
        guard !tiles.isEmpty else { return }
        shapeRevision &+= 1
        let group = Group(tiles: tiles, revision: Float(shapeRevision))
        group.mustRetire = mustRetire
        groups[group.id] = group
        for tile in tiles { residents[tile]?.arrival?.cancel(); residents[tile]?.arrival = nil }
        animate(group, removing: true)
        print("[Diorama HD] joined contraction tiles=\(tiles.count) boundary_cells=\(group.shape.cells.count)")
    }
    private func animate(_ group: Group, removing: Bool) {
        group.task?.cancel(); group.isRemoving = removing
        let from = group.inset, to = removing ? group.shape.emptyInset : -DioramaRevealStyle.support - 2
        group.task = Task { [weak self, weak group] in
            guard let self, let group else { return }
            var elapsed: Double = 0
            var previous = CACurrentMediaTime(), requested = previous
            var endpoint: Bool = false
            self.refreshMasks(); self.map?.triggerRepaint()
            while !Task.isCancelled, self.groups[group.id] === group {
                let now = CACurrentMediaTime()
                let finish = UIAccessibility.isReduceMotionEnabled || UIApplication.shared.applicationState != .active
                    || ProcessInfo.processInfo.thermalState == .critical
                let state = self.state(for: group)
                let visibleMembers = group.tiles.intersection(self.visibleTiles)
                let complete = visibleMembers.allSatisfy {
                    self.residents[$0]?.host.hasCompletedUnion(state) == true
                        && self.base?.hasCompletedHDUnion(tile: $0, state: state) == true
                }
                if finish || visibleMembers.isEmpty || now - requested > 20 {
                    // Offscreen hosts may not receive SDK callbacks; never hold an island forever.
                    group.inset = to; self.refreshMasks(); break
                }
                if complete {
                    if endpoint { break }
                    elapsed += min(1.0 / 30, max(0, now - previous))
                    let progress = Float(min(1, elapsed / 1.8))
                    let eased = progress * progress * (3 - 2 * progress)
                    group.inset = from + (to - from) * eased
                    self.refreshMasks(); self.map?.triggerRepaint()
                    requested = now; endpoint = progress >= 1
                }
                previous = now
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
            guard !Task.isCancelled, self.groups[group.id] === group else { return }
            self.groups[group.id] = nil
            if removing {
                for tile in group.tiles { self.remove(tile) }
                self.deferredTiles.removeAll()
            }
            else {
                for tile in group.tiles {
                    self.residents[tile]?.reveal = .zero
                    self.residents[tile]?.host.setReveal(.zero)
                }
            }
            self.refreshMasks(); self.onChanged?(); self.map?.triggerRepaint()
        }
    }
    private func state(for group: Group) -> SIMD4<Float> {
        SIMD4(1, Float(group.shape.cells.count), group.inset, group.revision)
    }
    private func edges(for tile: DioramaTileID) -> SIMD4<Float> {
        let attached = Set(residents.keys)
        return SIMD4(attached.contains(tile.offset(dx: -1, dy: 0)) ? 0 : 1,
            attached.contains(tile.offset(dx: 0, dy: 1)) ? 0 : 1,
            attached.contains(tile.offset(dx: 1, dy: 0)) ? 0 : 1,
            attached.contains(tile.offset(dx: 0, dy: -1)) ? 0 : 1)
    }
    private func applyMask(_ tile: DioramaTileID) {
        guard let resident = residents[tile] else { return }
        let group = groups.values.first { $0.tiles.contains(tile) }
        let edges = edges(for: tile), state = group.map { self.state(for: $0) } ?? .zero
        resident.host.setTileCoverage(edges: .zero, role: 1, paired: base?.isReady(tile) == true, focusEdges: edges)
        resident.host.setUnionCoverage(group?.shape, state: state)
        base?.setHDMask(tile: tile, reveal: resident.reveal, edges: edges, shape: group?.shape, union: state)
    }
    private func refreshMasks() { for tile in residents.keys { applyMask(tile) } }
}
