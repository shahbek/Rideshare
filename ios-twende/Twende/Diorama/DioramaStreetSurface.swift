import Foundation

/// A planar union of convex street pieces. Surface tessellation and exposed edges share exactly
/// the same masks, so crossing roads never leave internal kerbs or overlapping asphalt lids.
nonisolated struct DioramaStreetSurface: Sendable {
    let polygons: [[DV2]]
    private let bounds: [DioramaRect]
    private let grid: DioramaGrid

    init(_ polygons: [[DV2]]) {
        self.polygons = polygons.filter { $0.count >= 3 && DioramaPolygon.area($0) > 0.00001 }.map(DioramaPolygon.counterClockwise)
        bounds = self.polygons.map(DioramaRect.bounding)
        var index = DioramaGrid(cell: 24)
        for i in bounds.indices { index.insert(i, rect: bounds[i]) }
        grid = index
    }

    func contains(_ p: DV2) -> Bool {
        let box = DioramaRect.bounding([p]).expanded(by: 0.001)
        return grid.query(box).contains { bounds[$0].contains(p) && DioramaPolygon.contains(polygons[$0], p) }
    }

    /// Disjoint convex pieces, optionally with another union removed (pavement minus carriageway).
    func pieces(excluding other: DioramaStreetSurface? = nil) -> [[DV2]] {
        var result: [[DV2]] = []
        for i in polygons.indices {
            var pieces = [polygons[i]]
            for j in grid.query(bounds[i]).sorted() where j < i && bounds[j].intersects(bounds[i]) {
                pieces = pieces.flatMap { DioramaRect.bounding($0).intersects(bounds[j]) ? DioramaGroundCutouts.subtractConvex(polygons[j], from: $0) : [$0] }
                if pieces.isEmpty { break }
            }
            if let other {
                for j in other.grid.query(bounds[i]).sorted() where other.bounds[j].intersects(bounds[i]) {
                    pieces = pieces.flatMap { DioramaRect.bounding($0).intersects(other.bounds[j]) ? DioramaGroundCutouts.subtractConvex(other.polygons[j], from: $0) : [$0] }
                    if pieces.isEmpty { break }
                }
            }
            result += pieces.filter { $0.count >= 3 && DioramaPolygon.area($0) > 0.00001 }
        }
        return result
    }

    /// Disjoint intersection of a convex patch with this union, used to trim access ramps.
    func intersection(_ polygon: [DV2]) -> [[DV2]] {
        let bounds = DioramaRect.bounding(polygon)
        let candidates = grid.query(bounds).sorted()
        var result: [[DV2]] = []
        for j in candidates where self.bounds[j].intersects(bounds) {
            var clipped = DioramaPolygon.counterClockwise(polygon)
            let mask = polygons[j]
            for k in mask.indices {
                clipped = DioramaGroundCutouts.halfPlane(clipped, a: mask[k], b: mask[(k + 1) % mask.count], inside: true)
                if clipped.count < 3 { break }
            }
            guard clipped.count >= 3, DioramaPolygon.area(clipped) > 0.00001 else { continue }
            var pieces = [clipped]
            for k in candidates where k < j && self.bounds[k].intersects(DioramaRect.bounding(clipped)) {
                pieces = pieces.flatMap { DioramaRect.bounding($0).intersects(self.bounds[k]) ? DioramaGroundCutouts.subtractConvex(polygons[k], from: $0) : [$0] }
            }
            result += pieces.filter { $0.count >= 3 && DioramaPolygon.area($0) > 0.00001 }
        }
        return result
    }

    /// Exact mask intersections precede height subdivision; an edge is never dropped wholesale.
    func outsideSegments(_ a: DV2, _ b: DV2, within rect: DioramaRect) -> [(DV2, DV2)] {
        var result: [(DV2, DV2)] = []
        for line in DioramaPolygon.clip([a, b], to: rect) {
            guard let p = line.first, let q = line.last else { continue }
            let d = q - p
            let candidates = grid.query(DioramaRect.bounding([p, q])).sorted()
            var cuts: [Double] = [0, 1]
            for j in candidates {
                let ring = polygons[j]
                for k in ring.indices {
                    let c = ring[k], e = ring[(k + 1) % ring.count] - c
                    let denominator = d.cross(e)
                    guard abs(denominator) > 1e-9 else { continue }
                    let t = (c - p).cross(e) / denominator, u = (c - p).cross(d) / denominator
                    if t > 0, t < 1, u >= 0, u <= 1 { cuts.append(t) }
                }
            }
            cuts.sort()
            for (lo, hi) in zip(cuts, cuts.dropFirst()) where (hi - lo) * d.length > 0.001 {
                let mid = p + d * ((lo + hi) * 0.5)
                if !candidates.contains(where: { DioramaPolygon.contains(polygons[$0], mid) }) {
                    result.append((p + d * lo, p + d * hi))
                }
            }
        }
        return result
    }

    /// Split every edge at actual intersections, retaining only the union's external boundary.
    func boundary() -> [(a: DV2, b: DV2)] {
        var result: [(DV2, DV2)] = []
        var seen: Set<String> = []
        for i in polygons.indices {
            let ring = polygons[i]
            for k in ring.indices {
                let a = ring[k], b = ring[(k + 1) % ring.count], d = b - a
                guard d.length > 0.0001 else { continue }
                let candidates = grid.query(DioramaRect.bounding([a, b]).expanded(by: 0.001)).sorted()
                var cuts: [Double] = [0, 1]
                for j in candidates where j != i {
                    let mask = polygons[j]
                    for e in mask.indices {
                        let c = mask[e], f = mask[(e + 1) % mask.count] - c
                        let cross = d.cross(f)
                        if abs(cross) > 1e-9 {
                            let t = (c - a).cross(f) / cross
                            let u = (c - a).cross(d) / cross
                            if t > 0, t < 1, u >= -1e-8, u <= 1 + 1e-8 { cuts.append(t) }
                        } else if abs(d.cross(c - a)) < 1e-7 {
                            for p in [c, c + f] {
                                let t = (p - a).dot(d) / d.dot(d)
                                if t > 0, t < 1 { cuts.append(t) }
                            }
                        }
                    }
                }
                cuts.sort()
                for (lo, hi) in zip(cuts, cuts.dropFirst()) where (hi - lo) * d.length > 0.0001 {
                    let midpoint = a + d * ((lo + hi) * 0.5) + d.normalized.right * 0.00001
                    guard !candidates.contains(where: { $0 != i && DioramaPolygon.contains(polygons[$0], midpoint) }) else { continue }
                    let p = a + d * lo, q = a + d * hi
                    let key = Self.key(p) + "/" + Self.key(q)
                    if seen.insert(key).inserted { result.append((p, q)) }
                }
            }
        }
        return result
    }

    /// Small infill fillets at re-entrant road corners. These are real surface polygons, not kerbs
    /// drawn across empty ground. Convex outer bends are already round capsule joins.
    func cornerFillets(obstacles: [[DV2]]) -> [[DV2]] {
        let edges = boundary()
        var incoming: [String: DV2] = [:]
        for edge in edges { incoming[Self.key(edge.b)] = edge.a }
        var patches: [[DV2]] = []
        for edge in edges {
            let c = edge.a
            guard let prev = incoming[Self.key(c)] else { continue }
            let before = (c - prev).normalized, after = (edge.b - c).normalized
            guard before.cross(after) < -0.2, before.dot(after) > -0.75 else { continue }
            let reach = min(2.0, c.distance(to: prev) * 0.4, c.distance(to: edge.b) * 0.4)
            guard reach > 0.35 else { continue }
            let a = c - before * reach, b = c + after * reach
            let bounds = DioramaRect.bounding([a, b, c])
            guard !obstacles.contains(where: { DioramaRect.bounding($0).intersects(bounds) }) else { continue }
            var last = a
            for k in 1...8 {
                let t = Double(k) / 8
                let p = a * ((1 - t) * (1 - t)) + c * (2 * t * (1 - t)) + b * (t * t)
                patches.append(DioramaPolygon.counterClockwise([c, last, p]))
                last = p
            }
        }
        return patches
    }

    /// Capsules preserve centreline locations; curved joins are tessellated below 0.1 m chord error.
    static func corridor(_ road: DioramaRoadFeature, extra: Double) -> [[DV2]] {
        var result: [[DV2]] = []
        let half = road.width / 2 + extra
        for (a, b) in zip(road.line, road.line.dropFirst()) where a.distance(to: b) > 0.001 {
            let n = (b - a).normalized.left * half
            result.append([a - n, b - n, b + n, a + n])
        }
        for p in road.line {
            let count = max(24, Int(ceil(half * 5)))
            result.append((0..<count).map { k in
                let angle = Double(k) / Double(count) * 2 * Double.pi
                return p + DV2(cos(angle), sin(angle)) * half
            })
        }
        return result
    }

    private static func key(_ p: DV2) -> String {
        "\(Int64((p.x * 10000).rounded())):\(Int64((p.y * 10000).rounded()))"
    }
}
