import CoreLocation
import Foundation
@_spi(Experimental) import MapboxMaps
import Observation
import UIKit

/// Finished harbour pieces (`DioramaStreamPiece`), drawn the way Fenn draws its custom areas: the
/// finished scene ships inside the app and is read straight from the bundle, so nothing is downloaded,
/// unpacked, baked or simplified on the viewing phone. While the camera looks at the harbour this
/// mounts only the pieces it can see, nearest first: one coarse piece per tile from far away, four
/// medium pieces when close, and a window of full-detail 60 m pieces under the camera at HD zoom.
/// Pieces that leave the view are released. The coarse and medium pieces are decoded into GPU memory
/// at launch so the harbour is ready before the camera arrives.
///
/// Builds without the bundled set (`harbour_pieces.json` + `piece-*.bin`) fall back to streaming the
/// published set from the backend with a 500 MB recent-pieces disk cache.
///
/// Tiles saved on this phone (prepared or streamed as packages) keep drawing through the saved-tile
/// path; pieces cover only tiles that are not saved locally.
@Observable @MainActor
final class DioramaPieceStreamer {
    static let shared = DioramaPieceStreamer()
    typealias ID = DioramaStreamPiece.ID
    typealias Ring = DioramaStreamPiece.Ring

    let region: DioramaRegion = .harbour
    /// Recent pieces kept on disk (least recently used dropped first).
    nonisolated static let cacheCap: Int64 = 500 * 1_048_576
    /// Resident GPU memory for pieces; beyond it the farthest pieces are released first.
    nonisolated static let residentCap = 192 * 1_048_576
    nonisolated static let linger: TimeInterval = 5
    /// Half-size of the full-detail window (metres); 1.5 blocks each side of the camera's ground point.
    nonisolated static let fineHalfBlocks: Double = 1.5

    // MARK: Catalogue

    private(set) var catalogRevision: Int = 0
    /// The finished set is inside the app bundle (or baked on this phone); no network is used for the harbour.
    private(set) var isBundled: Bool = false
    /// The set being drawn is the one this phone baked (Settings → Bake), not the app's bundled set.
    private(set) var isLocalBake: Bool = false
    private(set) var isPublished: Bool = false
    private(set) var catalogChecked: Bool = false
    private(set) var catalogFiles: Int = 0
    private(set) var catalogBytes: Int64 = 0
    @ObservationIgnored private var available: [ID: DioramaPrebakedScenery.File] = [:]
    @ObservationIgnored private var catalogFetched: Date = .distantPast
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    /// Whole-package streaming must wait until the piece catalogue is known to be absent.
    var holdsPackageStreaming: Bool { !catalogChecked || isPublished }

    // MARK: Status

    private(set) var status: String = ""
    private(set) var isStreaming: Bool = false
    private(set) var isNearby: Bool = false
    private(set) var isBlockedByDownloadedOnly: Bool = false
    private(set) var piecesWanted: Int = 0
    private(set) var piecesReady: Int = 0
    private(set) var bytesStreamed: Int64 = 0
    private(set) var progress: (received: Int64, expected: Int64)?
    private(set) var cacheBytes: Int64 = 0
    @ObservationIgnored var allowsNetwork: () -> Bool = { true }
    @ObservationIgnored var onChanged: (() -> Void)?

    // MARK: Residents

