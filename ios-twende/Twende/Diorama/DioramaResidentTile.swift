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
    /// Metal allocations owned by this tile (shared storage; also the CPU view).
    let gpuBytes: Int
    /// CPU placement lists, labels and light grid.
    let cpuBytes: Int

    init(tile: DioramaTileID, device: MTLDevice, vertexBuffer: MTLBuffer, vertexCount: Int, indexBuffer: MTLBuffer, indexCount: Int,
         instanceBuffer: MTLBuffer, instanceCount: Int, ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup],
         lightGrid: DioramaLightGrid, paintBuffer: MTLBuffer, paintTableBuffer: MTLBuffer, paintIndexBuffer: MTLBuffer,
         groundTexture: MTLTexture?, waterHeight: Double, labels: [DioramaBuildingLabel], poolBounds: DioramaRenderLayer.Range?,
         shadowBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?, materialCounts: SIMD2<Int>, summary: DioramaTileSummary,
         lod: DioramaLODTable? = nil) {
        self.lod = lod
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
    }
    var totalTriangles: Int { indexCount / 3 }

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
        guard m.format == format, m.key == key, m.vertexStride == MemoryLayout<BuildingRenderVertex>.stride,
              m.instanceStride == MemoryLayout<DioramaInstanceData>.stride else { throw ArchiveError.incompatible }
        guard m.sections.count == 10, Set(m.sections.map(\.name)).count == 10,
              m.z >= 0, m.z <= 22, m.x >= 0, m.x < (1 << m.z), m.y >= 0, m.y < (1 << m.z),
              m.imageSize >= 0, m.imageSize <= 4096, m.lightCells > 0, m.lightCells <= 128,
              m.waterHeight.isFinite, m.lightCellSize.isFinite, m.lightCellSize > 0 else { throw ArchiveError.invalid }
        var budget = maxBytes
        for s in m.sections {
            guard s.bytes >= 0, s.bytes <= budget else { throw ArchiveError.invalid }
            budget -= s.bytes
        }
        return m
    }

    static func baseRanges(_ m: Manifest) -> [DioramaRenderLayer.Range] {
        m.ranges.map { .init(category: $0.category, start: $0.start, count: $0.count, minimum: $0.minimum, maximum: $0.maximum, doubleSided: $0.doubleSided) }
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
        return ResidentPlan(vertexCount: (sizes["vertices"] ?? 0) / MemoryLayout<BuildingRenderVertex>.stride + patchVertices,
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
                               scratch: UnsafeMutableRawPointer, sink: ((UnsafeRawBufferPointer, Int) throws -> Void)? = nil) throws {
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
            try decode(s, name: name, directory: directory, into: base, scratch: scratch)
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
                             patch: DioramaVisualPatch?, origin: CLLocationCoordinate2D) throws -> DioramaResidentTile {
        guard let sVertices = m.sections.first(where: { $0.name == "vertices" }),
              let sIndices = m.sections.first(where: { $0.name == "indices" }),
              let sGround = m.sections.first(where: { $0.name == "ground" }),
              sVertices.bytes % MemoryLayout<BuildingRenderVertex>.stride == 0, sIndices.bytes % 4 == 0 else { throw ArchiveError.invalid }
        let baseVertexCount = sVertices.bytes / MemoryLayout<BuildingRenderVertex>.stride
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
        let capacity = baseIndexCount + (additions?.indices.count ?? 0) + affected.reduce(0) { $0 + $1.count }
        var indexBuffer = try buffer(device, bytes: capacity * 4)
        try decode(sIndices, name: "indices", directory: directory, into: indexBuffer.contents(), scratch: scratchPointer)
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
        let flags = DioramaLegacyFoliageMaterial.flags(indices: UnsafeBufferPointer(start: idx, count: indexCount),
                                                       vertexCount: vertexCount, ranges: ranges, groups: groups)
        let vertexBuffer = try buffer(device, bytes: vertexCount * MemoryLayout<DioramaPackedVertex>.stride)
        let packed = vertexBuffer.contents().assumingMemoryBound(to: DioramaPackedVertex.self)
        var poolLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude), poolHigh = -poolLow
        var shadowLow = poolLow, shadowHigh = -poolLow
        var foliage = 0, architecture = 0
        func pack(_ source: BuildingRenderVertex, at i: Int) {
            var v = source
            let p = SIMD3(v.position.x, v.position.y, v.position.z)
            if v.appearance.y > 4.5 && v.appearance.y < 5.5 && v.appearance.w < 0.5 { poolLow = simd_min(poolLow, p); poolHigh = simd_max(poolHigh, p) }
            if v.appearance.w < 3.5, p.x.isFinite, p.y.isFinite, p.z.isFinite { shadowLow = simd_min(shadowLow, p); shadowHigh = simd_max(shadowHigh, p) }
            let material = DioramaLegacyFoliageMaterial.tag(&v, flags: flags[i])
            if material == 10 { foliage += 1 } else if material > 0 { architecture += 1 }
            packed[i] = DioramaPackedVertex(v)
        }
        let stride = MemoryLayout<BuildingRenderVertex>.stride
        try decode(sVertices, name: "vertices", directory: directory, into: nil, scratch: scratchPointer) { block, offset in
            guard block.count % stride == 0, offset % stride == 0 else { throw ArchiveError.invalid }
            let first = offset / stride
            let source = block.bindMemory(to: BuildingRenderVertex.self)
            for (i, v) in source.enumerated() { pack(v, at: first + i) }
        }
        if let additions { for (i, v) in additions.vertices.enumerated() { pack(v, at: baseVertexCount + i) } }

        // Bespoke Airtel ownership: rare; reallocate only when the footprint is actually touched.
        if let split = DioramaLandmarkOwnership.partition(indexCount: indexCount, index: { idx[$0] }, position: { packed[$0].position },
                                                          ranges: ranges, groups: groups, origin: origin) {
            let grown = try buffer(device, bytes: (indexCount + split.appended.count) * 4)
            grown.contents().copyMemory(from: indexBuffer.contents(), byteCount: indexCount * 4)
            let target = grown.contents().assumingMemoryBound(to: UInt32.self)
            for (i, value) in split.appended.enumerated() { target[indexCount + i] = value }
            indexCount += split.appended.count
            indexBuffer = grown; idx = target
            ranges = split.ranges; groups = split.groups
        }

        let instanceBuffer = try buffer(device, bytes: max(instances.count, 1) * MemoryLayout<DioramaInstanceData>.stride)
        instances.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { instanceBuffer.contents().copyMemory(from: base, byteCount: bytes.count) }
        }
        for i in instances { shadowLow = simd_min(shadowLow, i.centre - SIMD3(repeating: i.radius)); shadowHigh = simd_max(shadowHigh, i.centre + SIMD3(repeating: i.radius)) }

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
            try decode(sGround, name: "ground", directory: directory, into: nil, scratch: scratchPointer) { block, _ in
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
            try decode(s, name: name, directory: directory, into: b.contents(), scratch: scratchPointer)
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
        let grid = DioramaLightGrid(cells: m.lightCells, minX: m.lightMinX, minY: m.lightMinY, cellSize: m.lightCellSize,
                                    lights: lights, table: lightTable, indices: lightIndices)

        let pool = poolLow.x <= poolHigh.x ? DioramaRenderLayer.Range(category: .water, start: 0, count: 0, minimum: poolLow, maximum: poolHigh) : nil
        let shadow = shadowLow.x.isFinite && shadowHigh.x > shadowLow.x ? (shadowLow, shadowHigh) : nil
        var report = m.optimizationReport
        if let patch { report.append(patch.report) }
        let lod = DioramaLODStore.load(package: directory, patched: patch != nil, device: device, vertexCount: vertexCount,
                                       indexCount: indexCount, ranges: &ranges, groups: &groups)
        if let lod, let metadata = DioramaLODStore.sidecar(for: directory, patched: patch != nil).flatMap(DioramaLODStore.readMetadata) {
            report.append(metadata.report + " · \(lod.bytes / 1_048_576) MiB")
        } else { report.append("Pixel-error LOD: not optimized yet · full detail at every distance") }
        let summary = DioramaTileSummary(shorelineReport: m.shorelineReport, optimizationReport: report, stageTimings: m.stageTimings,
            totalTriangles: indexCount / 3, totalInstances: instances.count,
            totalBytes: vertexCount * MemoryLayout<DioramaPackedVertex>.stride + indexCount * 4, generationSeconds: m.generationSeconds)
        return DioramaResidentTile(tile: .init(z: m.z, x: m.x, y: m.y), device: device, vertexBuffer: vertexBuffer, vertexCount: vertexCount,
            indexBuffer: indexBuffer, indexCount: indexCount, instanceBuffer: instanceBuffer, instanceCount: instances.count,
            ranges: ranges, groups: groups, lightGrid: grid, paintBuffer: paintBuffer, paintTableBuffer: paintTableBuffer,
            paintIndexBuffer: paintIndexBuffer, groundTexture: groundTexture, waterHeight: m.waterHeight,
            labels: m.labels.map { .init(id: $0.id, title: $0.title, anchor: $0.anchor, footprint: $0.footprint.map { DV2($0.x, $0.y) }, isNamed: $0.isNamed) },
            poolBounds: pool, shadowBounds: shadow, materialCounts: SIMD2(foliage, architecture), summary: summary, lod: lod)
    }
}
