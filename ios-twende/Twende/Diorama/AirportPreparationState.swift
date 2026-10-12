import Foundation
import Observation
import SceneKit
import UIKit

/// Explicit foreground-only preparation. Geometry and source downloads are never reset implicitly.
@MainActor @Observable
final class AirportPreparationState {
    static let shared = AirportPreparationState()
    private(set) var isPreparing: Bool = false
    private(set) var completedPages: Int = 0
    private(set) var totalPages: Int = 0
    private(set) var storedBytes: Int = 0
    private(set) var isReady: Bool = false
    private(set) var hasSharpGround: Bool = false
    private(set) var hasSpatialTiles: Bool = false
    private(set) var message: String = "Save airport 3D once for local loading, sharp procedural roads and detailed grass."
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

    private init() {
        refresh()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }
    func refresh() {
        guard !isPreparing else { return }
        if let m = try? AirportPackageStore.metadata() {
            let ground = try? AirportGroundPackage.metadata(campusDigest: m.manifestDigest)
            let spatial = try? AirportSpatialPackage.catalog()
            isReady = true; hasSharpGround = ground != nil || spatial != nil; hasSpatialTiles = spatial != nil
            storedBytes = m.bytes + (ground?.bytes ?? 0) + (spatial?.bytes ?? 0)
            completedPages = m.pages.count; totalPages = m.pages.count
            message = hasSpatialTiles ? "Airport saved in 240 m tiles; only the viewed detail is loaded." : hasSharpGround ? "Airport ground saved. Prepare smaller tiles to update roads, parking and control tower."
                : "Airport 3D saved. Add sharp ground without rebuilding terminals or changing saved maps."
        } else {
            isReady = false; hasSharpGround = false; hasSpatialTiles = false; storedBytes = 0
        }
    }
    func pause() {
        guard isPreparing else { return }
        task?.cancel()
        message = "Pausing after the current work block. Keep the app open to prepare HD."
    }
    func prepare(repair: Bool = false) {
        guard !isPreparing, !isReady || !hasSharpGround || !hasSpatialTiles || repair else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            message = "Turn off Low Power Mode before preparing airport HD."
            return
        }
        completedPages = 0; totalPages = 0
        isPreparing = true; message = isReady ? "Saving sharp ground using the existing airport…" : "Preparing the existing airport for local loading…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparing = false; self.task = nil }
            do {
                let source = await Task.detached(priority: .utility) { AirportMapData.load() }.value
                try Task.checkCancellation()
                guard let data = source else { throw DioramaTileArchive.ArchiveError.invalid }
                if !repair, let existing = try? AirportPackageStore.metadata() {
                    self.message = "Reusing saved terminals and props; updating ground and tower…"
                    let read = Task.detached(priority: .utility) {
                        try DioramaTileArchive.read(from: AirportPackageStore.directory.appendingPathComponent("campus"), key: AirportPackageStore.revision)
                    }
                    let original = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                    try Task.checkCancellation()
                    let upgraded = try AirportSpatialUpgrade.applying(to: original, data: data, includeTower: !existing.builtIDs.contains(AirportControlTowerGeometry.sourceID))
                    let worker = Task.detached(priority: .utility) {
                        let spatial = try AirportSpatialPackage.save(upgraded, data: data, campus: existing) { done, total in
                            Task { @MainActor [weak self] in
                                self?.completedPages = done; self?.totalPages = total
                                self?.message = "Saving smaller airport tiles \(done)/\(total)…"
                            }
                        }
                        return spatial.bytes
                    }
                    let bytes = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    self.storedBytes = existing.bytes + bytes; self.isReady = true; self.hasSharpGround = true; self.hasSpatialTiles = true
                    self.message = "Airport updated in 240 m tiles. Original terminals and downloads retained."
                    NotificationCenter.default.post(name: AirportPackageStore.changed, object: nil)
                    return
                }
                let stage = try AirportPackageStore.stagingDirectory()
                let origin = data.site.anchor.coordinate
                let rect = data.groundRect(origin: origin)
                // SceneKit is a temporary construction adapter. Only packed packages remain installed.
                let package = try autoreleasepool { () -> (DioramaTileArtifacts, [Int]) in
                    let scene = AirportGeometry.make(data, site: data.site)
                    guard HarbourArchitectureParts.validate(scene, site: data.site, airportData: data) != nil,
                          let image = AirportGroundGeometry.image(data, origin: data.site.anchor.coordinate) else { throw DioramaTileArchive.ArchiveError.invalid }
                    var ids: Set<Int> = [597787841, 23359828, 1188629104, 1237792404]
                    scene.rootNode.enumerateChildNodes { node, _ in
                        if let name = node.name, name.hasPrefix("mappedAirportBuilding-"), let id = Int(name.dropFirst("mappedAirportBuilding-".count)) { ids.insert(id) }
                    }
                    return (DioramaLandmarkMesh.airport(scene, origin: data.site.anchor.coordinate, image: image, rect: rect), ids.sorted())
                }
                try Task.checkCancellation()
                self.message = "Saving checked geometry and sharp procedural ground…"
                let worker = Task.detached(priority: .utility) {
                    let bytes = try AirportPackageStore.saveCampus(package.0, to: stage)
                    let campus = try AirportPackageStore.savePages(data, origin: origin, stage: stage, bounds: rect, builtIDs: package.1, campusBytes: bytes, publish: false) { done, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.isPreparing else { return }
                            self.completedPages = done; self.totalPages = total
                            self.message = "Preparing HD ground tiles \(done)/\(total)…"
                        }
                    }
                    let groundBytes = try AirportGroundPackage.save(data, campus: campus, into: stage.appendingPathComponent("procedural-ground", isDirectory: true))
                    let spatial = try AirportSpatialPackage.save(package.0, data: data, campus: campus, into: stage.appendingPathComponent("spatial", isDirectory: true)) { done, total in
                        Task { @MainActor [weak self] in
                            self?.completedPages = done; self?.totalPages = total
                            self?.message = "Saving smaller airport tiles \(done)/\(total)…"
                        }
                    }
                    try AirportPackageStore.publishCampus(from: stage)
                    return (campus, groundBytes + spatial.bytes)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                self.storedBytes = result.0.bytes + result.1; self.isReady = true; self.hasSharpGround = true; self.hasSpatialTiles = true
                self.completedPages = result.0.pages.count; self.totalPages = result.0.pages.count
                self.message = "Airport saved in 240 m tiles; only the viewed detail is loaded."
                NotificationCenter.default.post(name: AirportPackageStore.changed, object: nil)
            } catch is CancellationError {
                self.message = "Airport preparation paused. Resume to save the smaller tiles; the installed airport is unchanged."
            } catch {
                self.message = (error as? CocoaError)?.code == .fileWriteOutOfSpace
                    ? "Not enough free storage. Free some space and retry; existing maps are unchanged."
                    : "Airport HD could not be prepared. Retry; the bundled preview and existing maps are unchanged."
                print("[AirportHD] Preparation did not publish a package; existing scenery retained")
            }
        }
    }
}
