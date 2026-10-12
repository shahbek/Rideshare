import Foundation
import simd

/// 32-byte archive vertex for compact (format 2) packages, half the 64-byte `BuildingRenderVertex`.
/// Positions are whole millimetres; normals, colours and the two material codes are stored as the
/// exact binary16 bits the GPU already draws (`DioramaPackedVertex`), and appearance.z keeps its full
/// float. So the only change from what is on screen today is millimetre rounding of positions.
nonisolated struct DioramaArchiveVertex: Sendable {
    var x: UInt32, y: UInt32, z: UInt32
    var nx: UInt16, ny: UInt16, nz: UInt16, nw: UInt16
    var cr: UInt16, cg: UInt16, cb: UInt16, cw: UInt16
    var az: UInt32

    static let zero = DioramaArchiveVertex(x: 0, y: 0, z: 0, nx: 0, ny: 0, nz: 0, nw: 0, cr: 0, cg: 0, cb: 0, cw: 0, az: 0)

    init(x: UInt32, y: UInt32, z: UInt32, nx: UInt16, ny: UInt16, nz: UInt16, nw: UInt16,
                 cr: UInt16, cg: UInt16, cb: UInt16, cw: UInt16, az: UInt32) {
        self.x = x; self.y = y; self.z = z
        self.nx = nx; self.ny = ny; self.nz = nz; self.nw = nw
        self.cr = cr; self.cg = cg; self.cb = cb; self.cw = cw
        self.az = az
    }

    init(_ v: BuildingRenderVertex) {
        func millimetres(_ value: Float) -> UInt32 {
            guard value.isFinite else { return 0 }
            return UInt32(bitPattern: Int32(clamping: Int64((Double(value) * 1000).rounded())))
        }
        x = millimetres(v.position.x); y = millimetres(v.position.y); z = millimetres(v.position.z)
        nx = DioramaHalf.bits(v.normal.x); ny = DioramaHalf.bits(v.normal.y); nz = DioramaHalf.bits(v.normal.z)
        nw = DioramaHalf.bits(v.appearance.w)
        cr = DioramaHalf.bits(v.color.x); cg = DioramaHalf.bits(v.color.y); cb = DioramaHalf.bits(v.color.z)
        cw = DioramaHalf.bits(v.appearance.y)
        az = v.appearance.z.bitPattern
    }

    /// appearance.x, position.w and color.w are not read by any diorama shader; they get their
    /// common generator values.
    var vertex: BuildingRenderVertex {
        func metres(_ bits: UInt32) -> Float { Float(Int32(bitPattern: bits)) / 1000 }
        return BuildingRenderVertex(position: SIMD4(metres(x), metres(y), metres(z), 1),
            normal: SIMD4(DioramaHalf.float(nx), DioramaHalf.float(ny), DioramaHalf.float(nz), 0),
            color: SIMD4(DioramaHalf.float(cr), DioramaHalf.float(cg), DioramaHalf.float(cb), 1),
            appearance: SIMD4(0.85, DioramaHalf.float(cw), Float(bitPattern: az), DioramaHalf.float(nw)))
    }
}

/// Lossless reordering applied to each block before LZFSE. Every field becomes a stream of
/// zig-zag deltas from the previous record, split into byte planes, so slowly varying values
/// (neighbouring positions, repeated normals/colours, sequential indices) turn into long runs of
/// zero bytes that compress far better than interleaved floats. Each block decodes on its own.
nonisolated enum DioramaArchiveCodec {
    nonisolated struct Layout: Sendable {
        let fields: [Int]
        var record: Int { fields.reduce(0, +) }
        /// Largest whole number of records that fits one archive block.
        func chunkBytes(_ blockSize: Int) -> Int { blockSize / record * record }
    }
    static let vertices = Layout(fields: [4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2, 4])
    static let words = Layout(fields: [4])
    static let rgba = Layout(fields: [1, 1, 1, 1])
    static let paint = Layout(fields: Array(repeating: 4, count: 16))

    /// Which sections are reordered in a given archive format (format 1 stores raw bytes).
    static func layout(section: String, format: Int) -> Layout? {
        guard format >= 2 else { return nil }
        switch section {
        case "vertices": return vertices
        case "indices", "paintIndices", "lightIndices": return words
        case "ground": return rgba
        case "paint": return paint
        default: return nil
        }
    }

    @inline(__always) private static func load(_ p: UnsafePointer<UInt8>, _ width: Int) -> UInt64 {
        var value: UInt64 = 0
        for b in 0..<width { value |= UInt64(p[b]) << (8 * UInt64(b)) }
        return value
    }
    @inline(__always) private static func store(_ value: UInt64, _ p: UnsafeMutablePointer<UInt8>, _ width: Int) {
        for b in 0..<width { p[b] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(b))) }
    }

    /// Records (interleaved) → per-field zig-zag delta byte planes. `output` must hold `input.count` bytes.
    static func encode(_ input: UnsafeRawBufferPointer, layout: Layout, into output: UnsafeMutableRawPointer) {
        let record = layout.record
        let count = input.count / record
        guard count > 0, let source = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let target = output.assumingMemoryBound(to: UInt8.self)
        var fieldOffset = 0, planeOffset = 0
        for width in layout.fields {
            let bits = UInt64(8 * width)
            let mask: UInt64 = bits == 64 ? .max : (1 << bits) - 1
            var previous: UInt64 = 0
            for i in 0..<count {
                let value = load(source + i * record + fieldOffset, width)
                let delta = (value &- previous) & mask
                previous = value
                // Sign-extend the w-byte delta, then zig-zag so small negatives become small positives.
                let negative = delta >> (bits - 1) & 1 == 1
                let zigzag = negative ? ((~delta & mask) << 1 | 1) & mask : (delta << 1) & mask
                for b in 0..<width { target[planeOffset + b * count + i] = UInt8(truncatingIfNeeded: zigzag >> (8 * UInt64(b))) }
            }
            fieldOffset += width
            planeOffset += width * count
        }
    }

    /// Inverse of `encode`, in place (uses one temporary copy of the block).
    static func decodeInPlace(_ block: UnsafeMutableRawPointer, bytes: Int, layout: Layout) throws {
        let record = layout.record
        guard bytes % record == 0 else { throw DioramaTileArchive.ArchiveError.invalid }
        let count = bytes / record
        guard count > 0 else { return }
        let planes = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        defer { planes.deallocate() }
        planes.update(from: block.assumingMemoryBound(to: UInt8.self), count: bytes)
        let target = block.assumingMemoryBound(to: UInt8.self)
        var fieldOffset = 0, planeOffset = 0
        for width in layout.fields {
            let bits = UInt64(8 * width)
            let mask: UInt64 = bits == 64 ? .max : (1 << bits) - 1
            var previous: UInt64 = 0
            for i in 0..<count {
                var zigzag: UInt64 = 0
                for b in 0..<width { zigzag |= UInt64(planes[planeOffset + b * count + i]) << (8 * UInt64(b)) }
                let delta = zigzag & 1 == 1 ? ~(zigzag >> 1) & mask : zigzag >> 1
                previous = (previous &+ delta) & mask
                store(previous, target + i * record + fieldOffset, width)
            }
            fieldOffset += width
            planeOffset += width * count
        }
    }
}
