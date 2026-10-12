import Foundation

/// Roofs framed the way a builder frames them, around footprints that cannot change.
///
/// Mapped outlines carry rounded corners, chamfers, bay notches and digitising wobble. A roof that
/// follows every one of those (curved eaves, S-shaped fascias, fat bands) reads as a toy. Real roofs
/// in Dar are framed on straight timber/steel members, so the footprint is first *regularised*:
/// the dominant wall direction is found from the outline itself, the wall-line polygon is rasterised
/// in that frame and decomposed into at most four overlapping rectangular wings (largest new cover
/// first, each at least 3 m across). Every wing side that sits on a real wall is snapped onto it.
/// Wings get hipped roofs of one common pitch, so their union produces proper valleys and hips with
/// no coplanar overlap; a single compact wing may instead take a gable (gable wall in the building's
/// own colour, barge boards, verge) or a lean-to. The roof is a thin closed slab: sloped surfaces, a
/// 12 cm fascia board, flat soffit, and an eave height solved so every covered wall top tucks under it.
/// Footprints the wings cannot cover well (< 85 %) keep their flat roof, as an architect would.
nonisolated enum DioramaArchitectRoof {
    /// `mansard`: French double-pitch roof, steep (72°) lower slopes to a curb, then a flat slate top.
    nonisolated enum Form: Sendable { case hip, gable, shed, mansard }

    nonisolated struct Plan: Sendable {
        /// Local frame: x along `u`, y along `v` (no translation).
        let u: DV2
        let v: DV2
        /// Wing rectangles in local coordinates, on the wall line.
        let wings: [DioramaRect]
        let coverage: Double
        let area: Double
    }

    private static let cell = 0.4
    private static let thickness = 0.12
    private static let verge = 0.35

    // MARK: Regularisation

    /// Length-weighted orientation of the outline modulo 90°, refined around the strongest bin.
    static func dominantAxis(_ ring: [DV2]) -> DV2 {
        let n = ring.count
        var bins = [Double](repeating: 0, count: 90)
        var edges: [(angle: Double, length: Double)] = []
        for i in 0..<n {
            let d = ring[(i + 1) % n] - ring[i]
            let length = d.length
            guard length > 0.05 else { continue }
            var a = atan2(d.y, d.x) * 180 / .pi
            a = a.truncatingRemainder(dividingBy: 90)
            if a < 0 { a += 90 }
            bins[min(89, Int(a))] += length
            edges.append((a, length))
        }
        var best = 0, bestScore = -1.0
        for b in 0..<90 {
            var score = 0.0
            for k in -2...2 { score += bins[(b + k + 90) % 90] * (k == 0 ? 1 : (abs(k) == 1 ? 0.6 : 0.25)) }
            if score > bestScore { bestScore = score; best = b }
        }
        let centre = Double(best) + 0.5
        var sum = 0.0, weight = 0.0
        for e in edges {
            var diff = e.angle - centre
            if diff > 45 { diff -= 90 } else if diff < -45 { diff += 90 }
            if abs(diff) <= 4 { sum += diff * e.length; weight += e.length }
        }
        let theta = (centre + (weight > 0 ? sum / weight : 0)) * .pi / 180
        return DV2(cos(theta), sin(theta))
    }

    /// Overlapping rectangular wings on the wall-line polygon (counter-clockwise, world metres).
    static func plan(wall: [DV2]) -> Plan? {
        guard wall.count >= 3 else { return nil }
        let u = dominantAxis(wall), v = u.left
        let local = wall.map { DV2($0.dot(u), $0.dot(v)) }
        var lo = DV2(.greatestFiniteMagnitude, .greatestFiniteMagnitude), hi = -lo
        for p in local { lo = DV2(min(lo.x, p.x), min(lo.y, p.y)); hi = DV2(max(hi.x, p.x), max(hi.y, p.y)) }
        let cols = Int(ceil((hi.x - lo.x) / cell)), rows = Int(ceil((hi.y - lo.y) / cell))
        guard cols >= 6, rows >= 6, cols * rows <= 120_000 else { return nil }

        // Scanline fill of cell centres.
        var inside = [Bool](repeating: false, count: rows * cols)
        var insideCount = 0
        let n = local.count
        for r in 0..<rows {
            let y = lo.y + (Double(r) + 0.5) * cell
            var xs: [Double] = []
            for i in 0..<n {
                let a = local[i], b = local[(i + 1) % n]
                if (a.y <= y) != (b.y <= y) { xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let c0 = max(0, Int(ceil((xs[k] - lo.x) / cell - 0.5)))
                let c1 = min(cols - 1, Int(floor((xs[k + 1] - lo.x) / cell - 0.5)))
                if c0 <= c1 { for c in c0...c1 where !inside[r * cols + c] { inside[r * cols + c] = true; insideCount += 1 } }
                k += 2
            }
        }
        guard insideCount > 0 else { return nil }
        let cellArea = cell * cell
        let minCells = Int(ceil(3.0 / cell))

        var covered = [Bool](repeating: false, count: rows * cols)
        var coveredCount = 0
        var rects: [(r0: Int, r1: Int, c0: Int, c1: Int)] = []
        var prefix = [Int](repeating: 0, count: (rows + 1) * (cols + 1))
        var heights = [Int](repeating: 0, count: cols)
        var left = [Int](repeating: 0, count: cols), right = [Int](repeating: 0, count: cols)
        var stack: [Int] = []
        for wing in 0..<4 {
            // Prefix sums of still-uncovered interior cells.
            for r in 0..<rows {
                var run = 0
                for c in 0..<cols {
                    run += inside[r * cols + c] && !covered[r * cols + c] ? 1 : 0
                    prefix[(r + 1) * (cols + 1) + c + 1] = prefix[r * (cols + 1) + c + 1] + run
                }
            }
            func gain(_ r0: Int, _ r1: Int, _ c0: Int, _ c1: Int) -> Int {
                prefix[(r1 + 1) * (cols + 1) + c1 + 1] - prefix[r0 * (cols + 1) + c1 + 1]
                    - prefix[(r1 + 1) * (cols + 1) + c0] + prefix[r0 * (cols + 1) + c0]
            }
            var best: (r0: Int, r1: Int, c0: Int, c1: Int)?
            var bestGain = 0, bestArea = 0
            for c in 0..<cols { heights[c] = 0 }
            for r in 0..<rows {
                for c in 0..<cols { heights[c] = inside[r * cols + c] ? heights[c] + 1 : 0 }
                stack.removeAll(keepingCapacity: true)
                for c in 0..<cols {
                    while let top = stack.last, heights[top] >= heights[c] { stack.removeLast() }
                    left[c] = stack.last.map { $0 + 1 } ?? 0
                    stack.append(c)
                }
                stack.removeAll(keepingCapacity: true)
                for c in stride(from: cols - 1, through: 0, by: -1) {
                    while let top = stack.last, heights[top] >= heights[c] { stack.removeLast() }
                    right[c] = stack.last.map { $0 - 1 } ?? cols - 1
                    stack.append(c)
                }
                for c in 0..<cols where heights[c] >= minCells && right[c] - left[c] + 1 >= minCells {
                    let r0 = r - heights[c] + 1
                    let g = gain(r0, r, left[c], right[c])
                    let area = heights[c] * (right[c] - left[c] + 1)
                    if g > bestGain || (g == bestGain && area > bestArea) {
                        bestGain = g; bestArea = area; best = (r0, r, left[c], right[c])
                    }
                }
            }
            guard let chosen = best else { break }
            let gained = Double(bestGain) * cellArea
            let needed = wing == 0 ? 8.0 : max(8.0, Double(insideCount) * cellArea * 0.08)
            guard gained >= needed else { break }
            rects.append(chosen)
            for r in chosen.r0...chosen.r1 { for c in chosen.c0...chosen.c1 where !covered[r * cols + c] { covered[r * cols + c] = true; coveredCount += 1 } }
        }
        guard !rects.isEmpty else { return nil }
        var wings = rects.map { DioramaRect(minX: lo.x + Double($0.c0) * cell, minY: lo.y + Double($0.r0) * cell,
                                            maxX: lo.x + Double($0.c1 + 1) * cell, maxY: lo.y + Double($0.r1 + 1) * cell) }
        wings = wings.map { snap($0, to: local) }
        return Plan(u: u, v: v, wings: wings, coverage: Double(coveredCount) / Double(insideCount),
                    area: Double(insideCount) * cellArea)
    }

    /// Moves each wing side out (or in) onto the real wall line where a wall is found within 0.6 m
    /// along three probe lines; interior sides (the footprint continues) stay where they are.
    private static func snap(_ rect: DioramaRect, to ring: [DV2]) -> DioramaRect {
        func crossings(horizontal: Bool, at value: Double) -> [Double] {
            var out: [Double] = []
            let n = ring.count
            for i in 0..<n {
                let a = ring[i], b = ring[(i + 1) % n]
                let (pa, pb, qa, qb) = horizontal ? (a.y, b.y, a.x, b.x) : (a.x, b.x, a.y, b.y)
                if (pa <= value) != (pb <= value) { out.append(qa + (value - pa) / (pb - pa) * (qb - qa)) }
            }
            return out
        }
        func shift(edge: Double, horizontal: Bool, probes: [Double], outward: Double) -> Double {
            var moves: [Double] = []
            for p in probes {
                let hits = crossings(horizontal: horizontal, at: p).map { ($0 - edge) * outward }.filter { $0 > -0.45 && $0 < 0.6 }
                guard let nearest = hits.min(by: { abs($0) < abs($1) }) else { return 0 }
                moves.append(nearest)
            }
            return moves.min() ?? 0
        }
        let ys = [0.25, 0.5, 0.75].map { rect.minY + rect.height * $0 }
        let xs = [0.25, 0.5, 0.75].map { rect.minX + rect.width * $0 }
        let maxX = rect.maxX + shift(edge: rect.maxX, horizontal: true, probes: ys, outward: 1)
        let minX = rect.minX - shift(edge: rect.minX, horizontal: true, probes: ys, outward: -1)
        let maxY = rect.maxY + shift(edge: rect.maxY, horizontal: false, probes: xs, outward: 1)
        let minY = rect.minY - shift(edge: rect.minY, horizontal: false, probes: xs, outward: -1)
        guard maxX - minX >= 2.6, maxY - minY >= 2.6 else { return rect }
        return DioramaRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    // MARK: Roof construction

    /// Builds the roof. `zDeck` is the top of the walls after the slab edge is squared. Sloped surfaces,
    /// fascias and soffits go to `mesh`; gable walls/cheeks go to `infill` (recoloured to the walls).
    @discardableResult
    static func build(_ plan: Plan, form requested: Form, wall: [DV2], zDeck: Double, pitchDegrees: Double,
                      overhang: Double, color: DioramaSwatch, into mesh: inout DioramaMesh, infill: inout DioramaMesh) -> Bool {
        var eave = 0.0, curb = 0.0
        return build(plan, form: requested, wall: wall, zDeck: zDeck, pitchDegrees: pitchDegrees, overhang: overhang,
                     color: color, into: &mesh, infill: &infill, eave: &eave, curb: &curb)
    }

    /// Same as `build`, also reporting the eave height and (mansard only) the curb rise above it.
    static func build(_ plan: Plan, form requested: Form, wall: [DV2], zDeck: Double, pitchDegrees: Double,
                      overhang: Double, color: DioramaSwatch, into mesh: inout DioramaMesh, infill: inout DioramaMesh,
                      eave: inout Double, curb: inout Double) -> Bool {
        let form: Form = plan.wings.count == 1 || requested == .mansard ? requested : .hip
        let u = plan.u, v = plan.v
        func world(_ q: DV2) -> DV2 { u * q.x + v * q.y }
        let localWall = wall.map { DV2($0.dot(u), $0.dot(v)) }

        // Ridge frame for single-wing forms: p along the ridge, q across.
        let rect = plan.wings[0]
        let alongX = rect.width >= rect.height
        func frame(_ p: Double, _ q: Double) -> DV2 { alongX ? DV2(p, q) : DV2(q, p) }
        let (P0, P1, Q0, Q1) = alongX ? (rect.minX, rect.maxX, rect.minY, rect.maxY) : (rect.minY, rect.maxY, rect.minX, rect.maxX)

        var eaves: [DioramaRect]
        switch form {
        case .hip, .mansard: eaves = plan.wings.map { $0.expanded(by: overhang) }
        case .gable, .shed:
            let e = alongX ? DioramaRect(minX: P0 - verge, minY: Q0 - overhang, maxX: P1 + verge, maxY: Q1 + overhang)
                : DioramaRect(minX: Q0 - overhang, minY: P0 - verge, maxX: Q1 + overhang, maxY: P1 + verge)
            eaves = [e]
        }
        var slope = tan((form == .mansard ? 72 : pitchDegrees) * .pi / 180)
        if form == .shed { slope = min(tan(10 * .pi / 180), 2.0 / max(Q1 - Q0 + 2 * overhang, 0.5)) }
        let maxHalf = eaves.map { min($0.width, $0.height) / 2 }.max() ?? 1
        let minHalf = eaves.map { min($0.width, $0.height) / 2 }.min() ?? 1
        if form != .shed, form != .mansard, slope * maxHalf > 3.6 { slope = 3.6 / maxHalf }
        guard slope.isFinite, slope > 0.05 else { return false }
        // Mansard curb: one storey of steep slate, never closer than 1.2 m to the narrowest wing's centre.
        let curbRise = form == .mansard ? min(2.5, max(0, minHalf - 1.2) * slope) : 0
        if form == .mansard, curbRise < 1.4 { return false }

        // Height of the roof surface above its eave at a local point (negative outside).
        func rise(_ q: DV2) -> Double {
            switch form {
            case .hip, .mansard:
                var best = -Double.greatestFiniteMagnitude
                for e in eaves { best = max(best, min(q.x - e.minX, e.maxX - q.x, q.y - e.minY, e.maxY - q.y)) }
                return form == .mansard ? min(best * slope, curbRise) : best * slope
            case .gable:
                let e = eaves[0]
                let inside = min(q.x - e.minX, e.maxX - q.x, q.y - e.minY, e.maxY - q.y)
                guard inside > 0 else { return inside }
                let across = alongX ? min(q.y - e.minY, e.maxY - q.y) : min(q.x - e.minX, e.maxX - q.x)
                return across * slope
            case .shed:
                let e = eaves[0]
                let inside = min(q.x - e.minX, e.maxX - q.x, q.y - e.minY, e.maxY - q.y)
                guard inside > 0 else { return inside }
                return (alongX ? q.y - e.minY : q.x - e.minX) * slope
            }
        }
        // Eave height: every covered wall top (sampled every 0.5 m) tucks 6 cm under the roof surface.
        var rises: [Double] = []
        var outside = 0, total = 0
        let n = localWall.count
        for i in 0..<n {
            let a = localWall[i], b = localWall[(i + 1) % n]
            let steps = max(1, Int(ceil(a.distance(to: b) / 0.5)))
            for s in 0..<steps {
                let q = a + (b - a) * (Double(s) / Double(steps))
                total += 1
                let r = rise(q)
                if r <= 0.0001 { outside += 1 } else { rises.append(r) }
            }
        }
        guard total > 0, Double(outside) / Double(total) <= 0.12, !rises.isEmpty else { return false }
        rises.sort()
        let low = rises[min(rises.count - 1, rises.count / 25)]
        let zE = zDeck + 0.06 - low
        guard zE <= zDeck + 0.12, zE >= zDeck - 2.0 else { return false }
        let t = thickness
        eave = zE
        curb = curbRise

        switch form {
        case .hip:
            hip(eaves: eaves, slope: slope, zE: zE, world: world, color: color, into: &mesh)
        case .mansard:
            hip(eaves: eaves, slope: slope, zE: zE, world: world, color: color, curb: curbRise, into: &mesh)
        case .gable:
            let half = (Q1 - Q0) / 2 + overhang, qc = (Q0 + Q1) / 2
            let e0 = qc - half, e1 = qc + half, p0 = P0 - verge, p1 = P1 + verge
            let zr = zE + slope * half
            let along = alongX ? u : v, across = alongX ? v : u
            func w(_ p: Double, _ q: Double, _ z: Double) -> DV3 { DV3(world(frame(p, q)), z) }
            let nA = DV3(across * -slope, 1).normalized, nB = DV3(across * slope, 1).normalized
            mesh.quad(w(p0, e0, zE), w(p1, e0, zE), w(p1, qc, zr), w(p0, qc, zr), color, normal: nA)
            mesh.quad(w(p1, e1, zE), w(p0, e1, zE), w(p0, qc, zr), w(p1, qc, zr), color, normal: nB)
            mesh.quad(w(p0, e0, zE - t), w(p0, qc, zr - t), w(p1, qc, zr - t), w(p1, e0, zE - t), color, dark: true, normal: nA * -1)
            mesh.quad(w(p1, e1, zE - t), w(p1, qc, zr - t), w(p0, qc, zr - t), w(p0, e1, zE - t), color, dark: true, normal: nB * -1)
            mesh.quad(w(p0, e0, zE - t), w(p1, e0, zE - t), w(p1, e0, zE), w(p0, e0, zE), .trimWhite, normal: DV3(across * -1, 0))
            mesh.quad(w(p1, e1, zE - t), w(p0, e1, zE - t), w(p0, e1, zE), w(p1, e1, zE), .trimWhite, normal: DV3(across, 0))
            for (p, sign) in [(p0, -1.0), (p1, 1.0)] {
                let out = DV3(along * sign, 0)
                mesh.quad(w(p, e0, zE - t), w(p, qc, zr - t), w(p, qc, zr), w(p, e0, zE), .trimWhite, normal: out)
                mesh.quad(w(p, qc, zr - t), w(p, e1, zE - t), w(p, e1, zE), w(p, qc, zr), .trimWhite, normal: out)
            }
            // Gable walls on the end wall lines, from the wall top up to the roof underside.
            let gableP = [wallEnd(localWall, alongX: alongX, at: qc, near: P0, outward: -1) ?? P0,
                          wallEnd(localWall, alongX: alongX, at: qc, near: P1, outward: 1) ?? P1]
            for (p, sign) in zip(gableP, [-1.0, 1.0]) {
                let out = DV3(along * sign, 0)
                func under(_ q: Double) -> Double { zE - t + slope * (half - abs(q - qc)) }
                let reach = half - (zDeck - (zE - t)) / slope
                guard reach > 0.2 else { continue }
                let q0 = max(Q0, qc - reach), q1 = min(Q1, qc + reach)
                var profile: [(Double, Double)] = [(q0, zDeck), (q1, zDeck)]
                if under(q1) > zDeck + 0.005 { profile.append((q1, under(q1))) }
                profile.append((qc, under(qc)))
                if under(q0) > zDeck + 0.005 { profile.append((q0, under(q0))) }
                for k in 1..<(profile.count - 1) {
                    infill.triangle(w(p, profile[0].0, profile[0].1), w(p, profile[k].0, profile[k].1),
                                    w(p, profile[k + 1].0, profile[k + 1].1), .whitewash, normal: out)
                }
            }
        case .shed:
            let e0 = Q0 - overhang, e1 = Q1 + overhang, p0 = P0 - verge, p1 = P1 + verge
            let zH = zE + slope * (e1 - e0)
            let along = alongX ? u : v, across = alongX ? v : u
            func w(_ p: Double, _ q: Double, _ z: Double) -> DV3 { DV3(world(frame(p, q)), z) }
            func under(_ q: Double) -> Double { zE - t + slope * (q - e0) }
            let nTop = DV3(across * -slope, 1).normalized
            mesh.quad(w(p0, e0, zE), w(p1, e0, zE), w(p1, e1, zH), w(p0, e1, zH), color, normal: nTop)
            mesh.quad(w(p0, e0, zE - t), w(p0, e1, zH - t), w(p1, e1, zH - t), w(p1, e0, zE - t), color, dark: true, normal: nTop * -1)
            mesh.quad(w(p0, e0, zE - t), w(p1, e0, zE - t), w(p1, e0, zE), w(p0, e0, zE), .trimWhite, normal: DV3(across * -1, 0))
            mesh.quad(w(p1, e1, zH - t), w(p0, e1, zH - t), w(p0, e1, zH), w(p1, e1, zH), .trimWhite, normal: DV3(across, 0))
            for (p, sign) in [(p0, -1.0), (p1, 1.0)] {
                mesh.quad(w(p, e0, zE - t), w(p, e1, zH - t), w(p, e1, zH), w(p, e0, zE), .trimWhite, normal: DV3(along * sign, 0))
            }
            // High wall and the two sloping cheeks close the lean-to above the wall tops.
            if under(Q1) > zDeck + 0.02 {
                infill.quad(w(P0, Q1, zDeck), w(P1, Q1, zDeck), w(P1, Q1, under(Q1)), w(P0, Q1, under(Q1)), .whitewash, normal: DV3(across, 0))
            }
            let qStart = max(Q0, e0 + max(0, zDeck - (zE - t)) / slope)
            if under(Q1) > zDeck + 0.02, qStart < Q1 - 0.1 {
                for (p, sign) in [(P0, -1.0), (P1, 1.0)] {
                    let out = DV3(along * sign, 0)
                    infill.triangle(w(p, qStart, zDeck), w(p, Q1, zDeck), w(p, Q1, under(Q1)), .whitewash, normal: out)
                    if under(qStart) > zDeck + 0.005 {
                        infill.triangle(w(p, qStart, zDeck), w(p, Q1, under(Q1)), w(p, qStart, under(qStart)), .whitewash, normal: out)
                    }
                }
            }
        }
        return true
    }

    /// The wall line crossing along the ridge axis nearest to `near` (within 0.6 m outward/0.45 m in).
    private static func wallEnd(_ ring: [DV2], alongX: Bool, at q: Double, near: Double, outward: Double) -> Double? {
        var best: Double?
        let n = ring.count
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            let (qa, qb, pa, pb) = alongX ? (a.y, b.y, a.x, b.x) : (a.x, b.x, a.y, b.y)
            guard (qa <= q) != (qb <= q) else { continue }
            let p = pa + (q - qa) / (qb - qa) * (pb - pa)
            let d = (p - near) * outward
            guard d > -0.45, d < 0.6 else { continue }
            if best.map({ abs($0 - near) > abs(p - near) }) ?? true { best = p }
        }
        return best
    }

    /// Union of equal-pitch hipped wings: each slope face minus the parts hidden inside another
    /// wing's roof volume (coplanar ties owned by the lower index), fascias only on exposed eaves.
    private static func hip(eaves: [DioramaRect], slope: Double, zE: Double, world: (DV2) -> DV2,
                            color: DioramaSwatch, curb: Double? = nil, into mesh: inout DioramaMesh) {
        typealias Plane = DioramaRoofBuilder.Plane
        let corners: [[DV2]] = eaves.map { e in
            [DV2(e.minX, e.minY), DV2(e.maxX, e.minY), DV2(e.maxX, e.maxY), DV2(e.minX, e.maxY)].map(world)
        }
        let volumes: [[Plane]] = corners.map { ring in
            ring.indices.map { i in
                let a = ring[i], inward = (ring[(i + 1) % 4] - a).normalized.left * slope
                return Plane(gradient: inward, offset: -inward.dot(a))
            }
        }
        for (wi, planes) in volumes.enumerated() {
            for (pi, plane) in planes.enumerated() {
                var face = corners[wi]
                for (k, other) in planes.enumerated() where k != pi { face = DioramaRoofBuilder.clip(face, by: other.minus(plane)) }
                if let curb { face = DioramaRoofBuilder.clip(face, by: Plane(gradient: plane.gradient * -1, offset: curb - plane.offset)) }
                guard face.count >= 3, DioramaPolygon.area(face) > 1e-6 else { continue }
                var visible = [face]
                for (oi, other) in volumes.enumerated() where oi != wi {
                    let constraints = other.map { $0.minus(plane) }
                    if oi > wi && constraints.contains(where: { $0.gradient.length < 1e-8 && abs($0.offset) < 1e-6 }) { continue }
                    visible = visible.flatMap { subtract($0, volume: constraints) }
                    if visible.isEmpty { break }
                }
                let normal = DV3(-plane.gradient.x, -plane.gradient.y, 1).normalized
                for piece in visible where piece.count >= 3 && DioramaPolygon.area(piece) > 1e-6 {
                    func lifted(_ p: DV2) -> DV3 { DV3(p, zE + min(curb ?? .greatestFiniteMagnitude, max(0, plane.height(p)))) }
                    for i in 1..<(piece.count - 1) { mesh.triangle(lifted(piece[0]), lifted(piece[i]), lifted(piece[i + 1]), color, normal: normal) }
                }
            }
        }
        let t = thickness
        // Exposed fascia spans: each eave side minus the parts inside (or shared with) other wings.
        for (wi, e) in eaves.enumerated() {
            let sides: [(fixed: Double, horizontal: Bool, from: Double, to: Double, sign: Double)] = [
                (e.minY, true, e.minX, e.maxX, -1), (e.maxY, true, e.minX, e.maxX, 1),
                (e.minX, false, e.minY, e.maxY, -1), (e.maxX, false, e.minY, e.maxY, 1)]
            for side in sides {
                var spans: [(Double, Double)] = [(side.from, side.to)]
                for (oi, o) in eaves.enumerated() where oi != wi {
                    let (lo, hi, a, b) = side.horizontal ? (o.minY, o.maxY, o.minX, o.maxX) : (o.minX, o.maxX, o.minY, o.maxY)
                    let eps = 1e-6
                    let strictly = side.fixed > lo + eps && side.fixed < hi - eps
                    let onOwnSide = abs(side.fixed - (side.sign < 0 ? lo : hi)) < eps
                    let onOppositeSide = abs(side.fixed - (side.sign < 0 ? hi : lo)) < eps
                    guard strictly || (onOwnSide && oi < wi) || onOppositeSide else { continue }
                    spans = spans.flatMap { s -> [(Double, Double)] in
                        let cutA = max(s.0, a), cutB = min(s.1, b)
                        guard cutB > cutA else { return [s] }
                        return [(s.0, cutA), (cutB, s.1)].filter { $0.1 - $0.0 > 0.02 }
                    }
                }
                for s in spans {
                    let a = side.horizontal ? DV2(s.0, side.fixed) : DV2(side.fixed, s.0)
                    let b = side.horizontal ? DV2(s.1, side.fixed) : DV2(side.fixed, s.1)
                    let out = side.horizontal ? DV2(0, side.sign) : DV2(side.sign, 0)
                    let wa = world(a), wb = world(b), wo = world(out)
                    mesh.quad(DV3(wa, zE - t), DV3(wb, zE - t), DV3(wb, zE), DV3(wa, zE), .trimWhite, normal: DV3(wo, 0))
                }
            }
            mesh.polygon(corners[wi], z: zE - t, color, dark: true, facingUp: false)
            // Mansard top: the flat leaded deck inside the curb (coplanar overlaps share colour and normal).
            if let curb {
                let inset = curb / slope
                let top = DioramaRect(minX: e.minX + inset, minY: e.minY + inset, maxX: e.maxX - inset, maxY: e.maxY - inset)
                if top.width > 0.05, top.height > 0.05 {
                    mesh.polygon([DV2(top.minX, top.minY), DV2(top.maxX, top.minY), DV2(top.maxX, top.maxY), DV2(top.minX, top.maxY)].map(world),
                                 z: zE + curb, color)
                }
            }
        }
    }

    /// Subtracts a convex volume (all constraints ≥ 0) from a convex polygon.
    private static func subtract(_ ring: [DV2], volume: [DioramaRoofBuilder.Plane]) -> [[DV2]] {
        var remaining = ring
        var outside: [[DV2]] = []
        for plane in volume {
            guard remaining.count >= 3 else { break }
            if plane.gradient.length < 1e-8 {
                if plane.offset < -1e-8 { outside.append(remaining); return outside }
                continue
            }
            let piece = DioramaRoofBuilder.clip(remaining, by: DioramaRoofBuilder.Plane(gradient: plane.gradient * -1, offset: -plane.offset))
            if piece.count >= 3, DioramaPolygon.area(piece) > 1e-8 { outside.append(piece) }
            remaining = DioramaRoofBuilder.clip(remaining, by: plane)
        }
        return outside
    }
}
