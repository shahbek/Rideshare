import Foundation

/// 2D vector in local metres (x east, y north).
nonisolated struct DV2: Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    static let zero = DV2(0, 0)
    static func + (a: DV2, b: DV2) -> DV2 { DV2(a.x + b.x, a.y + b.y) }
    static func - (a: DV2, b: DV2) -> DV2 { DV2(a.x - b.x, a.y - b.y) }
    static func * (a: DV2, s: Double) -> DV2 { DV2(a.x * s, a.y * s) }
    static prefix func - (a: DV2) -> DV2 { DV2(-a.x, -a.y) }

    var length: Double { (x * x + y * y).squareRoot() }
    var normalized: DV2 {
        let l = length
        return l > 1e-9 ? DV2(x / l, y / l) : DV2(1, 0)
    }
    /// Clockwise perpendicular: the outward side of a counter-clockwise ring edge.
    var right: DV2 { DV2(y, -x) }
    var left: DV2 { DV2(-y, x) }
    var angle: Double { atan2(y, x) }
    func dot(_ o: DV2) -> Double { x * o.x + y * o.y }
    func cross(_ o: DV2) -> Double { x * o.y - y * o.x }
    func distance(to o: DV2) -> Double { (self - o).length }
    func rotated(_ a: Double) -> DV2 {
        let c = cos(a), s = sin(a)
        return DV2(x * c - y * s, x * s + y * c)
    }
}

/// 3D vector in local metres (x east, y north, z up).
nonisolated struct DV3: Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ v: DV2, _ z: Double) {
        self.init(v.x, v.y, z)
    }

    static let up = DV3(0, 0, 1)
    static func + (a: DV3, b: DV3) -> DV3 { DV3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: DV3, b: DV3) -> DV3 { DV3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: DV3, s: Double) -> DV3 { DV3(a.x * s, a.y * s, a.z * s) }
    var xy: DV2 { DV2(x, y) }
    var length: Double { (x * x + y * y + z * z).squareRoot() }
    var normalized: DV3 {
        let l = length
        return l > 1e-9 ? DV3(x / l, y / l, z / l) : DV3(0, 0, 1)
    }
    func cross(_ o: DV3) -> DV3 { DV3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x) }
    func dot(_ o: DV3) -> Double { x * o.x + y * o.y + z * o.z }
}

nonisolated struct DioramaRect: Sendable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var centre: DV2 { DV2((minX + maxX) / 2, (minY + maxY) / 2) }
    var area: Double { max(width, 0) * max(height, 0) }

    func contains(_ p: DV2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    func expanded(by m: Double) -> DioramaRect { DioramaRect(minX: minX - m, minY: minY - m, maxX: maxX + m, maxY: maxY + m) }
    func intersects(_ o: DioramaRect) -> Bool { minX <= o.maxX && maxX >= o.minX && minY <= o.maxY && maxY >= o.minY }

    var isFinite: Bool { minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite }

    /// Bounding box of the points; an empty or non-finite input yields a zero rect at the origin.
    static func bounding(_ points: [DV2]) -> DioramaRect {
        var r = DioramaRect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for p in points where p.x.isFinite && p.y.isFinite {
            r.minX = min(r.minX, p.x); r.minY = min(r.minY, p.y)
            r.maxX = max(r.maxX, p.x); r.maxY = max(r.maxY, p.y)
        }
        return r.isFinite ? r : DioramaRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
    }
}

/// Rectangle with an arbitrary heading, used for roofs and compound walls.
nonisolated struct DioramaOrientedRect: Sendable {
    var centre: DV2
    /// Unit vector along the long side.
    var axis: DV2
    var halfLength: Double
    var halfWidth: Double

    var across: DV2 { axis.left }
    var area: Double { 4 * halfLength * halfWidth }

    /// Counter-clockwise corners.
    var corners: [DV2] {
        [
            centre - axis * halfLength - across * halfWidth,
            centre + axis * halfLength - across * halfWidth,
            centre + axis * halfLength + across * halfWidth,
            centre - axis * halfLength + across * halfWidth,
        ]
    }

    func expanded(by d: Double) -> DioramaOrientedRect {
        DioramaOrientedRect(centre: centre, axis: axis, halfLength: max(halfLength + d, 0.1), halfWidth: max(halfWidth + d, 0.1))
    }

    func contains(_ p: DV2) -> Bool {
        let v = p - centre
        return abs(v.dot(axis)) <= halfLength && abs(v.dot(across)) <= halfWidth
    }
}

