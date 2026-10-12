import Foundation
import MapboxMaps
import Metal
import Observation
import UIKit

/// One-time bake on this phone: decodes each harbour tile exactly as viewing does (the saved
/// full-detail package with landmarks, skyline, roofs, walls, planting and lights applied), encodes
/// it as one GPU-ready whole-tile piece and uploads the pieces to the harbour piece catalogue. The
/// pieces then go into the app bundle; no phone builds anything while viewing. Every bake reports
/// the measured triangles per category and per kit part, which is what the low-poly remodelling
/// of the kit is judged against.
///
/// Foreground only; pauses on Low Power Mode or when the app leaves the foreground, like
/// preparation. Re-running re-bakes (seconds per ring) and re-uploads; the server's upload token
/// lasts long enough to resume an interrupted upload.
@Observable @MainActor
final class DioramaPieceBaker {
    static let shared = DioramaPieceBaker()

    nonisolated struct Report: Codable, Sendable {
        struct Piece: Codable, Sendable {
            let directory: String
            let bytes: Int
            let triangles: Int
            let instances: Int
            let vertices: Int
        }
        let bakedAt: Double
        let pieces: [Piece]
        let published: Bool
        let revision: Int
        /// Measured lines per tile key (triangles by category and by kit part).
        var reports: [String: [String]]? = nil
    }
    nonisolated enum BakeFailure: LocalizedError {
        case missing(String), paused(String), device
        var errorDescription: String? {
            switch self {
            case .missing(let what): what
            case .paused(let why): why
            case .device: "Metal is unavailable on this device."
            }
        }
    }

