import Compression
import CoreLocation
import Foundation
import Metal
import simd

/// Lightweight report retained for Settings/debug instead of the decoded tile arrays.
nonisolated struct DioramaTileSummary: Sendable {
    let shorelineReport: [String]
    let optimizationReport: [String]
    let stageTimings: [String]
    let totalTriangles: Int
    let totalInstances: Int
    let totalBytes: Int
    let generationSeconds: Double
}

/// A saved tile decoded straight into GPU-shared Metal storage. Apple GPUs use unified memory, so
/// these buffers are the only copy: no CPU-side vertex/index/ground arrays survive decoding.
/// Vertices are packed to 32 bytes; groups keep their small CPU placement lists for culling.
nonisolated final class DioramaResidentTile: @unchecked Sendable {
    let tile: DioramaTileID
    let device: MTLDevice
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let instanceBuffer: MTLBuffer
    let instanceCount: Int
    let ranges: [DioramaRenderLayer.Range]
    let groups: [DioramaInstanceGroup]
    let lightGrid: DioramaLightGrid
    let paintBuffer: MTLBuffer
    let paintTableBuffer: MTLBuffer
    let paintIndexBuffer: MTLBuffer
    let groundTexture: MTLTexture?
    let waterHeight: Double
    let labels: [DioramaBuildingLabel]
    let poolBounds: DioramaRenderLayer.Range?
    let shadowBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?
    let materialCounts: SIMD2<Int>
    let summary: DioramaTileSummary
    /// Simplified pixel-error levels from a verified local sidecar; nil draws full detail everywhere.
    let lod: DioramaLODTable?
    /// Constant-time painted-ground lookup for vehicles, shadows and route heights.
    let groundIndex: DioramaGroundIndex?
    /// Metal allocations owned by this tile (shared storage; also the CPU view).
    let gpuBytes: Int
    /// CPU placement lists, labels and light grid.
    let cpuBytes: Int

    init(tile: DioramaTileID, device: MTLDevice, vertexBuffer: MTLBuffer, vertexCount: Int, indexBuffer: MTLBuffer, indexCount: Int,
         instanceBuffer: MTLBuffer, instanceCount: Int, ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup],
         lightGrid: DioramaLightGrid, paintBuffer: MTLBuffer, paintTableBuffer: MTLBuffer, paintIndexBuffer: MTLBuffer,
         groundTexture: MTLTexture?, waterHeight: Double, labels: [DioramaBuildingLabel], poolBounds: DioramaRenderLayer.Range?,
         shadowBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?, materialCounts: SIMD2<Int>, summary: DioramaTileSummary,
         lod: DioramaLODTable? = nil, groundIndex: DioramaGroundIndex? = nil) {
        self.lod = lod; self.groundIndex = groundIndex
        self.tile = tile; self.device = device
        self.vertexBuffer = vertexBuffer; self.vertexCount = vertexCount
        self.indexBuffer = indexBuffer; self.indexCount = indexCount
        self.instanceBuffer = instanceBuffer; self.instanceCount = instanceCount
        self.ranges = ranges; self.groups = groups; self.lightGrid = lightGrid
        self.paintBuffer = paintBuffer; self.paintTableBuffer = paintTableBuffer; self.paintIndexBuffer = paintIndexBuffer
        self.groundTexture = groundTexture; self.waterHeight = waterHeight; self.labels = labels
        self.poolBounds = poolBounds; self.shadowBounds = shadowBounds; self.materialCounts = materialCounts
        self.summary = summary
        let texture = groundTexture.map { $0.width * $0.height * 4 * 4 / 3 } ?? 0
        gpuBytes = vertexBuffer.length + indexBuffer.length + instanceBuffer.length + paintBuffer.length
            + paintTableBuffer.length + paintIndexBuffer.length + texture + (lod?.bytes ?? 0)
        cpuBytes = groups.reduce(0) { $0 + $1.instances.count * MemoryLayout<DioramaInstanceData>.stride }
            + lightGrid.lights.count * MemoryLayout<DioramaShaderLight>.stride * 2
            + labels.reduce(0) { $0 + $1.footprint.count * 16 + $1.title.utf8.count + 64 }
            + (groundIndex?.bytes ?? 0)
    }
    var totalTriangles: Int { indexCount / 3 }

    /// Same buffers with new range/group metadata and LOD table (used to attach computed levels).
    func replacing(ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup], lod: DioramaLODTable?, report: String) -> DioramaResidentTile {
        let s = summary
        let merged = DioramaTileSummary(shorelineReport: s.shorelineReport, optimizationReport: s.optimizationReport + [report],
            stageTimings: s.stageTimings, totalTriangles: s.totalTriangles, totalInstances: s.totalInstances,
            totalBytes: s.totalBytes, generationSeconds: s.generationSeconds)
        return DioramaResidentTile(tile: tile, device: device, vertexBuffer: vertexBuffer, vertexCount: vertexCount,
            indexBuffer: indexBuffer, indexCount: indexCount, instanceBuffer: instanceBuffer, instanceCount: instanceCount,
            ranges: ranges, groups: groups, lightGrid: lightGrid, paintBuffer: paintBuffer, paintTableBuffer: paintTableBuffer,
            paintIndexBuffer: paintIndexBuffer, groundTexture: groundTexture, waterHeight: waterHeight, labels: labels,
            poolBounds: poolBounds, shadowBounds: shadowBounds, materialCounts: materialCounts, summary: merged,
            lod: lod, groundIndex: groundIndex)
    }

    /// Packed positions/indices are immutable shared memory, safe to read from any thread.
    func position(_ index: Int) -> SIMD4<Float> {
        vertexBuffer.contents().assumingMemoryBound(to: DioramaPackedVertex.self)[index].position
    }
    func index(_ offset: Int) -> UInt32 {
        indexBuffer.contents().assumingMemoryBound(to: UInt32.self)[offset]
    }
    /// Painted heightfield support (texture code 9 survives packing in color.w).
    func isPaintedGround(_ index: Int) -> Bool {
        vertexBuffer.contents().assumingMemoryBound(to: DioramaPackedVertex.self)[index].color.w == DioramaHalf.bits(9)
    }
}

