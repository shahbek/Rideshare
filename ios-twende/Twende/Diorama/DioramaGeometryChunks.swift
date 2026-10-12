import Foundation
import Metal

/// Packs already-culled, LOD-selected geometry into bounded submission chunks. Only indices and
/// placement records move; vertex attributes, triangle order and the saved packages stay untouched.
/// One cache is shared by every pass of a host, including coarse, HD, airport and landmark hosts.
nonisolated final class DioramaGeometryChunks: @unchecked Sendable {
    struct Statistics {
        var draws: Int = 0
        var inputDraws: Int = 0
        var triangles: Int = 0
        var copiedBytes: Int = 0
        var cacheHits: Int = 0
        var fallbackDraws: Int = 0

        mutating func add(_ other: Statistics) {
            draws += other.draws; inputDraws += other.inputDraws; triangles += other.triangles
            copiedBytes += other.copiedBytes; cacheHits += other.cacheHits; fallbackDraws += other.fallbackDraws
        }
    }

    private struct Source {
        let buffer: MTLBuffer
        let offset: Int
        let bytes: Int
    }

    private struct Span: Hashable {
        let buffer: ObjectIdentifier
        let offset: Int
        let bytes: Int
    }

    private struct Key: Hashable {
        let spans: [Span]
    }

    private final class Entry: @unchecked Sendable {
        let buffer: MTLBuffer
        var commands: Set<ObjectIdentifier> = []
        var age: UInt64 = 0
        init(_ buffer: MTLBuffer) { self.buffer = buffer }
    }

    private struct Slice {
        let buffer: MTLBuffer
        let offset: Int
        var copiedBytes: Int = 0
        var cacheHit: Bool = false
    }

    private let device: MTLDevice
    private let limit: Int
    private let lock = NSLock()
    private var cache: [Key: Entry] = [:]
    private var allocatedBytes: Int = 0
    private var age: UInt64 = 0
    private static let chunkBytes = 512 * 1024
    private static let maxSpans = 128
    private static let maxEntries = 128
    private static let maxReaders = 3

    /// Includes all cached/in-flight chunk buffers plus bounded keys, entries and planning scratch.
    /// This is an allowance, not an allocation: buffers are created only when a merge saves a draw.
    static func reservationBytes(context: Bool) -> Int {
        bufferLimit(context: context) + 1_048_576
    }

    private static func bufferLimit(context: Bool) -> Int { (context ? 2 : 8) * 1_048_576 }

    init(device: MTLDevice, context: Bool) {
        self.device = device
        limit = Self.bufferLimit(context: context)
    }

    /// Caller has already selected the pipeline/depth/blend state and exact ordered geometry.
    /// Never reorder ranges, even for opaque geometry: fractional reveal coverage also blends.
    @discardableResult
    func drawRanges(_ ranges: [DioramaRenderLayer.Range], encoder: MTLRenderCommandEncoder,
                    command: MTLCommandBuffer, indices: MTLBuffer, lodIndices: MTLBuffer?,
                    cull cullOverride: MTLCullMode? = nil) -> Statistics {
        var stats = Statistics()
        var pending: [DioramaRenderLayer.Range] = []
        var pendingBytes = 0
        var pendingCull: MTLCullMode = .back
        var currentCull: MTLCullMode?
        func setCull(_ mode: MTLCullMode) {
            if currentCull != mode { encoder.setCullMode(mode); currentCull = mode }
        }
        func source(_ range: DioramaRenderLayer.Range) -> Source {
            Source(buffer: range.usesLODBuffer ? (lodIndices ?? indices) : indices,
                   offset: range.start * 4, bytes: range.count * 4)
        }
        func flush() {
            guard !pending.isEmpty else { return }
            setCull(pendingCull)
            let sources = pending.map(source)
            if let slice = packed(sources, command: command) {
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: pendingBytes / 4,
                    indexType: .uint32, indexBuffer: slice.buffer, indexBufferOffset: slice.offset)
                stats.draws += 1; stats.copiedBytes += slice.copiedBytes
                if slice.cacheHit { stats.cacheHits += 1 }
            } else {
                // Cache pressure/allocation failure must never erase, simplify or delay scenery.
                for s in sources {
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: s.bytes / 4,
                        indexType: .uint32, indexBuffer: s.buffer, indexBufferOffset: s.offset)
                }
                stats.draws += pending.count; stats.fallbackDraws += pending.count
            }
            pending.removeAll(keepingCapacity: true); pendingBytes = 0
        }
        for range in ranges where range.count > 0 {
            let mode = cullOverride ?? (range.doubleSided ? MTLCullMode.none : .back)
            let bytes = range.count * 4
            if !pending.isEmpty && (mode != pendingCull || bytes > Self.chunkBytes - pendingBytes || pending.count == Self.maxSpans) {
                flush()
            }
            pendingCull = mode; pending.append(range); pendingBytes += bytes
            stats.inputDraws += 1; stats.triangles += range.count / 3
            // Large existing draws remain single direct draws, not artificially split for batching.
            if pendingBytes >= Self.chunkBytes { flush() }
        }
        flush()
        return stats
    }

    /// Compact selected placements of the same prototype across culled gaps. Different prototypes,
    /// LODs and facing states remain separate. Instance tint/scale/height metadata is copied verbatim.
    @discardableResult
    func drawInstances(_ groups: [DioramaDrawPlan.Instance], encoder: MTLRenderCommandEncoder,
                       command: MTLCommandBuffer, indices: MTLBuffer, lodIndices: MTLBuffer?,
                       instances: MTLBuffer) -> Statistics {
        var stats = Statistics()
        var pending: [DioramaDrawPlan.Instance] = []
        var pendingCount = 0
        let stride = MemoryLayout<DioramaInstanceData>.stride
        var currentCull: MTLCullMode?
        func flush() {
            guard let first = pending.first else { return }
            let mode: MTLCullMode = first.doubleSided ? .none : .back
            if currentCull != mode { encoder.setCullMode(mode); currentCull = mode }
            let indexBuffer = first.usesLODBuffer ? (lodIndices ?? indices) : indices
            let sources = pending.map { Source(buffer: instances, offset: $0.firstInstance * stride, bytes: $0.instanceCount * stride) }
            if let slice = packed(sources, command: command) {
                encoder.setVertexBuffer(slice.buffer, offset: slice.offset, index: 3)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: first.count, indexType: .uint32,
                    indexBuffer: indexBuffer, indexBufferOffset: first.start * 4, instanceCount: pendingCount,
                    baseVertex: 0, baseInstance: 0)
                stats.draws += 1; stats.copiedBytes += slice.copiedBytes
                if slice.cacheHit { stats.cacheHits += 1 }
            } else {
                encoder.setVertexBuffer(instances, offset: 0, index: 3)
                for group in pending {
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: group.count, indexType: .uint32,
                        indexBuffer: indexBuffer, indexBufferOffset: group.start * 4,
                        instanceCount: group.instanceCount, baseVertex: 0, baseInstance: group.firstInstance)
                }
                stats.draws += pending.count; stats.fallbackDraws += pending.count
            }
            pending.removeAll(keepingCapacity: true); pendingCount = 0
        }
        for group in groups where group.count > 0 && group.instanceCount > 0 {
            if let first = pending.first,
               first.start != group.start || first.count != group.count || first.usesLODBuffer != group.usesLODBuffer
                || first.doubleSided != group.doubleSided || pending.count == Self.maxSpans
                || group.instanceCount > Self.chunkBytes / stride - pendingCount { flush() }
            pending.append(group); pendingCount += group.instanceCount
            stats.inputDraws += 1; stats.triangles += group.count / 3 * group.instanceCount
            if pendingCount >= Self.chunkBytes / stride { flush() }
        }
        flush()
        // Do not leak the compacted placement binding into another draw path.
        encoder.setVertexBuffer(instances, offset: 0, index: 3)
        return stats
    }

    /// Immutable cached buffers can be read by several in-flight frames. Completion releases a lease;
    /// no buffer is overwritten, evicted or recycled while the GPU may still read it. Never wait for it.
    private func packed(_ sources: [Source], command: MTLCommandBuffer) -> Slice? {
        guard let first = sources.first else { return nil }
        var bytes = 0
        var contiguous = true
        for source in sources {
            guard source.offset >= 0, source.bytes > 0, source.offset <= source.buffer.length,
                  source.bytes <= source.buffer.length - source.offset else { return nil }
            if source.buffer !== first.buffer || source.offset != first.offset + bytes { contiguous = false }
            bytes += source.bytes
        }
        if contiguous { return Slice(buffer: first.buffer, offset: first.offset) }
        guard sources.count > 1, sources.count <= Self.maxSpans, bytes <= Self.chunkBytes,
              sources.allSatisfy({ $0.buffer.storageMode == .shared && $0.buffer.device === device }) else { return nil }
        let key = Key(spans: sources.map { Span(buffer: ObjectIdentifier($0.buffer), offset: $0.offset, bytes: $0.bytes) })
        let commandID = ObjectIdentifier(command)
        lock.lock()
        age &+= 1
        let entry: Entry
        let copied: Int
        let hit: Bool
        if let existing = cache[key] {
            guard existing.commands.contains(commandID) || existing.commands.count < Self.maxReaders else {
                lock.unlock(); return nil
            }
            entry = existing; copied = 0; hit = true
        } else {
            // Page-round allocations so tiny chunks cannot silently exhaust the stated memory cap.
            let allocation = (bytes + 4095) / 4096 * 4096
            var reusable: (key: Key, value: Entry)?
            for item in cache where item.value.commands.isEmpty && item.value.buffer.length >= allocation
                && item.value.buffer.length <= allocation * 2 {
                if item.value.age < (reusable?.value.age ?? UInt64.max) { reusable = item }
            }
            let recycled = reusable?.value.buffer
            if let reusable {
                cache.removeValue(forKey: reusable.key)
                allocatedBytes -= reusable.value.buffer.length
            }
            let required = recycled?.length ?? allocation
            while allocatedBytes + required > limit || cache.count >= Self.maxEntries {
                var victim: (key: Key, value: Entry)?
                for item in cache where item.value.commands.isEmpty {
                    if item.value.age < (victim?.value.age ?? UInt64.max) { victim = item }
                }
                guard let victim else { lock.unlock(); return nil }
                allocatedBytes -= victim.value.buffer.length
                cache.removeValue(forKey: victim.key)
            }
            // Recycle only GPU-completed storage. In-flight frames always keep their old bytes.
            guard let buffer = recycled ?? device.makeBuffer(length: allocation, options: .storageModeShared) else {
                lock.unlock(); return nil
            }
            buffer.label = "Diorama visible geometry chunk"
            var offset = 0
            for source in sources {
                buffer.contents().advanced(by: offset).copyMemory(from: source.buffer.contents().advanced(by: source.offset), byteCount: source.bytes)
                offset += source.bytes
            }
            entry = Entry(buffer); copied = bytes; hit = false
            cache[key] = entry; allocatedBytes += buffer.length
        }
        entry.age = age
        let needsCompletion = entry.commands.insert(commandID).inserted
        lock.unlock()
        if needsCompletion {
            command.addCompletedHandler { [self, entry] _ in
                lock.lock(); entry.commands.remove(commandID); lock.unlock()
            }
        }
        return Slice(buffer: entry.buffer, offset: 0, copiedBytes: copied, cacheHit: hit)
    }
}