    private final class Resident {
        let id: ID
        let host: DioramaRenderLayer
        let bytes: Int
        let groundRect: DioramaRect
        var attached: Bool = false
        init(id: ID, host: DioramaRenderLayer, bytes: Int, groundRect: DioramaRect) {
            self.id = id; self.host = host; self.bytes = bytes; self.groundRect = groundRect
        }
    }
    @ObservationIgnored private var residents: [ID: Resident] = [:]
    @ObservationIgnored private var wanted: [ID] = []
    @ObservationIgnored private var wantedSet: Set<ID> = []
    @ObservationIgnored private var lastWanted: [ID: Date] = [:]
    @ObservationIgnored private var mounting: Set<ID> = []
    @ObservationIgnored private var failed: [ID: Date] = [:]
    @ObservationIgnored private var activeWorkers: Int = 0
    @ObservationIgnored private var workerGeneration: UInt = 0
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private weak var map: MapboxMap?
    @ObservationIgnored private var viewport: DioramaViewport?
    @ObservationIgnored private var config: DioramaConfig = .slipway
    @ObservationIgnored private var categories: Set<DioramaCategory> = Set(DioramaCategory.allCases)
    @ObservationIgnored private var time: DioramaTimeOfDay = .day
    @ObservationIgnored private var wireframe: Bool = false
    @ObservationIgnored private var reduced: Bool = false
    @ObservationIgnored private var motion: Bool = false
    /// Full-detail window: camera ground point (with hysteresis) and half-size in metres.
    @ObservationIgnored private var fineWindow: (centre: CLLocationCoordinate2D, half: Double)?
    @ObservationIgnored private var requestedAt: [ID: Date] = [:]
    @ObservationIgnored private var firstRequestAt: Date?
    @ObservationIgnored private var firstDrawLogged: Bool = false
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: c)
    }()

    // MARK: Bundled set

    /// Decoded-but-not-yet-mounted pieces, ready before the camera arrives.
    @ObservationIgnored private var warm: [ID: DioramaStreamPiece.Decoded] = [:]
    @ObservationIgnored private var warmTask: Task<Void, Never>?

    /// Reads the manifest shipped in the app and keeps only pieces whose file is really present with
    /// the published size (a missing or placeholder file simply falls back to the backend).
    nonisolated private static func loadBundledSet() -> (catalog: DioramaPrebakedScenery.Catalog, files: [ID: DioramaPrebakedScenery.File])? {
        guard let url = Bundle.main.url(forResource: "harbour_pieces", withExtension: "json")
            ?? Bundle.main.url(forResource: "harbour_pieces", withExtension: "json", subdirectory: "HarbourPieces"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(DioramaPrebakedScenery.Catalog.self, from: data) else { return nil }
        var files: [ID: DioramaPrebakedScenery.File] = [:]
        for file in catalog.files where file.f == DioramaStreamPiece.fileName {
            guard let id = ID(directory: file.d), DioramaRegion.harbour.tiles.contains(id.tile), bundledURL(file) != nil else { continue }
            files[id] = file
        }
        guard !files.isEmpty else { return nil }
        if files.count < catalog.files.count { print("[Pieces] bundled set incomplete: \(files.count) of \(catalog.files.count) pieces usable") }
        return (catalog, files)
    }

    /// Marker digest of pieces baked on this phone (never uploaded under this name).
    nonisolated private static let localBakeDigest = "local-bake"

    /// The set this phone baked itself (`DioramaPieceBaker`), so a fresh bake can be looked at
    /// before it is uploaded or built into the app. Only pieces whose file is really present with
    /// the measured size count.
    nonisolated private static func loadLocalBake() -> (catalog: DioramaPrebakedScenery.Catalog, files: [ID: DioramaPrebakedScenery.File])? {
        let root = DioramaPieceBaker.root
        guard let data = try? Data(contentsOf: root.appendingPathComponent("bake.json")),
              let report = try? JSONDecoder().decode(DioramaPieceBaker.Report.self, from: data) else { return nil }
        var files: [ID: DioramaPrebakedScenery.File] = [:]
        for piece in report.pieces {
            let file = DioramaPrebakedScenery.File(d: piece.directory, f: DioramaStreamPiece.fileName, b: piece.bytes, s: localBakeDigest)
            guard let id = ID(directory: piece.directory), DioramaRegion.harbour.tiles.contains(id.tile), pieceURL(file) != nil else { continue }
            files[id] = file
        }
        guard !files.isEmpty else { return nil }
        let catalog = DioramaPrebakedScenery.Catalog(revision: report.revision, publishedAt: report.bakedAt, files: Array(files.values))
        return (catalog, files)
    }

    /// The piece file on this phone: the local bake, or inside the app; only when its size matches.
    nonisolated private static func pieceURL(_ file: DioramaPrebakedScenery.File?) -> URL? {
        guard let file else { return nil }
        if file.s == localBakeDigest {
            let url = DioramaPieceBaker.root.appendingPathComponent(file.d).appendingPathComponent(file.f)
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.b ? url : nil
        }
        return bundledURL(file)
    }

    /// The piece file inside the app, only when its size matches the manifest.
    nonisolated private static func bundledURL(_ file: DioramaPrebakedScenery.File?) -> URL? {
        guard let file, let url = Bundle.main.url(forResource: file.d, withExtension: "bin")
            ?? Bundle.main.url(forResource: file.d, withExtension: "bin", subdirectory: "HarbourPieces"),
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.b else { return nil }
        return url
    }

    /// Loads the bundled manifest and decodes the coarse and medium pieces into GPU memory in the
    /// background, so the first look at the harbour mounts finished buffers instead of reading files.
    /// Called once at launch; harmless when the app has no bundled set.
    func warmUp() {
        refreshCatalog()
        guard isBundled, warmTask == nil, let device = DioramaGPUPreparation.shared.device else { return }
        let jobs = available.filter { $0.key.ring != .fine }.sorted { ($0.key.ring.order, $0.key.directory) < ($1.key.ring.order, $1.key.directory) }
        let started = Date()
        warmTask = Task.detached(priority: .utility) { [weak self] in
            var decoded: [(ID, DioramaStreamPiece.Decoded)] = []
            for (id, file) in jobs {
                guard !Task.isCancelled, let url = Self.pieceURL(file),
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let piece = try? DioramaStreamPiece.decode(data, expected: id, device: device) else { continue }
                decoded.append((id, piece))
            }
            let ready = decoded
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, piece) in ready where self.residents[id] == nil { self.warm[id] = piece }
                self.warmTask = nil
                print("[Pieces] warmed \(ready.count) whole-tile pieces from \(self.isLocalBake ? "this phone's bake" : "the app bundle") in \(String(format: "%.2f", Date().timeIntervalSince(started))) s (no network)")
                self.ensureWorkers()
            }
        }
    }

    nonisolated static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HarbourPieces", isDirectory: true)
    }

    private init() {
        cacheBytes = Self.measureCache()
    }

    var hasResidents: Bool { residents.values.contains { $0.attached } }
    /// Tiles the attached pieces currently cover (coarse or medium), for native-3D suppression.
    func covers(_ tile: DioramaTileID) -> Bool {
        residents.values.contains { $0.attached && $0.id.tile == tile && $0.id.ring != .fine }
    }
    var coveredTiles: Set<DioramaTileID> { Set(residents.values.filter { $0.attached && $0.id.ring != .fine }.map(\.id.tile)) }

    func groundHeight(at point: GeoPoint) -> Double? {
        for ring in [Ring.scene, .fine, .medium, .coarse] {
            for resident in residents.values where resident.attached && resident.id.ring == ring {
                if let height = resident.host.groundHeight(at: point) { return height }
            }
        }
        return nil
    }

    var report: String {
        let attached = residents.values.filter(\.attached)
        let rings = Ring.allCases.map { ring in "\(attached.filter { $0.id.ring == ring }.count) \(ring.displayName)" }.joined(separator: " · ")
        return "Pieces: \(rings) · \(attached.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB resident · \(piecesReady)/\(piecesWanted) wanted ready"
    }

    // MARK: Catalogue

    func refreshCatalog(force: Bool = false) {
        if isBundled { return }
        if !catalogChecked {
            let local = Self.loadLocalBake()
            if let set = local ?? Self.loadBundledSet() {
                available = set.files
                catalogRevision = set.catalog.revision
                catalogFiles = set.files.count
                catalogBytes = set.files.values.reduce(Int64(0)) { $0 + Int64($1.b) }
                isLocalBake = local != nil
                isPublished = true; isBundled = true; catalogChecked = true; catalogFetched = Date()
                print("[Pieces] \(isLocalBake ? "this phone's baked set" : "bundled set rev \(catalogRevision)"): \(catalogFiles) pieces, \(catalogBytes) bytes, no network needed")
                onChanged?()
                return
            }
        }
        if !force, catalogChecked, Date().timeIntervalSince(catalogFetched) < 600 { return }
        guard catalogTask == nil else { return }
        catalogTask = Task { [weak self] in
            guard let self else { return }
            defer { self.catalogTask = nil }
            do {
                let catalog = try await DioramaPrebakedScenery.catalog(named: DioramaStreamPiece.catalogName)
                var files: [ID: DioramaPrebakedScenery.File] = [:]
                for file in catalog.files where file.f == DioramaStreamPiece.fileName {
                    if let id = ID(directory: file.d), self.region.tiles.contains(id.tile) { files[id] = file }
                }
                self.available = files
                self.catalogRevision = catalog.revision
                self.catalogFiles = files.count
                self.catalogBytes = files.values.reduce(Int64(0)) { $0 + Int64($1.b) }
                self.isPublished = !files.isEmpty
                print("[Pieces] catalogue rev \(catalog.revision): \(files.count) pieces, \(self.catalogBytes) bytes")
            } catch {
                self.isPublished = false
                self.available = [:]
            }
            self.catalogChecked = true
            self.catalogFetched = Date()
            self.onChanged?()
        }
    }

    /// Published counts and sizes per ring (from the catalogue, measured by the server).
    var catalogSummary: [(ring: Ring, count: Int, bytes: Int64, largest: Int64)] {
        Ring.allCases.compactMap { ring in
            let files = available.filter { $0.key.ring == ring }.map(\.value)
            guard !files.isEmpty else { return nil }
            return (ring, files.count, files.reduce(Int64(0)) { $0 + Int64($1.b) }, Int64(files.map(\.b).max() ?? 0))
        }
    }

    // MARK: Requests

    /// Called on each diorama update with the live camera. Ranks the visible pieces nearest first and
    /// keeps the resident set in step with the view.
    func update(map: MapboxMap, viewport: DioramaViewport, config: DioramaConfig, categories: Set<DioramaCategory>,
                time: DioramaTimeOfDay, wireframe: Bool, reduced: Bool, motion: Bool) {
        self.map = map; self.viewport = viewport; self.config = config
        self.categories = categories; self.time = time; self.wireframe = wireframe; self.reduced = reduced; self.motion = motion
        for resident in residents.values {
            resident.host.viewport = viewport
            resident.host.setVisible(categories, timeOfDay: time); resident.host.setWireframe(wireframe)
            resident.host.setReducedEffects(reduced); resident.host.setWaterMotion(motion)
        }
        guard UIApplication.shared.applicationState == .active else { return }
        let centre = map.cameraState.center, zoom = map.cameraState.zoom
        let tiles = region.tiles.filter { !DioramaOfflineStore.hasSavedPackage($0) }
        let ranked = tiles.map { ($0, DioramaSceneryStreamer.distance(from: centre, to: $0)) }
            .filter { $0.1 <= 2500 }
            .sorted { ($0.1, $0.0.key) < ($1.1, $1.0.key) }
        let nearby = !ranked.isEmpty
        if isNearby != nearby { isNearby = nearby }
        guard nearby else { setWanted([]); return }
        refreshCatalog()
        guard catalogChecked else { setStatus("Checking the harbour piece catalogue…"); return }
        guard isPublished else { setWanted([]); return }
        let networkAllowed = allowsNetwork()
        guard zoom >= config.minimumZoom - 0.5 else {
            setWanted([]); setStatus(isBundled ? "Zoom in closer to the harbour to see its 3D scenery" : "Zoom in closer to the harbour to stream its 3D scenery"); return
        }

        var list: [ID] = []
        for (tile, distance) in ranked {
            // A stylised scene is the whole tile at every distance: nothing else is wanted for it.
            let scene = ID(tile: tile, ring: .scene, column: 0, row: 0)
            if available[scene] != nil { list.append(scene); continue }
            list.append(ID(tile: tile, ring: .coarse, column: 0, row: 0))
            guard zoom >= config.minimumZoom + 1, distance <= 700 else { continue }
            let projection = DioramaProjection(origin: tile.centre)
            let local = projection.local(longitude: centre.longitude, latitude: centre.latitude)
            let rect = projection.rect(of: tile)
            let medium = (0..<2).flatMap { row in (0..<2).map { column in ID(tile: tile, ring: .medium, column: column, row: row) } }
            list.append(contentsOf: medium.sorted { $0.block(in: rect).centre.distance(to: local) < $1.block(in: rect).centre.distance(to: local) })
        }
        // Full-detail window under the camera: moves only when the ground point leaves its middle block.
        if zoom >= config.fullDetailMinimumZoom - 0.5, let focus = ranked.first, focus.1 <= 200 {
            let rect = DioramaProjection(origin: focus.0.centre).rect(of: focus.0)
            let block = rect.width / Double(Ring.fine.divisions)
            let half = Self.fineHalfBlocks * block
            if let window = fineWindow {
                let previous = DioramaProjection(origin: focus.0.centre).local(longitude: window.centre.longitude, latitude: window.centre.latitude)
                let now = DioramaProjection(origin: focus.0.centre).local(longitude: centre.longitude, latitude: centre.latitude)
                if abs(now.x - previous.x) > block * 0.5 || abs(now.y - previous.y) > block * 0.5 { fineWindow = (centre, half) }
            } else { fineWindow = (centre, half) }
            if let window = fineWindow {
                let reach = window.half + Double(DioramaRevealStyle.support) + 2
                var fine: [(ID, Double)] = []
                for (tile, distance) in ranked where distance <= reach + 10 && available[ID(tile: tile, ring: .scene, column: 0, row: 0)] == nil {
                    let projection = DioramaProjection(origin: tile.centre)
                    let p = projection.local(longitude: window.centre.longitude, latitude: window.centre.latitude)
                    let tileRect = projection.rect(of: tile)
                    let square = DioramaRect(minX: p.x - reach, minY: p.y - reach, maxX: p.x + reach, maxY: p.y + reach)
                    let n = Ring.fine.divisions
                    for row in 0..<n {
                        for column in 0..<n {
                            let id = ID(tile: tile, ring: .fine, column: column, row: row)
                            let blockRect = id.block(in: tileRect)
                            guard blockRect.intersects(square), available[id] != nil else { continue }
                            fine.append((id, blockRect.centre.distance(to: p)))
                        }
                    }
                }
                list.append(contentsOf: fine.sorted { ($0.1, $0.0.directory) < ($1.1, $1.0.directory) }.map(\.0))
            }
        } else {
            fineWindow = nil
        }
        let final = list.filter { available[$0] != nil }
        let missing = final.contains { residents[$0] == nil && !Self.isLocal(available[$0]) }
        if isBlockedByDownloadedOnly != (!networkAllowed && missing) { isBlockedByDownloadedOnly = !networkAllowed && missing }
        setWanted(final)
        if !networkAllowed, missing { setStatus("“Downloaded maps only” is on · harbour 3D can't stream") }
        ensureWorkers()
    }

    private func setStatus(_ value: String) {
        guard status != value else { return }
        status = value
    }

    private func setWanted(_ list: [ID]) {
        var seen: Set<ID> = []
        let unique = list.filter { seen.insert($0).inserted }
        wanted = unique; wantedSet = seen
        let now = Date()
        for id in unique { lastWanted[id] = now; if requestedAt[id] == nil { requestedAt[id] = now } }
        if firstRequestAt == nil, !unique.isEmpty { firstRequestAt = now }
        for id in Array(requestedAt.keys) where !seen.contains(id) && residents[id] == nil { requestedAt[id] = nil }
        piecesWanted = unique.count
        piecesReady = unique.filter { residents[$0] != nil }.count
        reconcile()
        refreshStatus()
    }

    private func refreshStatus() {
        guard isNearby, isPublished else { if !isNearby { setStatus("") }; return }
        if wanted.isEmpty { return }
        let pending = wanted.filter { residents[$0] == nil }
        if pending.isEmpty {
            setStatus("Harbour pieces ready · \(ByteCountFormatter.string(fromByteCount: bytesStreamed, countStyle: .file)) streamed this session")
            return
        }
        var line = "\(isBundled ? "Loading" : "Streaming") harbour · \(piecesReady) of \(piecesWanted) pieces"
        if let progress, progress.expected > 0 {
            line += " · \(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.expected, countStyle: .file))"
        } else if bytesStreamed > 0 {
            line += " · \(ByteCountFormatter.string(fromByteCount: bytesStreamed, countStyle: .file))"
        }
        if let failure = pending.compactMap({ failureReasons[$0] }).first { line += " · \(failure)" }
        setStatus(line)
    }
    @ObservationIgnored private var failureReasons: [ID: String] = [:]
    /// The first failure among wanted, not yet drawn pieces; nil while everything is loading normally.
    var failureSummary: String? { wanted.filter { residents[$0] == nil }.compactMap { failureReasons[$0] }.first }

    func retryLast() {
        failed.removeAll(); failureReasons.removeAll()
        ensureWorkers()
    }

    func pause() {
        workerGeneration &+= 1
        mounting.removeAll(); isStreaming = false; progress = nil
    }

    /// Releases every piece (style reload, teardown, memory pressure). The disk cache stays.
    func clear() {
        pause()
        for id in Array(residents.keys) { release(id) }
        wanted.removeAll(); wantedSet.removeAll(); lastWanted.removeAll(); requestedAt.removeAll()
        lingerTask?.cancel(); lingerTask = nil
        fineWindow = nil
        piecesWanted = 0; piecesReady = 0
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: Self.cacheRoot)
        cacheBytes = 0
    }

    /// After a bake on this phone (or when its pieces are deleted): drop everything resident, forget
    /// the catalogue and read the set again, so the fresh pieces draw on the next look at the harbour.
    func reloadLocalBake() {
        clear()
        warmTask?.cancel(); warmTask = nil
        warm.removeAll()
        failed.removeAll(); failureReasons.removeAll()
        available = [:]
        catalogChecked = false; isBundled = false; isLocalBake = false; isPublished = false
        catalogRevision = 0; catalogFiles = 0; catalogBytes = 0
        firstDrawLogged = false; firstRequestAt = nil
        warmUp()
        onChanged?()
    }

    // MARK: Reconciliation

    private func hostID(_ id: ID) -> String { "zuri-piece-\(id.directory)" }

    private func mediumComplete(_ tile: DioramaTileID) -> Bool {
        (0..<2).allSatisfy { row in (0..<2).allSatisfy { column in residents[ID(tile: tile, ring: .medium, column: column, row: row)] != nil } }
            && wantedSet.contains(ID(tile: tile, ring: .medium, column: 0, row: 0))
    }

    /// Attaches and detaches hosts so each tile is drawn by exactly one of its coarse/medium sets,
    /// full-detail pieces draw over a masked window, and pieces that left interest are released.
    private func reconcile() {
        guard let map else { return }
        let now = Date()
        // Release pieces that left interest (after a short linger against zoom/pan jitter), farthest-first
        // if the resident cap is exceeded.
        var retained = residents.values.filter { wantedSet.contains($0.id) || now.timeIntervalSince(lastWanted[$0.id] ?? .distantPast) < Self.linger }
        var bytes = retained.reduce(0) { $0 + $1.bytes }
        if bytes > Self.residentCap {
            for resident in retained.filter({ !wantedSet.contains($0.id) }).sorted(by: { (lastWanted[$0.id] ?? .distantPast) < (lastWanted[$1.id] ?? .distantPast) }) where bytes > Self.residentCap {
                retained.removeAll { $0 === resident }; bytes -= resident.bytes
            }
        }
        let keep = Set(retained.map(\.id))
        for id in Array(residents.keys) where !keep.contains(id) { release(id) }
        let group = try? DioramaLayerGroup.group(for: map)
        for resident in residents.values {
            let id = resident.id
            let shouldAttach: Bool
            switch id.ring {
            case .coarse: shouldAttach = !mediumComplete(id.tile)
            case .medium: shouldAttach = mediumComplete(id.tile)
            case .fine, .scene: shouldAttach = wantedSet.contains(id)
            }
            if shouldAttach != resident.attached {
                if shouldAttach { group?.attach(resident.host, id: hostID(id), order: id.ring.order, map: map) }
                else { group?.detach(hostID(id)) }
                resident.attached = shouldAttach
            }
            if id.ring == .coarse || id.ring == .medium {
                // Mask the full-detail window out of the coarse/medium geometry once every wanted
                // fine piece of this tile is resident; until then the tile stays whole.
                let fineWanted = wanted.filter { $0.ring == .fine && $0.tile == id.tile }
                if let window = fineWindow, !fineWanted.isEmpty, fineWanted.allSatisfy({ residents[$0] != nil }) {
                    let p = DioramaProjection(origin: id.tile.centre).local(longitude: window.centre.longitude, latitude: window.centre.latitude)
                    resident.host.setTileCoverage(edges: .zero, role: 2, paired: false, focusEdges: .zero)
                    resident.host.setReveal(SIMD4(Float(p.x), Float(p.y), Float(window.half), 1))
                } else {
                    resident.host.setTileCoverage(edges: .zero, role: 0, paired: false, focusEdges: .zero)
                    resident.host.setReveal(.zero)
                }
            }
        }
        lingerTask?.cancel(); lingerTask = nil
        if residents.keys.contains(where: { !wantedSet.contains($0) }) {
            lingerTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Self.linger + 0.1)) } catch { return }
                guard let self else { return }
                self.lingerTask = nil; self.reconcile(); self.onChanged?()
            }
        }
        map.triggerRepaint()
    }

    private func release(_ id: ID) {
        guard let resident = residents.removeValue(forKey: id) else { return }
        if resident.attached, let map { DioramaLayerGroup.existing(for: map)?.detach(hostID(id)) }
    }

    func trimForMemoryWarning() {
        warm.removeAll()
        for id in Array(residents.keys) where !wantedSet.contains(id) || id.ring == .fine { release(id) }
        reconcile()
    }

    // MARK: Workers

    private func nextJob() -> ID? {
        let now = Date()
        return wanted.first { residents[$0] == nil && !mounting.contains($0) && (failed[$0] ?? .distantPast) <= now && available[$0] != nil }
    }

    /// Up to two pieces in flight over the network (a far coarse/medium piece and a near fine one);
    /// four when they come from the app bundle, where decoding is the only cost.
    private func ensureWorkers() {
        guard nextJob() != nil else { return }
        guard allowsNetwork() || wanted.contains(where: { residents[$0] == nil && Self.isLocal(available[$0]) }) else { return }
        while activeWorkers < (isBundled ? 4 : 2) {
            activeWorkers += 1
            let generation = workerGeneration
            Task { [weak self] in
                guard let self else { return }
                defer { self.activeWorkers -= 1 }
                while self.workerGeneration == generation, UIApplication.shared.applicationState == .active, let job = self.nextJob() {
                    self.mounting.insert(job)
                    self.isStreaming = true
                    await self.stream(job)
                    self.mounting.remove(job)
                    self.piecesReady = self.wanted.filter { self.residents[$0] != nil }.count
                    self.refreshStatus()
                    self.onChanged?()
                }
                if self.mounting.isEmpty { self.isStreaming = false; self.progress = nil; self.refreshStatus() }
            }
        }
    }

    private func stream(_ id: ID) async {
        guard let file = available[id] else { return }
        let started = Date()
        do {
            let decoded: DioramaStreamPiece.Decoded
            let source: String
            var decodeSeconds: TimeInterval = 0
            if let ready = warm.removeValue(forKey: id) {
                decoded = ready; source = "warm"
            } else {
                let (data, origin) = try await fetch(id, file: file)
                guard let device = DioramaGPUPreparation.shared.device else { throw DioramaPrebakedScenery.Failure.unavailable }
                let decodeStarted = Date()
                let job = Task.detached(priority: .userInitiated) { try DioramaStreamPiece.decode(data, expected: id, device: device) }
                decoded = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                decodeSeconds = Date().timeIntervalSince(decodeStarted)
                source = origin
            }
            guard !Task.isCancelled, map != nil, wantedSet.contains(id) || lastWanted[id] != nil else { return }
            try await mount(decoded, id: id)
            failed[id] = nil; failureReasons[id] = nil
            let since = requestedAt[id].map { Date().timeIntervalSince($0) } ?? 0
            print("[Pieces] drawn \(id.directory) \(file.b) bytes \(source) decode=\(String(format: "%.3f", decodeSeconds))s"
                  + " request→draw=\(String(format: "%.2f", since))s triangles=\(decoded.header.indexCount / 3)")
            if !firstDrawLogged, let first = firstRequestAt {
                firstDrawLogged = true
                print("[Pieces] first piece drawn \(String(format: "%.2f", Date().timeIntervalSince(first))) s after the first request")
            }
        } catch is CancellationError {
            return
        } catch {
            failed[id] = Date().addingTimeInterval(30)
            let offline = (error as? URLError)?.networkUnavailableReason == .constrained
            failureReasons[id] = offline ? "Low Data Mode is on" : DioramaSceneryStreamer.describe(error)
            print("[Pieces] \(id.directory) failed after \(String(format: "%.2f", Date().timeIntervalSince(started))) s: \(error)")
        }
    }

    /// This phone's bake or the app bundle first, then the disk cache; otherwise one verified
    /// download that is then cached.
    private func fetch(_ id: ID, file: DioramaPrebakedScenery.File) async throws -> (Data, String) {
        if let local = Self.pieceURL(file), let data = try? Data(contentsOf: local, options: .mappedIfSafe), data.count == file.b {
            return (data, file.s == Self.localBakeDigest ? "from this phone's bake" : "from app bundle")
        }
        let url = Self.cacheURL(file)
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count == file.b {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return (data, "from cache")
        }
        guard allowsNetwork() else { throw DioramaPrebakedScenery.Failure.unavailable }
        let data = try await DioramaPrebakedScenery.fetchData(file, catalog: DioramaStreamPiece.catalogName, session: session) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progress = (received, expected); self.refreshStatus()
            }
        }
        progress = nil
        bytesStreamed += Int64(data.count)
        let root = Self.cacheRoot
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            let total = Self.trimCache()
            Task { @MainActor in DioramaPieceStreamer.shared.cacheBytes = total }
        }
        return (data, "downloaded")
    }

    private func mount(_ decoded: DioramaStreamPiece.Decoded, id: ID) async throws {
        let host = DioramaRenderLayer(resident: decoded.resident, groundRect: decoded.groundRect, visible: categories, timeOfDay: time,
            config: config, labels: decoded.resident.labels, displayScale: Float(UIScreen.main.scale), contextOnly: true, stylised: id.ring.isStylised)
        let upload = Task.detached(priority: .userInitiated) { await DioramaGPUUploadQueue.shared.prepare(host) }
        await withTaskCancellationHandler { await upload.value } onCancel: { upload.cancel() }
        guard !Task.isCancelled, map != nil, residents[id] == nil else { return }
        if host.diagnostic.contains("failed") || host.diagnostic.contains("missing") {
            throw DioramaTileArchive.ArchiveError.invalid
        }
        host.viewport = viewport
        host.setVisible(categories, timeOfDay: time); host.setWireframe(wireframe)
        host.setReducedEffects(reduced); host.setWaterMotion(motion)
        host.setTileCoverage(edges: .zero, role: 0, paired: false, focusEdges: .zero)
        host.setReveal(.zero)
        host.onInitialized = { [weak self] in Task { @MainActor [weak self] in self?.map?.triggerRepaint() } }
        host.onInitializationFailed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.failed[id] = Date().addingTimeInterval(30); self.failureReasons[id] = "GPU setup failed"
                self.release(id); self.reconcile()
            }
        }
        residents[id] = Resident(id: id, host: host, bytes: decoded.resident.gpuBytes + decoded.resident.cpuBytes, groundRect: decoded.groundRect)
        reconcile()
    }

    // MARK: Disk cache

    nonisolated private static func cacheURL(_ file: DioramaPrebakedScenery.File) -> URL {
        cacheRoot.appendingPathComponent(file.s + ".bin")
    }
    nonisolated private static func isCached(_ file: DioramaPrebakedScenery.File?) -> Bool {
        guard let file, let size = try? cacheURL(file).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size == file.b
    }
    /// Readable without the network: inside the app or in the disk cache.
    nonisolated private static func isLocal(_ file: DioramaPrebakedScenery.File?) -> Bool {
        pieceURL(file) != nil || isCached(file)
    }
    nonisolated private static func measureCache() -> Int64 {
        let entries = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return entries.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    /// Least-recently-used eviction within the cache cap; returns the bytes kept.
    nonisolated private static func trimCache() -> Int64 {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return 0 }
        var items: [(url: URL, date: Date, bytes: Int64)] = entries.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
        }
        var total = items.reduce(Int64(0)) { $0 + $1.bytes }
        items.sort { $0.date < $1.date }
        for item in items where total > cacheCap {
            try? fm.removeItem(at: item.url); total -= item.bytes
        }
        return total
    }
}
