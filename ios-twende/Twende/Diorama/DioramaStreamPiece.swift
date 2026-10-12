import Compression
import CoreLocation
import Foundation
import Metal
import simd

/// One finished, GPU-ready slice of a baked harbour tile ("ZPC1"). The baking phone decodes a tile
/// exactly as viewing does (landmarks, skyline, roofs, walls, planting, lights, labels, pixel-error
/// levels all applied) and cuts the finished image into pieces: one coarse piece per tile at its
/// lightest levels, four medium pieces of the surroundings mesh and a 10×10 grid of full-detail
/// pieces. A viewer receives a piece, decompresses each section straight into shared Metal storage
/// and draws it; nothing is unpacked into a package, merged, baked or simplified on the phone.
///
/// Pieces are cut by overlap, not by centroid: every triangle and placement that touches a block is
/// in that block's piece, and the piece's ground rectangle clips fragments to the block, so
/// neighbouring pieces meet without gaps or doubled surfaces.
nonisolated enum DioramaStreamPiece {
    static let format = 1
    static let magic: [UInt8] = Array("ZPC1".utf8)
    /// Server catalogue holding the harbour's piece set.
    static let catalogName = "harbour-z2"
    static let fileName = "piece.bin"
    /// Largest decoded piece a viewer accepts (a damaged or hostile file cannot exhaust memory).
    static let maxDecodedBytes = 96 * 1_048_576

    enum Ring: String, CaseIterable, Sendable, Codable {
        case coarse = "c"
        case medium = "m"
        case fine = "f"
        /// One stylised, fully baked scene per tile (`DioramaStylisedScene`); replaces every other ring.
        case scene = "s"
        /// Blocks per tile side.
        var divisions: Int {
            switch self {
            case .coarse, .scene: 1
            case .medium: 2
            case .fine: 10
            }
        }
        var displayName: String {
            switch self {
            case .coarse: "coarse"
            case .medium: "medium"
            case .fine: "fine"
            case .scene: "stylised scene"
            }
        }
        /// Layer-group draw order: fine pieces draw after the coarse/medium geometry they replace.
        var order: Int { self == .fine ? 1 : 0 }
        var lightCells: Int {
            switch self {
            case .coarse: 48
            case .medium: 24
            case .fine: 8
            case .scene: 16
            }
        }
        /// Drawn with the baked-only stylised shader.
        var isStylised: Bool { self == .scene }
    }

    struct ID: Hashable, Sendable, CustomStringConvertible {
        let tile: DioramaTileID
        let ring: Ring
        let column: Int
        let row: Int

        init(tile: DioramaTileID, ring: Ring, column: Int, row: Int) {
            self.tile = tile; self.ring = ring; self.column = column; self.row = row
        }
        /// `piece-<z>-<x>-<y>-<ring>-<column>-<row>` (the catalogue directory name).
        init?(directory: String) {
            let parts = directory.split(separator: "-").map(String.init)
            guard parts.count == 7, parts[0] == "piece", let z = Int(parts[1]), let x = Int(parts[2]), let y = Int(parts[3]),
                  let ring = Ring(rawValue: parts[4]), let column = Int(parts[5]), let row = Int(parts[6]),
                  z >= 0, z <= 22, x >= 0, y >= 0, column >= 0, row >= 0, column < ring.divisions, row < ring.divisions else { return nil }
            self.init(tile: DioramaTileID(z: z, x: x, y: y), ring: ring, column: column, row: row)
        }
        var directory: String { "piece-\(tile.key)-\(ring.rawValue)-\(column)-\(row)" }
        var description: String { directory }

        /// Exact block rectangle in the tile's local frame (origin at the tile centre).
        func block(in tileRect: DioramaRect) -> DioramaRect {
            let n = Double(ring.divisions)
            return DioramaRect(minX: tileRect.minX + tileRect.width * Double(column) / n,
                               minY: tileRect.minY + tileRect.height * Double(row) / n,
                               maxX: tileRect.minX + tileRect.width * Double(column + 1) / n,
                               maxY: tileRect.minY + tileRect.height * Double(row + 1) / n)
        }
        var tileRect: DioramaRect { DioramaProjection(origin: tile.centre).rect(of: tile) }
        var block: DioramaRect { block(in: tileRect) }
    }

    // MARK: - Records

    struct RangeRecord: Codable {
        let c: DioramaCategory; let s: Int; let n: Int; let lo: SIMD3<Float>; let hi: SIMD3<Float>
        let d: Bool; let t: Bool; let p: Bool; let id: String?
        init(_ r: DioramaRenderLayer.Range) {
            c = r.category; s = r.start; n = r.count; lo = r.minimum; hi = r.maximum; d = r.doubleSided; t = r.translucent
            p = r.landmarkPlaceholder; id = r.landmarkID
        }
        var range: DioramaRenderLayer.Range {
            var r = DioramaRenderLayer.Range(category: c, start: s, count: n, minimum: lo, maximum: hi, doubleSided: d, translucent: t)
            r.landmarkPlaceholder = p; r.landmarkID = id
            return r
        }
    }
    struct GroupRecord: Codable {
        let c: DioramaCategory; let fs: Int; let fc: Int; let ls: Int; let lc: Int; let d: Bool
        let first: Int; let n: Int; let lo: SIMD3<Float>; let hi: SIMD3<Float>
        let p: Bool; let id: String?; let scale: Float
        init(_ g: DioramaInstanceGroup) {
            c = g.category; fs = g.fullStart; fc = g.fullCount; ls = g.lightStart; lc = g.lightCount; d = g.doubleSided
            first = g.firstInstance; n = g.instances.count; lo = g.minimum; hi = g.maximum
            p = g.landmarkPlaceholder; id = g.landmarkID; scale = g.lodScale
        }
        func group(_ instances: [DioramaInstanceData]) -> DioramaInstanceGroup {
            var g = DioramaInstanceGroup(category: c, fullStart: fs, fullCount: fc, lightStart: ls, lightCount: lc, doubleSided: d,
                                         instances: instances, firstInstance: first, minimum: lo, maximum: hi)
            g.landmarkPlaceholder = p; g.landmarkID = id; g.lodScale = scale
            return g
        }
    }
    struct LabelRecord: Codable { let id: UInt64; let title: String; let anchor: SIMD3<Float>; let footprint: [Double]; let named: Bool }
    struct GroundRecord: Codable { let minX: Float; let minY: Float; let cell: Float; let columns: Int; let rows: Int }
    /// A section of the payload: `codec` names the byte-plane layout undone after LZFSE (0 none).
    struct Section: Codable {
        let name: String
        let offset: Int
        let length: Int
        let stored: Int
        let compressed: Bool
        let codec: Int
    }
    struct Header: Codable {
        let format: Int
        let z: Int; let x: Int; let y: Int
        let ring: Ring; let column: Int; let row: Int
        /// Piece ground rectangle (texel-aligned block) in the tile's local frame.
        let bounds: [Double]
        let vertexCount: Int
        let indexCount: Int
        let instanceCount: Int
        let ranges: [RangeRecord]
        let groups: [GroupRecord]
        let lightCells: Int; let lightMinX: Float; let lightMinY: Float; let lightCellSize: Float
        let ground: GroundRecord?
        let imageWidth: Int; let imageHeight: Int; let mipOffsets: [Int]
        let waterHeight: Double
        let pool: RangeRecord?
        let shadowLow: SIMD3<Float>?; let shadowHigh: SIMD3<Float>?
        let foliage: Int; let architecture: Int
        let labels: [LabelRecord]
        let sections: [Section]
        /// Where the piece came from, for the Settings listing.
        let sourceTriangles: Int
    }

    /// What a bake measured for one piece (only measured values are ever shown).
    struct Measured: Sendable {
        let id: ID
        let bytes: Int
        let triangles: Int
        let instances: Int
        let vertices: Int
    }

    // MARK: - Codecs

    /// 32-byte packed vertex: four floats, then eight halves.
    static let vertexLayout = DioramaArchiveCodec.Layout(fields: [4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2])
    /// 64-byte instance / paint triangle: sixteen floats.
    static let floats16Layout = DioramaArchiveCodec.Layout(fields: Array(repeating: 4, count: 16))
    static let pairLayout = DioramaArchiveCodec.Layout(fields: [4, 4])

    private static func layout(_ codec: Int) -> DioramaArchiveCodec.Layout? {
        switch codec {
        case 1: vertexLayout
        case 2: DioramaArchiveCodec.words
        case 3: floats16Layout
        case 4: pairLayout
        case 5: DioramaArchiveCodec.rgba
        default: nil
        }
    }

    // MARK: - Slicing (bake time)

    /// Everything the baker needs from a finished resident tile to cut one piece.
    private struct Source {
        let tile: DioramaResidentTile
        let vertices: UnsafeMutablePointer<DioramaPackedVertex>
        let indices: UnsafeMutablePointer<UInt32>
        let lodIndices: UnsafeMutablePointer<UInt32>?
        init(_ tile: DioramaResidentTile) {
            self.tile = tile
            vertices = tile.vertexBuffer.contents().assumingMemoryBound(to: DioramaPackedVertex.self)
            indices = tile.indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
            lodIndices = tile.lod?.indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        }
        /// Index list a range draws from: the coarse ring takes the lightest measured level.
        func source(for range: DioramaRenderLayer.Range, coarse: Bool) -> (UnsafeMutablePointer<UInt32>, Int, Int)? {
            if coarse, range.lodSlot >= 0, let lod = tile.lod, Int(range.lodSlot) < lod.rangeLevels.count,
               let lightest = lod.rangeLevels[Int(range.lodSlot)].last, let lodIndices,
               lightest.start >= 0, lightest.count >= 0, lightest.start <= lod.indexCount - lightest.count {
                return (lodIndices, lightest.start, lightest.count)
            }
            if range.usesLODBuffer {
                guard let lodIndices, let lod = tile.lod, range.start >= 0, range.start <= lod.indexCount - range.count else { return nil }
                return (lodIndices, range.start, range.count)
            }
            guard range.start >= 0, range.count >= 0, range.start <= tile.indexCount - range.count else { return nil }
            return (indices, range.start, range.count)
        }
        func prototype(for group: DioramaInstanceGroup, coarse: Bool) -> (UnsafeMutablePointer<UInt32>, Int, Int)? {
            if coarse, group.lodSlot >= 0, let lod = tile.lod, Int(group.lodSlot) < lod.prototypeLevels.count,
               let lightest = lod.prototypeLevels[Int(group.lodSlot)].last, let lodIndices,
               lightest.start >= 0, lightest.count >= 0, lightest.start <= lod.indexCount - lightest.count {
                return (lodIndices, lightest.start, lightest.count)
            }
            guard group.fullStart >= 0, group.fullCount >= 0, group.fullStart <= tile.indexCount - group.fullCount else { return nil }
            return (indices, group.fullStart, group.fullCount)
        }
    }

    private struct Slice {
        var vertices: [DioramaPackedVertex] = []
        var indices: [UInt32] = []
        var ranges: [DioramaRenderLayer.Range] = []
        var groups: [DioramaInstanceGroup] = []
        var instances: [DioramaInstanceData] = []
        var poolLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var poolHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var shadowLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var shadowHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var isEmpty: Bool { indices.isEmpty && instances.isEmpty }
    }

    /// Cuts every non-empty block of `ring` out of a finished tile and hands each encoded piece to
    /// `sink`. Triangles and placements are binned once by overlap; vertices are re-indexed per piece.
    static func bake(_ r: DioramaResidentTile, ring: Ring, device: MTLDevice,
                     sink: (ID, Data, Measured) throws -> Void) throws {
        let source = Source(r)
        let n = ring.divisions
        let tileRect = DioramaProjection(origin: r.tile.centre).rect(of: r.tile)
        let coarse = ring == .coarse
        func blockIndex(_ x: Float, _ y: Float) -> (Int, Int) {
            let c = Int(floor((Double(x) - tileRect.minX) / tileRect.width * Double(n)))
            let rw = Int(floor((Double(y) - tileRect.minY) / tileRect.height * Double(n)))
            return (c, rw)
        }
        // Bin triangle starts per block and range, then placements per block and group.
        var triangleBins = [[(range: Int, starts: [UInt32])]](repeating: [], count: n * n)
        var sources: [(UnsafeMutablePointer<UInt32>, Int, Int)?] = []
        for (ri, range) in r.ranges.enumerated() {
            try Task.checkCancellation()
            let src = source.source(for: range, coarse: coarse)
            sources.append(src)
            guard let (list, start, count) = src, count >= 3 else { continue }
            if n == 1 {
                triangleBins[0].append((ri, Array(Swift.stride(from: start, to: start + count - 2, by: 3)).map(UInt32.init)))
                continue
            }
            var perBlock = [[UInt32]](repeating: [], count: n * n)
            for t in Swift.stride(from: start, to: start + count - 2, by: 3) {
                let a = Int(list[t]), b = Int(list[t + 1]), c = Int(list[t + 2])
                guard a < r.vertexCount, b < r.vertexCount, c < r.vertexCount else { continue }
                let pa = source.vertices[a].position, pb = source.vertices[b].position, pc = source.vertices[c].position
                let lo = simd_min(simd_min(pa, pb), pc), hi = simd_max(simd_max(pa, pb), pc)
                guard lo.x.isFinite, lo.y.isFinite, hi.x.isFinite, hi.y.isFinite else { continue }
                let (c0, r0) = blockIndex(lo.x, lo.y), (c1, r1) = blockIndex(hi.x, hi.y)
                guard c1 >= 0, r1 >= 0, c0 < n, r0 < n else { continue }
                for row in max(0, r0)...min(n - 1, r1) {
                    for column in max(0, c0)...min(n - 1, c1) { perBlock[row * n + column].append(UInt32(t)) }
                }
            }
            for block in 0..<(n * n) where !perBlock[block].isEmpty { triangleBins[block].append((ri, perBlock[block])) }
        }
        var placementBins = [[(group: Int, placements: [DioramaInstanceData])]](repeating: [], count: n * n)
        for (gi, group) in r.groups.enumerated() {
            if n == 1 { placementBins[0].append((gi, group.instances)); continue }
            var perBlock = [[DioramaInstanceData]](repeating: [], count: n * n)
            for placement in group.instances {
                let radius = max(0, placement.radius)
                let (c0, r0) = blockIndex(placement.placement.x - radius, placement.placement.y - radius)
                let (c1, r1) = blockIndex(placement.placement.x + radius, placement.placement.y + radius)
                guard c1 >= 0, r1 >= 0, c0 < n, r0 < n else { continue }
                for row in max(0, r0)...min(n - 1, r1) {
                    for column in max(0, c0)...min(n - 1, c1) { perBlock[row * n + column].append(placement) }
                }
            }
            for block in 0..<(n * n) where !perBlock[block].isEmpty { placementBins[block].append((gi, perBlock[block])) }
        }

        // Shared ground texture copy the CPU can read (snapshot-mapped tiles keep theirs private).
        let readable = try r.groundTexture.map { try readableCopy($0, device: device) }
        let paintCount = r.paintBuffer.length / MemoryLayout<DioramaPaintTriangle>.stride
        let paint = UnsafeBufferPointer(start: r.paintBuffer.contents().assumingMemoryBound(to: DioramaPaintTriangle.self), count: paintCount)
        var remap = [Int32](repeating: -1, count: r.vertexCount)
        let painted = DioramaHalf.bits(9)

        for row in 0..<n {
            for column in 0..<n {
                try Task.checkCancellation()
                let block = row * n + column
                let id = ID(tile: r.tile, ring: ring, column: column, row: row)
                let blockRect = id.block(in: tileRect)
                var slice = Slice()
                var touched: [Int] = []
                func mapped(_ old: UInt32) -> UInt32 {
                    let o = Int(old)
                    if remap[o] >= 0 { return UInt32(remap[o]) }
                    let new = slice.vertices.count
                    remap[o] = Int32(new); touched.append(o)
                    let v = source.vertices[o]
                    slice.vertices.append(v)
                    let p = SIMD3(v.position.x, v.position.y, v.position.z)
                    if v.color.w == DioramaHalf.bits(5), DioramaHalf.float(v.normal.w) < 0.5 {
                        slice.poolLow = simd_min(slice.poolLow, p); slice.poolHigh = simd_max(slice.poolHigh, p)
                    }
                    if DioramaHalf.float(v.normal.w) < 3.5, p.x.isFinite, p.y.isFinite, p.z.isFinite {
                        slice.shadowLow = simd_min(slice.shadowLow, p); slice.shadowHigh = simd_max(slice.shadowHigh, p)
                    }
                    return UInt32(new)
                }
                for (ri, starts) in triangleBins[block] {
                    guard let (list, _, _) = sources[ri] else { continue }
                    let range = r.ranges[ri]
                    let start = slice.indices.count
                    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                    for t in starts {
                        let o = Int(t)
                        let a = list[o], b = list[o + 1], c = list[o + 2]
                        guard Int(a) < r.vertexCount, Int(b) < r.vertexCount, Int(c) < r.vertexCount else { continue }
                        let ma = mapped(a), mb = mapped(b), mc = mapped(c)
                        slice.indices.append(contentsOf: [ma, mb, mc])
                        for m in [ma, mb, mc] {
                            let p = slice.vertices[Int(m)].position
                            lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                        }
                    }
                    let count = slice.indices.count - start
                    guard count > 0 else { continue }
                    var cut = DioramaRenderLayer.Range(category: range.category, start: start, count: count, minimum: lo, maximum: hi,
                                                       doubleSided: range.doubleSided, translucent: range.translucent)
                    cut.landmarkPlaceholder = range.landmarkPlaceholder; cut.landmarkID = range.landmarkID
                    slice.ranges.append(cut)
                }
                var prototypes: [String: Int] = [:]
                func prototype(_ list: UnsafeMutablePointer<UInt32>, _ start: Int, _ count: Int, lod: Bool) -> Int? {
                    let key = "\(lod ? "l" : "m")/\(start)/\(count)"
                    if let prior = prototypes[key] { return prior }
                    let copied = slice.indices.count
                    for i in start..<(start + count) {
                        guard Int(list[i]) < r.vertexCount else { return nil }
                        slice.indices.append(mapped(list[i]))
                    }
                    prototypes[key] = copied
                    return copied
                }
                for (gi, placements) in placementBins[block] {
                    let group = r.groups[gi]
                    guard let (list, start, count) = source.prototype(for: group, coarse: coarse), count >= 3,
                          let fullStart = prototype(list, start, count, lod: list == source.lodIndices) else { continue }
                    var lightStart = fullStart, lightCount = count
                    if group.lightCount >= 3, group.lightStart >= 0, group.lightStart <= r.indexCount - group.lightCount,
                       let copied = prototype(source.indices, group.lightStart, group.lightCount, lod: false) {
                        lightStart = copied; lightCount = group.lightCount
                    }
                    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                    for i in placements {
                        lo = simd_min(lo, i.centre - SIMD3(repeating: i.radius)); hi = simd_max(hi, i.centre + SIMD3(repeating: i.radius))
                    }
                    slice.shadowLow = simd_min(slice.shadowLow, lo); slice.shadowHigh = simd_max(slice.shadowHigh, hi)
                    var cut = DioramaInstanceGroup(category: group.category, fullStart: fullStart, fullCount: count, lightStart: lightStart,
                        lightCount: lightCount, doubleSided: group.doubleSided, instances: placements, firstInstance: slice.instances.count,
                        minimum: lo, maximum: hi)
                    cut.landmarkPlaceholder = group.landmarkPlaceholder; cut.landmarkID = group.landmarkID; cut.lodScale = group.lodScale
                    slice.groups.append(cut)
                    slice.instances.append(contentsOf: placements)
                }
                for o in touched { remap[o] = -1 }
                touched.removeAll(keepingCapacity: true)
                guard !slice.isEmpty, slice.vertices.count < 1 << 24 else { continue }

                // Ground rectangle: the block snapped outward to whole texels of the tile raster.
                var groundRect = blockRect
                var crop: (x: Int, y: Int, width: Int, height: Int)?
                if let texture = readable {
                    let size = texture.width
                    let u0 = (blockRect.minX - tileRect.minX) / tileRect.width, u1 = (blockRect.maxX - tileRect.minX) / tileRect.width
                    let v0 = (blockRect.minY - tileRect.minY) / tileRect.height, v1 = (blockRect.maxY - tileRect.minY) / tileRect.height
                    let x0 = max(0, Int(floor(u0 * Double(size) - 1e-6))), x1 = min(size, Int(ceil(u1 * Double(size) + 1e-6)))
                    // Row 0 of the raster is the tile's north edge.
                    let y0 = max(0, Int(floor((1 - v1) * Double(texture.height) - 1e-6))), y1 = min(texture.height, Int(ceil((1 - v0) * Double(texture.height) + 1e-6)))
                    guard x1 > x0, y1 > y0 else { continue }
                    crop = (x0, y0, x1 - x0, y1 - y0)
                    groundRect = DioramaRect(minX: tileRect.minX + Double(x0) / Double(size) * tileRect.width,
                                             minY: tileRect.minY + (1 - Double(y1) / Double(texture.height)) * tileRect.height,
                                             maxX: tileRect.minX + Double(x1) / Double(size) * tileRect.width,
                                             maxY: tileRect.minY + (1 - Double(y0) / Double(texture.height)) * tileRect.height)
                }

                // Lights that reach the block, re-gridded over the piece rectangle.
                let reach = r.lightGrid.lights.filter { l in
                    groundRect.expanded(by: Double(max(0, l.position.w))).contains(DV2(Double(l.position.x), Double(l.position.y)))
                }.map { l in
                    DioramaLight(position: DV3(Double(l.position.x), Double(l.position.y), Double(l.position.z)),
                                 color: SIMD3(l.color.x, l.color.y, l.color.z), radius: Double(l.position.w), intensity: l.color.w)
                }
                let grid = DioramaLightGrid.build(reach, rect: groundRect, cells: ring.lightCells, perCell: 16)
                // Vector finishes that touch the block, re-binned over the piece rectangle (epochs kept).
                let marks = paint.filter { AirportSpatialPackage.paintIntersects($0, rect: groundRect.expanded(by: 0.6)) }
                let vectorPaint = AirportSpatialPackage.rebinned(Array(marks), rect: groundRect)
                let labels = r.labels.filter { groundRect.contains(DV2(Double($0.anchor.x), Double($0.anchor.y))) }
                let groundIndex: DioramaGroundIndex? = slice.indices.withUnsafeBufferPointer { idx in
                    slice.vertices.withUnsafeBufferPointer { verts in
                        DioramaGroundIndex(rect: groundRect, ranges: slice.ranges, index: { idx[$0] }, position: { verts[$0].position },
                                           isGround: { verts[$0].color.w == painted })
                    }
                }

                let data = try encode(slice, id: id, groundRect: groundRect, lightGrid: grid, paint: vectorPaint, labels: labels,
                                      groundIndex: groundIndex, texture: readable, crop: crop, device: device,
                                      waterHeight: r.waterHeight, materialCounts: r.materialCounts)
                try sink(id, data, Measured(id: id, bytes: data.count, triangles: slice.ranges.reduce(0) { $0 + $1.count } / 3,
                                            instances: slice.instances.count, vertices: slice.vertices.count))
            }
        }
    }

    /// A CPU-readable (shared) copy of a tile's ground raster.
    private static func readableCopy(_ texture: MTLTexture, device: MTLDevice) throws -> MTLTexture {
        if texture.storageMode == .shared { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
        guard let copy = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue(),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { throw DioramaTileArchive.ArchiveError.invalid }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: copy, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw DioramaTileArchive.ArchiveError.invalid }
        return copy
    }

    // MARK: - Encode

    private static func encode(_ slice: Slice, id: ID, groundRect: DioramaRect, lightGrid: DioramaLightGrid, paint: DioramaVectorPaint,
                               labels: [DioramaBuildingLabel], groundIndex: DioramaGroundIndex?, texture: MTLTexture?,
                               crop: (x: Int, y: Int, width: Int, height: Int)?, device: MTLDevice,
                               waterHeight: Double, materialCounts: SIMD2<Int>) throws -> Data {
        var payload = Data()
        var sections: [Section] = []
        func section(_ name: String, _ bytes: UnsafeRawBufferPointer, codec: Int) {
            guard bytes.count > 0, let base = bytes.baseAddress else {
                sections.append(Section(name: name, offset: payload.count, length: 0, stored: 0, compressed: false, codec: 0)); return
            }
            var planes: UnsafeMutableRawPointer?
            var input = base
            if let layout = layout(codec), bytes.count % layout.record == 0 {
                let p = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 16)
                DioramaArchiveCodec.encode(bytes, layout: layout, into: p)
                planes = p; input = UnsafeRawPointer(p)
            }
            defer { planes?.deallocate() }
            let capacity = bytes.count + 65536
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { output.deallocate() }
            let stored = compression_encode_buffer(output, capacity, input.assumingMemoryBound(to: UInt8.self), bytes.count, nil, COMPRESSION_LZFSE)
            let offset = payload.count
            if stored > 0, stored < bytes.count {
                payload.append(output, count: stored)
                sections.append(Section(name: name, offset: offset, length: bytes.count, stored: stored, compressed: true, codec: planes == nil ? 0 : codec))
            } else {
                payload.append(input.assumingMemoryBound(to: UInt8.self), count: bytes.count)
                sections.append(Section(name: name, offset: offset, length: bytes.count, stored: bytes.count, compressed: false, codec: planes == nil ? 0 : codec))
            }
        }
        func array<T>(_ name: String, _ values: [T], codec: Int) { values.withUnsafeBytes { section(name, $0, codec: codec) } }

        array("vertices", slice.vertices, codec: 1)
        array("indices", slice.indices, codec: 2)
        array("instances", slice.instances, codec: 3)
        array("paint", paint.triangles, codec: 3)
        array("paintTable", paint.table, codec: 4)
        array("paintIndices", paint.indices, codec: 2)
        array("lights", lightGrid.lights, codec: 0)
        array("lightTable", lightGrid.table, codec: 4)
        array("lightIndices", lightGrid.indices, codec: 2)
        array("groundOffsets", groundIndex?.offsets ?? [], codec: 2)
        array("groundTriangles", groundIndex?.triangles ?? [], codec: 2)

        var imageWidth = 0, imageHeight = 0
        var mipOffsets: [Int] = []
        if let texture, let crop {
            // Cut level 0, then let the GPU build the piece's own mip chain so distant sampling matches tiles.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: crop.width, height: crop.height, mipmapped: true)
            descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
            guard let piece = device.makeTexture(descriptor: descriptor) else { throw DioramaTileArchive.ArchiveError.invalid }
            var level0 = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            level0.withUnsafeMutableBytes { bytes in
                texture.getBytes(bytes.baseAddress!, bytesPerRow: crop.width * 4, from: MTLRegionMake2D(crop.x, crop.y, crop.width, crop.height), mipmapLevel: 0)
                piece.replace(region: MTLRegionMake2D(0, 0, crop.width, crop.height), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: crop.width * 4)
            }
            if piece.mipmapLevelCount > 1, let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: piece); blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            }
            var texels: [UInt8] = []
            for level in 0..<piece.mipmapLevelCount {
                let w = max(1, crop.width >> level), h = max(1, crop.height >> level)
                mipOffsets.append(texels.count)
                var rows = [UInt8](repeating: 0, count: w * h * 4)
                rows.withUnsafeMutableBytes { piece.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level) }
                texels.append(contentsOf: rows)
            }
            imageWidth = crop.width; imageHeight = crop.height
            array("texture", texels, codec: 5)
        }
        let pool = slice.poolLow.x <= slice.poolHigh.x
            ? RangeRecord(DioramaRenderLayer.Range(category: .water, start: 0, count: 0, minimum: slice.poolLow, maximum: slice.poolHigh)) : nil
        let shadow = slice.shadowLow.x.isFinite && slice.shadowHigh.x > slice.shadowLow.x
        let header = Header(format: format, z: id.tile.z, x: id.tile.x, y: id.tile.y, ring: id.ring, column: id.column, row: id.row,
            bounds: [groundRect.minX, groundRect.minY, groundRect.maxX, groundRect.maxY],
            vertexCount: slice.vertices.count, indexCount: slice.indices.count, instanceCount: slice.instances.count,
            ranges: slice.ranges.map(RangeRecord.init), groups: slice.groups.map(GroupRecord.init),
            lightCells: lightGrid.cells, lightMinX: lightGrid.minX, lightMinY: lightGrid.minY, lightCellSize: lightGrid.cellSize,
            ground: groundIndex.map { GroundRecord(minX: $0.minX, minY: $0.minY, cell: $0.cell, columns: $0.columns, rows: $0.rows) },
            imageWidth: imageWidth, imageHeight: imageHeight, mipOffsets: mipOffsets, waterHeight: waterHeight, pool: pool,
            shadowLow: shadow ? slice.shadowLow : nil, shadowHigh: shadow ? slice.shadowHigh : nil,
            foliage: materialCounts.x, architecture: materialCounts.y,
            labels: labels.map { LabelRecord(id: $0.id, title: $0.title, anchor: $0.anchor, footprint: $0.footprint.flatMap { [$0.x, $0.y] }, named: $0.isNamed) },
            sections: sections, sourceTriangles: slice.indices.count / 3)
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let json = try encoder.encode(header)
        var data = Data(magic)
        var length = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(payload)
        return data
    }

    // MARK: - Decode (view time)

    struct Decoded: @unchecked Sendable {
        let resident: DioramaResidentTile
        let groundRect: DioramaRect
        let header: Header
    }

    /// Receive → decompress into shared Metal storage → draw. Every offset is bounds-checked so a
    /// damaged download is rejected rather than handed to the GPU.
    static func decode(_ data: Data, expected id: ID, device: MTLDevice) throws -> Decoded {
        guard data.count > magic.count + 4, Array(data.prefix(magic.count)) == magic else { throw DioramaTileArchive.ArchiveError.incompatible }
        let headerLength = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: magic.count, as: UInt32.self).littleEndian })
        let headerStart = magic.count + 4
        guard headerLength > 0, headerLength <= 8 * 1_048_576, headerLength <= data.count - headerStart else { throw DioramaTileArchive.ArchiveError.invalid }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let h = try decoder.decode(Header.self, from: data.subdata(in: headerStart..<(headerStart + headerLength)))
        guard h.format == format, h.z == id.tile.z, h.x == id.tile.x, h.y == id.tile.y, h.ring == id.ring, h.column == id.column, h.row == id.row,
              h.bounds.count == 4, h.bounds.allSatisfy({ $0.isFinite && abs($0) < 100_000 }),
              h.vertexCount >= 0, h.indexCount >= 0, h.indexCount % 3 == 0, h.instanceCount >= 0, h.vertexCount < 1 << 24,
              h.waterHeight.isFinite, h.lightCells > 0, h.lightCells <= 128, h.lightCellSize.isFinite, h.lightCellSize > 0,
              h.imageWidth >= 0, h.imageWidth <= 4096, h.imageHeight >= 0, h.imageHeight <= 4096,
              h.sections.reduce(0, { $0 + $1.length }) <= maxDecodedBytes else { throw DioramaTileArchive.ArchiveError.invalid }
        let groundRect = DioramaRect(minX: h.bounds[0], minY: h.bounds[1], maxX: h.bounds[2], maxY: h.bounds[3])
        guard groundRect.width > 0, groundRect.height > 0 else { throw DioramaTileArchive.ArchiveError.invalid }
        let payloadStart = headerStart + headerLength
        let sections = Dictionary(h.sections.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        func fill(_ s: Section, into target: UnsafeMutableRawPointer) throws {
            guard s.length > 0 else { return }
            guard s.offset >= 0, s.stored > 0, s.offset <= data.count - payloadStart - s.stored else { throw DioramaTileArchive.ArchiveError.invalid }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { throw DioramaTileArchive.ArchiveError.invalid }
                let input = base.advanced(by: payloadStart + s.offset).assumingMemoryBound(to: UInt8.self)
                if s.compressed {
                    let decoded = compression_decode_buffer(target.assumingMemoryBound(to: UInt8.self), s.length, input, s.stored, nil, COMPRESSION_LZFSE)
                    guard decoded == s.length else { throw DioramaTileArchive.ArchiveError.compression }
                } else {
                    guard s.stored == s.length else { throw DioramaTileArchive.ArchiveError.invalid }
                    target.copyMemory(from: input, byteCount: s.length)
                }
            }
            if let layout = layout(s.codec) { try DioramaArchiveCodec.decodeInPlace(target, bytes: s.length, layout: layout) }
        }
        func buffer(_ name: String, minimum: Int) throws -> MTLBuffer {
            guard let s = sections[name], s.length >= minimum else { throw DioramaTileArchive.ArchiveError.invalid }
            guard let b = device.makeBuffer(length: max(16, s.length), options: .storageModeShared) else { throw DioramaTileArchive.ArchiveError.invalid }
            try fill(s, into: b.contents())
            return b
        }
        func values<T>(_ name: String, _ type: T.Type) throws -> [T] {
            guard let s = sections[name], s.length % MemoryLayout<T>.stride == 0 else { throw DioramaTileArchive.ArchiveError.invalid }
            let count = s.length / MemoryLayout<T>.stride
            guard count > 0 else { return [] }
            var result = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
            try result.withUnsafeMutableBytes { try fill(s, into: $0.baseAddress!) }
            return result
        }

        let vertexStride = MemoryLayout<DioramaPackedVertex>.stride
        let vertexBuffer = try buffer("vertices", minimum: h.vertexCount * vertexStride)
        let indexBuffer = try buffer("indices", minimum: h.indexCount * 4)
        let instanceBuffer = try buffer("instances", minimum: h.instanceCount * MemoryLayout<DioramaInstanceData>.stride)
        let paintBuffer = try buffer("paint", minimum: 0)
        let paintTableBuffer = try buffer("paintTable", minimum: 0)
        let paintIndexBuffer = try buffer("paintIndices", minimum: 0)
        let lights = try values("lights", DioramaShaderLight.self)
        let lightTable = try values("lightTable", SIMD2<UInt32>.self)
        let lightIndices = try values("lightIndices", UInt32.self)
        if Task.isCancelled { throw CancellationError() }

        let idx = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let vertexLimit = UInt32(h.vertexCount)
        for i in 0..<h.indexCount where idx[i] >= vertexLimit { throw DioramaTileArchive.ArchiveError.invalid }
        let packed = vertexBuffer.contents().assumingMemoryBound(to: DioramaPackedVertex.self)
        for i in 0..<h.vertexCount {
            let p = packed[i].position
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.w.isFinite else { throw DioramaTileArchive.ArchiveError.invalid }
        }
        let ranges = h.ranges.map(\.range)
        guard ranges.allSatisfy({ $0.start >= 0 && $0.count >= 0 && $0.count % 3 == 0 && $0.start <= h.indexCount - $0.count }) else { throw DioramaTileArchive.ArchiveError.invalid }
        var groups: [DioramaInstanceGroup] = []
        let groupInstances = instanceBuffer.contents().assumingMemoryBound(to: DioramaInstanceData.self)
        for record in h.groups {
            guard record.n >= 0, record.first >= 0, record.first <= h.instanceCount - record.n,
                  record.fs >= 0, record.fc >= 0, record.fs <= h.indexCount - record.fc,
                  record.ls >= 0, record.lc >= 0, record.ls <= h.indexCount - record.lc else { throw DioramaTileArchive.ArchiveError.invalid }
            let placements = (0..<record.n).map { groupInstances[record.first + $0] }
            guard placements.allSatisfy({ $0.placement.x.isFinite && $0.placement.y.isFinite && $0.placement.z.isFinite && $0.scale.w.isFinite }) else { throw DioramaTileArchive.ArchiveError.invalid }
            groups.append(record.group(placements))
        }
        let paintCount = (sections["paint"]?.length ?? 0) / MemoryLayout<DioramaPaintTriangle>.stride
        let paintTableCount = (sections["paintTable"]?.length ?? 0) / MemoryLayout<SIMD2<UInt32>>.stride
        let paintIndexCount = (sections["paintIndices"]?.length ?? 0) / 4
        let paintTable = paintTableBuffer.contents().assumingMemoryBound(to: SIMD2<UInt32>.self)
        let paintIndices = paintIndexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        guard paintTableCount == 0 || paintTableCount == DioramaVectorPaint.cells * DioramaVectorPaint.cells else { throw DioramaTileArchive.ArchiveError.invalid }
        for i in 0..<paintIndexCount where Int(paintIndices[i]) >= paintCount { throw DioramaTileArchive.ArchiveError.invalid }
        for i in 0..<paintTableCount {
            let t = paintTable[i]
            guard Int(t.x) <= paintIndexCount, Int(t.y) <= paintIndexCount - Int(t.x) else { throw DioramaTileArchive.ArchiveError.invalid }
        }
        guard lightTable.count == h.lightCells * h.lightCells, lightIndices.allSatisfy({ Int($0) < lights.count }),
              lightTable.allSatisfy({ Int($0.x) <= lightIndices.count && Int($0.y) <= lightIndices.count - Int($0.x) }),
              lights.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite && $0.position.w.isFinite }) else { throw DioramaTileArchive.ArchiveError.invalid }
        let grid = DioramaLightGrid(cells: h.lightCells, minX: h.lightMinX, minY: h.lightMinY, cellSize: h.lightCellSize,
                                    lights: lights, table: lightTable, indices: lightIndices)
        var groundIndex: DioramaGroundIndex?
        if let g = h.ground {
            let offsets = try values("groundOffsets", UInt32.self), triangles = try values("groundTriangles", UInt32.self)
            guard g.columns > 0, g.rows > 0, g.columns * g.rows < 4_000_000, g.cell > 0, g.cell.isFinite, offsets.count == g.columns * g.rows + 1,
                  offsets.first == 0, Int(offsets.last ?? 0) == triangles.count, zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }),
                  triangles.allSatisfy({ Int($0) <= h.indexCount - 3 }) else { throw DioramaTileArchive.ArchiveError.invalid }
            groundIndex = DioramaGroundIndex(minX: g.minX, minY: g.minY, cell: g.cell, columns: g.columns, rows: g.rows, offsets: offsets, triangles: triangles)
        }
        if Task.isCancelled { throw CancellationError() }

        var groundTexture: MTLTexture?
        if h.imageWidth > 0, h.imageHeight > 0 {
            let texels = try values("texture", UInt8.self)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: h.imageWidth, height: h.imageHeight, mipmapped: true)
            descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
            guard descriptor.mipmapLevelCount == h.mipOffsets.count, let texture = device.makeTexture(descriptor: descriptor) else { throw DioramaTileArchive.ArchiveError.invalid }
            try texels.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw DioramaTileArchive.ArchiveError.invalid }
                for (level, offset) in h.mipOffsets.enumerated() {
                    let w = max(1, h.imageWidth >> level), hgt = max(1, h.imageHeight >> level), count = w * hgt * 4
                    guard offset >= 0, offset <= texels.count - count else { throw DioramaTileArchive.ArchiveError.invalid }
                    texture.replace(region: MTLRegionMake2D(0, 0, w, hgt), mipmapLevel: level, withBytes: base.advanced(by: offset), bytesPerRow: w * 4)
                }
            }
            groundTexture = texture
        }
        let shadow: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? = h.shadowLow.flatMap { low in h.shadowHigh.map { (low, $0) } }
        let summary = DioramaTileSummary(shorelineReport: [], optimizationReport: ["Streamed \(id.ring.displayName) piece: drawn as received, nothing built on this phone"],
            stageTimings: [], totalTriangles: h.indexCount / 3, totalInstances: h.instanceCount,
            totalBytes: h.vertexCount * vertexStride + h.indexCount * 4, generationSeconds: 0)
        let resident = DioramaResidentTile(tile: id.tile, device: device, vertexBuffer: vertexBuffer, vertexCount: h.vertexCount,
            indexBuffer: indexBuffer, indexCount: h.indexCount, instanceBuffer: instanceBuffer, instanceCount: h.instanceCount,
            ranges: ranges, groups: groups, lightGrid: grid, paintBuffer: paintBuffer, paintTableBuffer: paintTableBuffer,
            paintIndexBuffer: paintIndexBuffer, groundTexture: groundTexture, waterHeight: h.waterHeight,
            labels: h.labels.map { l in
                DioramaBuildingLabel(id: l.id, title: l.title, anchor: l.anchor,
                    footprint: Swift.stride(from: 0, to: l.footprint.count - 1, by: 2).map { DV2(l.footprint[$0], l.footprint[$0 + 1]) }, isNamed: l.named)
            },
            poolBounds: h.pool?.range, shadowBounds: shadow, materialCounts: SIMD2(h.foliage, h.architecture), summary: summary,
            lod: nil, groundIndex: groundIndex)
        return Decoded(resident: resident, groundRect: groundRect, header: h)
    }
}