    let region: DioramaRegion = .harbour
    private(set) var isRunning: Bool = false
    private(set) var stage: String = ""
    private(set) var message: String = ""
    private(set) var done: Int = 0
    private(set) var total: Int = 0
    private(set) var report: Report?
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarbourPieces", isDirectory: true)
    }
    nonisolated private static var reportURL: URL { root.appendingPathComponent("bake.json") }

    private init() {
        report = Self.readReport()
        tileReports = report?.reports ?? [:]
    }

    nonisolated private static func readReport() -> Report? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: data)
    }

    /// Per-ring counts and measured sizes of the last bake, for Settings.
    var ringSummary: [(ring: DioramaStreamPiece.Ring, count: Int, bytes: Int, largest: Int)] {
        guard let report else { return [] }
        return DioramaStreamPiece.Ring.allCases.compactMap { ring in
            let pieces = report.pieces.filter { DioramaStreamPiece.ID(directory: $0.directory)?.ring == ring }
            guard !pieces.isEmpty else { return nil }
            return (ring, pieces.count, pieces.reduce(0) { $0 + $1.bytes }, pieces.map(\.bytes).max() ?? 0)
        }
    }

    var blocker: String? {
        if DioramaDownloadService.isProcessing { return "Wait for the current preparation/optimizing to finish." }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Turn off Low Power Mode in iPhone Settings → Battery to bake." }
        return nil
    }

    /// Per-tile measured output of the last bake (triangles by category, landmarks, placements).
    private(set) var tileReports: [String: [String]] = [:]

    /// True when the last bake's pieces are still on disk, so they can be uploaded without rebaking.
    var hasUploadablePieces: Bool {
        guard let report, !report.pieces.isEmpty else { return false }
        return missingPieceCount == 0
    }

    /// Pieces listed in the last report whose files are no longer on disk.
    var missingPieceCount: Int {
        guard let report else { return 0 }
        return report.pieces.filter {
            !FileManager.default.fileExists(atPath: Self.root.appendingPathComponent($0.directory).appendingPathComponent(DioramaStreamPiece.fileName).path)
        }.count
    }

    func start() { launch(uploadOnly: false) }

    /// Uploads the pieces already baked on this phone; nothing is rebaked.
    func upload() { launch(uploadOnly: true) }

    private func launch(uploadOnly: Bool) {
        guard !isRunning, task == nil else { return }
        if !uploadOnly, let blocker { message = blocker; return }
        if uploadOnly, !hasUploadablePieces { message = "No baked pieces on this phone yet. Bake first."; return }
        isRunning = true; message = ""; done = 0; total = 0
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.task = nil; self.stage = "" }
            do {
                if uploadOnly, let report = self.report {
                    try await self.publish(report)
                } else {
                    try await self.run()
                }
            } catch is CancellationError {
                self.message = uploadOnly ? "Upload stopped. Tap Upload to resume; nothing needs rebaking." : "Bake stopped."
            } catch {
                self.message = (error as? LocalizedError)?.errorDescription ?? "Bake failed: \(type(of: error))"
                print("[Pieces] bake failed: \(error)")
            }
        }
    }

    func cancel() { task?.cancel() }

    private func checkPolicy() throws {
        try Task.checkCancellation()
        if UIApplication.shared.applicationState != .active { throw BakeFailure.paused("Keep the app open while the harbour bakes, then tap Bake again.") }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { throw BakeFailure.paused("Low Power Mode paused the bake. Turn it off, then tap Bake again.") }
    }

    private func run() async throws {
        guard let device = DioramaGPUPreparation.shared.device else { throw BakeFailure.device }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        var url = Self.root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        // Previous pieces are replaced wholesale: a set is one bake. The old report goes with them so
        // Settings never claims a baked set whose files are gone.
        for entry in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] where entry.lastPathComponent.hasPrefix("piece-") {
            try? fm.removeItem(at: entry)
        }
        try? fm.removeItem(at: Self.reportURL)
        report = nil
        var pieces: [Report.Piece] = []
        var reports: [String: [String]] = [:]
        let started = Date()
        let store = DioramaOfflineStore.store(for: region)
        for tile in region.tiles {
            try checkPolicy()
            stage = "Baking landmark recipes · \(tile.key)"
            _ = await DioramaBakedLandmarks.shared.meshes(for: tile)
            try checkPolicy()
            stage = "Measuring detail levels · \(tile.key)"
            _ = try await store.optimize(tile, context: true)
            try checkPolicy()
            stage = "Decoding full detail with everything applied · \(tile.key)"
            guard let resident = await store.readResident(tile, context: false) else {
                throw BakeFailure.missing("The saved full-detail package of \(tile.key) could not be read: \(await store.readFailure(tile)). Download the harbour in Settings first, then bake again.")
            }
            let lines = Self.measure(resident)
            reports[tile.key] = lines
            for line in lines { print("[Pieces] \(tile.key) \(line)") }
            try checkPolicy()
            stage = "Encoding the whole-tile piece · \(tile.key)"
            let root = Self.root
            let job = Task.detached(priority: .userInitiated) { () throws -> [Report.Piece] in
                var out: [Report.Piece] = []
                try DioramaStreamPiece.bake(resident, ring: .scene, device: device) { id, data, measured in
                    let directory = root.appendingPathComponent(id.directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent(DioramaStreamPiece.fileName), options: .atomic)
                    out.append(.init(directory: id.directory, bytes: measured.bytes, triangles: measured.triangles,
                                     instances: measured.instances, vertices: measured.vertices))
                }
                return out
            }
            let made = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            pieces.append(contentsOf: made)
            done = pieces.count
            let bytes = made.reduce(0) { $0 + $1.bytes }
            print("[Pieces] \(tile.key) whole-tile piece: \(bytes) bytes, \(made.reduce(0) { $0 + $1.triangles }) unique triangles, \(made.reduce(0) { $0 + $1.instances }) placements")
        }
        tileReports = reports
        let bakeSeconds = Date().timeIntervalSince(started)
        let current = Report(bakedAt: Date().timeIntervalSince1970, pieces: pieces, published: false, revision: 0, reports: reports)
        try JSONEncoder().encode(current).write(to: Self.reportURL, options: .atomic)
        report = current
        let totalBytes = pieces.reduce(0) { $0 + $1.bytes }
        let baked = "Baked \(pieces.count) pieces (\(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))) in \(Int(bakeSeconds)) s."
        message = baked + " Uploading…"
        // The fresh pieces draw on this phone right away, upload or not.
        DioramaPieceStreamer.shared.reloadLocalBake()
        do {
            try await publish(current)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[Pieces] upload failed: \(error)")
            message = baked + " Upload failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)"). The baked scene draws on this phone now (zoom into the harbour); tap Upload to retry."
        }
    }

    /// Measured geometry of one decoded tile: unique triangles (each prototype once), triangles the
    /// GPU draws with every placement, placements per category, then the generator's own part
    /// report (prototype kinds and counts). Only measured values; nothing estimated.
    nonisolated static func measure(_ r: DioramaResidentTile) -> [String] {
        var unique: [DioramaCategory: Int] = [:], drawn: [DioramaCategory: Int] = [:], placements: [DioramaCategory: Int] = [:]
        for range in r.ranges {
            unique[range.category, default: 0] += range.count / 3
            drawn[range.category, default: 0] += range.count / 3
        }
        var prototypes = Set<Int>()
        for group in r.groups {
            if prototypes.insert(group.fullStart).inserted { unique[group.category, default: 0] += group.fullCount / 3 }
            drawn[group.category, default: 0] += group.fullCount / 3 * group.instances.count
            placements[group.category, default: 0] += group.instances.count
        }
        let totalUnique = unique.values.reduce(0, +), totalDrawn = drawn.values.reduce(0, +), totalPlacements = placements.values.reduce(0, +)
        var out = ["\(totalUnique) unique triangles · \(totalDrawn) drawn with placements · \(totalPlacements) placements · \(r.vertexCount) vertices"]
        for category in DioramaCategory.allCases {
            let u = unique[category] ?? 0, d = drawn[category] ?? 0, p = placements[category] ?? 0
            guard u > 0 || d > 0 else { continue }
            out.append("\(category.rawValue): \(u) unique · \(d) drawn" + (p > 0 ? " · \(p) placements" : ""))
        }
        out.append(contentsOf: r.summary.optimizationReport)
        return out
    }

    /// Uploads a baked set to the `harbour-z2` catalogue and marks the report published.
    private func publish(_ baked: Report) async throws {
        var current = baked
        let pieces = baked.pieces
        let totalBytes = pieces.reduce(0) { $0 + $1.bytes }
        try checkPolicy()
        stage = "Uploading \(pieces.count) pieces"
        total = pieces.count
        let files = pieces.map {
            DioramaPrebakedScenery.Upload(directory: $0.directory, file: DioramaStreamPiece.fileName,
                                          url: Self.root.appendingPathComponent($0.directory).appendingPathComponent(DioramaStreamPiece.fileName))
        }
        do {
            let count = try await DioramaPrebakedScenery.publish(catalog: DioramaStreamPiece.catalogName, keyless: true, files: files) { [weak self] sent, all in
                self?.stage = "Uploading piece \(sent) of \(all)"; self?.done = sent; self?.total = all
            }
            let revision = (try? await DioramaPrebakedScenery.catalog(named: DioramaStreamPiece.catalogName))?.revision ?? 0
            current = Report(bakedAt: current.bakedAt, pieces: pieces, published: true, revision: revision)
            try JSONEncoder().encode(current).write(to: Self.reportURL, options: .atomic)
            report = current
            message = "Published \(count) whole-tile pieces (\(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))). They go into the app with the next build."
        } catch DioramaPrebakedScenery.Failure.rejected(let reason) where reason.contains("already_published") {
            message = "A whole-tile harbour set is already published. Replacing it needs the scenery publish key: enter it under Publisher tools, then tap Upload again. The baked pieces stay on this phone and draw here."
        } catch DioramaPrebakedScenery.Failure.rejected(let reason) where reason.contains("seed_in_progress") {
            message = "Another phone is uploading to the harbour piece set right now. Wait 3 minutes, then tap Upload again; nothing needs rebaking."
        } catch DioramaPrebakedScenery.Failure.rejected(let reason) where reason.contains("seed_expired") || reason.contains("stale_or_invalid") {
            message = "The upload session expired. Tap Upload again to start a fresh one; nothing needs rebaking."
        }
    }
}
