import CryptoKit
import Darwin
import Foundation
import Metal
import QuartzCore
import simd

/// GPU-ready image of a fully decoded saved tile (after r3 edits, legacy material tags, landmark
/// ownership, baked landmarks, LOD matching and the painted-ground grid). The first visit decodes the
/// original package as before and writes this image to purgeable Caches in the background; later
/// visits memory-map its page-aligned sections straight into shared Metal buffers, so there is no
/// decompression, block checksumming, per-vertex tagging, merging or landmark rebuilding.
///
/// It is a cache, never user data: original packages and sidecars are untouched, iOS may purge it,
/// and any identity mismatch, size mismatch or failed bounds check falls back to the original read.
nonisolated enum DioramaResidentSnapshot {
    /// Bump whenever `DioramaTileArchive.readResident` output changes for the same inputs
    /// (tagging, ownership, packing or landmark appending rules).
    /// 2: tile-drawn landmarks carry computed pixel-error levels.
    /// 6: planting/estate ground lookups read the raster north-up and honour vector finish layers.
    static let format = 6
    private static let cap: Int64 = 3 * 1_073_741_824
    private static let minimumFreeSpace: Int64 = 2 * 1_073_741_824
    private static let page = Int(getpagesize())

    private final class Writes: @unchecked Sendable {
        let lock = NSLock()
        var keys: Set<String> = []
    }
    private static let writes = Writes()

    struct Loaded: @unchecked Sendable {
        let tile: DioramaResidentTile
        let seconds: Double
    }

    // MARK: - Records

    private struct Section: Codable { let name: String; let offset: Int; let length: Int; let mapped: Int }
    private struct RangeRecord: Codable {
        let c: DioramaCategory; let s: Int; let n: Int; let lo: SIMD3<Float>; let hi: SIMD3<Float>
        let d: Bool; let t: Bool; let p: Bool; let id: String?; let slot: Int32; let lod: Bool
        init(_ r: DioramaRenderLayer.Range) {
            c = r.category; s = r.start; n = r.count; lo = r.minimum; hi = r.maximum; d = r.doubleSided; t = r.translucent
            p = r.landmarkPlaceholder; id = r.landmarkID; slot = r.lodSlot; lod = r.usesLODBuffer
        }
        var range: DioramaRenderLayer.Range {
            var r = DioramaRenderLayer.Range(category: c, start: s, count: n, minimum: lo, maximum: hi, doubleSided: d, translucent: t)
            r.landmarkPlaceholder = p; r.landmarkID = id; r.lodSlot = slot; r.usesLODBuffer = lod
            return r
        }
    }
    private struct GroupRecord: Codable {
        let c: DioramaCategory; let fs: Int; let fc: Int; let ls: Int; let lc: Int; let d: Bool
        let first: Int; let n: Int; let lo: SIMD3<Float>; let hi: SIMD3<Float>
        let p: Bool; let id: String?; let slot: Int32; let scale: Float
        init(_ g: DioramaInstanceGroup) {
            c = g.category; fs = g.fullStart; fc = g.fullCount; ls = g.lightStart; lc = g.lightCount; d = g.doubleSided
            first = g.firstInstance; n = g.instances.count; lo = g.minimum; hi = g.maximum
            p = g.landmarkPlaceholder; id = g.landmarkID; slot = g.lodSlot; scale = g.lodScale
        }
        func group(_ instances: [DioramaInstanceData]) -> DioramaInstanceGroup {
            var g = DioramaInstanceGroup(category: c, fullStart: fs, fullCount: fc, lightStart: ls, lightCount: lc, doubleSided: d,
                                         instances: instances, firstInstance: first, minimum: lo, maximum: hi)
            g.landmarkPlaceholder = p; g.landmarkID = id; g.lodSlot = slot; g.lodScale = scale
            return g
        }
    }
    private struct LabelRecord: Codable { let id: UInt64; let title: String; let anchor: SIMD3<Float>; let footprint: [Double]; let named: Bool }
    private struct GroundRecord: Codable { let minX: Float; let minY: Float; let cell: Float; let columns: Int; let rows: Int }
    private struct SummaryRecord: Codable {
        let shoreline: [String]; let optimization: [String]; let stages: [String]
        let triangles: Int; let instances: Int; let bytes: Int; let seconds: Double
    }
    private struct Header: Codable {
        let format: Int
        let identity: String
        let tile: String
        let fileLength: Int
        let sections: [Section]
        let vertexCount: Int
        let indexCount: Int
        let instanceCount: Int
        let ranges: [RangeRecord]
        let groups: [GroupRecord]
        let lodIndexCount: Int?
        let lodRanges: [[DioramaLODTable.Level]]?
        let lodPrototypes: [[DioramaLODTable.Level]]?
        let lightCells: Int
        let lightMinX: Float
        let lightMinY: Float
        let lightCellSize: Float
        let ground: GroundRecord?
        let imageSize: Int
        let mipOffsets: [Int]
        let waterHeight: Double
        let pool: RangeRecord?
        let shadowLow: SIMD3<Float>?
        let shadowHigh: SIMD3<Float>?
        let foliage: Int
        let architecture: Int
        let summary: SummaryRecord
        let labels: [LabelRecord]
        let drawn: [String]
        let expected: [String]
        let floors: [String: Double]
    }

    // MARK: - Location and identity

    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DioramaResident", isDirectory: true)
    }
    private static func name(_ tile: DioramaTileID, context: Bool) -> String { "\(tile.key)-\(context ? "context" : "focus")" }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Everything the decoded result depends on: package manifest (which carries every block digest),
    /// the r3 and LOD sidecar checksums, the landmark recipe stamp and this format.
    static func identity(package: URL, landmarks: String) -> String? {
        guard let manifest = try? Data(contentsOf: package.appendingPathComponent("manifest.json")) else { return nil }
        let digest = hex(SHA256.hash(data: manifest))
        let name = package.lastPathComponent, parent = package.deletingLastPathComponent()
        var hasher = SHA256()
        func add(_ text: String) { hasher.update(data: Data(text.utf8)) }
        add("resident\(format)|\(name)|\(digest)|\(landmarks)")
        let patch = "visual-r\(DioramaVisualUpgrade.patchRevision)-\(name)-\(digest.prefix(16))"
        let sidecars = [parent.appendingPathComponent(patch).appendingPathComponent("patch.sha")] + [false, true].map {
            parent.appendingPathComponent(DioramaLODStore.directoryName(package: name, digest: digest, patched: $0)).appendingPathComponent("lod.sha")
        }
        for file in sidecars {
            add("|" + file.deletingLastPathComponent().lastPathComponent + "=")
            if let bytes = try? Data(contentsOf: file) { hasher.update(data: bytes) } else { add("none") }
        }
        return hex(hasher.finalize())
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Whether a snapshot with exactly this identity is already on disk (header check only).
    static func isCurrent(tile: DioramaTileID, context: Bool, identity: String) -> Bool {
        let base = name(tile, context: context)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? Data(contentsOf: root.appendingPathComponent(base + ".json")),
              let h = try? decoder.decode(Header.self, from: data),
              let size = try? root.appendingPathComponent(base + ".bin").resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return h.format == format && h.identity == identity && h.tile == tile.key && size == h.fileLength
    }

    /// Background writes still holding a decoded tile's buffers.
    static var hasPendingWrites: Bool {
        writes.lock.lock(); defer { writes.lock.unlock() }
        return !writes.keys.isEmpty
    }

    // MARK: - Read

    /// Maps a matching snapshot into Metal. Returns nil (caller decodes the original) on any doubt.
    static func read(tile: DioramaTileID, context: Bool, identity: String, device: MTLDevice) -> Loaded? {
        let started = CACurrentMediaTime()
        let base = name(tile, context: context)
        let headerURL = root.appendingPathComponent(base + ".json"), binURL = root.appendingPathComponent(base + ".bin")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? Data(contentsOf: headerURL), let h = try? decoder.decode(Header.self, from: data),
              h.format == format, h.identity == identity, h.tile == tile.key,
              let size = try? binURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == h.fileLength,
              h.vertexCount > 0, h.indexCount > 0, h.indexCount % 3 == 0 else { return nil }
        let fd = open(binURL.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let sections = Dictionary(h.sections.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        func valid(_ s: Section) -> Bool {
            s.offset >= 0 && s.length >= 0 && s.offset % page == 0 && s.mapped >= s.length && s.mapped % page == 0
                && s.offset <= h.fileLength - s.mapped
        }
        func buffer(_ name: String, minimum: Int) -> MTLBuffer? {
            guard let s = sections[name], valid(s), s.length >= minimum else { return nil }
            guard s.mapped > 0 else { return device.makeBuffer(length: 16, options: .storageModeShared) }
            let raw: UnsafeMutableRawPointer? = mmap(nil, s.mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, off_t(s.offset))
            guard let p = raw, p != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
            // Clean file-backed pages: adopt without copying when Metal accepts the mapping.
            if let b = device.makeBuffer(bytesNoCopy: p, length: s.mapped, options: .storageModeShared, deallocator: { pointer, length in
                munmap(pointer, length)
            }) { return b }
            let copy = device.makeBuffer(bytes: p, length: s.mapped, options: .storageModeShared)
            munmap(p, s.mapped)
            return copy
        }
        func values<T>(_ name: String, _ type: T.Type) -> [T]? {
            guard let s = sections[name], valid(s), s.length % MemoryLayout<T>.stride == 0 else { return nil }
            let count = s.length / MemoryLayout<T>.stride
            var ok = true
            let result = [T](unsafeUninitializedCapacity: count) { output, initialized in
                var done = 0
                let target = UnsafeMutableRawPointer(output.baseAddress)
                while done < s.length, let target {
                    let got = pread(fd, target.advanced(by: done), s.length - done, off_t(s.offset + done))
                    if got <= 0 { break }
                    done += got
                }
                ok = done == s.length
                initialized = ok ? count : 0
            }
            return ok ? result : nil
        }
        /// Fault pages in on this background thread so the first GPU frame never waits on flash.
        func prefault(_ b: MTLBuffer) {
            let p = b.contents()
            madvise(p, b.length, MADV_WILLNEED)
            var sum: UInt8 = 0
            for offset in Swift.stride(from: 0, to: b.length, by: page) { sum &+= p.load(fromByteOffset: offset, as: UInt8.self) }
            if sum == 0xA5, b.length == 1 { print("[Diorama snapshot] prefault") }
        }

        let vertexStride = MemoryLayout<DioramaPackedVertex>.stride
        guard let vertexBuffer = buffer("vertices", minimum: h.vertexCount * vertexStride),
              let indexBuffer = buffer("indices", minimum: h.indexCount * 4),
              let instanceBuffer = buffer("instances", minimum: max(h.instanceCount, 1) * MemoryLayout<DioramaInstanceData>.stride),
              let paintBuffer = buffer("paint", minimum: 0), let paintTableBuffer = buffer("paintTable", minimum: 0),
              let paintIndexBuffer = buffer("paintIndices", minimum: 0),
              let groupInstances = values("groupInstances", DioramaInstanceData.self),
              let lights = values("lights", DioramaShaderLight.self), let lightTable = values("lightTable", SIMD2<UInt32>.self),
              let lightIndices = values("lightIndices", UInt32.self) else { return nil }
        if Task.isCancelled { return nil }

        // Bounds checks protect the GPU from a damaged cache file; they read indices once.
        let idx = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let vertexLimit = UInt32(h.vertexCount)
        for i in 0..<h.indexCount where idx[i] >= vertexLimit { return nil }
        var lod: DioramaLODTable?
        if let lodCount = h.lodIndexCount, let rangeLevels = h.lodRanges, let protoLevels = h.lodPrototypes {
            guard lodCount >= 0, let lodBuffer = buffer("lod", minimum: lodCount * 4) else { return nil }
            let lodIdx = lodBuffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<lodCount where lodIdx[i] >= vertexLimit { return nil }
            guard (rangeLevels + protoLevels).allSatisfy({ $0.allSatisfy { $0.start >= 0 && $0.count >= 0 && $0.start <= lodCount - $0.count } }) else { return nil }
            lod = DioramaLODTable(indexBuffer: lodBuffer, indexCount: lodCount, rangeLevels: rangeLevels, prototypeLevels: protoLevels)
        }
        let ranges = h.ranges.map(\.range)
        guard ranges.allSatisfy({ r in
            let limit = r.usesLODBuffer ? (lod?.indexCount ?? -1) : h.indexCount
            return r.start >= 0 && r.count >= 0 && r.start <= limit - r.count
                && (r.lodSlot < 0 || Int(r.lodSlot) < (lod?.rangeLevels.count ?? 0))
        }) else { return nil }
        let instanceLimit = instanceBuffer.length / MemoryLayout<DioramaInstanceData>.stride
        var cursor = 0
        var groups: [DioramaInstanceGroup] = []
        groups.reserveCapacity(h.groups.count)
        for record in h.groups {
            guard record.n >= 0, record.n <= groupInstances.count - cursor, record.first >= 0, record.first <= instanceLimit - record.n,
                  record.fs >= 0, record.fc >= 0, record.fs <= h.indexCount - record.fc,
                  record.ls >= 0, record.lc >= 0, record.ls <= h.indexCount - record.lc,
                  record.slot < 0 || Int(record.slot) < (lod?.prototypeLevels.count ?? 0) else { return nil }
            groups.append(record.group(Array(groupInstances[cursor..<(cursor + record.n)])))
            cursor += record.n
        }
        let paintCount = paintBuffer.length / MemoryLayout<DioramaPaintTriangle>.stride
        let paintTableCount = (sections["paintTable"]?.length ?? 0) / MemoryLayout<SIMD2<UInt32>>.stride
        let paintIndexCount = (sections["paintIndices"]?.length ?? 0) / 4
        let paintTable = paintTableBuffer.contents().assumingMemoryBound(to: SIMD2<UInt32>.self)
        let paintIndices = paintIndexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<paintIndexCount where Int(paintIndices[i]) >= paintCount { return nil }
        for i in 0..<paintTableCount {
            let t = paintTable[i]
            guard Int(t.x) <= paintIndexCount, Int(t.y) <= paintIndexCount - Int(t.x) else { return nil }
        }
        guard h.lightCells > 0, lightTable.count == h.lightCells * h.lightCells, lightIndices.allSatisfy({ Int($0) < lights.count }),
              lightTable.allSatisfy({ Int($0.x) <= lightIndices.count && Int($0.y) <= lightIndices.count - Int($0.x) }) else { return nil }
        let grid = DioramaLightGrid(cells: h.lightCells, minX: h.lightMinX, minY: h.lightMinY, cellSize: h.lightCellSize,
                                    lights: lights, table: lightTable, indices: lightIndices)
        var groundIndex: DioramaGroundIndex?
        if let g = h.ground {
            guard g.columns > 0, g.rows > 0, let offsets = values("groundOffsets", UInt32.self),
                  let triangles = values("groundTriangles", UInt32.self), offsets.count == g.columns * g.rows + 1,
                  offsets.first == 0, Int(offsets.last ?? 0) == triangles.count,
                  zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }),
                  triangles.allSatisfy({ Int($0) <= h.indexCount - 3 }) else { return nil }
            groundIndex = DioramaGroundIndex(minX: g.minX, minY: g.minY, cell: g.cell, columns: g.columns, rows: g.rows,
                                             offsets: offsets, triangles: triangles)
        }
        if Task.isCancelled { return nil }

        var groundTexture: MTLTexture?
        if h.imageSize > 0 {
            guard h.imageSize <= 4096, let texels = buffer("texture", minimum: 0) else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: h.imageSize, height: h.imageSize, mipmapped: true)
            guard descriptor.mipmapLevelCount == h.mipOffsets.count else { return nil }
            // Private storage lets Apple GPUs keep the ground losslessly compressed: same texels, less bandwidth.
            descriptor.usage = [.shaderRead]; descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue(),
                  let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return nil }
            for (level, offset) in h.mipOffsets.enumerated() {
                let side = max(1, h.imageSize >> level), bytes = side * side * 4
                guard offset >= 0, offset % 4 == 0, offset <= texels.length - bytes else { blit.endEncoding(); return nil }
                blit.copy(from: texels, sourceOffset: offset, sourceBytesPerRow: side * 4, sourceBytesPerImage: bytes,
                          sourceSize: MTLSize(width: side, height: side, depth: 1), to: texture, destinationSlice: 0,
                          destinationLevel: level, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { return nil }
            groundTexture = texture
        }
        for b in [vertexBuffer, instanceBuffer, paintBuffer, paintTableBuffer, paintIndexBuffer] + (lod.map { [$0.indexBuffer] } ?? []) {
            prefault(b)
        }
        if Task.isCancelled { return nil }

        // Same landmark floors as the decode that produced this image; a conflicting session floor
        // means a neighbour already used another datum, so decode instead of risking a step.
        for (id, floor) in h.floors where !DioramaBakedLandmarks.shared.adopt(floor: floor, for: id) { return nil }
        for id in h.expected where !h.drawn.contains(id) { DioramaBakedLandmarks.shared.markUnavailable(id) }

        let s = h.summary
        let summary = DioramaTileSummary(shorelineReport: s.shoreline,
            optimizationReport: s.optimization + ["GPU-ready local snapshot: mapped without decoding"], stageTimings: s.stages,
            totalTriangles: s.triangles, totalInstances: s.instances, totalBytes: s.bytes, generationSeconds: s.seconds)
        let shadow: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? = h.shadowLow.flatMap { low in h.shadowHigh.map { (low, $0) } }
        let resident = DioramaResidentTile(tile: tile, device: device, vertexBuffer: vertexBuffer, vertexCount: h.vertexCount,
            indexBuffer: indexBuffer, indexCount: h.indexCount, instanceBuffer: instanceBuffer, instanceCount: h.instanceCount,
            ranges: ranges, groups: groups, lightGrid: grid, paintBuffer: paintBuffer, paintTableBuffer: paintTableBuffer,
            paintIndexBuffer: paintIndexBuffer, groundTexture: groundTexture, waterHeight: h.waterHeight,
            labels: h.labels.map { l in
                DioramaBuildingLabel(id: l.id, title: l.title, anchor: l.anchor,
                    footprint: Swift.stride(from: 0, to: l.footprint.count - 1, by: 2).map { DV2(l.footprint[$0], l.footprint[$0 + 1]) },
                    isNamed: l.named)
            },
            poolBounds: h.pool?.range, shadowBounds: shadow, materialCounts: SIMD2(h.foliage, h.architecture), summary: summary,
            lod: lod, groundIndex: groundIndex)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: headerURL.path)
        return Loaded(tile: resident, seconds: CACurrentMediaTime() - started)
    }

    // MARK: - Write

    /// Writes the decoded tile once, off the render path. Header last, so a header always describes a
    /// complete image. Skips quietly on low storage or any error; the original read keeps working.
    static func write(_ r: DioramaResidentTile, context: Bool, identity: String, drawn: [String], expected: [String], floors: [String: Double]) {
        let base = name(r.tile, context: context)
        writes.lock.lock()
        guard !writes.keys.contains(base) else { writes.lock.unlock(); return }
        writes.keys.insert(base)
        writes.lock.unlock()
        defer { writes.lock.lock(); writes.keys.remove(base); writes.lock.unlock() }
        if let texture = r.groundTexture, texture.storageMode != .shared || texture.pixelFormat != .rgba8Unorm || texture.width != texture.height { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey]).volumeAvailableCapacityForOpportunisticUsage) ?? 0
            guard free > minimumFreeSpace else { return }
            let headerURL = root.appendingPathComponent(base + ".json"), binURL = root.appendingPathComponent(base + ".bin")
            let tempURL = root.appendingPathComponent(base + ".bin.tmp")
            try? fm.removeItem(at: headerURL)
            try? fm.removeItem(at: tempURL)
            guard fm.createFile(atPath: tempURL.path, contents: nil) else { return }
            let handle = try FileHandle(forWritingTo: tempURL)
            var cursor = 0
            var sections: [Section] = []
            func zeros(_ count: Int) throws {
                guard count > 0 else { return }
                try handle.write(contentsOf: Data(count: count)); cursor += count
            }
            func pad() throws { try zeros((page - cursor % page) % page) }
            func raw(_ name: String, _ pointer: UnsafeRawPointer?, _ count: Int) throws {
                try pad()
                let start = cursor
                if let pointer, count > 0 {
                    var offset = 0
                    while offset < count {
                        let n = min(4 << 20, count - offset)
                        try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer.advanced(by: offset)), count: n, deallocator: .none))
                        offset += n
                    }
                }
                cursor += count
                sections.append(Section(name: name, offset: start, length: count, mapped: (count + page - 1) / page * page))
            }
            func array<T>(_ name: String, _ values: [T]) throws { try values.withUnsafeBytes { try raw(name, $0.baseAddress, $0.count) } }

            try raw("vertices", r.vertexBuffer.contents(), r.vertexCount * MemoryLayout<DioramaPackedVertex>.stride)
            try raw("indices", r.indexBuffer.contents(), r.indexCount * 4)
            try raw("instances", r.instanceBuffer.contents(), r.instanceBuffer.length)
            try raw("paint", r.paintBuffer.contents(), r.paintBuffer.length)
            try raw("paintTable", r.paintTableBuffer.contents(), r.paintTableBuffer.length)
            try raw("paintIndices", r.paintIndexBuffer.contents(), r.paintIndexBuffer.length)
            if let lod = r.lod { try raw("lod", lod.indexBuffer.contents(), lod.indexCount * 4) }
            try array("groupInstances", r.groups.flatMap(\.instances))
            try array("lights", r.lightGrid.lights)
            try array("lightTable", r.lightGrid.table)
            try array("lightIndices", r.lightGrid.indices)
            if let g = r.groundIndex {
                try array("groundOffsets", g.offsets)
                try array("groundTriangles", g.triangles)
            }
            var mipOffsets: [Int] = []
            if let texture = r.groundTexture {
                try pad()
                let start = cursor
                for level in 0..<texture.mipmapLevelCount {
                    try zeros((256 - (cursor - start) % 256) % 256)
                    mipOffsets.append(cursor - start)
                    let side = max(1, texture.width >> level), rowBytes = side * 4
                    let rowsPerChunk = max(1, (4 << 20) / rowBytes)
                    var scratch = [UInt8](repeating: 0, count: min(side, rowsPerChunk) * rowBytes)
                    var y = 0
                    while y < side {
                        let rows = min(rowsPerChunk, side - y)
                        try scratch.withUnsafeMutableBytes { bytes in
                            guard let address = bytes.baseAddress else { throw CocoaError(.fileWriteUnknown) }
                            texture.getBytes(address, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, y, side, rows), mipmapLevel: level)
                            try handle.write(contentsOf: Data(bytesNoCopy: address, count: rows * rowBytes, deallocator: .none))
                        }
                        cursor += rows * rowBytes; y += rows
                    }
                }
                let length = cursor - start
                sections.append(Section(name: "texture", offset: start, length: length, mapped: (length + page - 1) / page * page))
            }
            try pad()
            try handle.close()
            try? fm.removeItem(at: binURL)
            try fm.moveItem(at: tempURL, to: binURL)

            let s = r.summary
            let header = Header(format: format, identity: identity, tile: r.tile.key, fileLength: cursor, sections: sections,
                vertexCount: r.vertexCount, indexCount: r.indexCount, instanceCount: r.instanceCount,
                ranges: r.ranges.map(RangeRecord.init), groups: r.groups.map(GroupRecord.init),
                lodIndexCount: r.lod?.indexCount, lodRanges: r.lod?.rangeLevels, lodPrototypes: r.lod?.prototypeLevels,
                lightCells: r.lightGrid.cells, lightMinX: r.lightGrid.minX, lightMinY: r.lightGrid.minY, lightCellSize: r.lightGrid.cellSize,
                ground: r.groundIndex.map { GroundRecord(minX: $0.minX, minY: $0.minY, cell: $0.cell, columns: $0.columns, rows: $0.rows) },
                imageSize: r.groundTexture?.width ?? 0, mipOffsets: mipOffsets, waterHeight: r.waterHeight,
                pool: r.poolBounds.map(RangeRecord.init), shadowLow: r.shadowBounds?.minimum, shadowHigh: r.shadowBounds?.maximum,
                foliage: r.materialCounts.x, architecture: r.materialCounts.y,
                summary: SummaryRecord(shoreline: s.shorelineReport, optimization: s.optimizationReport, stages: s.stageTimings,
                                       triangles: s.totalTriangles, instances: s.totalInstances, bytes: s.totalBytes, seconds: s.generationSeconds),
                labels: r.labels.map { LabelRecord(id: $0.id, title: $0.title, anchor: $0.anchor, footprint: $0.footprint.flatMap { [$0.x, $0.y] }, named: $0.isNamed) },
                drawn: drawn, expected: expected, floors: floors)
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            try encoder.encode(header).write(to: headerURL, options: .atomic)
            print("[Diorama snapshot] wrote \(base) \(cursor / 1_048_576) MiB")
            trim()
        } catch {
            print("[Diorama snapshot] \(base) not cached; original package read remains")
        }
    }

    /// Least-recently-used eviction within the cache cap.
    private static func trim() {
        let fm = FileManager.default
        guard let headers = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var entries: [(base: String, date: Date, bytes: Int64)] = headers.filter { $0.pathExtension == "json" }.map { url in
            let base = url.deletingPathExtension().lastPathComponent
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bytes = (try? root.appendingPathComponent(base + ".bin").resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return (base, date, bytes)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > cap {
            try? fm.removeItem(at: root.appendingPathComponent(entry.base + ".json"))
            try? fm.removeItem(at: root.appendingPathComponent(entry.base + ".bin"))
            total -= entry.bytes
        }
    }
}