nonisolated extension DioramaTileArchive {
    /// Peak/retained Metal + CPU bytes for loading `manifest` through `readResident`.
    struct ResidentPlan {
        let vertexCount: Int
        let indexCapacity: Int
        let instanceCount: Int
        let groupInstances: Int
        let imageSize: Int
        let paintBytes: Int
        let lightBytes: Int
        let ownershipCopy: Bool
        var lodBytes: Int = 0
    }

    static func validatedManifest(at directory: URL, key: String) throws -> Manifest {
        let json = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard json.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalid }
        let m = try JSONDecoder().decode(Manifest.self, from: json)
        guard supports(m), m.key == key else { throw ArchiveError.incompatible }
        guard m.sections.count == 10, Set(m.sections.map(\.name)).count == 10,
              m.z >= 0, m.z <= 22, m.x >= 0, m.x < (1 << m.z), m.y >= 0, m.y < (1 << m.z),
              m.imageSize >= 0, m.imageSize <= 4096, m.lightCells > 0, m.lightCells <= 128,
              m.waterHeight.isFinite, m.lightCellSize.isFinite, m.lightCellSize > 0 else { throw ArchiveError.invalid }
        try checkBlockAlignment(m)
        var budget = maxBytes
        for s in m.sections {
            guard s.bytes >= 0, s.bytes <= budget else { throw ArchiveError.invalid }
            budget -= s.bytes
        }
        return m
    }

    static func baseRanges(_ m: Manifest) -> [DioramaRenderLayer.Range] {
        m.ranges.map { .init(category: $0.category, start: $0.start, count: $0.count, minimum: $0.minimum, maximum: $0.maximum, doubleSided: $0.doubleSided, translucent: $0.translucent ?? false) }
    }
    /// Group metadata without placements (validation/patch lookup only).
    static func baseGroupShells(_ m: Manifest) -> [DioramaInstanceGroup] {
        m.groups.map { .init(category: $0.category, fullStart: $0.fullStart, fullCount: $0.fullCount, lightStart: $0.lightStart,
            lightCount: $0.lightCount, doubleSided: $0.doubleSided, instances: [], firstInstance: $0.first,
            minimum: $0.minimum, maximum: $0.maximum) }
    }

    static func residentPlan(_ m: Manifest, origin: CLLocationCoordinate2D, patchVertices: Int, patchIndices: Int, affectedIndices: Int) -> ResidentPlan {
        let sizes = Dictionary(uniqueKeysWithValues: m.sections.map { ($0.name, $0.bytes) })
        let groupInstances = m.groups.reduce(0) { $0 + max(0, $1.count) }
        let ranges = baseRanges(m)
        return ResidentPlan(vertexCount: vertexCount(m) + patchVertices,
            indexCapacity: (sizes["indices"] ?? 0) / 4 + patchIndices + affectedIndices,
            instanceCount: (sizes["instances"] ?? 0) / MemoryLayout<DioramaInstanceData>.stride, groupInstances: groupInstances,
            imageSize: m.imageSize,
            paintBytes: (sizes["paint"] ?? 0) + (sizes["paintTable"] ?? 0) + (sizes["paintIndices"] ?? 0),
            lightBytes: (sizes["lights"] ?? 0) + (sizes["lightTable"] ?? 0) + (sizes["lightIndices"] ?? 0),
            ownershipCopy: DioramaLandmarkOwnership.affects(ranges: ranges, groups: baseGroupShells(m), origin: origin))
    }

    /// Decode a section into raw destination memory, verifying every block checksum and length.
    /// `sink` receives each decoded block (already written to `scratch`) when no destination is given.
    private static func decode(_ s: Section, name: String, directory: URL, into destination: UnsafeMutableRawPointer?,
                               scratch: UnsafeMutableRawPointer, format: Int, sink: ((UnsafeRawBufferPointer, Int) throws -> Void)? = nil) throws {
        let layout = DioramaArchiveCodec.layout(section: name, format: format)
        var offset = 0
        for (index, block) in s.blocks.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            guard block.file == "\(name)-\(index).bin", block.bytes > 0, block.bytes <= blockSize,
                  block.bytes <= s.bytes - offset, block.stored > 0, block.stored <= blockSize + 65536 else { throw ArchiveError.invalid }
            let data = try Data(contentsOf: directory.appendingPathComponent(block.file), options: .mappedIfSafe)
            guard data.count == block.stored, digestHex(data) == block.sha256 else { throw ArchiveError.invalid }
            let target = destination.map { $0.advanced(by: offset) } ?? scratch
            try data.withUnsafeBytes { source in
                guard let address = source.baseAddress else { throw ArchiveError.invalid }
                if block.compressed {
                    let decoded = compression_decode_buffer(target.assumingMemoryBound(to: UInt8.self), block.bytes,
                        address.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_LZFSE)
                    guard decoded == block.bytes else { throw ArchiveError.invalid }
                } else {
                    guard data.count == block.bytes else { throw ArchiveError.invalid }
                    target.copyMemory(from: address, byteCount: block.bytes)
                }
            }
            if let layout { try DioramaArchiveCodec.decodeInPlace(target, bytes: block.bytes, layout: layout) }
            try sink?(UnsafeRawBufferPointer(start: target, count: block.bytes), offset)
            offset += block.bytes
        }
        guard offset == s.bytes else { throw ArchiveError.invalid }
    }

    private static func smallSection<T>(_ m: Manifest, _ name: String, directory: URL, scratch: UnsafeMutableRawPointer, default value: T) throws -> [T] {
        guard let s = m.sections.first(where: { $0.name == name }), s.bytes % MemoryLayout<T>.stride == 0 else { throw ArchiveError.invalid }
        var values = Array(repeating: value, count: s.bytes / MemoryLayout<T>.stride)
        try values.withUnsafeMutableBytes { output in
            guard let base = output.baseAddress ?? (s.bytes == 0 ? scratch : nil) else { throw ArchiveError.invalid }
            try decode(s, name: name, directory: directory, into: base, scratch: scratch, format: m.format)
        }
        return values
    }

    private static func buffer(_ device: MTLDevice, bytes: Int) throws -> MTLBuffer {
        // Metal rejects zero-length buffers.
        guard let b = device.makeBuffer(length: max(bytes, 16), options: .storageModeShared) else { throw ArchiveError.invalid }
        return b
    }

    /// Reads a saved package straight into shared Metal storage. Applies a previously verified r3
    /// sidecar, legacy material tags and Airtel ownership in place, with only one 4 MiB scratch block.
    static func readResident(from directory: URL, key: String, manifest m: Manifest, device: MTLDevice,
                             patch: DioramaVisualPatch?, origin: CLLocationCoordinate2D, materialsPrepared: Bool = false,
                             landmarks: [DioramaLandmarkBake] = [], roofs: Bool = true) throws -> DioramaResidentTile {
        let landmarks = materialsPrepared ? [] : landmarks
        let fitsRoofs = roofs && !materialsPrepared
        guard let sVertices = m.sections.first(where: { $0.name == "vertices" }),
              let sIndices = m.sections.first(where: { $0.name == "indices" }),
              let sGround = m.sections.first(where: { $0.name == "ground" }),
              m.vertexStride > 0, sVertices.bytes % m.vertexStride == 0, sIndices.bytes % 4 == 0 else { throw ArchiveError.invalid }
        let baseVertexCount = sVertices.bytes / m.vertexStride
        // Compact packages carry analytic finish layers over a smaller raster (see DioramaGroundPainter).
        let compact = m.format >= format
        let baseIndexCount = sIndices.bytes / 4
        guard baseIndexCount % 3 == 0 else { throw ArchiveError.invalid }
        let scratchPointer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { scratchPointer.deallocate() }

        // Indices (plus r3 additions and retained triangles of edited ranges) go straight to Metal.
        let baseRanges = baseRanges(m)
        func validRange(_ start: Int, _ count: Int) -> Bool { start >= 0 && count >= 0 && start <= baseIndexCount && count <= baseIndexCount - start && count % 3 == 0 }
        guard baseRanges.allSatisfy({ validRange($0.start, $0.count) }) else { throw ArchiveError.invalid }
        let removed = Set(patch?.metadata.removedTriangles ?? [])
        let affected = baseRanges.filter { range in
            range.category == .buildings && !removed.isEmpty
                && stride(from: range.start, to: range.start + range.count, by: 3).contains { removed.contains($0) }
        }
        let additions = patch?.additions
        let addVertexCount = additions?.vertices.count ?? 0
        let vertexCount = baseVertexCount + addVertexCount
        let additionIndexCount: Int = additions?.indices.count ?? 0
        let affectedIndexCount: Int = affected.reduce(0) { $0 + $1.count }
        let capacity: Int = baseIndexCount + additionIndexCount + affectedIndexCount
        var indexBuffer = try buffer(device, bytes: capacity * 4)
        try decode(sIndices, name: "indices", directory: directory, into: indexBuffer.contents(), scratch: scratchPointer, format: m.format)
        var idx = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<baseIndexCount where Int(idx[i]) >= baseVertexCount { throw ArchiveError.invalid }
        var indexCount = baseIndexCount
        var ranges: [DioramaRenderLayer.Range] = []
        for range in baseRanges {
            guard affected.contains(where: { $0.start == range.start && $0.count == range.count }) else { ranges.append(range); continue }
            let start = indexCount
            for index in stride(from: range.start, to: range.start + range.count, by: 3) where !removed.contains(index) {
                idx[indexCount] = idx[index]; idx[indexCount + 1] = idx[index + 1]; idx[indexCount + 2] = idx[index + 2]
                indexCount += 3
            }
            if indexCount > start {
                ranges.append(.init(category: range.category, start: start, count: indexCount - start,
                    minimum: range.minimum, maximum: range.maximum, doubleSided: range.doubleSided))
            }
        }
        // Additions are appended after the retained copies; their ranges are offset accordingly.
        let additionOffset = indexCount
        if let additions {
            for i in additions.indices { idx[indexCount] = i + UInt32(baseVertexCount); indexCount += 1 }
            ranges.append(contentsOf: additions.ranges.map {
                .init(category: $0.category, start: $0.start + additionOffset, count: $0.count,
                      minimum: $0.minimum, maximum: $0.maximum, doubleSided: $0.doubleSided)
            })
        }

        // Placements (small) stay on CPU for culling; one shared GPU copy for drawing.
        let rawInstances = try smallSection(m, "instances", directory: directory, scratch: scratchPointer, default: DioramaInstanceData.identity)
        var groups: [DioramaInstanceGroup] = try m.groups.map {
            guard validRange($0.fullStart, $0.fullCount), validRange($0.lightStart, $0.lightCount),
                  $0.first >= 0, $0.count >= 0, $0.first <= rawInstances.count, $0.count <= rawInstances.count - $0.first else { throw ArchiveError.invalid }
            return .init(category: $0.category, fullStart: $0.fullStart, fullCount: $0.fullCount, lightStart: $0.lightStart,
                lightCount: $0.lightCount, doubleSided: $0.doubleSided, instances: Array(rawInstances[$0.first..<($0.first + $0.count)]),
                firstInstance: $0.first, minimum: $0.minimum, maximum: $0.maximum)
        }
        var instances = rawInstances
        if let patch {
            // Tree prototypes are offset relative to the additions' first index.
            let patched = patch.patchedGroups(groups, indexOffset: additionOffset)
            groups = patched.0; instances = patched.1
        }

        // Landmark ownership needs positions; tag flags need final ranges. Flags first.
        let flags = materialsPrepared ? [] : DioramaLegacyFoliageMaterial.flags(indices: UnsafeBufferPointer(start: idx, count: indexCount),
                                                       vertexCount: vertexCount, ranges: ranges, groups: groups)
        let landmarkVertices = landmarks.reduce(0) { $0 + $1.geometry.vertices.count }
        // Spare capacity for read-time framed roofs (60–200 vertices each) and the mapped-planting prototypes.
        let roofReserve = fitsRoofs ? roofReserveVertices(vertexCount) : 0
        let plantingVertices = fitsRoofs ? DioramaVegetation.vertexCount : 0
        let vertexBuffer = try buffer(device, bytes: (vertexCount + landmarkVertices + roofReserve + plantingVertices) * MemoryLayout<DioramaPackedVertex>.stride)
        let packed = vertexBuffer.contents().assumingMemoryBound(to: DioramaPackedVertex.self)
        var poolLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude), poolHigh = -poolLow
        var shadowLow = poolLow, shadowHigh = -poolLow
        var foliage = 0, architecture = 0
        func pack(_ source: BuildingRenderVertex, at i: Int) {
            var v = source
            let p = SIMD3(v.position.x, v.position.y, v.position.z)
            if v.appearance.y > 4.5 && v.appearance.y < 5.5 && v.appearance.w < 0.5 { poolLow = simd_min(poolLow, p); poolHigh = simd_max(poolHigh, p) }
            if v.appearance.w < 3.5, p.x.isFinite, p.y.isFinite, p.z.isFinite { shadowLow = simd_min(shadowLow, p); shadowHigh = simd_max(shadowHigh, p) }
            let material = materialsPrepared ? 0 : DioramaLegacyFoliageMaterial.tag(&v, flags: flags[i])
            if material == 10 { foliage += 1 } else if material > 0 { architecture += 1 }
            packed[i] = DioramaPackedVertex(v)
        }
        let vertexStride = m.vertexStride
        try decode(sVertices, name: "vertices", directory: directory, into: nil, scratch: scratchPointer, format: m.format) { block, offset in
            guard block.count % vertexStride == 0, offset % vertexStride == 0 else { throw ArchiveError.invalid }
            let first = offset / vertexStride
            let source: [BuildingRenderVertex] = compact
                ? block.bindMemory(to: DioramaArchiveVertex.self).map(\.vertex)
                : Array(block.bindMemory(to: BuildingRenderVertex.self))
            for (i, v) in source.enumerated() {
                if materialsPrepared {
                    guard [v.position.x, v.position.y, v.position.z, v.position.w, v.normal.x, v.normal.y, v.normal.z,
                           v.color.x, v.color.y, v.color.z, v.color.w, v.appearance.x, v.appearance.y, v.appearance.z, v.appearance.w].allSatisfy(\.isFinite) else { throw ArchiveError.invalid }
                }
                pack(v, at: first + i)
            }
        }
        if let additions { for (i, v) in additions.vertices.enumerated() { pack(v, at: baseVertexCount + i) } }

        // Bespoke Airtel ownership: rare; reallocate only when the footprint is actually touched.
        if !materialsPrepared, let split = DioramaLandmarkOwnership.partition(indexCount: indexCount, index: { idx[$0] }, position: { packed[$0].position },
                                                          ranges: ranges, groups: groups, origin: origin) {
            let grown = try buffer(device, bytes: (indexCount + split.appended.count) * 4)
            grown.contents().copyMemory(from: indexBuffer.contents(), byteCount: indexCount * 4)
            let target = grown.contents().assumingMemoryBound(to: UInt32.self)
            for (i, value) in split.appended.enumerated() { target[indexCount + i] = value }
            indexCount += split.appended.count
            indexBuffer = grown; idx = target
            ranges = split.ranges; groups = split.groups
        }

        // Ground: decoded rows go straight into a mipmapped texture.
        var groundTexture: MTLTexture?
        guard sGround.bytes == m.imageSize * m.imageSize * 4 else { throw ArchiveError.invalid }
        if m.imageSize > 0 {
            let size = m.imageSize, rowBytes = size * 4
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true)
            descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw ArchiveError.invalid }
            var carry = [UInt8](); carry.reserveCapacity(rowBytes)
            var row = 0
            try decode(sGround, name: "ground", directory: directory, into: nil, scratch: scratchPointer, format: m.format) { block, _ in
                var cursor = 0
                if !carry.isEmpty {
                    let take = min(rowBytes - carry.count, block.count)
                    carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: block[0..<take]))
                    cursor = take
                    if carry.count == rowBytes {
                        carry.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, row, size, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rowBytes) }
                        row += 1; carry.removeAll(keepingCapacity: true)
                    }
                }
                let rows = (block.count - cursor) / rowBytes
                if rows > 0, let base = block.baseAddress {
                    texture.replace(region: MTLRegionMake2D(0, row, size, rows), mipmapLevel: 0, withBytes: base.advanced(by: cursor), bytesPerRow: rowBytes)
                    row += rows; cursor += rows * rowBytes
                }
                if cursor < block.count { carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: block[cursor..<block.count])) }
            }
            guard row == size, carry.isEmpty else { throw ArchiveError.invalid }
            if let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: texture); blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            }
            groundTexture = texture
        }

        // Paint goes straight to Metal; tables are validated through the shared view.
        func rawBuffer(_ name: String, stride: Int) throws -> (MTLBuffer, Int) {
            guard let s = m.sections.first(where: { $0.name == name }), s.bytes % stride == 0 else { throw ArchiveError.invalid }
            let b = try buffer(device, bytes: s.bytes)
            try decode(s, name: name, directory: directory, into: b.contents(), scratch: scratchPointer, format: m.format)
            return (b, s.bytes / stride)
        }
        let (paintBuffer, paintCount) = try rawBuffer("paint", stride: MemoryLayout<DioramaPaintTriangle>.stride)
        let (paintTableBuffer, paintTableCount) = try rawBuffer("paintTable", stride: MemoryLayout<SIMD2<UInt32>>.stride)
        let (paintIndexBuffer, paintIndexCount) = try rawBuffer("paintIndices", stride: 4)
        let paintTable = paintTableBuffer.contents().assumingMemoryBound(to: SIMD2<UInt32>.self)
        let paintIndices = paintIndexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        guard m.imageSize == 0 || paintTableCount == DioramaVectorPaint.cells * DioramaVectorPaint.cells else { throw ArchiveError.invalid }
        for i in 0..<paintIndexCount where Int(paintIndices[i]) >= paintCount { throw ArchiveError.invalid }
        for i in 0..<paintTableCount {
            let t = paintTable[i]
            guard Int(t.x) <= paintIndexCount, Int(t.y) <= paintIndexCount - Int(t.x) else { throw ArchiveError.invalid }
        }

        let lights = try smallSection(m, "lights", directory: directory, scratch: scratchPointer, default: DioramaShaderLight(position: .zero, color: .zero))
        let lightTable = try smallSection(m, "lightTable", directory: directory, scratch: scratchPointer, default: SIMD2<UInt32>.zero)
        let lightIndices = try smallSection(m, "lightIndices", directory: directory, scratch: scratchPointer, default: UInt32(0))
        guard lightTable.count == m.lightCells * m.lightCells, lightIndices.allSatisfy({ Int($0) < lights.count }),
              lightTable.allSatisfy({ Int($0.x) <= lightIndices.count && Int($0.y) <= lightIndices.count - Int($0.x) }) else { throw ArchiveError.invalid }
        var grid = DioramaLightGrid(cells: m.lightCells, minX: m.lightMinX, minY: m.lightMinY, cellSize: m.lightCellSize,
                                    lights: lights, table: lightTable, indices: lightIndices)

        var report = m.optimizationReport
        if let patch { report.append(patch.report) }
        // LOD validates the original saved layout, so it is matched before landmarks are added.
        let lod = DioramaLODStore.load(package: directory, patched: patch != nil, device: device, vertexCount: vertexCount,
                                       indexCount: indexCount, ranges: &ranges, groups: &groups)
        if let lod, let metadata = DioramaLODStore.sidecar(for: directory, patched: patch != nil).flatMap(DioramaLODStore.readMetadata) {
            report.append(metadata.report + " · \(lod.bytes / 1_048_576) MiB")
        } else { report.append("Pixel-error LOD: not optimized yet · full detail at every distance") }
        // Bougainvillea blobs on compound walls read as meaningless pink/orange lumps: drop them.
        let removedFlowers = removeBougainvillea(&groups, index: idx, packed: packed, vertexCount: vertexCount)
        if removedFlowers > 0 { report.append("Wall bougainvillea removed: \(removedFlowers) placements") }
        let painted = DioramaHalf.bits(9)
        let tileRect = DioramaProjection(origin: origin).rect(of: .init(z: m.z, x: m.x, y: m.y))
        let groundMaterials: DioramaGroundMaterialLookup? = fitsRoofs ? groundTexture.map {
            DioramaGroundMaterialLookup(texture: $0, rect: tileRect, paint: paintBuffer, paintCount: paintCount,
                                        table: paintTableBuffer, tableCount: paintTableCount, indices: paintIndexBuffer, indexCount: paintIndexCount)
        } : nil

        // Bespoke landmarks are drawn by this tile, exactly like Slipway and Sea Cliff: the generic saved
        // shell under each footprint is dropped for as long as the tile is resident, and the designed
        // model joins the same buffers, lighting, shadows, reveal and lifecycle. Original bytes untouched.
        var finalVertexCount = vertexCount
        var landmarkRanges: [DioramaRenderLayer.Range] = []
        var landmarkLights: [DioramaShaderLight] = []
        var groundIndex: DioramaGroundIndex?
        if !landmarks.isEmpty {
            let owned = Set(landmarks.map(\.id))
            ranges.removeAll { $0.landmarkPlaceholder && owned.contains($0.landmarkID ?? "") }
            groups.removeAll { $0.landmarkPlaceholder && owned.contains($0.landmarkID ?? "") }
            groundIndex = DioramaGroundIndex(rect: tileRect, ranges: ranges, index: { idx[$0] }, position: { packed[$0].position },
                                             isGround: { packed[$0].color.w == painted })
            var ground = DioramaCameraGround()
            let projection = DioramaProjection(origin: origin)
            let clip = tileRect.expanded(by: 0.5)
            var appended: [UInt32] = []
            for mesh in landmarks {
                let g = mesh.geometry
                let offset = projection.local(longitude: mesh.origin.longitude, latitude: mesh.origin.latitude)
                let floor = DioramaBakedLandmarks.shared.floor(for: mesh.id) {
                    guard let support = groundIndex else { return nil }
                    return (mesh.floorRing + [DV2(0, 0)]).compactMap { p -> Double? in
                        let q = DV2(p.x + offset.x, p.y + offset.y)
                        guard tileRect.contains(q) else { return nil }
                        return ground.height(q, grid: support, index: { idx[$0] }, position: { packed[$0].position })
                    }.max()
                }
                let move = SIMD3<Float>(Float(offset.x), Float(offset.y), Float(floor))
                // Extend only the skyline foundation's lower perimeter to the lowest sampled
                // saved terrain. This keeps a level occupied floor without floating over slopes.
                var foundationBottom = Float(floor - 0.3)
                if DarSkyline.isSkyline(mesh.id), let support = groundIndex, mesh.floorRing.count >= 3 {
                    for edge in mesh.floorRing.indices {
                        let a = mesh.floorRing[edge], b = mesh.floorRing[(edge + 1) % mesh.floorRing.count]
                        let steps = max(1, Int(ceil(a.distance(to: b) / 4)))
                        for step in 0...steps {
                            let p = a + (b - a) * (Double(step) / Double(steps)) + offset
                            guard tileRect.contains(p), let z = ground.height(p, grid: support,
                                index: { idx[$0] }, position: { packed[$0].position }) else { continue }
                            foundationBottom = min(foundationBottom, Float(z - 0.25))
                        }
                    }
                }
                let base = finalVertexCount
                var moved: [SIMD3<Float>] = []
                moved.reserveCapacity(g.vertices.count)
                for (i, v) in g.vertices.enumerated() {
                    var p = SIMD3(v.position.x, v.position.y, v.position.z) + move
                    if DarSkyline.isSkyline(mesh.id), v.position.z <= -0.299 { p.z = foundationBottom }
                    moved.append(p)
                    if v.appearance.y > 4.5 && v.appearance.y < 5.5 && v.appearance.w < 0.5 { poolLow = simd_min(poolLow, p); poolHigh = simd_max(poolHigh, p) }
                    if v.appearance.w < 3.5, p.x.isFinite, p.y.isFinite, p.z.isFinite { shadowLow = simd_min(shadowLow, p); shadowHigh = simd_max(shadowHigh, p) }
                    packed[base + i] = DioramaPackedVertex(BuildingRenderVertex(position: SIMD4(p.x, p.y, p.z, v.position.w),
                        normal: v.normal, color: v.color, appearance: v.appearance))
                }
                for r in g.ranges {
                    let start = indexCount + appended.count
                    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                    for t in Swift.stride(from: r.start, to: r.start + r.count - 2, by: 3) {
                        let a = Int(g.indices[t]), b = Int(g.indices[t + 1]), c = Int(g.indices[t + 2])
                        let pa = moved[a], pb = moved[b], pc = moved[c]
                        let tlo = simd_min(simd_min(pa, pb), pc), thi = simd_max(simd_max(pa, pb), pc)
                        // Triangles reaching a neighbour are drawn by both tiles; each clips to its own square.
                        guard Double(tlo.x) <= clip.maxX, Double(thi.x) >= clip.minX, Double(tlo.y) <= clip.maxY, Double(thi.y) >= clip.minY else { continue }
                        appended.append(contentsOf: [UInt32(base + a), UInt32(base + b), UInt32(base + c)])
                        lo = simd_min(lo, tlo); hi = simd_max(hi, thi)
                    }
                    let count = indexCount + appended.count - start
                    if count > 0 {
                        landmarkRanges.append(.init(category: r.category, start: start, count: count, minimum: lo, maximum: hi,
                                                    doubleSided: r.doubleSided, translucent: r.translucent))
                    }
                }
                for l in g.lights {
                    let p = SIMD3(Float(l.position.x), Float(l.position.y), Float(l.position.z)) + move
                    guard tileRect.contains(DV2(Double(p.x), Double(p.y))) else { continue }
                    landmarkLights.append(DioramaShaderLight(position: SIMD4(p, Float(l.radius)), color: SIMD4(l.color, l.intensity)))
                }
                finalVertexCount += g.vertices.count
            }
            if !appended.isEmpty {
                let grown = try buffer(device, bytes: (indexCount + appended.count) * 4)
                grown.contents().copyMemory(from: indexBuffer.contents(), byteCount: indexCount * 4)
                let target = grown.contents().assumingMemoryBound(to: UInt32.self)
                for (i, value) in appended.enumerated() { target[indexCount + i] = value }
                indexCount += appended.count
                indexBuffer = grown; idx = target
            }
            grid = grid.merging(landmarkLights)
            report.append("Bespoke landmarks drawn by this tile: \(owned.sorted().joined(separator: ", ")) · \(appended.count / 3) triangles")
            print("[DarLandmarks] tile \(m.z)-\(m.x)-\(m.y) draws \(owned.sorted().joined(separator: ",")) (\(appended.count / 3) triangles, saved shells owned)")
        } else {
            groundIndex = DioramaGroundIndex(rect: tileRect, ranges: ranges, index: { idx[$0] }, position: { packed[$0].position },
                                             isGround: { packed[$0].color.w == painted })
        }
        // Flat saved decks on low-rise buildings get a pitched roof fitted to their outline.
        if fitsRoofs {
            try Task.checkCancellation()
            let started = Date()
            // Estate pass queries: painted ground material and saved terrain height.
            var estate: DioramaEstate.Context?
            if let materials = groundMaterials, let support = groundIndex {
                // Material codes resampled once onto a 1 m grid.
                let gx = max(1, Int(ceil(tileRect.width))), gy = max(1, Int(ceil(tileRect.height)))
                var codes = [UInt8](repeating: 255, count: gx * gy)
                for cy in 0..<gy {
                    for cx in 0..<gx {
                        let p = DV2(tileRect.minX + (Double(cx) + 0.5) / Double(gx) * tileRect.width,
                                    tileRect.minY + (Double(cy) + 0.5) / Double(gy) * tileRect.height)
                        codes[cy * gx + cx] = UInt8(clamping: materials.code(p) ?? 255)
                    }
                }
                var heights = DioramaCameraGround()
                let index = idx
                estate = DioramaEstate.Context(
                    material: { p in
                        let x = Int(floor((p.x - tileRect.minX) / tileRect.width * Double(gx))), y = Int(floor((p.y - tileRect.minY) / tileRect.height * Double(gy)))
                        guard x >= 0, y >= 0, x < gx, y < gy else { return nil }
                        return Int(codes[y * gx + x])
                    },
                    ground: { p in heights.height(p, grid: support, index: { index[$0] }, position: { packed[$0].position }) },
                    sites: DioramaEstate.sites(projection: DioramaProjection(origin: origin)), waterHeight: m.waterHeight)
            }
            if let roofs = DioramaRoofRetrofit.build(packed: packed, vertexCount: finalVertexCount, index: idx, ranges: ranges,
                                                     tileRect: tileRect, vertexBudget: roofReserve, estate: estate), !roofs.indices.isEmpty {
                for (i, v) in roofs.vertices.enumerated() {
                    packed[finalVertexCount + i] = v
                    let p = SIMD3(v.position.x, v.position.y, v.position.z)
                    shadowLow = simd_min(shadowLow, p); shadowHigh = simd_max(shadowHigh, p)
                }
                let grown = try buffer(device, bytes: (indexCount + roofs.indices.count) * 4)
                grown.contents().copyMemory(from: indexBuffer.contents(), byteCount: indexCount * 4)
                let target = grown.contents().assumingMemoryBound(to: UInt32.self)
                for (i, value) in roofs.indices.enumerated() { target[indexCount + i] = value + UInt32(finalVertexCount) }
                for r in roofs.ranges {
                    ranges.append(.init(category: r.category, start: r.start + indexCount, count: r.count,
                                        minimum: r.minimum, maximum: r.maximum, doubleSided: r.doubleSided))
                }
                indexCount += roofs.indices.count
                indexBuffer = grown; idx = target
                finalVertexCount += roofs.vertices.count
                let seconds = Date().timeIntervalSince(started)
                report.append(roofs.report + " · " + String(format: "%.2f", seconds) + "s")
            }
        }
        // Mapped planting from OpenStreetMap: trees where they stand, woodland, bush, scrub, gardens.
        if fitsRoofs, let groundMaterials, let support = groundIndex {
            try Task.checkCancellation()
            let started = Date()
            // Compact packages: HD paints 1024 px, coarse 512 px. Older packages: 4096/2048.
            let planted = plant(tileRect: tileRect, origin: origin, coarse: m.imageSize < (compact ? 1024 : 2048), materials: groundMaterials, support: support,
                                packed: packed, index: idx, ranges: ranges, groups: groups, baseVertex: finalVertexCount,
                                indexOffset: indexCount, firstInstance: instances.count, waterHeight: m.waterHeight)
            if !planted.groups.isEmpty {
                let grown = try buffer(device, bytes: (indexCount + planted.indices.count) * 4)
                grown.contents().copyMemory(from: indexBuffer.contents(), byteCount: indexCount * 4)
                let target = grown.contents().assumingMemoryBound(to: UInt32.self)
                for (i, value) in planted.indices.enumerated() { target[indexCount + i] = value }
                indexCount += planted.indices.count
                indexBuffer = grown; idx = target
                finalVertexCount += planted.vertexCount
                instances.append(contentsOf: planted.instances)
                groups.append(contentsOf: planted.groups)
                report.append("Mapped planting (OSM): \(planted.instances.count) trees and shrubs · " + String(format: "%.2f", Date().timeIntervalSince(started)) + "s")
            }
        }
        let instanceBuffer = try buffer(device, bytes: max(instances.count, 1) * MemoryLayout<DioramaInstanceData>.stride)
        instances.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { instanceBuffer.contents().copyMemory(from: base, byteCount: bytes.count) }
        }
        for i in instances { shadowLow = simd_min(shadowLow, i.centre - SIMD3(repeating: i.radius)); shadowHigh = simd_max(shadowHigh, i.centre + SIMD3(repeating: i.radius)) }
        // Landmark plinths never become vehicle/route support: the ground index covers saved terrain only.
        ranges.append(contentsOf: landmarkRanges)
        let pool = poolLow.x <= poolHigh.x ? DioramaRenderLayer.Range(category: .water, start: 0, count: 0, minimum: poolLow, maximum: poolHigh) : nil
        let shadow = shadowLow.x.isFinite && shadowHigh.x > shadowLow.x ? (shadowLow, shadowHigh) : nil
        let summary = DioramaTileSummary(shorelineReport: m.shorelineReport, optimizationReport: report, stageTimings: m.stageTimings,
            totalTriangles: indexCount / 3, totalInstances: instances.count,
            totalBytes: finalVertexCount * MemoryLayout<DioramaPackedVertex>.stride + indexCount * 4, generationSeconds: m.generationSeconds)
        let landmarkSlots = Set((ranges.count - landmarkRanges.count)..<ranges.count)
        let resident = DioramaResidentTile(tile: .init(z: m.z, x: m.x, y: m.y), device: device, vertexBuffer: vertexBuffer, vertexCount: finalVertexCount,
            indexBuffer: indexBuffer, indexCount: indexCount, instanceBuffer: instanceBuffer, instanceCount: instances.count,
            ranges: ranges, groups: groups, lightGrid: grid, paintBuffer: paintBuffer, paintTableBuffer: paintTableBuffer,
            paintIndexBuffer: paintIndexBuffer, groundTexture: groundTexture, waterHeight: m.waterHeight,
            labels: m.labels.map { .init(id: $0.id, title: $0.title, anchor: $0.anchor, footprint: $0.footprint.map { DV2($0.x, $0.y) }, isNamed: $0.isNamed) },
            poolBounds: pool, shadowBounds: shadow, materialCounts: SIMD2(foliage, architecture), summary: summary, lod: lod, groundIndex: groundIndex)
        // Tile-drawn landmarks and skyline towers previously drew full detail at every distance and in
        // every pass (shadow, reflection, AO); give them the same measured pixel-error levels.
        guard !landmarkSlots.isEmpty else { return resident }
        try Task.checkCancellation()
        return DioramaLODBuilder.completing(resident, ranges: landmarkSlots, groups: false)
    }

    /// Same formula the admission estimate uses (`DioramaResidencyBudget`).
    static func roofReserveVertices(_ vertexCount: Int) -> Int { min(max(vertexCount / 6, 160_000), 900_000) }

    /// Removes instance groups whose prototype is a bougainvillea blob (identified by its flower pigment).
    fileprivate static func removeBougainvillea(_ groups: inout [DioramaInstanceGroup], index: UnsafePointer<UInt32>,
                                                packed: UnsafeMutablePointer<DioramaPackedVertex>, vertexCount: Int) -> Int {
        let flowers: [SIMD3<Float>] = [
            SIMD3<Float>(200, 51, 126) / 255,
            SIMD3<Float>(240, 124, 58) / 255,
        ]
        var removed = 0
        groups.removeAll { group in
            guard group.category == .vegetation, group.fullCount > 0 else { return false }
            var matches = 0, total = 0
            for i in group.fullStart..<(group.fullStart + min(group.fullCount, 900)) {
                let v = Int(index[i])
                guard v < vertexCount else { continue }
                let c = packed[v].color
                let rgb = SIMD3(DioramaHalf.float(c.x), DioramaHalf.float(c.y), DioramaHalf.float(c.z))
                total += 1
                if flowers.contains(where: { simd_length($0 - rgb) < 0.03 }) { matches += 1 }
            }
            let drop = total > 0 && Double(matches) / Double(total) > 0.3
            if drop { removed += group.instances.count }
            return drop
        }
        return removed
    }

    fileprivate struct Planting {
        var vertexCount = 0
        var indices: [UInt32] = []
        var instances: [DioramaInstanceData] = []
        var groups: [DioramaInstanceGroup] = []
    }

    /// Appends the shared planting prototypes and OSM-driven placements (see `DioramaVegetation`).
    fileprivate static func plant(tileRect: DioramaRect, origin: CLLocationCoordinate2D, coarse: Bool, materials: DioramaGroundMaterialLookup,
                                  support: DioramaGroundIndex, packed: UnsafeMutablePointer<DioramaPackedVertex>,
                                  index: UnsafeMutablePointer<UInt32>, ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup],
                                  baseVertex: Int, indexOffset: Int, firstInstance: Int, waterHeight: Double) -> Planting {
        // 1 m occupancy of buildings and walls (triangle bounds), so stems never stand in either.
        let grid = tileRect.expanded(by: 2)
        let columns = Int(ceil(grid.width)), rows = Int(ceil(grid.height))
        guard columns > 0, rows > 0, columns * rows < 2_000_000 else { return Planting() }
        var solid = [Bool](repeating: false, count: columns * rows)
        for range in ranges where (range.category == .buildings || range.category == .walls) && !range.translucent {
            for t in Swift.stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                let a = packed[Int(index[t])].position, b = packed[Int(index[t + 1])].position, c = packed[Int(index[t + 2])].position
                let x0 = Int(floor(Double(min(a.x, b.x, c.x)) - grid.minX)), x1 = Int(floor(Double(max(a.x, b.x, c.x)) - grid.minX))
                let y0 = Int(floor(Double(min(a.y, b.y, c.y)) - grid.minY)), y1 = Int(floor(Double(max(a.y, b.y, c.y)) - grid.minY))
                guard x1 >= 0, y1 >= 0, x0 < columns, y0 < rows, x1 - x0 < 80, y1 - y0 < 80 else { continue }
                for y in max(0, y0)...min(rows - 1, y1) { for x in max(0, x0)...min(columns - 1, x1) { solid[y * columns + x] = true } }
            }
        }
        func blocked(_ p: DV2, _ clearance: Int) -> Bool {
            let cx = Int(floor(p.x - grid.minX)), cy = Int(floor(p.y - grid.minY))
            for y in (cy - clearance)...(cy + clearance) { for x in (cx - clearance)...(cx + clearance) {
                guard x >= 0, y >= 0, x < columns, y < rows else { return true }
                if solid[y * columns + x] { return true }
            } }
            return false
        }
        // Existing saved trees (4 m cells).
        var existing: [Int64: [DV2]] = [:]
        func key(_ x: Int64, _ y: Int64) -> Int64 { (x << 32) ^ (y & 0xFFFF_FFFF) }
        for group in groups where group.category == .vegetation {
            for i in group.instances where i.radius > 1.5 {
                let p = DV2(Double(i.placement.x), Double(i.placement.y))
                existing[key(Int64(floor(p.x / 4)), Int64(floor(p.y / 4))), default: []].append(p)
            }
        }
        func occupied(_ p: DV2, _ radius: Double) -> Bool {
            let cx = Int64(floor(p.x / 4)), cy = Int64(floor(p.y / 4))
            for dy in -1...1 { for dx in -1...1 {
                if (existing[key(cx + Int64(dx), cy + Int64(dy))] ?? []).contains(where: { $0.distance(to: p) < radius }) { return true }
            } }
            return false
        }
        func material(_ p: DV2) -> Int? { materials.code(p) }
        var heights = DioramaCameraGround()
        func ground(_ p: DV2, _ tree: Bool) -> Double? {
            guard !blocked(p, tree ? 1 : 0) else { return nil }
            // Natural ground only: grass or worn soil. Never roads, paving, sand, golf turf, clay or water.
            for probe in tree ? [p, p + DV2(0.9, 0), p - DV2(0.9, 0), p + DV2(0, 0.9), p - DV2(0, 0.9)] : [p] {
                guard let m = material(probe), m == 1 || m == 6 else { return nil }
            }
            guard let z = heights.height(p, grid: support, index: { index[$0] }, position: { packed[$0].position }),
                  z > waterHeight + 0.25 else { return nil }
            return z
        }
        let projection = DioramaProjection(origin: origin)
        let placements = DioramaVegetation.placements(tile: tileRect, projection: projection, bushes: !coarse,
                                                      limit: coarse ? 4_000 : 14_000, ground: ground, occupied: occupied)
        guard !placements.isEmpty else { return Planting() }

        var out = Planting()
        // Prototype geometry: appended once, each kind's full and light index spans recorded.
        var spans: [(full: (Int, Int), light: (Int, Int))] = []
        var vertexCursor = baseVertex
        for prototype in DioramaVegetation.prototypes {
            for (i, v) in prototype.vertices.enumerated() { packed[vertexCursor + i] = v }
            let base = UInt32(vertexCursor)
            let fullStart = indexOffset + out.indices.count
            out.indices.append(contentsOf: prototype.full.map { $0 + base })
            let lightStart = indexOffset + out.indices.count
            out.indices.append(contentsOf: prototype.light.map { $0 + base })
            spans.append(((fullStart, prototype.full.count), (lightStart, prototype.light.count)))
            vertexCursor += prototype.vertices.count
        }
        out.vertexCount = vertexCursor - baseVertex
        // One group per kind and 60 m bin, so distant bins cull.
        var binned: [Int: [Int: [DioramaInstanceData]]] = [:]
        for p in placements {
            let bin = Int(floor(p.data.placement.x / 60)) + Int(floor(p.data.placement.y / 60)) * 10_000
            binned[p.kind.rawValue, default: [:]][bin, default: []].append(p.data)
        }
        for kind in binned.keys.sorted() {
            guard let bins = binned[kind] else { continue }
            for bin in bins.keys.sorted() {
                guard let list = bins[bin], !list.isEmpty else { continue }
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                for item in list { lo = simd_min(lo, item.centre - SIMD3(repeating: item.radius)); hi = simd_max(hi, item.centre + SIMD3(repeating: item.radius)) }
                let span = spans[kind]
                out.groups.append(DioramaInstanceGroup(category: .vegetation, fullStart: span.full.0, fullCount: span.full.1,
                    lightStart: span.light.0, lightCount: span.light.1, doubleSided: false, instances: list,
                    firstInstance: firstInstance + out.instances.count, minimum: lo, maximum: hi))
                out.instances.append(contentsOf: list)
            }
        }
        return out
    }

}