/// Polygon and polyline helpers. Rings are open (no repeated closing point).
nonisolated enum DioramaPolygon {
    static func signedArea(_ ring: [DV2]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    static func area(_ ring: [DV2]) -> Double { abs(signedArea(ring)) }

    static func centroid(_ ring: [DV2]) -> DV2 {
        let a = signedArea(ring)
        guard abs(a) > 1e-6 else {
            let sum = ring.reduce(DV2.zero, +)
            return sum * (1 / Double(max(ring.count, 1)))
        }
        var cx = 0.0, cy = 0.0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            let f = p.x * q.y - q.x * p.y
            cx += (p.x + q.x) * f
            cy += (p.y + q.y) * f
        }
        return DV2(cx / (6 * a), cy / (6 * a))
    }

    /// Removes the closing point, near-duplicates and collinear vertices while keeping per-edge flags
    /// (flag `i` describes the edge from vertex `i` to vertex `i + 1`).
    static func clean(_ points: [DV2], flags: [Bool]) -> (points: [DV2], flags: [Bool]) {
        var pts = points
        var fl = flags
        if fl.count != pts.count { fl = [Bool](repeating: false, count: pts.count) }
        if pts.count > 1, pts[0].distance(to: pts[pts.count - 1]) < 0.01 {
            pts.removeLast()
            fl.removeLast()
        }
        var changed = true
        while changed && pts.count > 3 {
            changed = false
            var i = 0
            while i < pts.count && pts.count > 3 {
                let n = pts.count
                let prev = pts[(i + n - 1) % n], cur = pts[i], next = pts[(i + 1) % n]
                let e1 = cur - prev, e2 = next - cur
                let tooClose = e1.length < 0.08
                let collinear = abs(e1.normalized.cross(e2.normalized)) < 0.004 && e1.dot(e2) > 0
                if tooClose || collinear {
                    let p = (i + n - 1) % n
                    fl[p] = fl[p] && fl[i]
                    pts.remove(at: i)
                    fl.remove(at: i)
                    changed = true
                } else {
                    i += 1
                }
            }
        }
        return (pts, fl)
    }

    /// Returns the ring counter-clockwise, remapping edge flags if it had to be reversed.
    static func counterClockwise(_ ring: [DV2], flags: [Bool]) -> (points: [DV2], flags: [Bool]) {
        guard signedArea(ring) < 0 else { return (ring, flags) }
        let n = ring.count
        let points = Array(ring.reversed())
        var newFlags = [Bool](repeating: false, count: n)
        for j in 0..<n { newFlags[j] = flags[((n - 2 - j) % n + n) % n] }
        return (points, newFlags)
    }

    static func counterClockwise(_ ring: [DV2]) -> [DV2] {
        signedArea(ring) < 0 ? Array(ring.reversed()) : ring
    }

    static func contains(_ ring: [DV2], _ p: DV2) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Outer ring followed by holes.
    static func contains(polygon: [[DV2]], _ p: DV2) -> Bool {
        guard let outer = polygon.first, contains(outer, p) else { return false }
        for hole in polygon.dropFirst() where contains(hole, p) { return false }
        return true
    }

    static func distanceToSegment(_ p: DV2, _ a: DV2, _ b: DV2) -> Double {
        let ab = b - a
        let l2 = ab.dot(ab)
        guard l2 > 1e-12 else { return p.distance(to: a) }
        let t = min(max((p - a).dot(ab) / l2, 0), 1)
        return p.distance(to: a + ab * t)
    }

    static func closestPointOnSegment(_ p: DV2, _ a: DV2, _ b: DV2) -> DV2 {
        let ab = b - a
        let l2 = ab.dot(ab)
        guard l2 > 1e-12 else { return a }
        let t = min(max((p - a).dot(ab) / l2, 0), 1)
        return a + ab * t
    }

    static func distanceToRing(_ ring: [DV2], _ p: DV2) -> Double {
        var best = Double.infinity
        for i in 0..<ring.count {
            best = min(best, distanceToSegment(p, ring[i], ring[(i + 1) % ring.count]))
        }
        return best
    }

    static func segmentsIntersect(_ a: DV2, _ b: DV2, _ c: DV2, _ d: DV2) -> Bool {
        let d1 = (b - a).cross(c - a), d2 = (b - a).cross(d - a)
        let d3 = (d - c).cross(a - c), d4 = (d - c).cross(b - c)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    static func isSimple(_ ring: [DV2]) -> Bool {
        let n = ring.count
        guard n >= 4 else { return n == 3 }
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            // `stride` tolerates i + 2 > n; a `..<` range there would trap.
            for j in stride(from: i + 2, to: n, by: 1) {
                if i == 0 && j == n - 1 { continue }
                if segmentsIntersect(a, b, ring[j], ring[(j + 1) % n]) { return false }
            }
        }
        return true
    }

    /// Mitred offset of a counter-clockwise ring; positive grows outward. Nil when the result folds.
    static func offset(_ ring: [DV2], by d: Double) -> [DV2]? {
        let n = ring.count
        guard n >= 3 else { return nil }
        var out: [DV2] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let prev = ring[(i + n - 1) % n], cur = ring[i], next = ring[(i + 1) % n]
            let n1 = (cur - prev).normalized.right
            let n2 = (next - cur).normalized.right
            let m = (n1 + n2).normalized
            let cosHalf = max(m.dot(n1), 0.35)
            out.append(cur + m * (d / cosHalf))
        }
        let originalArea = signedArea(ring)
        let newArea = signedArea(out)
        guard newArea > 0, (d > 0 ? newArea > originalArea : newArea < originalArea), isSimple(out) else { return nil }
        return out
    }

    /// Ear clipping preserving original indices. Never fan-fill a concave remainder: that creates
    /// crossing triangles outside the footprint. Remove duplicate/collinear vertices before clipping.
    static func triangulate(_ ring: [DV2]) -> [(Int, Int, Int)] {
        let n = ring.count
        guard n >= 3 else { return [] }
        var indices = Array(0..<n)
        if signedArea(ring) < 0 { indices.reverse() }
        var changed = true
        while changed && indices.count > 3 {
            changed = false
            for k in indices.indices {
                let a = ring[indices[(k + indices.count - 1) % indices.count]]
                let b = ring[indices[k]], c = ring[indices[(k + 1) % indices.count]]
                if a.distance(to: b) < 0.00001 ||
                    (abs((b - a).cross(c - b)) < 0.0000001 && (b - a).dot(c - b) >= 0) {
                    indices.remove(at: k)
                    changed = true
                    break
                }
            }
        }
        var result: [(Int, Int, Int)] = []
        result.reserveCapacity(n - 2)
        var guardCounter = 0
        while indices.count > 3 && guardCounter < n * n {
            guardCounter += 1
            var clipped = false
            let m = indices.count
            for k in 0..<m {
                let i0 = indices[(k + m - 1) % m], i1 = indices[k], i2 = indices[(k + 1) % m]
                let a = ring[i0], b = ring[i1], c = ring[i2]
                let turn = (b - a).cross(c - b)
                // Clipping an ear can make its neighbours collinear. Clean again here, otherwise
                // a valid roof/deck can lose its entire surface when only a flat remainder is left.
                if a.distance(to: b) < 0.00001 ||
                    (abs(turn) < 0.0000001 && (b - a).dot(c - b) >= 0) {
                    indices.remove(at: k)
                    clipped = true
                    break
                }
                guard turn > 1e-9 else { continue }
                var containsOther = false
                for idx in indices where idx != i0 && idx != i1 && idx != i2 {
                    let p = ring[idx]
                    if (b - a).cross(p - a) >= 0 && (c - b).cross(p - b) >= 0 && (a - c).cross(p - c) >= 0 {
                        containsOther = true
                        break
                    }
                }
                if containsOther { continue }
                result.append((i0, i1, i2))
                indices.remove(at: k)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if indices.count == 3 {
            let a = ring[indices[0]], b = ring[indices[1]], c = ring[indices[2]]
            if abs((b - a).cross(c - a)) > 1e-9 { result.append((indices[0], indices[1], indices[2])) }
        } else if indices.count > 3 {
            // Reject the whole invalid surface rather than drawing a plausible-looking partial lid.
            return []
        }
        return result
    }

    /// Smallest-area rectangle aligned with one of the ring's edges.
    static func minimumAreaRectangle(_ ring: [DV2]) -> DioramaOrientedRect {
        var best = DioramaOrientedRect(centre: centroid(ring), axis: DV2(1, 0), halfLength: 1, halfWidth: 1)
        var bestArea = Double.infinity
        for i in 0..<ring.count {
            let e = ring[(i + 1) % ring.count] - ring[i]
            guard e.length > 0.3 else { continue }
            let u = e.normalized, v = u.left
            var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
            for p in ring {
                let pu = p.dot(u), pv = p.dot(v)
                minU = min(minU, pu); maxU = max(maxU, pu); minV = min(minV, pv); maxV = max(maxV, pv)
            }
            let a = (maxU - minU) * (maxV - minV)
            if a < bestArea {
                bestArea = a
                let centre = u * ((minU + maxU) / 2) + v * ((minV + maxV) / 2)
                let hl = (maxU - minU) / 2, hw = (maxV - minV) / 2
                best = hl >= hw
                    ? DioramaOrientedRect(centre: centre, axis: u, halfLength: hl, halfWidth: hw)
                    : DioramaOrientedRect(centre: centre, axis: v, halfLength: hw, halfWidth: hl)
            }
        }
        return best
    }

    /// Liang–Barsky clip of a polyline to a rectangle; returns the pieces inside.
    static func clip(_ line: [DV2], to rect: DioramaRect) -> [[DV2]] {
        var pieces: [[DV2]] = []
        var current: [DV2] = []
        for i in 0..<max(line.count - 1, 0) {
            guard let (a, b) = clipSegment(line[i], line[i + 1], rect) else {
                if current.count > 1 { pieces.append(current) }
                current = []
                continue
            }
            if let last = current.last, last.distance(to: a) < 1e-6 {
                current.append(b)
            } else {
                if current.count > 1 { pieces.append(current) }
                current = [a, b]
            }
            if b.distance(to: line[i + 1]) > 1e-6 {
                pieces.append(current)
                current = []
            }
        }
        if current.count > 1 { pieces.append(current) }
        return pieces
    }

    private static func clipSegment(_ a: DV2, _ b: DV2, _ r: DioramaRect) -> (DV2, DV2)? {
        var t0 = 0.0, t1 = 1.0
        let d = b - a
        let checks: [(Double, Double)] = [(-d.x, a.x - r.minX), (d.x, r.maxX - a.x), (-d.y, a.y - r.minY), (d.y, r.maxY - a.y)]
        for (p, q) in checks {
            if abs(p) < 1e-12 {
                if q < 0 { return nil }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return nil }
            }
        }
        return (a + d * t0, a + d * t1)
    }

    /// Sutherland–Hodgman clip of a ring to an axis-aligned rect. Empty when nothing is left.
    static func clipPolygon(_ ring: [DV2], to r: DioramaRect) -> [DV2] {
        var out = ring
        let edges: [(inside: (DV2) -> Bool, cut: (DV2, DV2) -> DV2)] = [
            ({ $0.x >= r.minX }, { a, b in a + (b - a) * ((r.minX - a.x) / (b.x - a.x)) }),
            ({ $0.x <= r.maxX }, { a, b in a + (b - a) * ((r.maxX - a.x) / (b.x - a.x)) }),
            ({ $0.y >= r.minY }, { a, b in a + (b - a) * ((r.minY - a.y) / (b.y - a.y)) }),
            ({ $0.y <= r.maxY }, { a, b in a + (b - a) * ((r.maxY - a.y) / (b.y - a.y)) }),
        ]
        for edge in edges {
            guard out.count >= 3 else { return [] }
            var next: [DV2] = []
            let n = out.count
            for i in 0..<n {
                let cur = out[i], prev = out[(i + n - 1) % n]
                let cin = edge.inside(cur), pin = edge.inside(prev)
                if cin {
                    if !pin { next.append(edge.cut(prev, cur)) }
                    next.append(cur)
                } else if pin {
                    next.append(edge.cut(prev, cur))
                }
            }
            out = next
        }
        guard out.count >= 3 else { return [] }
        return clean(out, flags: [Bool](repeating: false, count: out.count)).points
    }

    static func length(_ line: [DV2]) -> Double {
        var l = 0.0
        for i in 0..<max(line.count - 1, 0) { l += line[i].distance(to: line[i + 1]) }
        return l
    }

    /// Point and unit direction at a distance along a polyline.
    static func sample(_ line: [DV2], at distance: Double) -> (point: DV2, direction: DV2)? {
        var remaining = distance
        for i in 0..<max(line.count - 1, 0) {
            let a = line[i], b = line[i + 1]
            let l = a.distance(to: b)
            if remaining <= l, l > 1e-6 {
                return (a + (b - a) * (remaining / l), (b - a).normalized)
            }
            remaining -= l
        }
        return nil
    }
}

