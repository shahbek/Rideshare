import Compression
import CryptoKit
import Foundation
import simd

/// ZPK1: the compact streaming form of one format-2 scenery package (written by
/// `tools/scenery-stream/zpk.py`). Each vertex attribute is its own LZMA2 (xz) stream; repeated
/// values are back-references, new values residuals from the previous one; flat-shaded normals are
/// recomputed here from their triangle, the rest are 2×10-bit octahedral; wall-height floats are
/// 1 mm; paint half-planes travel as millimetre corners. Positions and indices are exact and checked
/// by SHA-256. Decoding writes an ordinary format-2 package, so every later read is unchanged.
nonisolated enum DioramaStreamPackage {
    static let magic: [UInt8] = Array("ZPK1".utf8)
    static let octMax: Double = 511
    static let heightFlagMillimetres: Int64 = 50_000

    nonisolated enum Failure: Error { case invalid, compression, check }

    nonisolated struct Header: Decodable {
        let version: Int
        let package: String
        let vertexCount: Int
        let indexCount: Int
        let instanceCount: Int
        let paintCount: Int
        let paintRawCount: Int
        let check: String
        let streams: [Stream]
    }
    nonisolated struct Stream: Decodable {
        let name: String
        let raw: Int
        let stored: Int
    }

    /// Column-coded manifest without its sections (see `meta` in zpk.py).
    nonisolated struct Meta: Decodable {
        let format: Int
        let key: String
        let z: Int, x: Int, y: Int
        let vertexStride: Int
        let instanceStride: Int
        let waterHeight: Double
        let imageSize: Int
        let lightCells: Int
        let lightMinX: Float
        let lightMinY: Float
        let lightCellSize: Float
        let generationSeconds: Double
        let shorelineReport: [String]
        let optimizationReport: [String]
        let stageTimings: [String]
        let coverage: Bool
        let ranges: RangeColumns
        let groups: GroupColumns
        let labels: LabelColumns
        let sources: SourceColumns
    }
    nonisolated struct RangeColumns: Decodable {
        let category: [DioramaCategory]
        let start: [Int]
        let count: [Int]
        let doubleSided: [Bool]
        let translucent: [Bool?]
        let minX: [Int64], minY: [Int64], minZ: [Int64], maxX: [Int64], maxY: [Int64], maxZ: [Int64]
    }
    nonisolated struct GroupColumns: Decodable {
        let category: [DioramaCategory]
        let fullStart: [Int], fullCount: [Int], lightStart: [Int], lightCount: [Int], first: [Int], count: [Int]
        let doubleSided: [Bool]
        let minX: [Int64], minY: [Int64], minZ: [Int64], maxX: [Int64], maxY: [Int64], maxZ: [Int64]
    }
    nonisolated struct LabelColumns: Decodable {
        let id: [UInt64]
        let title: [String]
        let isNamed: [Bool]
        let anchor: [Int64]
        let footprintCount: [Int]
        let footprint: [Int64]
    }
    nonisolated struct SourceColumns: Decodable {
        let position: [Int64]
        let color: [Float]
        let radius: [Double]
        let intensity: [Float]
    }

    // MARK: - Container

    private struct Container {
        let data: Data
        let header: Header
        let offsets: [String: Range<Int>]
        let raws: [String: Int]

        init(_ data: Data) throws {
            guard data.count > 8, Array(data.prefix(4)) == DioramaStreamPackage.magic else { throw Failure.invalid }
            let length = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
            guard length > 0, 8 + length <= data.count else { throw Failure.invalid }
            header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8..<(8 + length)))
            guard header.version == 1 else { throw Failure.invalid }
            var offset = 8 + length
            var offsets: [String: Range<Int>] = [:], raws: [String: Int] = [:]
            for s in header.streams {
                guard s.stored >= 0, s.raw >= 0, s.raw <= DioramaTileArchive.maxBytes, offset + s.stored <= data.count else { throw Failure.invalid }
                offsets[s.name] = offset..<(offset + s.stored)
                raws[s.name] = s.raw
                offset += s.stored
            }
            guard offset == data.count else { throw Failure.invalid }
            self.data = data; self.offsets = offsets; self.raws = raws
        }

        func stream(_ name: String) throws -> Data {
            guard let range = offsets[name], let raw = raws[name] else { throw Failure.invalid }
            if raw == 0 { return Data() }
            var out = Data(count: raw)
            let written = out.withUnsafeMutableBytes { output in
                data.withUnsafeBytes { input in
                    compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, raw,
                        input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: range.lowerBound), range.count, nil, COMPRESSION_LZMA)
                }
            }
            guard written == raw else { throw Failure.compression }
            return out
        }
    }

    // MARK: - Byte-plane readers

    /// Reads value `i` of a `width`-byte plane-split stream starting at `offset`.
    private struct Planes {
        let base: UnsafePointer<UInt8>
        let count: Int
        let width: Int
        init(_ buffer: UnsafeRawBufferPointer, count: Int, width: Int, offset: Int = 0) throws {
            guard count >= 0, offset >= 0, offset + count * width <= buffer.count else { throw Failure.invalid }
            base = (buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!).assumingMemoryBound(to: UInt8.self).advanced(by: offset)
            self.count = count; self.width = width
        }
        @inline(__always) func value(_ i: Int) -> UInt64 {
            var v: UInt64 = 0
            for b in 0..<width { v |= UInt64(base[b * count + i]) << (8 * UInt64(b)) }
            return v
        }
        @inline(__always) func signed(_ i: Int) -> UInt64 {
            let mask: UInt64 = width == 8 ? .max : (1 << UInt64(8 * width)) - 1
            let z = value(i)
            return z & 1 == 1 ? ~(z >> 1) & mask : z >> 1
        }
    }

    /// Cumulative modular deltas, as `delta_planes` in zpk.py.
    private static func undelta(_ data: Data, count: Int, width: Int, offset: Int = 0) throws -> [UInt64] {
        try data.withUnsafeBytes { buffer in
            let p = try Planes(buffer, count: count, width: width, offset: offset)
            let mask: UInt64 = (1 << UInt64(8 * width)) - 1
            var out = [UInt64](repeating: 0, count: count)
            var previous: UInt64 = 0
            for i in 0..<count { previous = (previous &+ p.signed(i)) & mask; out[i] = previous }
            return out
        }
    }

    private static func bit(_ buffer: UnsafeRawBufferPointer, _ i: Int) -> Bool {
        (buffer[i >> 3] >> (7 - UInt8(i & 7))) & 1 == 1
    }

    /// Back-referenced 32-bit columns (`column_dictionary` in zpk.py). Advances `offset`.
    private static func dictionaryColumn(_ buffer: UnsafeRawBufferPointer, rows: Int, offset: inout Int) throws -> [UInt32] {
        let refs = try Planes(buffer, count: rows, width: 4, offset: offset)
        var fresh = 0
        for i in 0..<rows where refs.value(i) == 0 { fresh += 1 }
        let values = try Planes(buffer, count: fresh, width: 4, offset: offset + rows * 4)
        var seen: [UInt32] = []
        seen.reserveCapacity(fresh)
        var out = [UInt32](repeating: 0, count: rows)
        for i in 0..<rows {
            let r = Int(refs.value(i))
            if r == 0 { seen.append(UInt32(truncatingIfNeeded: values.value(seen.count))) }
            guard r <= seen.count else { throw Failure.invalid }
            out[i] = seen[seen.count - max(r, 1)]
        }
        offset += rows * 4 + fresh * 4
        return out
    }

    private static func metres(_ mm: Int64) -> Float { Float(Double(mm) / 1000) }

    // MARK: - Decode

    /// Decodes a verified .zpk into a format-2 package directory named for `expectedPackage`.
    static func install(_ data: Data, expectedPackage: String, into directory: URL) throws {
        let c = try Container(data)
        let h = c.header
        let n = h.vertexCount, m = h.indexCount
        guard h.package == expectedPackage, n > 0, m % 3 == 0, n <= DioramaTileArchive.maxBytes / 32,
              m <= DioramaTileArchive.maxBytes / 4 else { throw Failure.invalid }
        let meta = try JSONDecoder().decode(Meta.self, from: try c.stream("meta"))
        guard meta.key == expectedPackage, meta.format == DioramaTileArchive.format,
              meta.vertexStride == MemoryLayout<DioramaArchiveVertex>.stride,
              meta.instanceStride == MemoryLayout<DioramaInstanceData>.stride else { throw Failure.invalid }

        // Indices (exact).
        var indices = [UInt32](repeating: 0, count: m)
        do {
            let raw = try undelta(try c.stream("indices"), count: m, width: 4)
            for i in 0..<m {
                guard raw[i] < UInt64(n) else { throw Failure.invalid }
                indices[i] = UInt32(raw[i])
            }
        }
        try Task.checkCancellation()

        // Positions (exact millimetres): back-references or residuals from the previous vertex.
        var positions = [Int32](repeating: 0, count: 3 * n)
        do {
            let refsData = try c.stream("positionRefs")
            let newData = try c.stream("positionNew")
            try refsData.withUnsafeBytes { refsBuffer in
                try newData.withUnsafeBytes { newBuffer in
                    let refs = try Planes(refsBuffer, count: n, width: 4)
                    let fresh = newBuffer.count / 12
                    guard fresh * 12 == newBuffer.count else { throw Failure.invalid }
                    let rx = try Planes(newBuffer, count: fresh, width: 4, offset: 0)
                    let ry = try Planes(newBuffer, count: fresh, width: 4, offset: 4 * fresh)
                    let rz = try Planes(newBuffer, count: fresh, width: 4, offset: 8 * fresh)
                    var unique = [Int32](repeating: 0, count: 3 * fresh)
                    var seen = 0
                    var px: Int32 = 0, py: Int32 = 0, pz: Int32 = 0
                    try positions.withUnsafeMutableBufferPointer { out in
                        for i in 0..<n {
                            let r = Int(refs.value(i))
                            if r == 0 {
                                guard seen < fresh else { throw Failure.invalid }
                                px = px &+ Int32(truncatingIfNeeded: rx.signed(seen))
                                py = py &+ Int32(truncatingIfNeeded: ry.signed(seen))
                                pz = pz &+ Int32(truncatingIfNeeded: rz.signed(seen))
                                unique[3 * seen] = px; unique[3 * seen + 1] = py; unique[3 * seen + 2] = pz
                                seen += 1
                            } else {
                                guard r <= seen else { throw Failure.invalid }
                                let j = seen - r
                                px = unique[3 * j]; py = unique[3 * j + 1]; pz = unique[3 * j + 2]
                            }
                            out[3 * i] = px; out[3 * i + 1] = py; out[3 * i + 2] = pz
                        }
                    }
                    guard seen == fresh else { throw Failure.invalid }
                }
            }
        }
        var hasher = SHA256()
        positions.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        indices.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == h.check else { throw Failure.check }
        try Task.checkCancellation()

        // First triangle that uses each vertex, for recomputed flat normals.
        var firstTriangle = [Int32](repeating: -1, count: n)
        for i in stride(from: m - 1, through: 0, by: -1) { firstTriangle[Int(indices[i])] = Int32(i / 3) }

        var writer = try DioramaTileArchive.Writer(directory: directory)
        do {
            let flat = try c.stream("flatNormals"), oct = try c.stream("octNormals")
            let colorRefs = try c.stream("colorRefs"), colorNew = try c.stream("colorNew")
            let heightFlags = try c.stream("heightFlags"), heights = try c.stream("heights")
            guard flat.count * 8 >= n, heightFlags.count * 8 >= n, oct.count % 4 == 0, colorNew.count % 6 == 0 else { throw Failure.invalid }
            let colorW = try undelta(try c.stream("colorW"), count: n, width: 2)
            let normalW = try undelta(try c.stream("normalW"), count: n, width: 2)
            let octCount = oct.count / 4
            let ox = try undelta(oct, count: octCount, width: 2), oy = try undelta(oct, count: octCount, width: 2, offset: 2 * octCount)
            let colorCount = colorNew.count / 6
            var palette: [(UInt16, UInt16, UInt16)] = []
            palette.reserveCapacity(colorCount)
            var octNext = 0, heightPrevious: UInt64 = 0
            try flat.withUnsafeBytes { flatBuffer in
                try heightFlags.withUnsafeBytes { heightFlagBuffer in
                    try colorRefs.withUnsafeBytes { colorRefBuffer in
                        try colorNew.withUnsafeBytes { colorNewBuffer in
                            try heights.withUnsafeBytes { heightBuffer in
                                let crefs = try Planes(colorRefBuffer, count: n, width: 4)
                                let cr = try Planes(colorNewBuffer, count: colorCount, width: 2, offset: 0)
                                let cg = try Planes(colorNewBuffer, count: colorCount, width: 2, offset: 2 * colorCount)
                                let cb = try Planes(colorNewBuffer, count: colorCount, width: 2, offset: 4 * colorCount)
                                let hr = try Planes(heightBuffer, count: n, width: 4)
                                try writer.vertices(count: n) { range, records in
                                    for i in range {
                                        let x = positions[3 * i], y = positions[3 * i + 1], z = positions[3 * i + 2]
                                        var normal = SIMD3<Double>(0, 0, 1)
                                        if bit(flatBuffer, i) {
                                            let t = Int(firstTriangle[i])
                                            guard t >= 0 else { throw Failure.invalid }
                                            normal = faceNormal(positions, indices[3 * t], indices[3 * t + 1], indices[3 * t + 2])
                                        } else {
                                            guard octNext < octCount else { throw Failure.invalid }
                                            normal = octDecode(Int16(truncatingIfNeeded: ox[octNext]), Int16(truncatingIfNeeded: oy[octNext]))
                                            octNext += 1
                                        }
                                        let r = Int(crefs.value(i))
                                        if r == 0 {
                                            guard palette.count < colorCount else { throw Failure.invalid }
                                            let k = palette.count
                                            palette.append((UInt16(cr.value(k)), UInt16(cg.value(k)), UInt16(cb.value(k))))
                                        }
                                        guard r <= palette.count else { throw Failure.invalid }
                                        let colour = palette[palette.count - max(r, 1)]
                                        heightPrevious = (heightPrevious &+ hr.signed(i)) & 0xFFFF_FFFF
                                        var q = Int64(Int32(truncatingIfNeeded: heightPrevious))
                                        if bit(heightFlagBuffer, i) { q += Int64(z) }
                                        records.append(DioramaArchiveVertex(
                                            x: UInt32(bitPattern: x), y: UInt32(bitPattern: y), z: UInt32(bitPattern: z),
                                            nx: DioramaHalf.bits(Float(normal.x)), ny: DioramaHalf.bits(Float(normal.y)), nz: DioramaHalf.bits(Float(normal.z)),
                                            nw: UInt16(truncatingIfNeeded: normalW[i]),
                                            cr: colour.0, cg: colour.1, cb: colour.2, cw: UInt16(truncatingIfNeeded: colorW[i]),
                                            az: Float(Double(q) / 1000).bitPattern))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            guard octNext == octCount else { throw Failure.invalid }
        }
        positions = []
        firstTriangle = []
        try writer.section("indices", indices)
        indices = []
        try Task.checkCancellation()

        let instances = try decodeInstances(try c.stream("instances"), count: h.instanceCount)
        try writer.section("instances", instances)
        try c.stream("ground").withUnsafeBytes { try writer.section("ground", bytes: $0) }
        let paint = try decodePaint(c, count: h.paintCount, rawCount: h.paintRawCount)
        try writer.section("paint", paint)
        try c.stream("paintTable").withUnsafeBytes { try writer.section("paintTable", bytes: $0) }
        let paintIndexData = try c.stream("paintIndices")
        guard paintIndexData.count % 4 == 0 else { throw Failure.invalid }
        let paintIndices = try undelta(paintIndexData, count: paintIndexData.count / 4, width: 4).map { UInt32($0) }
        try writer.section("paintIndices", paintIndices)
        try c.stream("lights").withUnsafeBytes { try writer.section("lights", bytes: $0) }
        try c.stream("lightTable").withUnsafeBytes { try writer.section("lightTable", bytes: $0) }
        try c.stream("lightIndices").withUnsafeBytes { try writer.section("lightIndices", bytes: $0) }
        _ = try writer.finish(try manifest(meta, sections: writer.sections))
    }

    // MARK: - Attributes

    private static func faceNormal(_ p: [Int32], _ a: UInt32, _ b: UInt32, _ c: UInt32) -> SIMD3<Double> {
        func at(_ i: UInt32) -> SIMD3<Double> {
            let k = 3 * Int(i)
            return SIMD3(Double(p[k]), Double(p[k + 1]), Double(p[k + 2]))
        }
        let pa = at(a), u = at(b) - pa, v = at(c) - pa
        let x = u.y * v.z - u.z * v.y
        let y = u.z * v.x - u.x * v.z
        let z = u.x * v.y - u.y * v.x
        let length = (x * x + y * y + z * z).squareRoot()
        guard length > 0 else { return SIMD3(0, 0, 1) }
        return SIMD3(x / length, y / length, z / length)
    }

    private static func octDecode(_ ox: Int16, _ oy: Int16) -> SIMD3<Double> {
        let fx = Double(ox) / octMax, fy = Double(oy) / octMax
        let fz = 1 - abs(fx) - abs(fy)
        var nx = fx, ny = fy
        if fz < 0 {
            nx = (1 - abs(fy)) * (fx >= 0 ? 1 : -1)
            ny = (1 - abs(fx)) * (fy >= 0 ? 1 : -1)
        }
        let length = (nx * nx + ny * ny + fz * fz).squareRoot()
        guard length > 0 else { return SIMD3(0, 0, 1) }
        return SIMD3(nx / length, ny / length, fz / length)
    }

    private static func decodeInstances(_ data: Data, count: Int) throws -> [DioramaInstanceData] {
        guard count > 0 else { return [] }
        return try data.withUnsafeBytes { buffer in
            var columns: [[UInt32]] = []
            for k in 0..<3 {
                let values = try undelta(data, count: count, width: 4, offset: k * 4 * count)
                columns.append(values.map { metres(Int64(Int32(truncatingIfNeeded: $0))).bitPattern })
            }
            var offset = 12 * count
            for _ in 3..<16 { columns.append(try dictionaryColumn(buffer, rows: count, offset: &offset)) }
            guard offset == buffer.count else { throw Failure.invalid }
            func v(_ i: Int, _ k: Int) -> Float { Float(bitPattern: columns[k][i]) }
            return (0..<count).map { i in
                DioramaInstanceData(placement: SIMD4(v(i, 0), v(i, 1), v(i, 2), v(i, 3)), scale: SIMD4(v(i, 4), v(i, 5), v(i, 6), v(i, 7)),
                                    tint: SIMD4(v(i, 8), v(i, 9), v(i, 10), v(i, 11)), grading: SIMD4(v(i, 12), v(i, 13), v(i, 14), v(i, 15)))
            }
        }
    }

    private static func decodePaint(_ c: Container, count: Int, rawCount: Int) throws -> [DioramaPaintTriangle] {
        guard count > 0 else { return [] }
        let flags = try c.stream("paintFlags"), pointData = try c.stream("paintPoints")
        let attributes = try c.stream("paintAttributes"), raw = try c.stream("paintRaw")
        let good = count - rawCount
        let stride = MemoryLayout<DioramaPaintTriangle>.stride
        guard good >= 0, flags.count * 8 >= count, raw.count == rawCount * stride else { throw Failure.invalid }
        let pointCount = 3 * good
        var points = [SIMD2<Double>](repeating: .zero, count: pointCount)
        try pointData.withUnsafeBytes { buffer in
            let refs = try Planes(buffer, count: pointCount, width: 4)
            let fresh = (buffer.count - 4 * pointCount) / 8
            guard fresh >= 0, 4 * pointCount + 8 * fresh == buffer.count else { throw Failure.invalid }
            let rx = try Planes(buffer, count: fresh, width: 4, offset: 4 * pointCount)
            let ry = try Planes(buffer, count: fresh, width: 4, offset: 4 * pointCount + 4 * fresh)
            var unique: [SIMD2<Int32>] = []
            unique.reserveCapacity(fresh)
            var px: Int32 = 0, py: Int32 = 0
            for i in 0..<pointCount {
                let r = Int(refs.value(i))
                if r == 0 {
                    guard unique.count < fresh else { throw Failure.invalid }
                    px = px &+ Int32(truncatingIfNeeded: rx.signed(unique.count))
                    py = py &+ Int32(truncatingIfNeeded: ry.signed(unique.count))
                    unique.append(SIMD2(px, py))
                } else {
                    guard r <= unique.count else { throw Failure.invalid }
                    let p = unique[unique.count - r]
                    px = p.x; py = p.y
                }
                points[i] = SIMD2(Double(px) / 1000, Double(py) / 1000)
            }
            guard unique.count == fresh else { throw Failure.invalid }
        }
        var colour: [[UInt32]] = []
        var layers: [UInt64] = [], epochs: [UInt64] = []
        try attributes.withUnsafeBytes { buffer in
            var offset = 0
            for _ in 0..<4 { colour.append(try dictionaryColumn(buffer, rows: good, offset: &offset)) }
            layers = try undelta(attributes, count: good, width: 4, offset: offset)
            epochs = try undelta(attributes, count: good, width: 4, offset: offset + 4 * good)
            guard offset + 8 * good == buffer.count else { throw Failure.invalid }
        }
        func edge(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ w: Float) -> SIMD4<Float> {
            let d = b - a
            let length = (d.x * d.x + d.y * d.y).squareRoot()
            let ix = -d.y / length, iy = d.x / length
            return SIMD4(Float(ix), Float(iy), Float(-(ix * a.x + iy * a.y)), w)
        }
        var out: [DioramaPaintTriangle] = []
        out.reserveCapacity(count)
        try flags.withUnsafeBytes { flagBuffer in
            try raw.withUnsafeBytes { rawBuffer in
                var g = 0, r = 0
                for i in 0..<count {
                    if bit(flagBuffer, i) {
                        guard r < rawCount else { throw Failure.invalid }
                        out.append(rawBuffer.loadUnaligned(fromByteOffset: r * stride, as: DioramaPaintTriangle.self))
                        r += 1
                    } else {
                        guard g < good else { throw Failure.invalid }
                        let p0 = points[3 * g], p1 = points[3 * g + 1], p2 = points[3 * g + 2]
                        let layer = Float(Int32(truncatingIfNeeded: layers[g])), epoch = Float(Int32(truncatingIfNeeded: epochs[g]))
                        out.append(DioramaPaintTriangle(edge0: edge(p0, p1, layer), edge1: edge(p1, p2, epoch), edge2: edge(p2, p0, layer),
                            color: SIMD4(Float(bitPattern: colour[0][g]), Float(bitPattern: colour[1][g]),
                                         Float(bitPattern: colour[2][g]), Float(bitPattern: colour[3][g]))))
                        g += 1
                    }
                }
                guard g == good, r == rawCount else { throw Failure.invalid }
            }
        }
        return out
    }

    // MARK: - Manifest

    private static func cumulative(_ values: [Int64]) -> [Int64] {
        var total: Int64 = 0
        return values.map { total += $0; return total }
    }
    private static func cumulative(_ values: [Int]) -> [Int] {
        var total = 0
        return values.map { total += $0; return total }
    }

    private static func manifest(_ m: Meta, sections: [DioramaTileArchive.Section]) throws -> DioramaTileArchive.Manifest {
        let r = m.ranges, g = m.groups, l = m.labels, s = m.sources
        let rc = r.category.count, gc = g.category.count, lc = l.id.count, sc = s.radius.count
        guard [r.start.count, r.count.count, r.doubleSided.count, r.translucent.count, r.minX.count, r.minY.count, r.minZ.count,
               r.maxX.count, r.maxY.count, r.maxZ.count].allSatisfy({ $0 == rc }),
              [g.fullStart.count, g.fullCount.count, g.lightStart.count, g.lightCount.count, g.first.count, g.count.count,
               g.doubleSided.count, g.minX.count, g.minY.count, g.minZ.count, g.maxX.count, g.maxY.count, g.maxZ.count].allSatisfy({ $0 == gc }),
              l.title.count == lc, l.isNamed.count == lc, l.footprintCount.count == lc, l.anchor.count == 3 * lc,
              l.footprint.count == 2 * l.footprintCount.reduce(0, +),
              s.position.count == 3 * sc, s.color.count == 3 * sc, s.intensity.count == sc else { throw Failure.invalid }
        func bounds(_ x: [Int64], _ y: [Int64], _ z: [Int64]) -> [SIMD3<Float>] {
            let cx = cumulative(x), cy = cumulative(y), cz = cumulative(z)
            return (0..<cx.count).map { SIMD3(metres(cx[$0]), metres(cy[$0]), metres(cz[$0])) }
        }
        let rStart = cumulative(r.start), rMin = bounds(r.minX, r.minY, r.minZ), rMax = bounds(r.maxX, r.maxY, r.maxZ)
        let ranges = (0..<rc).map {
            DioramaTileArchive.DrawRange(category: r.category[$0], start: rStart[$0], count: r.count[$0], minimum: rMin[$0], maximum: rMax[$0],
                                         doubleSided: r.doubleSided[$0], translucent: r.translucent[$0])
        }
        let fullStart = cumulative(g.fullStart), lightStart = cumulative(g.lightStart), first = cumulative(g.first)
        let gMin = bounds(g.minX, g.minY, g.minZ), gMax = bounds(g.maxX, g.maxY, g.maxZ)
        let groups = (0..<gc).map {
            DioramaTileArchive.Group(category: g.category[$0], fullStart: fullStart[$0], fullCount: g.fullCount[$0], lightStart: lightStart[$0],
                                     lightCount: g.lightCount[$0], first: first[$0], count: g.count[$0], minimum: gMin[$0], maximum: gMax[$0],
                                     doubleSided: g.doubleSided[$0])
        }
        var cursor = 0
        let labels = (0..<lc).map { i -> DioramaTileArchive.Label in
            let footprint = (0..<l.footprintCount[i]).map { k in
                SIMD2(Double(l.footprint[2 * (cursor + k)]) / 1000, Double(l.footprint[2 * (cursor + k) + 1]) / 1000)
            }
            cursor += l.footprintCount[i]
            return DioramaTileArchive.Label(id: l.id[i], title: l.title[i],
                anchor: SIMD3(metres(l.anchor[3 * i]), metres(l.anchor[3 * i + 1]), metres(l.anchor[3 * i + 2])),
                footprint: footprint, isNamed: l.isNamed[i])
        }
        var sources: [DioramaTileArchive.Light] = []
        sources.reserveCapacity(sc)
        for i in 0..<sc {
            let px: Double = Double(s.position[3 * i]) / 1000
            let py: Double = Double(s.position[3 * i + 1]) / 1000
            let pz: Double = Double(s.position[3 * i + 2]) / 1000
            let color = SIMD3(s.color[3 * i], s.color[3 * i + 1], s.color[3 * i + 2])
            sources.append(DioramaTileArchive.Light(position: SIMD3(px, py, pz), color: color,
                                                    radius: s.radius[i], intensity: s.intensity[i]))
        }
        return DioramaTileArchive.Manifest(format: m.format, key: m.key, z: m.z, x: m.x, y: m.y, vertexStride: m.vertexStride,
            instanceStride: m.instanceStride, ranges: ranges, groups: groups, labels: labels, sources: sources, waterHeight: m.waterHeight,
            imageSize: m.imageSize, lightCells: m.lightCells, lightMinX: m.lightMinX, lightMinY: m.lightMinY, lightCellSize: m.lightCellSize,
            generationSeconds: m.generationSeconds, shorelineReport: m.shorelineReport, optimizationReport: m.optimizationReport,
            stageTimings: m.stageTimings, coverage: m.coverage, sections: sections)
    }
}
