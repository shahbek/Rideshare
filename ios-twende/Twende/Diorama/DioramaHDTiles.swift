import Foundation
@_spi(Experimental) import MapboxMaps
import UIKit

/// Demand-loaded HD overlays. Connected residents are retained and demoted as one union footprint.
@MainActor
final class DioramaHDTiles {
    private final class Resident {
        let host: DioramaRenderLayer
        let bytes: Int
        let reservation: UUID
        var reveal: SIMD4<Float>
        var arrival: Task<Void, Never>?
        var isRevealStalled: Bool = false
        init(host: DioramaRenderLayer, bytes: Int, reservation: UUID) {
            self.host = host; self.bytes = bytes; self.reservation = reservation
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
        var isStalled: Bool = false
        var task: Task<Void, Never>?
        init(tiles: Set<DioramaTileID>, revision: Float) {
            self.tiles = tiles; shape = DioramaUnionShape(tiles: tiles); self.revision = revision
        }
    }
    private var residents: [DioramaTileID: Resident] = [:]
    private var groups: [UUID: Group] = [:]
    private var wanted: [DioramaTileID] = []
    /// Wanted tiles plus residents that left interest moments ago (zoom/pan jitter) and still fit.
    private var retained: Set<DioramaTileID> = []
    private var lastWanted: [DioramaTileID: Date] = [:]
    private var lingerTask: Task<Void, Never>?
    private static let linger: TimeInterval = 6
    private var visibleTiles: Set<DioramaTileID> = []
    private var deferredTiles: Set<DioramaTileID> = []
    /// Residents read before all of their landmark recipes were baked; reloaded once they are.
    private var landmarksPending: Set<DioramaTileID> = []
    private var retries: [DioramaTileID: Date] = [:]
    private var readTask: Task<Void, Never>?
    private var loadingTile: DioramaTileID?
    private var revision: UInt = 0
    private var shapeRevision: UInt = 0
    private var admissionRetry: Date = .distantPast
    var budget: DioramaResidencyBudget?
    var outputSize: CGSize = .zero
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
    var onArtifact: ((DioramaTileID, DioramaTileSummary?) -> Void)?

    var hasResidents: Bool { !residents.isEmpty }
    var hasTransitions: Bool { !groups.isEmpty || residents.values.contains { $0.arrival != nil } }
    var tiles: [DioramaTileID] { residents.keys.sorted { $0.key < $1.key } }
    var report: String {
        let summary = "HD: \(residents.count) tiles · \(groups.count) joined transitions · \(residents.values.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB resident GPU-shared scenery (not total memory)"
        if !loadingPhase.isEmpty { return summary + "\n" + loadingPhase }
        guard let focus = wanted.first else { return summary + "\n" + requestState }
        if let failure = failures[focus] { return summary + "\n" + focus.key + ": " + failure }
        if groups.values.contains(where: { $0.tiles.contains(focus) && $0.isStalled }) {
            return summary + "\nJoined retraction waiting for paired GPU frame · coverage retained"
        }
        if residents[focus]?.arrival != nil { return summary + "\nHD expanding reveal · " + focus.key }
        if residents[focus] != nil { return summary + "\nFull-detail focus ready · " + focus.key }
        if deferredTiles.contains(focus) { return summary + "\nHD exceeds available CPU/GPU allowance · coarse/native fallback retained" }
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
        let next = Array(wanted.prefix(budget?.hdLimit ?? 1))
        // Dense tiles append tile-baked landmarks/skyline; build those meshes as soon as a tile is
        // wanted (not at its read) so the preflight estimate is real and the read is not delayed.
        for tile in next where residents[tile] == nil && !landmarkWarmed.contains(tile) && !DioramaBakedLandmarks.ids(for: tile).isEmpty {
            landmarkWarmed.insert(tile)
            DioramaBakedLandmarks.shared.buildMissing(for: tile)
        }
        if self.wanted != next {
            base.finishHDReclamation()
            retryAdmission()
        }
        self.wanted = next; self.visibleTiles = Set(visibleTiles)
        refreshRetained()
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
        base?.finishHDReclamation()
    }