/// Uniform grid of bounding boxes for fast neighbour lookups.
nonisolated struct DioramaGrid: Sendable {
    let cell: Double
    private var buckets: [Int64: [Int]] = [:]

    init(cell: Double) {
        self.cell = cell
    }

    private func key(_ ix: Int, _ iy: Int) -> Int64 { Int64(ix) &* 73_856_093 ^ Int64(iy) &* 19_349_663 }

    mutating func insert(_ index: Int, rect: DioramaRect) {
        guard rect.isFinite, abs(rect.minX) < 1e7, abs(rect.maxX) < 1e7, abs(rect.minY) < 1e7, abs(rect.maxY) < 1e7 else { return }
        let x0 = Int(floor(rect.minX / cell)), x1 = Int(floor(rect.maxX / cell))
        let y0 = Int(floor(rect.minY / cell)), y1 = Int(floor(rect.maxY / cell))
        guard x1 - x0 < 200, y1 - y0 < 200 else { return }
        for ix in x0...x1 {
            for iy in y0...y1 { buckets[key(ix, iy), default: []].append(index) }
        }
    }

    func query(_ rect: DioramaRect) -> Set<Int> {
        var out = Set<Int>()
        guard rect.isFinite, abs(rect.minX) < 1e7, abs(rect.maxX) < 1e7, abs(rect.minY) < 1e7, abs(rect.maxY) < 1e7 else { return out }
        let x0 = Int(floor(rect.minX / cell)), x1 = Int(floor(rect.maxX / cell))
        let y0 = Int(floor(rect.minY / cell)), y1 = Int(floor(rect.maxY / cell))
        guard x1 - x0 < 400, y1 - y0 < 400 else { return out }
        for ix in x0...x1 {
            for iy in y0...y1 {
                if let items = buckets[key(ix, iy)] { out.formUnion(items) }
            }
        }
        return out
    }
}

/// Deterministic randomness seeded per feature (SplitMix64).
nonisolated struct DioramaRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64, salt: UInt64 = 0) {
        state = DioramaRandom.mix(seed ^ (salt &* 0xD1B5_4A32_D192_ED03))
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a, stable across launches (unlike `Hasher`).
    static func hash(_ string: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01B3
        }
        return h
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        return DioramaRandom.mix(state)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * unit() }
    /// Safe for callers whose bounds may be inverted (a `...` literal with lower > upper would trap).
    mutating func range(between a: Double, and b: Double) -> Double { min(a, b) + abs(b - a) * unit() }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(max(r.upperBound - r.lowerBound + 1, 1))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ items: [T]) -> T {
        precondition(!items.isEmpty, "pick from empty list")
        return items[Int(next() % UInt64(items.count))]
    }
}
