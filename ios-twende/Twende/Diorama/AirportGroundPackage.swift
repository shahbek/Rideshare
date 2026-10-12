import CoreLocation
import Foundation
import Metal

/// Additive checked procedural ground. Existing campus and raster-page bytes remain untouched.
nonisolated enum AirportGroundPackage {
    static let key = "airport-procedural-ground-v1"
    struct Metadata: Codable, Sendable {
        let campusDigest: String
        let manifestDigest: String
        let boundary: [[Double]]
        let clips: [[[Double]]]
        let bytes: Int
        var site: DarLandmarkSite {
            AirportMapData(boundary: .init(id: 135694174, tags: [:], coordinates: boundary), features: [], points: []).site
        }
    }
    struct Saved: Sendable {
        let metadata: Metadata
        let resident: DioramaResidentTile
    }
    static var directory: URL { AirportPackageStore.root.appendingPathComponent(key, isDirectory: true) }

    private static var installedDirectory: URL {
        let embedded = AirportPackageStore.directory.appendingPathComponent("procedural-ground", isDirectory: true)
        return FileManager.default.fileExists(atPath: embedded.appendingPathComponent("ground.json").path) ? embedded : directory
    }

    static func metadata(campusDigest: String, at path: URL? = nil) throws -> Metadata {
        let path = path ?? installedDirectory
        let bytes = try Data(contentsOf: path.appendingPathComponent("ground.json"))
        guard bytes.count <= 2 * 1_048_576 else { throw DioramaTileArchive.ArchiveError.invalid }
        let m = try JSONDecoder().decode(Metadata.self, from: bytes)
        func valid(_ ring: [[Double]]) -> Bool {
            ring.count >= 4 && ring.count <= 2048 && ring.first == ring.last && ring.allSatisfy {
                $0.count == 2 && $0.allSatisfy(\.isFinite) && (39.1...39.3).contains($0[0]) && (-7.0 ... -6.7).contains($0[1])
            }
        }
        guard m.campusDigest == campusDigest, m.bytes >= 0, valid(m.boundary), m.clips.count <= 1000, m.clips.allSatisfy(valid),
              DioramaTileArchive.digestHex(try Data(contentsOf: path.appendingPathComponent("manifest.json"))) == m.manifestDigest else {
            throw DioramaTileArchive.ArchiveError.invalid
        }
        return m
    }

    static func read(campus: AirportPackageStore.Metadata, device: MTLDevice) throws -> Saved {
        let path = installedDirectory
        let info = try metadata(campusDigest: campus.manifestDigest, at: path)
        let manifest = try DioramaTileArchive.validatedManifest(at: path, key: key)
        guard manifest.imageSize == 64, manifest.ranges.isEmpty, manifest.groups.isEmpty else { throw DioramaTileArchive.ArchiveError.invalid }
        let resident = try DioramaTileArchive.readResident(from: path, key: key, manifest: manifest, device: device, patch: nil, origin: campus.coordinate, materialsPrepared: true)
        let count = resident.paintBuffer.length / MemoryLayout<DioramaPaintTriangle>.stride
        let triangles = resident.paintBuffer.contents().assumingMemoryBound(to: DioramaPaintTriangle.self)
        guard count > 0, count < 500_000 else { throw DioramaTileArchive.ArchiveError.invalid }
        var hasFinishes = false
        for i in 0..<count {
            let t = triangles[i]
            guard [t.edge0, t.edge1, t.edge2, t.color].allSatisfy({ v in (0..<4).allSatisfy { v[$0].isFinite } }),
                  t.color.w >= -8, t.color.w <= 1, t.edge0.w >= 0, t.edge0.w <= 100_000 else { throw DioramaTileArchive.ArchiveError.invalid }
            hasFinishes = hasFinishes || t.color.w < 0
        }
        guard hasFinishes else { throw DioramaTileArchive.ArchiveError.invalid }
        return Saved(metadata: info, resident: resident)
    }

    static func save(_ data: AirportMapData, campus: AirportPackageStore.Metadata, into destination: URL? = nil) throws -> Int {
        try Task.checkCancellation()
        guard let image = AirportGroundGeometry.image(data, origin: campus.coordinate, rect: campus.rect, size: 64) else { throw DioramaTileArchive.ArchiveError.invalid }
        let stage = destination ?? AirportPackageStore.root.appendingPathComponent(key + ".preparing", isDirectory: true)
        let a = DioramaTileArtifacts(tile: .init(latitude: campus.coordinate.latitude, longitude: campus.coordinate.longitude, zoom: 16),
            vertices: [], indices: [], ranges: [], groups: [], allInstances: [], parts: [], lights: [],
            lightGrid: DioramaLightGrid.build([], rect: campus.rect, cells: 1, perCell: 1), waterHeight: 0,
            shorelineReport: [], generationSeconds: 0, groundImage: image)
        let size = try DioramaTileArchive.write(a, key: key, to: stage)
        let info = Metadata(campusDigest: campus.manifestDigest,
            manifestDigest: DioramaTileArchive.digestHex(try Data(contentsOf: stage.appendingPathComponent("manifest.json"))),
            boundary: data.boundary.coordinates, clips: data.features.filter { campus.builtIDs.contains($0.id) && $0.isClosed }.map(\.coordinates), bytes: size)
        try JSONEncoder().encode(info).write(to: stage.appendingPathComponent("ground.json"), options: .atomic)
        try Task.checkCancellation()
        _ = try metadata(campusDigest: campus.manifestDigest, at: stage)
        if destination == nil {
            let installed = installedDirectory
            let target = FileManager.default.fileExists(atPath: installed.path) ? installed : directory
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: stage,
                    backupItemName: key + ".previous-" + UUID().uuidString, options: [.withoutDeletingBackupItem])
            } else {
                try FileManager.default.moveItem(at: stage, to: target)
            }
        }
        return size
    }
}