    private var landmarkWarmed: Set<DioramaTileID> = []
    /// A package for `tile` just arrived (streamed); forget its missing-package backoff.
    func packageArrived(_ tile: DioramaTileID) { retries[tile] = nil; failures[tile] = nil; deferredTiles.remove(tile) }
    func retryAdmission() {
        for tile in deferredTiles { failures[tile] = nil }
        deferredTiles.removeAll(); admissionRetry = .distantPast
    }

    /// All recipes of `tile` are baked. A resident drawn without them retires and is re-read
    /// (cached meshes now, so the second read is the ordinary decode time).
    func landmarksReady(_ tile: DioramaTileID) {
        guard landmarksPending.remove(tile) != nil, residents[tile] != nil else { return }
        print("[Diorama HD] \(tile.key) landmarks baked; reloading the tile with them")
        retries[tile] = nil; failures[tile] = nil
        beginGroup([tile], mustRetire: true)
    }

    func demoteAll() {
        pauseLoading(); wanted.removeAll(); lastWanted.removeAll(); retained.removeAll()
        lingerTask?.cancel(); lingerTask = nil
        reconcileGroups()
    }

    /// Zooming into an HD area shrinks the view, so edge tiles momentarily leave interest. They stay
    /// resident (inside the HD limit) for a few seconds while still visible or adjacent to a wanted
    /// tile, instead of retracting and re-reading when interest returns.
    private func refreshRetained() {
        let now = Date()
        for tile in wanted { lastWanted[tile] = now }
        lastWanted = lastWanted.filter { now.timeIntervalSince($0.value) < Self.linger }
        let slots = max(0, (budget?.hdLimit ?? 1) - wanted.count)
        let lingering = residents.keys.filter { tile in
            !wanted.contains(tile) && lastWanted[tile] != nil
                && (visibleTiles.contains(tile) || neighbours(tile).contains(where: wanted.contains))
                && !(groups.values.contains { $0.tiles.contains(tile) && $0.mustRetire })
        }.sorted { (lastWanted[$0] ?? .distantPast) > (lastWanted[$1] ?? .distantPast) }
        retained = Set(wanted).union(lingering.prefix(slots))
        lingerTask?.cancel(); lingerTask = nil
        if let soonest = lingering.prefix(slots).compactMap({ lastWanted[$0] }).min() {
            let delay = max(0.1, Self.linger - now.timeIntervalSince(soonest) + 0.05)
            lingerTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                self.lingerTask = nil
                self.refreshRetained(); self.reconcileGroups(); self.onChanged?()
            }
        }
    }

    func clear() {
        pauseLoading()
        for group in groups.values { group.task?.cancel() }
        groups.removeAll()
        for tile in Array(residents.keys) { remove(tile) }
        wanted.removeAll(); visibleTiles.removeAll(); retries.removeAll(); failures.removeAll(); deferredTiles.removeAll(); admissionRetry = .distantPast
        lastWanted.removeAll(); retained.removeAll(); lingerTask?.cancel(); lingerTask = nil
        landmarksPending.removeAll()
    }

    private func id(_ tile: DioramaTileID) -> String { "zuri-diorama-\(tile.key)" }
    private func remove(_ tile: DioramaTileID) {
        residents[tile]?.arrival?.cancel()
        if let map {
            DioramaLayerGroup.existing(for: map)?.detach(id(tile))
            for layer in [id(tile) + "-labels", id(tile)] where map.layerExists(withId: layer) { try? map.removeLayer(withId: layer) }
            if map.sourceExists(withId: id(tile) + "-source") { try? map.removeSource(withId: id(tile) + "-source") }
        }
        if let resident = residents.removeValue(forKey: tile) { budget?.release(resident.reservation) }
        base?.removeFocusMask(tile); onArtifact?(tile, nil)
    }

