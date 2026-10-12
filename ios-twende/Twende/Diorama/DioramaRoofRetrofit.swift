import Foundation
import simd

/// Read-time architecture pass over saved buildings.
///
/// Saved packages cap ordinary buildings with a flat deck behind a fat 0.8 m quarter-round shoulder,
/// which reads as a toy. At saved-tile read this pass finds every flat roof deck in the decoded
/// building geometry and analyses the actual vertices around it: the shoulder radius (fitted from the
/// shoulder's own positions and normals), anything standing on the deck, neighbours or parapets
/// pressing against it, the wall colour and the height above ground.
///
/// 1. The shoulder is re-profiled in place into a squared slab edge: the wall runs straight up to the
///    deck with a 10 cm arris and a thin coping strip. Same vertices, same triangles, no new geometry.
/// 2. Eligible low-rise decks get a roof designed by `DioramaArchitectRoof` around the footprint:
///    regularised rectangular wings, one pitch, thin fascia and soffit, gable walls in the wall colour.
///
/// Original package bytes, r3 and LOD stay valid (LOD levels index the same, re-profiled vertices).
/// Results are deterministic per building and carried in GPU-ready snapshots.
nonisolated enum DioramaRoofRetrofit {
    nonisolated struct Output: Sendable {
        var vertices: [DioramaPackedVertex] = []
        /// Zero-based into `vertices`.
        var indices: [UInt32] = []
        /// Starts are into `indices`.
        var ranges: [DioramaRenderLayer.Range] = []
        var decks = 0
        var roofs = 0
        var squared = 0
        var mansions = 0
        var walled = 0
        var report: String {
            "Architecture at read: \(squared) slab edges squared, \(roofs) framed roofs over \(decks) flat decks, \(mansions) period residences, \(walled) compound walls"
        }
    }

    private static let cell: Double = 2
    private static let upBits = DioramaHalf.bits(1)

    /// - Parameters:
    ///   - ranges: drawable saved ranges (landmark-owned shells already removed).
    ///   - vertexBudget: spare vertex capacity; roof building stops when it would be exceeded.
    static func build(packed: UnsafeMutablePointer<DioramaPackedVertex>, vertexCount: Int, index: UnsafePointer<UInt32>,
                      ranges: [DioramaRenderLayer.Range], tileRect: DioramaRect, vertexBudget: Int,
                      estate: DioramaEstate.Context? = nil, config: DioramaConfig = .slipway) -> Output? {
        let buildings = ranges.filter { $0.category == .buildings && !$0.landmarkPlaceholder && !$0.translucent && $0.count > 0 }
        guard !buildings.isEmpty else { return nil }
        let grid = tileRect.expanded(by: 24)
        let columns = Int(ceil(grid.width / cell)), rows = Int(ceil(grid.height / cell))
        guard columns > 0, rows > 0, columns * rows < 4_000_000 else { return nil }
        func cellIndex(_ x: Double, _ y: Double) -> Int? {
            let cx = Int(floor((x - grid.minX) / cell)), cy = Int(floor((y - grid.minY) / cell))
            guard cx >= 0, cy >= 0, cx < columns, cy < rows else { return nil }
            return cy * columns + cx
        }

        // 1. Unique building vertices bucketed by 2 m cell (counting sort), ground minima, flat decks.
        var seen = [Bool](repeating: false, count: vertexCount)
        var unique: [UInt32] = []
        var cellOf: [Int32] = []
        var minZ = [Float](repeating: .greatestFiniteMagnitude, count: columns * rows)
        var deckTriangles: [(UInt32, UInt32, UInt32)] = []
        for range in buildings {
            for t in Swift.stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                let a = index[t], b = index[t + 1], c = index[t + 2]
                guard Int(a) < vertexCount, Int(b) < vertexCount, Int(c) < vertexCount else { continue }
                for v in [a, b, c] where !seen[Int(v)] {
                    seen[Int(v)] = true
                    let p = packed[Int(v)].position
                    guard p.x.isFinite, p.y.isFinite, p.z.isFinite, let i = cellIndex(Double(p.x), Double(p.y)) else { continue }
                    unique.append(v); cellOf.append(Int32(i))
                    minZ[i] = min(minZ[i], p.z)
                    calmPaint(&packed[Int(v)])
                }
                let va = packed[Int(a)], vb = packed[Int(b)], vc = packed[Int(c)]
                guard va.normal.z == upBits, vb.normal.z == upBits, vc.normal.z == upBits,
                      va.normal.w == 0, vb.normal.w == 0, vc.normal.w == 0 else { continue }
                let tex = DioramaHalf.float(va.color.w)
                guard tex < 0.5 || (tex > 3.5 && tex < 4.5) || (tex > 10.5 && tex < 12.5) else { continue }
                deckTriangles.append((a, b, c))
            }
        }
        seen = []
        guard !deckTriangles.isEmpty else { return Output() }
        var starts = [Int](repeating: 0, count: columns * rows + 1)
        for c in cellOf { starts[Int(c) + 1] += 1 }
        for i in 0..<(columns * rows) { starts[i + 1] += starts[i] }
        var fill = starts
        var bucket = [UInt32](repeating: 0, count: unique.count)
        for (k, v) in unique.enumerated() { let c = Int(cellOf[k]); bucket[fill[c]] = v; fill[c] += 1 }
        unique = []; cellOf = []; fill = []

        // 2. Weld deck vertices by position (1 cm) and group triangles into connected decks.
        func key(_ v: UInt32) -> SIMD3<Int32> {
            let p = packed[Int(v)].position
            return SIMD3(Int32((p.x * 100).rounded()), Int32((p.y * 100).rounded()), Int32((p.z * 100).rounded()))
        }
        var parent = Array(0..<deckTriangles.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var owner: [SIMD3<Int32>: Int] = [:]
        owner.reserveCapacity(deckTriangles.count * 2)
        for (t, tri) in deckTriangles.enumerated() {
            for v in [tri.0, tri.1, tri.2] {
                let k = key(v)
                if let o = owner[k] {
                    let ra = find(o), rb = find(t)
                    if ra != rb { parent[rb] = ra }
                } else { owner[k] = t }
            }
        }
        owner = [:]
        var components: [Int: [Int]] = [:]
        for t in deckTriangles.indices { components[find(t), default: []].append(t) }

        var out = Output()
        var processed = [Bool](repeating: false, count: vertexCount)
        var bins: [Int: [UInt32]] = [:]
        var wallBins: [Int: [UInt32]] = [:]
        var homes: [DioramaEstate.Home] = []
        /// Packs a part into 60 m bins; `color` overrides every vertex colour (wall paint).
        func emit(_ part: DioramaMesh, color: SIMD3<Float>?, walls: Bool = false) {
            guard !part.indices.isEmpty else { return }
            let base = UInt32(out.vertices.count)
            for v in DioramaMeshPacking.vertices(part, category: walls ? .walls : .buildings, config: config) {
                out.vertices.append(DioramaPackedVertex(color.map {
                    BuildingRenderVertex(position: v.position, normal: v.normal, color: SIMD4($0, 1), appearance: v.appearance)
                } ?? v))
            }
            for i in Swift.stride(from: 0, to: part.indices.count - 2, by: 3) {
                let p = (part.positions[Int(part.indices[i])] + part.positions[Int(part.indices[i + 1])] + part.positions[Int(part.indices[i + 2])]) * (1.0 / 3)
                let binKey = (Int(floor(p.x / 60)) + 500) + (Int(floor(p.y / 60)) + 500) * 1000
                let triangle = [base + part.indices[i], base + part.indices[i + 1], base + part.indices[i + 2]]
                if walls { wallBins[binKey, default: []].append(contentsOf: triangle) } else { bins[binKey, default: []].append(contentsOf: triangle) }
            }
        }
        // Realistic Dar roofing: clay/stone-coated tile and red-oxide, galvanised or charcoal mabati.
        let tilePalette: [DioramaSwatch] = [.roofTerracotta, .roofTerracotta, .roofTerracotta, .roofMaroon, .roofMaroon]
        let mabatiPalette: [DioramaSwatch] = [.roofRust, .roofRust, .roofRust, .mabatiGrey, .mabatiGrey, .mabatiGrey, .roofCharcoal, .roofCharcoal, .roofGreen]
        let inner = tileRect.expanded(by: -1.0)

        for root in components.keys.sorted() {
            guard let members = components[root], members.count >= 2 else { continue }
            if Task.isCancelled { return nil }
            // Planar deck, its area and its single boundary loop.
            var zLow = Float.greatestFiniteMagnitude, zHigh = -zLow
            var area = 0.0
            var directed = Set<SIMD2<Int64>>()
            var points: [SIMD3<Int32>: DV2] = [:]
            func packKey(_ k: SIMD3<Int32>) -> Int64 { (Int64(k.x) << 32) ^ (Int64(k.y) & 0xFFFF_FFFF) }
            var keyOf: [Int64: SIMD3<Int32>] = [:]
            for t in members {
                let tri = deckTriangles[t]
                let ks = [key(tri.0), key(tri.1), key(tri.2)]
                let ps = [tri.0, tri.1, tri.2].map { packed[Int($0)].position }
                for p in ps { zLow = min(zLow, p.z); zHigh = max(zHigh, p.z) }
                let p0 = DV2(Double(ps[0].x), Double(ps[0].y)), p1 = DV2(Double(ps[1].x), Double(ps[1].y)), p2 = DV2(Double(ps[2].x), Double(ps[2].y))
                area += abs((p1 - p0).cross(p2 - p0)) * 0.5
                for j in 0..<3 {
                    points[ks[j]] = [p0, p1, p2][j]
                    keyOf[packKey(ks[j])] = ks[j]
                    directed.insert(SIMD2(packKey(ks[j]), packKey(ks[(j + 1) % 3])))
                }
            }
            out.decks += 1
            guard zHigh - zLow < 0.05, area >= 8, area <= 4_000 else { continue }
            var next: [Int64: Int64] = [:]
            var ambiguous = false
            for e in directed where !directed.contains(SIMD2(e.y, e.x)) {
                if next[e.x] != nil { ambiguous = true; break }
                next[e.x] = e.y
            }
            guard !ambiguous, let start = next.keys.min() else { continue }
            var loop: [DV2] = []
            var cursor = start
            var steps = 0
            repeat {
                guard let k = keyOf[cursor], let p = points[k], let n = next[cursor] else { ambiguous = true; break }
                loop.append(p); cursor = n; steps += 1
            } while cursor != start && steps <= next.count
            // Exactly one closed loop: courtyards, rings and fragments keep their saved roof.
            guard !ambiguous, cursor == start, steps == next.count else { continue }
            let ring = DioramaPolygon.counterClockwise(simplify(DioramaPolygon.counterClockwise(loop)))
            guard (4...240).contains(ring.count) else { continue }
            let zDeck = Double(zHigh)

            // 3. The actual vertices around the deck.
            var low = DV2(.greatestFiniteMagnitude, .greatestFiniteMagnitude), high = -low
            for p in ring { low = DV2(min(low.x, p.x), min(low.y, p.y)); high = DV2(max(high.x, p.x), max(high.y, p.y)) }
            let reach = 1.6
            var blocked = false, crowded = false
            var estimates: [Double] = []
            var shoulder: [(vertex: UInt32, estimate: Double)] = []
            var walls: [(d: Double, z: Float, rgb: SIMD3<Float>)] = []
            var rims: [(vertex: UInt32, d: Double, z: Double)] = []
            var ground = Float.greatestFiniteMagnitude
            if let c0 = cellIndex(low.x - reach, low.y - reach), let c1 = cellIndex(high.x + reach, high.y + reach) {
                let x0 = c0 % columns, y0 = c0 / columns, x1 = c1 % columns, y1 = c1 / columns
                for cy in y0...y1 {
                    for cx in x0...x1 {
                        let c = cy * columns + cx
                        ground = min(ground, minZ[c])
                        for k in starts[c]..<starts[c + 1] {
                            let v = bucket[k]
                            let vertex = packed[Int(v)]
                            let z = Double(vertex.position.z)
                            guard z >= zDeck - 3.6 else { continue }
                            let q = DV2(Double(vertex.position.x), Double(vertex.position.y))
                            guard q.x >= low.x - reach, q.x <= high.x + reach, q.y >= low.y - reach, q.y <= high.y + reach else { continue }
                            let inside = DioramaPolygon.contains(ring, q)
                            let d = DioramaPolygon.distanceToRing(ring, q)
                            if inside && d > 0.05 && z > zDeck + 0.35 { blocked = true }
                            if (!inside || d < 0.05) && d <= 1.4 && z > zDeck + 0.25 { crowded = true }
                            let nz = Double(DioramaHalf.float(vertex.normal.z))
                            let outsideOrOn = !inside || d < 0.02
                            if outsideOrOn, d <= 1.3, z <= zDeck + 0.01, z >= zDeck - 1.3, nz >= 0.15, nz <= 0.985, vertex.normal.w == 0 {
                                let b1 = d / max(1e-4, (1 - nz * nz).squareRoot()), b2 = (zDeck - z) / max(1e-4, 1 - nz)
                                if abs(b1 - b2) < 0.08 { let e = (b1 + b2) / 2; estimates.append(e); shoulder.append((v, e)) }
                            }
                            if outsideOrOn, abs(nz) < 0.03, d >= 0.2, d <= 1.3, z <= zDeck - 0.2, z >= zDeck - 1.3,
                               DioramaHalf.float(vertex.color.x) > 0.95, DioramaHalf.float(vertex.color.z) > 0.9 {
                                rims.append((v, d, z))
                            }
                            if outsideOrOn, abs(nz) < 0.25, d >= 0.05, d <= 1.5, z < zDeck - 0.3, vertex.normal.w == 0 {
                                let tex = DioramaHalf.float(vertex.color.w)
                                if tex < 0.5 || (tex > 11.5 && tex < 12.5) {
                                    walls.append((d, vertex.position.z, SIMD3(DioramaHalf.float(vertex.color.x), DioramaHalf.float(vertex.color.y), DioramaHalf.float(vertex.color.z))))
                                }
                            }
                        }
                    }
                }
            }
            // Shoulder radius from the shoulder's own geometry (generator default 0.8 m).
            var bevel = 0.0
            if estimates.count >= 8 {
                estimates.sort()
                let median = estimates[estimates.count / 2]
                let q1 = estimates[estimates.count / 4], q3 = estimates[estimates.count * 3 / 4]
                if median >= 0.25, median <= 1.25, q3 - q1 < 0.1 { bevel = median }
            }
            let zWall = zDeck - bevel
            // Wall colour: the most common colour on the wall plane itself (frames and cornices stand
            // proud of it), averaged within that bucket.
            var votes: [SIMD3<Int32>: (count: Int, sum: SIMD3<Float>)] = [:]
            for tolerance in [0.03, 0.4] where votes.isEmpty {
                for w in walls where abs(w.d - bevel) < tolerance && Double(w.z) < zWall - 0.1 && Double(w.z) > zWall - 3.0 {
                    let k = SIMD3<Int32>(Int32(w.rgb.x * 24), Int32(w.rgb.y * 24), Int32(w.rgb.z * 24))
                    let e = votes[k] ?? (0, .zero)
                    votes[k] = (e.count + 1, e.sum + w.rgb)
                }
            }
            let wall: SIMD3<Float>? = votes.values.max { $0.count < $1.count }.map { $0.sum / Float($0.count) }

            // 4. Square the shoulder in place: straight wall to the deck, 10 cm arris, coping strip.
            if bevel > 0 {
                let r = min(0.1, bevel * 0.25)
                var changed = false
                for item in shoulder where !processed[Int(item.vertex)] && abs(item.estimate - bevel) < 0.07 {
                    let i = Int(item.vertex)
                    var vertex = packed[i]
                    let n = SIMD3(DioramaHalf.float(vertex.normal.x), DioramaHalf.float(vertex.normal.y), DioramaHalf.float(vertex.normal.z))
                    let horizontal = SIMD2(n.x, n.y)
                    let length = simd_length(horizontal)
                    guard length > 0.1 else { continue }
                    let nh = horizontal / length
                    let a = Double(asin(min(1, max(0, n.z))))
                    let u = a / (Double.pi / 2)
                    guard u <= 5.0 / 6.0 + 0.02 else { continue }
                    let current = bevel * (1 - cos(a))
                    let wallPoint = SIMD2(vertex.position.x, vertex.position.y) + nh * Float(current)
                    var inset = 0.0, z = zWall, normal = SIMD3<Float>(nh.x, nh.y, 0)
                    if u <= 0.5 + 0.01 {
                        z = zWall + (bevel - r) * min(1, u / 0.5)
                        if let wall { vertex.color = SIMD4(DioramaHalf.bits(wall.x), DioramaHalf.bits(wall.y), DioramaHalf.bits(wall.z), vertex.color.w) }
                    } else {
                        let theta = min(1, (u - 0.5) * 3) * Double.pi / 2
                        inset = r * (1 - cos(theta)); z = zDeck - r + r * sin(theta)
                        normal = SIMD3(nh.x * Float(cos(theta)), nh.y * Float(cos(theta)), Float(sin(theta)))
                    }
                    let xy = wallPoint - nh * Float(inset)
                    let dz = Float(z) - vertex.position.z
                    let w = vertex.position.w > 50 ? vertex.position.w + dz : vertex.position.w
                    vertex.position = SIMD4(xy.x, xy.y, Float(z), w)
                    vertex.normal = SIMD4(DioramaHalf.bits(normal.x), DioramaHalf.bits(normal.y), DioramaHalf.bits(normal.z), vertex.normal.w)
                    packed[i] = vertex
                    processed[i] = true
                    changed = true
                }
                // The shoulder's bottom ring (still trim white) takes the wall colour too, so the wall
                // runs cleanly into the new slab edge with no white gradient.
                if changed, let wall {
                    for rim in rims where !processed[Int(rim.vertex)] && abs(rim.d - bevel) < 0.04 && abs(rim.z - zWall) < 0.03 {
                        let i = Int(rim.vertex)
                        packed[i].color = SIMD4(DioramaHalf.bits(wall.x), DioramaHalf.bits(wall.y), DioramaHalf.bits(wall.z), packed[i].color.w)
                        processed[i] = true
                    }
                }
                if changed { out.squared += 1 }
            }

            let insideTile = ring.allSatisfy({ inner.contains($0) })
            let centre = DioramaPolygon.centroid(ring)
            let wallRing = bevel > 0 ? (DioramaPolygon.offset(ring, by: bevel) ?? ring) : ring
            if let estate, insideTile, ground.isFinite, zDeck - Double(ground) >= 2.4 {
                // 5a. Grand residences: period architecture chosen from the plan.
                let heightAbove = zDeck - Double(ground)
                let site = estate.sites.first { $0.centre.distance(to: centre) < $0.radius }
                var greenery = 0.0
                // Two/three-storey residences on big garden plots; half stay contemporary villas.
                var periodRng = DioramaRandom(seed: UInt64(bitPattern: Int64(floor(centre.x)) &* 2_654_435_761 ^ Int64(floor(centre.y))), salt: 0x50_45_52)
                let periodRoll = periodRng.unit()
                if site == nil, area >= 450, area <= 3_500, heightAbove >= 5.5, heightAbove <= 11.5, !crowded, periodRoll < 0.5 {
                    var soft = 0, total = 0
                    for side in 0..<4 {
                        for k in 0..<4 {
                            let t = (Double(k) + 0.5) / 4
                            let p: DV2 = side == 0 ? DV2(low.x + (high.x - low.x) * t, low.y - 4) : side == 1 ? DV2(high.x + 4, low.y + (high.y - low.y) * t)
                                : side == 2 ? DV2(low.x + (high.x - low.x) * t, high.y + 4) : DV2(low.x - 4, low.y + (high.y - low.y) * t)
                            guard let m = estate.material(p) else { continue }
                            total += 1
                            if m == 0 || m == 1 || m == 6 { soft += 1 }
                        }
                    }
                    greenery = total > 0 ? Double(soft) / Double(total) : 0
                }
                if site != nil || greenery >= 0.5 {
                    var srng = DioramaRandom(seed: UInt64(bitPattern: Int64(floor(centre.x / 4)) &* 83_492_791 ^ Int64(floor(centre.y / 4)) &* 19_349_663), salt: 0x45_53_54)
                    let plan = DioramaArchitectRoof.plan(wall: wallRing)
                    let style = DioramaEstate.style(for: site, area: area, wings: plan?.wings.count ?? 1, seed: srng.unit())
                    let paint = DioramaEstate.wallPaint(style, current: wall)
                    // Repaint the facade planes (frames, glass and trim keep their own pigments).
                    if let c0 = cellIndex(low.x - 1.8, low.y - 1.8), let c1 = cellIndex(high.x + 1.8, high.y + 1.8) {
                        let x0 = c0 % columns, y0 = c0 / columns, x1 = c1 % columns, y1 = c1 / columns
                        for cy in y0...y1 {
                            for cx in x0...x1 {
                                let c = cy * columns + cx
                                for k in starts[c]..<starts[c + 1] {
                                    let v = Int(bucket[k])
                                    let vertex = packed[v]
                                    guard Double(vertex.position.z) < zDeck + 0.01, vertex.normal.w == 0,
                                          abs(DioramaHalf.float(vertex.normal.z)) < 0.25 else { continue }
                                    let tex = DioramaHalf.float(vertex.color.w)
                                    guard tex < 0.5 || (tex > 11.5 && tex < 12.5) else { continue }
                                    let q = DV2(Double(vertex.position.x), Double(vertex.position.y))
                                    let inside = DioramaPolygon.contains(ring, q)
                                    let d = DioramaPolygon.distanceToRing(ring, q)
                                    guard !inside || d < 0.05, d <= 1.6 else { continue }
                                    let rgb = SIMD3(DioramaHalf.float(vertex.color.x), DioramaHalf.float(vertex.color.y), DioramaHalf.float(vertex.color.z))
                                    // Painted plaster only: dark frames/doors and coloured trim stay.
                                    guard simd_reduce_min(rgb) > 0.35 else { continue }
                                    packed[v].color = SIMD4(DioramaHalf.bits(paint.x), DioramaHalf.bits(paint.y), DioramaHalf.bits(paint.z), vertex.color.w)
                                }
                            }
                        }
                    }
                    var roofMesh = DioramaMesh(), infill = DioramaMesh(), dressing = DioramaMesh()
                    var flatRoof = true
                    var mansard: (eave: Double, curb: Double)?
                    if style != .neoclassical, !blocked, let plan, plan.coverage >= 0.8 {
                        var eave = 0.0, curb = 0.0
                        let french = style == .french
                        if DioramaArchitectRoof.build(plan, form: french ? .mansard : .hip, wall: wallRing, zDeck: zDeck,
                                                      pitchDegrees: french ? 72 : 28, overhang: french ? 0.3 : 0.75,
                                                      color: french ? .roofSlate : .roofTerracotta, into: &roofMesh, infill: &infill,
                                                      eave: &eave, curb: &curb), !roofMesh.indices.isEmpty {
                            flatRoof = false
                            if french { mansard = (eave, curb) }
                        } else if french {
                            roofMesh = DioramaMesh(); infill = DioramaMesh()
                            if DioramaArchitectRoof.build(plan, form: .hip, wall: wallRing, zDeck: zDeck, pitchDegrees: 32, overhang: 0.45,
                                                          color: .roofSlate, into: &roofMesh, infill: &infill), !roofMesh.indices.isEmpty {
                                flatRoof = false
                            }
                        }
                    }
                    let front = DioramaEstate.front(of: wallRing, context: estate, site: site)
                    DioramaEstate.dress(style: style, wall: wallRing, zDeck: zDeck, ground: Double(ground), front: front,
                                        columns: site?.columns ?? 0, plan: plan, flatRoof: flatRoof, mansard: mansard,
                                        context: estate, into: &dressing)
                    let added = roofMesh.positions.count + infill.positions.count + dressing.positions.count
                    if out.vertices.count + added <= vertexBudget {
                        emit(roofMesh, color: nil)
                        emit(infill, color: paint)
                        emit(dressing, color: nil)
                        out.mansions += 1
                        homes.append(.init(wall: wallRing, area: area, height: heightAbove, ground: Double(ground), color: paint, mansion: true))
                        continue
                    }
                }
                if heightAbove <= 22 {
                    homes.append(.init(wall: wallRing, area: area, height: heightAbove, ground: Double(ground), color: wall, mansion: false))
                }
            }

            // 5. A framed roof where an architect would put one.
            guard !blocked, !crowded, ground.isFinite, area >= 20, area <= 2_500, insideTile else { continue }
            let height = zDeck - Double(ground)
            guard height >= 2.4 else { continue }
            var rng = DioramaRandom(seed: UInt64(bitPattern: Int64(floor(centre.x / 4)) &* 73_856_093 ^ Int64(floor(centre.y / 4)) &* 19_349_663),
                                    salt: 0x52_45_54_52)
            let roll = rng.unit()
            let large = area > 700
            // Share of pitched roofs by storeys (Kisutu/Masaki/Sinza street surveys): single and double
            // storey almost always mabati or tile; four storeys rarely; big sheds usually low pitch.
            let share: Double
            if large { share = height <= 10.5 ? 0.8 : 0 }
            else if height <= 7.5 { share = 0.9 }
            else if height <= 10.5 { share = 0.7 }
            else if height <= 13.5 { share = 0.35 }
            else { share = 0 }
            guard roll < share else { continue }
            guard let wallLine = bevel > 0 ? DioramaPolygon.offset(ring, by: bevel) : ring,
                  let plan = DioramaArchitectRoof.plan(wall: wallLine), plan.coverage >= 0.85 else { continue }

            let formRoll = rng.unit()
            let wing = plan.wings[0]
            let aspect = max(wing.width, wing.height) / max(min(wing.width, wing.height), 0.1)
            let form: DioramaArchitectRoof.Form
            if plan.wings.count > 1 { form = .hip }
            else if large { form = formRoll < 0.6 ? .gable : .hip }
            else if wing.width * wing.height < 40 { form = formRoll < 0.55 ? .shed : (formRoll < 0.85 ? .gable : .hip) }
            else if aspect > 1.8 { form = formRoll < 0.45 ? .gable : .hip }
            else { form = formRoll < 0.3 ? .gable : .hip }
            let tile = rng.unit() < 0.42
            let color = tile ? tilePalette[Int(rng.next() % UInt64(tilePalette.count))] : mabatiPalette[Int(rng.next() % UInt64(mabatiPalette.count))]
            let pitch = large ? 12.0 : (tile ? 26.0 : 20.0)
            var mesh = DioramaMesh(), infill = DioramaMesh()
            guard DioramaArchitectRoof.build(plan, form: form, wall: wallLine, zDeck: zDeck, pitchDegrees: pitch,
                                             overhang: large ? 0.8 : 0.6, color: color, into: &mesh, infill: &infill),
                  !mesh.indices.isEmpty else { continue }
            guard out.vertices.count + mesh.positions.count + infill.positions.count <= vertexBudget else { break }

            emit(mesh, color: nil)
            emit(infill, color: wall ?? SIMD3<Float>(0.95, 0.92, 0.84))
            out.roofs += 1
        }

        // 6. Compound walls around homes and apartment blocks with room for a plot.
        if let estate, !homes.isEmpty, var occupancy = DioramaEstate.Occupancy(rect: tileRect.expanded(by: 2)) {
            for range in ranges where (range.category == .buildings || range.category == .walls) && !range.translucent {
                let bit: UInt8 = range.category == .walls ? 2 : 1
                for t in Swift.stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                    let a = packed[Int(index[t])].position, b = packed[Int(index[t + 1])].position, c = packed[Int(index[t + 2])].position
                    occupancy.mark(DV2(Double(min(a.x, b.x, c.x)), Double(min(a.y, b.y, c.y))),
                                   DV2(Double(max(a.x, b.x, c.x)), Double(max(a.y, b.y, c.y))), bit)
                }
            }
            // New roofs and porticos are buildings too.
            for v in out.vertices {
                let p = DV2(Double(v.position.x), Double(v.position.y))
                occupancy.mark(p, p, 1)
            }
            if !Task.isCancelled {
                let walls = DioramaEstate.compoundWalls(homes: homes, occupancy: &occupancy, context: estate, tileRect: tileRect,
                                                        vertexBudget: max(0, vertexBudget - out.vertices.count))
                for part in walls.parts { emit(part.mesh, color: part.color, walls: true) }
                out.walled = walls.count
            }
        }

        for (category, table) in [(DioramaCategory.buildings, bins), (DioramaCategory.walls, wallBins)] {
            for key in table.keys.sorted() {
                guard let list = table[key], !list.isEmpty else { continue }
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                for i in list {
                    let p = out.vertices[Int(i)].position
                    lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                }
                out.ranges.append(.init(category: category, start: out.indices.count, count: list.count,
                                        minimum: lo, maximum: hi, doubleSided: false))
                out.indices.append(contentsOf: list)
            }
        }
        return out
    }

    /// Toy-bright wall paints (sunflower, mint, sky blue, coral) are eased 20 % toward a warm mineral
    /// grey of the same lightness; cream, white and already muted renders are left as they are.
    private static func calmPaint(_ vertex: inout DioramaPackedVertex) {
        let tex = DioramaHalf.float(vertex.color.w)
        guard vertex.normal.w == 0, tex < 0.5 || (tex > 11.5 && tex < 12.5) else { return }
        let c = SIMD3(DioramaHalf.float(vertex.color.x), DioramaHalf.float(vertex.color.y), DioramaHalf.float(vertex.color.z))
        let high = max(c.x, c.y, c.z), low = min(c.x, c.y, c.z)
        guard high > 0.05, (high - low) / high > 0.32 else { return }
        let luma = simd_dot(c, SIMD3(0.299, 0.587, 0.114))
        let mineral = SIMD3<Float>(1.04, 1.0, 0.93) * luma
        let eased = simd_mix(c, simd_min(mineral, SIMD3(repeating: 1)), SIMD3(repeating: 0.2))
        vertex.color = SIMD4(DioramaHalf.bits(eased.x), DioramaHalf.bits(eased.y), DioramaHalf.bits(eased.z), vertex.color.w)
    }

    /// Drops near-duplicate and collinear points (rounded-corner arcs keep their shape within 3 cm).
    private static func simplify(_ ring: [DV2]) -> [DV2] {
        var points: [DV2] = []
        for p in ring where points.last.map({ $0.distance(to: p) > 0.05 }) ?? true { points.append(p) }
        if let first = points.first, let last = points.last, points.count > 1, first.distance(to: last) <= 0.05 { points.removeLast() }
        var changed = true
        while changed && points.count > 3 {
            changed = false
            var i = 0
            while i < points.count && points.count > 3 {
                let a = points[(i + points.count - 1) % points.count], b = points[i], c = points[(i + 1) % points.count]
                let span = c - a
                let length = span.length
                let deviation = length > 1e-6 ? abs(span.cross(b - a)) / length : 0
                if deviation < 0.03 { points.remove(at: i); changed = true } else { i += 1 }
            }
        }
        return points
    }
}
