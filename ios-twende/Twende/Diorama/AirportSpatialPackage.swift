import CoreLocation
import Foundation
import Metal
import simd

/// Airport-only spatial archives. One shared renderer combines the current view, not one effect rig per chunk.
nonisolated enum AirportSpatialPackage {
    static let revision = "airport-spatial-v2"
    static let metres = 240.0
    static let publicationLock = NSRecursiveLock()
    static var directory: URL { AirportPackageStore.root.appendingPathComponent(revision, isDirectory: true) }
    static var installedDirectory: URL {
        let embedded = AirportPackageStore.directory.appendingPathComponent("spatial", isDirectory: true)
        return FileManager.default.fileExists(atPath: embedded.appendingPathComponent("spatial.json").path) ? embedded : directory
    }
    struct Ownership: Codable, Sendable {
        let ring: [[Double]]
        let keys: [String]
    }

    struct Chunk: Codable, Sendable {
        let key: String
        let bounds: [Double]
        let digest: String
        let residentBytes: Int
        var rect: DioramaRect { .init(minX: bounds[0], minY: bounds[1], maxX: bounds[2], maxY: bounds[3]) }
    }
    struct Catalog: Codable, Sendable {
        let revision: String
        let campusDigest: String
        let origin: [Double]
        let bounds: [Double]
        let boundary: [[Double]]
        let clips: [[[Double]]]
        let ownership: [Ownership]
        let chunks: [Chunk]
        let bytes: Int
        var coordinate: CLLocationCoordinate2D { .init(latitude: origin[1], longitude: origin[0]) }
        var rect: DioramaRect { .init(minX: bounds[0], minY: bounds[1], maxX: bounds[2], maxY: bounds[3]) }
        var site: DarLandmarkSite { AirportMapData(boundary: .init(id: 135694174, tags: [:], coordinates: boundary), features: [], points: []).site }
    }
    struct Selection: Sendable {
        let catalog: Catalog
        let keys: Set<String>
        let resident: DioramaResidentTile
        var rect: DioramaRect {
            DioramaRect.bounding(catalog.chunks.filter { keys.contains($0.key) }.flatMap {
                [DV2($0.rect.minX, $0.rect.minY), DV2($0.rect.maxX, $0.rect.maxY)]
            })
        }
    }

    static func key(_ point: DV2) -> String { "chunk-\(Int(floor(point.x / metres)))-\(Int(floor(point.y / metres)))" }
    static func rect(_ point: DV2) -> DioramaRect {
        let x = floor(point.x / metres) * metres, y = floor(point.y / metres) * metres
        return .init(minX: x, minY: y, maxX: x + metres, maxY: y + metres)
    }

    static func catalog() throws -> Catalog {
        publicationLock.lock(); defer { publicationLock.unlock() }
        let bytes = try Data(contentsOf: installedDirectory.appendingPathComponent("spatial.json"))
        guard bytes.count <= 2 * 1_048_576 else { throw DioramaTileArchive.ArchiveError.invalid }
        let c = try JSONDecoder().decode(Catalog.self, from: bytes)
        let campus = try AirportPackageStore.metadata()
        func validRing(_ ring: [[Double]]) -> Bool {
            ring.count >= 4 && ring.count <= 2048 && ring.first == ring.last && ring.allSatisfy {
                $0.count == 2 && $0.allSatisfy(\.isFinite) && (39.1...39.3).contains($0[0]) && (-7.0 ... -6.7).contains($0[1])
            }
        }
        guard c.revision == revision, c.campusDigest == campus.manifestDigest, c.origin == campus.origin,
              c.bounds.count == 4, c.bounds.allSatisfy({ $0.isFinite && abs($0) < 10_000 }), c.rect.width > 0, c.rect.height > 0,
              validRing(c.boundary), c.clips.count <= 1000, c.clips.allSatisfy(validRing), c.bytes >= 0,
              !c.chunks.isEmpty, c.chunks.count <= 1024, Set(c.chunks.map(\.key)).count == c.chunks.count,
              c.chunks.allSatisfy({ item in
                  item.bounds.count == 4 && item.bounds.allSatisfy({ $0.isFinite && abs($0) < 10_000 }) && item.rect.width > 0 && item.rect.height > 0 && item.residentBytes > 0 && item.residentBytes < 512 * 1_048_576
                      && item.key.range(of: "^chunk--?[0-9]+--?[0-9]+$", options: .regularExpression) != nil
                      && item.digest.count == 64
              }), c.ownership.count <= 1000, c.ownership.allSatisfy({ owner in
                  validRing(owner.ring) && !owner.keys.isEmpty && Set(owner.keys).isSubset(of: Set(c.chunks.map(\.key)))
              }) else { throw DioramaTileArchive.ArchiveError.invalid }
        return c
    }

    /// Assign whole architectural triangles once; bounds include crossing triangles and full prop extents.
    static func forEachChunk(_ a: DioramaTileArtifacts, rect groundRect: DioramaRect,
                             sink: (String, DioramaTileArtifacts, DioramaRect, Int) throws -> Void) throws {
        var rangeBins: [String: [(DioramaRenderLayer.Range, [UInt32])]] = [:]
        for range in a.ranges {
            try Task.checkCancellation()
            var bins: [String: [UInt32]] = [:]
            for offset in stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                let ids = Array(a.indices[offset..<(offset + 3)])
                let p = ids.reduce(SIMD4<Float>.zero) { $0 + a.vertices[Int($1)].position } / 3
                bins[key(DV2(Double(p.x), Double(p.y))), default: []].append(contentsOf: ids)
            }
            for (key, ids) in bins { rangeBins[key, default: []].append((range, ids)) }
        }
        var groupBins: [String: [(DioramaInstanceGroup, [DioramaInstanceData])]] = [:]
        for group in a.groups {
            try Task.checkCancellation()
            let bins = Dictionary(grouping: group.instances) { key(DV2(Double($0.placement.x), Double($0.placement.y))) }
            for (key, instances) in bins { groupBins[key, default: []].append((group, instances)) }
        }
        let names = Set(rangeBins.keys).union(groupBins.keys).sorted()
        for name in names {
            try Task.checkCancellation()
            var vertices: [BuildingRenderVertex] = [], indices: [UInt32] = [], ranges: [DioramaRenderLayer.Range] = []
            var groups: [DioramaInstanceGroup] = [], instances: [DioramaInstanceData] = [], remap: [UInt32: UInt32] = [:]
            func copied(_ ids: [UInt32]) -> [UInt32] {
                ids.map { old in
                    if let new = remap[old] { return new }
                    let new = UInt32(vertices.count); vertices.append(a.vertices[Int(old)]); remap[old] = new; return new
                }
            }
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
            for (source, ids) in rangeBins[name] ?? [] {
                let mapped = copied(ids)
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                for id in mapped { let p = vertices[Int(id)].position; lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z)) }
                ranges.append(.init(category: source.category, start: indices.count, count: mapped.count, minimum: lo, maximum: hi, doubleSided: source.doubleSided, translucent: source.translucent))
                indices.append(contentsOf: mapped); low = simd_min(low, lo); high = simd_max(high, hi)
            }
            var prototypes: [String: Int] = [:]
            func prototype(_ start: Int, _ count: Int) -> Int {
                let identity = "\(start)/\(count)"
                if let prior = prototypes[identity] { return prior }
                let copiedStart = indices.count; prototypes[identity] = copiedStart
                indices.append(contentsOf: copied(Array(a.indices[start..<(start + count)])))
                return copiedStart
            }
            for (source, placements) in groupBins[name] ?? [] {
                let start = prototype(source.fullStart, source.fullCount)
                let lightStart = source.lightCount > 0 ? prototype(source.lightStart, source.lightCount) : start
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                for i in placements { lo = simd_min(lo, i.centre - SIMD3(repeating: i.radius)); hi = simd_max(hi, i.centre + SIMD3(repeating: i.radius)) }
                groups.append(.init(category: source.category, fullStart: start, fullCount: source.fullCount, lightStart: lightStart, lightCount: source.lightCount,
                    doubleSided: source.doubleSided, instances: placements, firstInstance: instances.count, minimum: lo, maximum: hi))
                instances.append(contentsOf: placements); low = simd_min(low, lo); high = simd_max(high, hi)
            }
            let bounds = DioramaRect(minX: Double(low.x), minY: Double(low.y), maxX: Double(high.x), maxY: Double(high.y))
            // Stable source ordinals let working-set assembly deduplicate paint without changing precedence.
            let paint = (a.groundImage?.paint.triangles ?? []).enumerated().compactMap { index, source -> DioramaPaintTriangle? in
                let gridRect = Self.rect(DV2((bounds.minX + bounds.maxX) / 2, (bounds.minY + bounds.maxY) / 2))
                let frame = DioramaRect(minX: min(bounds.minX, gridRect.minX), minY: min(bounds.minY, gridRect.minY), maxX: max(bounds.maxX, gridRect.maxX), maxY: max(bounds.maxY, gridRect.maxY))
                guard paintIntersects(source, rect: frame.expanded(by: 0.6)) else { return nil }
                var t = source; t.edge1.w = Float(index); return t
            }
            let image = DioramaGroundImage(size: 64, rgba: Array(repeating: 0, count: 64 * 64 * 4), paint: rebinned(paint, rect: groundRect))
            let sources = a.lights.filter { bounds.expanded(by: $0.radius).contains(DV2($0.position.x, $0.position.y)) }
            let tile = DioramaTileArtifacts(tile: a.tile, vertices: vertices, indices: indices, ranges: ranges, groups: groups, allInstances: instances, parts: [], lights: sources,
                lightGrid: DioramaLightGrid.build(sources, rect: groundRect, cells: 96, perCell: 16), waterHeight: 0, shorelineReport: [], generationSeconds: 0, groundImage: image, renderMaterialsPrepared: true)
            try sink(name, tile, bounds, names.count)
        }
    }

    static func paintIntersects(_ t: DioramaPaintTriangle, rect: DioramaRect) -> Bool {
        let corners = [DV2(rect.minX, rect.minY), DV2(rect.maxX, rect.minY), DV2(rect.maxX, rect.maxY), DV2(rect.minX, rect.maxY)]
        return [t.edge0, t.edge1, t.edge2].allSatisfy { edge in
            corners.contains { Double(edge.x) * $0.x + Double(edge.y) * $0.y + Double(edge.z) >= -0.001 }
        }
    }

    static func paintBounds(_ t: DioramaPaintTriangle) -> DioramaRect? {
        let edges = [t.edge0, t.edge1, t.edge2]
        var points: [DV2] = []
        for i in 0..<3 {
            let a = edges[i], b = edges[(i + 1) % 3]
            let cross = Double(a.x) * Double(b.y) - Double(a.y) * Double(b.x)
            guard abs(cross) > 1e-12 else { return nil }
            let x = (Double(a.y) * Double(b.z) - Double(a.z) * Double(b.y)) / cross
            let y = (Double(a.z) * Double(b.x) - Double(a.x) * Double(b.z)) / cross
            guard x.isFinite, y.isFinite else { return nil }
            points.append(DV2(x, y))
        }
        return DioramaRect.bounding(points)
    }

    static func rebinned(_ triangles: [DioramaPaintTriangle], rect: DioramaRect) -> DioramaVectorPaint {
        var paint = DioramaVectorPaint(), bins = [[UInt32]](repeating: [], count: 4096)
        paint.triangles = triangles
        func cell(_ p: Double, origin: Double, size: Double) -> Int {
            let value = min(63.0, max(0.0, floor((p - origin) / size * 64)))
            return value.isFinite ? Int(value) : 0
        }
        for (id, triangle) in triangles.enumerated() {
            guard let bound = paintBounds(triangle)?.expanded(by: 0.6), bound.intersects(rect) else { continue }
            for y in cell(bound.minY, origin: rect.minY, size: rect.height)...cell(bound.maxY, origin: rect.minY, size: rect.height) {
                for x in cell(bound.minX, origin: rect.minX, size: rect.width)...cell(bound.maxX, origin: rect.minX, size: rect.width) {
                    bins[y * 64 + x].append(UInt32(id))
                }
            }
        }
        for i in 0..<4096 {
            paint.table[i] = SIMD2(UInt32(paint.indices.count), UInt32(bins[i].count)); paint.indices.append(contentsOf: bins[i])
        }
        return paint
    }

    static func save(_ a: DioramaTileArtifacts, data: AirportMapData, campus: AirportPackageStore.Metadata,
                     into destination: URL? = nil, progress: @Sendable (Int, Int) -> Void) throws -> Catalog {
        let stage = destination ?? AirportPackageStore.root.appendingPathComponent(revision + ".preparing", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let groundRect = data.groundRect(origin: campus.coordinate)
        var chunks: [Chunk] = [], bytes = 0
        try forEachChunk(a, rect: groundRect) { name, tile, r, total in
            try Task.checkCancellation()
            let path = stage.appendingPathComponent(name, isDirectory: true)
            bytes += try DioramaTileArchive.write(tile, key: revision + "/" + name, to: path)
            let digest = DioramaTileArchive.digestHex(try Data(contentsOf: path.appendingPathComponent("manifest.json")))
            chunks.append(.init(key: name, bounds: [r.minX, r.minY, r.maxX, r.maxY], digest: digest, residentBytes: tile.decodedBytes))
            progress(chunks.count, total)
        }
        let clips = data.features.filter { (campus.builtIDs.contains($0.id) || $0.id == AirportControlTowerGeometry.sourceID) && $0.isClosed }.map(\.coordinates)
        let projection = DioramaProjection(origin: campus.coordinate)
        let ownership = clips.compactMap { ring -> Ownership? in
            let bounds = DioramaRect.bounding(ring.map { projection.local(longitude: $0[0], latitude: $0[1]) }).expanded(by: 1)
            let keys = chunks.filter { $0.rect.intersects(bounds) }.map(\.key)
            return keys.isEmpty ? nil : Ownership(ring: ring, keys: keys)
        }
        let c = Catalog(revision: revision, campusDigest: campus.manifestDigest, origin: campus.origin,
            bounds: [groundRect.minX, groundRect.minY, groundRect.maxX, groundRect.maxY], boundary: data.boundary.coordinates, clips: clips, ownership: ownership, chunks: chunks, bytes: bytes)
        try JSONEncoder().encode(c).write(to: stage.appendingPathComponent("spatial.json"), options: .atomic)
        try Task.checkCancellation()
        if destination == nil {
            publicationLock.lock(); defer { publicationLock.unlock() }
            let target = installedDirectory
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: stage, backupItemName: revision + ".previous-" + UUID().uuidString, options: [.withoutDeletingBackupItem])
            } else { try FileManager.default.moveItem(at: stage, to: target) }
        }
        return c
    }

    static func read(_ c: Catalog, keys: Set<String>, device: MTLDevice, retainingBytes: Int = 0) throws -> Selection {
        publicationLock.lock(); defer { publicationLock.unlock() }
        guard try catalog().campusDigest == c.campusDigest, !keys.isEmpty,
              keys.isSubset(of: Set(c.chunks.map(\.key))) else { throw DioramaTileArchive.ArchiveError.invalid }
        guard keys.count <= 64 else { throw CocoaError(.fileReadTooLarge) }
        let path = installedDirectory
        var manifests: [(Chunk, DioramaTileArchive.Manifest)] = []
        var counts = SIMD3<Int>.zero
        for chunk in c.chunks where keys.contains(chunk.key) {
            try Task.checkCancellation()
            let path = path.appendingPathComponent(chunk.key)
            guard DioramaTileArchive.digestHex(try Data(contentsOf: path.appendingPathComponent("manifest.json"))) == chunk.digest else { throw DioramaTileArchive.ArchiveError.invalid }
            let m = try DioramaTileArchive.validatedManifest(at: path, key: revision + "/" + chunk.key)
            let sizes = Dictionary(uniqueKeysWithValues: m.sections.map { ($0.name, $0.bytes) })
            let vertexCount: Int = DioramaTileArchive.vertexCount(m)
            let indexCount: Int = (sizes["indices"] ?? 0) / 4
            let instanceCount: Int = (sizes["instances"] ?? 0) / MemoryLayout<DioramaInstanceData>.stride
            counts = SIMD3<Int>(counts.x + vertexCount, counts.y + indexCount, counts.z + instanceCount)
            manifests.append((chunk, m))
        }
        guard !manifests.isEmpty else { throw DioramaTileArchive.ArchiveError.invalid }
        let retained = counts.x * MemoryLayout<DioramaPackedVertex>.stride + counts.y * 4 + counts.z * MemoryLayout<DioramaInstanceData>.stride
        let largest = manifests.map { $0.0.residentBytes }.max() ?? 0
        // Retiring and incoming airport hosts may both retain immutable in-flight draw chunks.
        let chunkCaches = 2 * DioramaGeometryChunks.reservationBytes(context: false)
        let peak = retained + largest + max(0, retainingBytes) + 96 * 1_048_576 + chunkCaches
        let allowance = min(384 * 1_048_576, Int(ProcessInfo.processInfo.physicalMemory / 12))
        guard peak <= allowance else { throw CocoaError(.fileReadTooLarge) }
        let bounds = DioramaRect.bounding(c.chunks.filter { keys.contains($0.key) }.flatMap {
            [DV2($0.rect.minX, $0.rect.minY), DV2($0.rect.maxX, $0.rect.maxY)]
        })
        let projection = DioramaProjection(origin: c.coordinate)
        let nativeOnly = c.ownership.filter { !Set($0.keys).isSubset(of: keys) }.map { owner in
            owner.ring.map { projection.local(longitude: $0[0], latitude: $0[1]) }
        }
        let resident = try AirportResidentAssembly.combine(device: device,
            tileID: .init(latitude: c.coordinate.latitude, longitude: c.coordinate.longitude, zoom: 16), counts: counts,
            chunkCount: manifests.count, rect: bounds, nativeOnly: nativeOnly) { item in
                let (chunk, manifest) = manifests[item]
                return try DioramaTileArchive.readResident(from: path.appendingPathComponent(chunk.key), key: revision + "/" + chunk.key,
                    manifest: manifest, device: device, patch: nil, origin: c.coordinate, materialsPrepared: true)
            }
        // Measured pixel-error levels for the selected campus chunks (the airport had none). Index-only,
        // at most about the size of the original index buffer; skipped if that would exceed the allowance.
        try Task.checkCancellation()
        let lodFits = peak + counts.y * 4 <= allowance
        return Selection(catalog: c, keys: keys, resident: lodFits ? DioramaLODBuilder.completing(resident, groups: true) : resident)
    }
}
