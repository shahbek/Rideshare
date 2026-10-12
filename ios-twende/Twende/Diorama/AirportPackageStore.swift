import CoreLocation
import Foundation
import Metal

/// Separate airport packages. No Masaki versions, files, readiness or download settings are changed.
nonisolated enum AirportPackageStore {
    static let revision = "airport-shell-hd-v1"
    static let pageMetres = 600.0
    static let changed = Notification.Name("TwendeAirportPackagesChanged")
    struct Metadata: Codable, Sendable {
        let revision: String
        let origin: [Double]
        let bounds: [Double]
        let builtIDs: [Int]
        let pages: [String]
        let bytes: Int
        let manifestDigest: String
        var coordinate: CLLocationCoordinate2D { .init(latitude: origin[1], longitude: origin[0]) }
        var rect: DioramaRect { .init(minX: bounds[0], minY: bounds[1], maxX: bounds[2], maxY: bounds[3]) }
    }
    struct Saved: Sendable {
        let metadata: Metadata
        let resident: DioramaResidentTile
        let ground: AirportGroundPackage.Saved?
    }
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TwendeAirportHD", isDirectory: true)
    }
    static var directory: URL { root.appendingPathComponent(revision, isDirectory: true) }
    static func metadata() throws -> Metadata {
        let data = try Data(contentsOf: directory.appendingPathComponent("airport.json"))
        guard data.count < 256 * 1024 else { throw DioramaTileArchive.ArchiveError.invalid }
        let m = try JSONDecoder().decode(Metadata.self, from: data)
        guard m.revision == revision, m.origin.count == 2, m.origin.allSatisfy(\.isFinite),
              abs(m.origin[0] - 39.20505933538462) < 0.000001, abs(m.origin[1] + 6.8717225202564105) < 0.000001,
              m.bounds.count == 4, m.bounds.allSatisfy(\.isFinite), m.bounds[2] > m.bounds[0], m.bounds[3] > m.bounds[1],
              m.pages.count <= 100, Set(m.pages).count == m.pages.count, m.builtIDs.count <= 1000, m.bytes >= 0 else { throw DioramaTileArchive.ArchiveError.invalid }
        let manifest = try Data(contentsOf: directory.appendingPathComponent("campus/manifest.json"))
        guard DioramaTileArchive.digestHex(manifest) == m.manifestDigest else { throw DioramaTileArchive.ArchiveError.invalid }
        return m
    }
    static func read(device: MTLDevice) throws -> Saved {
        let m = try metadata(), path = directory.appendingPathComponent("campus")
        let manifest = try DioramaTileArchive.validatedManifest(at: path, key: revision)
        let saved = try DioramaTileArchive.readResident(from: path, key: revision, manifest: manifest, device: device, patch: nil, origin: m.coordinate, materialsPrepared: true)
        // The campus never had detail levels: give it the same measured pixel-error LOD as saved tiles.
        try Task.checkCancellation()
        let tile = DioramaLODBuilder.completing(saved, groups: true)
        return Saved(metadata: m, resident: tile, ground: try? AirportGroundPackage.read(campus: m, device: device))
    }
    static func pageKey(at p: DV2) -> String { "page-\(Int(floor(p.x / pageMetres)))-\(Int(floor(p.y / pageMetres)))" }
    static func pageRect(at p: DV2) -> DioramaRect {
        let x = floor(p.x / pageMetres) * pageMetres, y = floor(p.y / pageMetres) * pageMetres
        return .init(minX: x, minY: y, maxX: x + pageMetres, maxY: y + pageMetres)
    }
    static func readPage(at p: DV2, device: MTLDevice) throws -> DioramaResidentTile {
        let key = pageKey(at: p), m = try metadata()
        guard m.pages.contains(key) else { throw DioramaTileArchive.ArchiveError.invalid }
        let path = directory.appendingPathComponent(key)
        let manifest = try DioramaTileArchive.validatedManifest(at: path, key: revision + "/" + key)
        return try DioramaTileArchive.readResident(from: path, key: revision + "/" + key, manifest: manifest, device: device, patch: nil, origin: m.coordinate, materialsPrepared: true)
    }
    /// Returns a private staging directory; cancellation/failure never replaces the installed package.
    static func stagingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity > 512 * 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
        let stage = root.appendingPathComponent(revision + ".preparing", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        return stage
    }
    static func saveCampus(_ a: DioramaTileArtifacts, to stage: URL) throws -> Int {
        let path = stage.appendingPathComponent("campus")
        return try DioramaTileArchive.write(a, key: revision, to: path)
    }
    static func savePages(_ data: AirportMapData, origin: CLLocationCoordinate2D, stage: URL, bounds: DioramaRect, builtIDs: [Int], campusBytes: Int,
                          prepareRasterPages: Bool = false, publish: Bool = true, progress: @Sendable (Int, Int) -> Void) throws -> Metadata {
        var pages: [(String, DioramaRect)] = []
        // Analytic airport finishes no longer require 49 large raster pages for sharp roads.
        // Keep the legacy page preparation path and every already installed page usable.
        if prepareRasterPages {
            for x in stride(from: floor(bounds.minX / pageMetres) * pageMetres, to: bounds.maxX, by: pageMetres) {
                for y in stride(from: floor(bounds.minY / pageMetres) * pageMetres, to: bounds.maxY, by: pageMetres) {
                    let p = DV2(x + 1, y + 1)
                    pages.append((pageKey(at: p), pageRect(at: p)))
                }
            }
        }
        var bytes = campusBytes
        for (i, page) in pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let path = stage.appendingPathComponent(page.0), key = revision + "/" + page.0
                if let _ = try? DioramaTileArchive.read(from: path, key: key), let manifest = try? DioramaTileArchive.validatedManifest(at: path, key: key) {
                    bytes += manifest.sections.flatMap(\.blocks).reduce(0) { $0 + $1.stored } + (try Data(contentsOf: path.appendingPathComponent("manifest.json"))).count
                    return
                }
                guard let image = AirportGroundGeometry.image(data, origin: origin, rect: page.1, size: 4096, analyticFinishes: false) else { throw DioramaTileArchive.ArchiveError.invalid }
                let a = DioramaTileArtifacts(tile: DioramaTileID(latitude: origin.latitude, longitude: origin.longitude, zoom: 16), vertices: [], indices: [], ranges: [], groups: [], allInstances: [], parts: [], lights: [],
                    lightGrid: DioramaLightGrid.build([], rect: page.1, cells: 1, perCell: 1), waterHeight: 0, shorelineReport: [], generationSeconds: 0, groundImage: image)
                bytes += try DioramaTileArchive.write(a, key: revision + "/" + page.0, to: stage.appendingPathComponent(page.0))
            }
            progress(i + 1, pages.count)
        }
        let manifest = try Data(contentsOf: stage.appendingPathComponent("campus/manifest.json"))
        let m = Metadata(revision: revision, origin: [origin.longitude, origin.latitude], bounds: [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY], builtIDs: builtIDs,
            pages: pages.map(\.0), bytes: bytes, manifestDigest: DioramaTileArchive.digestHex(manifest))
        try JSONEncoder().encode(m).write(to: stage.appendingPathComponent("airport.json"), options: .atomic)
        try Task.checkCancellation()
        if publish { try publishCampus(from: stage) }
        return m
    }

    /// Campus and its embedded procedural ground are staged together before this single publication.
    static func publishCampus(from stage: URL) throws {
        AirportSpatialPackage.publicationLock.lock(); defer { AirportSpatialPackage.publicationLock.unlock() }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: directory.path) {
            _ = try FileManager.default.replaceItemAt(directory, withItemAt: stage,
                backupItemName: revision + ".previous-" + UUID().uuidString, options: [.withoutDeletingBackupItem])
        } else {
            try FileManager.default.moveItem(at: stage, to: directory)
        }
    }
}