    /// Decoding may start as soon as the paired base is installed (even mid-reveal) and while an
    /// adjacent HD tile is still revealing; only installation waits for those (see `canInstall`).
    private func nextLoadableTile() -> DioramaTileID? {
        wanted.first { tile in
            residents[tile] == nil && !deferredTiles.contains(tile)
                && (retries[tile] ?? .distantPast) <= Date() && base?.isInstalled(tile) == true
        }
    }
    private func canInstall(_ tile: DioramaTileID) -> Bool {
        base?.isReady(tile) == true && neighbours(tile).allSatisfy { adjacent in
            residents[adjacent]?.arrival == nil && residents[adjacent]?.isRevealStalled != true
                && !groups.values.contains(where: { $0.tiles.contains(adjacent) })
        }
    }

    func updateRetirementVisibility(_ tiles: [DioramaTileID]) {
        visibleTiles = Set(tiles)
        for group in Array(groups.values) where group.isStalled && group.tiles.isDisjoint(with: visibleTiles) {
            animate(group, removing: group.isRemoving)
        }
    }
    private func startLoading() {
        guard readTask == nil, budget?.isLoading(context: false) != true, Date() >= admissionRetry, let map, nextLoadableTile() != nil else { return }
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
                // Only admitted visible bases load; reserve CPU/GPU peak before decoding HD.
                self.loadingTile = tile
                // Brief settle so a fast pan does not start a read for a tile it is passing over.
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard self.wanted.contains(tile), let budget = self.budget else { continue }
                // Never wait for landmark/skyline recipes: draw the tile now and reload it with them later.
                if !DioramaBakedLandmarks.ids(for: tile).isEmpty, !DioramaBakedLandmarks.shared.isComplete(for: tile) {
                    self.landmarksPending.insert(tile)
                    DioramaBakedLandmarks.shared.buildMissing(for: tile)
                } else {
                    self.landmarksPending.remove(tile)
                }
                guard let cost = await DioramaOfflineStore.store(for: tile).residencyCost(tile, context: false, size: self.outputSize, scale: Float(UIScreen.main.scale)) else {
                    self.retries[tile] = Date().addingTimeInterval(30)
                    self.failures[tile] = "Saved HD manifest unavailable · downloads retained"; continue
                }
                guard !Task.isCancelled, self.revision == expected, self.wanted.contains(tile) else { return }
                if !budget.canReserve(cost, context: false), !budget.isLoading(context: false) {
                    self.base?.makeRoomForHD(tile, cost: cost, pinned: self.tiles)
                }
                guard let reservation = budget.reserve(cost, context: false) else {
                    if budget.isLoading(context: false) { return }
                    // Timed retry, not a permanent deferral: coarse retirement and HD commits free
                    // headroom without changing the wanted list.
                    self.retries[tile] = Date().addingTimeInterval(2.5)
                    let reason = cost.peak > budget.limit ? "Tile alone exceeds scenery allowance" : "Waiting for scenery memory headroom"
                    self.failures[tile] = "\(reason) · HD peak \((cost.peak + 1_048_575) / 1_048_576) MiB, available \(budget.availableBytes / 1_048_576)/\(budget.limit / 1_048_576) MiB · coarse/native retained"
                    self.onChanged?()
                    print("[Diorama HD] preflight deferred \(tile.key) peak=\(cost.peak) · \(budget.report)")
                    continue
                }
                self.base?.finishHDReclamation(for: tile)
                defer { if self.residents[tile]?.reservation != reservation { budget.release(reservation) } }
                self.loadingPhase = "Reading saved HD · \(tile.key)"; self.onChanged?()
                print("[Diorama HD] reading \(tile.key)")
                let job = Task.detached(priority: .userInitiated) { await DioramaOfflineStore.store(for: tile).readResident(tile, context: false) }
                let artifact = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, self.revision == expected, self.wanted.contains(tile),
                      UIApplication.shared.applicationState == .active else { return }
                guard let artifact else {
                    let reason = await DioramaOfflineStore.store(for: tile).readFailure(tile)
                    guard !Task.isCancelled, self.revision == expected else { return }
                    self.retries[tile] = Date().addingTimeInterval(30)
                    self.failures[tile] = reason + " · retry in 30 s; downloads retained"
                    print("[Diorama HD] saved read unavailable \(tile.key): \(reason); low-detail retained")
                    continue
                }
                // Decoding is complete: the remaining reservation is the actual retained allocation.
                let retained = DioramaResidencyBudget.residentCost(artifact, context: false, size: self.outputSize, scale: Float(UIScreen.main.scale))
                let settled = DioramaResidencyBudget.Cost(retained: retained, peak: retained)
                guard budget.revise(reservation, cost: settled) else {
                    self.retries[tile] = Date().addingTimeInterval(2.5)
                    self.failures[tile] = "Decoded HD requires \((retained + 1_048_575) / 1_048_576) MiB · base retained within \(budget.limit / 1_048_576) MiB allowance"
                    continue
                }
                self.retries[tile] = nil; self.failures[tile] = nil
                // Decoded while the base or a neighbour finished revealing; install once they settle.
                var abandoned = false
                while !self.canInstall(tile) {
                    guard !Task.isCancelled, self.revision == expected, UIApplication.shared.applicationState == .active else { return }
                    guard self.wanted.contains(tile), self.base?.isInstalled(tile) == true else { abandoned = true; break }
                    self.loadingPhase = "HD decoded · waiting for base/neighbour reveal · \(tile.key)"
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                }
                if abandoned { continue }
                self.loadingPhase = "Preparing full-detail GPU resources · \(tile.key)"; self.onChanged?()
                await self.install(artifact, map: map, revision: expected, reservation: reservation)
                if self.residents[tile]?.reservation == reservation { budget.commit(reservation, cost: settled) }
                await Task.yield()
            }
        }
    }

    private func priority(of component: Set<DioramaTileID>) -> Int {
        component.compactMap { wanted.firstIndex(of: $0) }.min() ?? Int.max
    }

    private func install(_ artifacts: DioramaResidentTile, map: MapboxMap, revision expected: UInt, reservation: UUID) async {
        let tile = artifacts.tile
        let host = DioramaRenderLayer(resident: artifacts, groundRect: DioramaProjection(origin: tile.centre).rect(of: tile),
            visible: categories, timeOfDay: time, config: config, labels: artifacts.labels,
            displayScale: Float(UIScreen.main.scale), contextOnly: false)
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
        let resident = Resident(host: host, bytes: artifacts.gpuBytes + artifacts.cpuBytes, reservation: reservation)
        let settled = Set(residents.keys.filter { candidate in
            residents[candidate]?.host.isRendererReady == true && residents[candidate]?.arrival == nil
                && residents[candidate]?.reveal.w == 0
                && !groups.values.contains(where: { $0.tiles.contains(candidate) })
        })
        let frontier = SIMD4<Float>(settled.contains(tile.offset(dx: -1, dy: 0)) ? 0 : 1,
            settled.contains(tile.offset(dx: 0, dy: 1)) ? 0 : 1,
            settled.contains(tile.offset(dx: 1, dy: 0)) ? 0 : 1,
            settled.contains(tile.offset(dx: 0, dy: -1)) ? 0 : 1)
        resident.reveal = DioramaRevealStyle.growthSeed(edges: frontier)
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
        host.onUnionCompleted = { [weak self] in
            Task { @MainActor [weak self] in self?.resumeArrivalIfStalled(tile) }
        }
        host.onRevealCompleted = { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeArrivalIfStalled(tile) }
        }
        host.onFrameReport = { [weak self] report in
            Task { @MainActor [weak self] in self?.onFrameReport?(report) }
        }
        host.onPassReport = { report in
            Task { @MainActor in DioramaState.shared.passReport = "\(tile.key)\n" + report }
        }
        do {
            residents[tile] = resident
            refreshMasks()
            try DioramaLayerGroup.group(for: map).attach(host, id: id(tile), order: 1, map: map)
            var source = GeoJSONSource(id: id(tile) + "-source")
            source.data = .geometry(.polygon(Polygon([tile.outline])))
            try map.addSource(source)
            var clip = ClipLayer(id: id(tile) + "-labels", source: source.id)
            clip.slot = .top; clip.clipLayerScope = .constant(["basemap"]); clip.clipLayerTypes = .constant([.symbol])
            try map.addLayer(clip)
            onArtifact?(tile, artifacts.summary)
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
        if let group = groups.values.first(where: { $0.tiles.contains(tile) && $0.isStalled }) {
            let state = self.state(for: group)
            let complete = group.tiles.intersection(visibleTiles).allSatisfy {
                residents[$0]?.host.hasCompletedUnion(state) == true && base?.hasCompletedHDUnion(tile: $0, state: state) == true
            }
            if complete { animate(group, removing: group.isRemoving) }
            return
        }
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
            abs(host.revealBounds.minimum.y), abs(host.revealBounds.maximum.y)) * (resident.reveal.w > 3.5 ? 3 : 1) + DioramaRevealStyle.support + 50
        resident.arrival = Task { [weak self, weak resident] in
            guard let self, let resident else { return }
            let finished = await DioramaTileTransition.run(host: host, from: resident.reveal.z, to: extent, lifecycle: false, field: resident.reveal, duration: 0.9,
                pairedCompletion: { [weak self] field in self?.base?.hasCompletedHDReveal(tile: tile, state: field) == true }) {
                [weak self, weak resident] field, _ in
                guard let self, let resident else { return }
                let joinedFront = field.w > 3.5 && resident.reveal.z < DioramaRevealStyle.support
                    && field.z >= DioramaRevealStyle.support
                resident.reveal = field
                if joinedFront { self.refreshMasks() } else { self.applyMask(tile) }
                self.map?.triggerRepaint()
            }
            guard !Task.isCancelled, self.residents[tile] === resident else { return }
            resident.arrival = nil
            if finished {
                resident.reveal = .zero; host.setReveal(.zero); self.refreshMasks()
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
        let desired = retained.union(wanted)
        for group in Array(groups.values) {
            let shouldRemove = group.mustRetire || !group.tiles.isSubset(of: desired)
            if group.isRemoving != shouldRemove || (group.isStalled && group.tiles.isDisjoint(with: visibleTiles)) {
                animate(group, removing: shouldRemove)
            }
        }
        // Retire only the members that left interest; the rest of a joined island stays put
        // (previously one departing edge tile retracted and re-read the whole island).
        for component in components() {
            let leaving = component.subtracting(desired)
            if !leaving.isEmpty { beginGroup(leaving) }
        }
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
        group.task?.cancel(); group.isRemoving = removing; group.isStalled = false
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
                if finish || visibleMembers.isEmpty {
                    // Offscreen hosts may not receive SDK callbacks; never hold an island forever.
                    group.inset = to; self.refreshMasks(); break
                }
                if !complete, now - requested > 20 {
                    group.isStalled = true; group.task = nil; self.onChanged?()
                    print("[Diorama HD] joined contraction waiting for paired GPU; resources retained")
                    return
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
                    if let resident = self.residents[tile], resident.reveal.w > 0.5 {
                        self.startArrival(tile, resident: resident)
                    }
                }
            }
            self.refreshMasks(); self.onChanged?(); self.map?.triggerRepaint()
        }
    }
    private func state(for group: Group) -> SIMD4<Float> {
        SIMD4(1, Float(group.shape.cells.count), group.inset, group.revision)
    }
    private func edges(for tile: DioramaTileID) -> SIMD4<Float> {
        func connected(_ neighbour: DioramaTileID) -> Bool {
            guard let resident = residents[neighbour] else { return false }
            if resident.reveal.w < 0.5 || groups.values.contains(where: { $0.tiles.contains(tile) && $0.tiles.contains(neighbour) }) { return true }
            guard resident.reveal.w > 3.5, resident.reveal.z >= DioramaRevealStyle.support else { return false }
            let side = tile.x < neighbour.x ? 0 : tile.x > neighbour.x ? 2 : tile.y > neighbour.y ? 1 : 3
            return Int(resident.reveal.x) & (1 << side) != 0
        }
        return SIMD4(connected(tile.offset(dx: -1, dy: 0)) ? 0 : 1,
            connected(tile.offset(dx: 0, dy: 1)) ? 0 : 1,
            connected(tile.offset(dx: 1, dy: 0)) ? 0 : 1,
            connected(tile.offset(dx: 0, dy: -1)) ? 0 : 1)
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
