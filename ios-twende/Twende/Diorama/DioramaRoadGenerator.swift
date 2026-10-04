import Foundation

/// Toy-town streets: a raised asphalt (or red-earth) carriageway ribbon draped over the terrain, pale
/// pavements with a kerb step on paved streets, a dashed centre line, white edge lines and zebra
/// crossings where streets meet. Everything is built from the centreline, so it follows every bend.
nonisolated struct DioramaRoadGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain

    /// Height of the road surface above the terrain at a point on the centreline.
    static let surfaceLift: Double = 0.12

    func generate(into mesh: inout DioramaMesh) {
        // Pavements first, then carriageways on top so junctions read as continuous asphalt.
        for road in data.roads where road.isPaved {
            let line = DioramaPolygon.densify(road.line, maxStep: 6)
            let half = road.width / 2
            let outer = half + config.pavementWidth
            // Kerb face and pavement slab on each side.
            for side in [-1.0, 1.0] {
                ribbon(line, from: half * side, to: outer * side, lift: Self.surfaceLift + config.kerbHeight, .pavement, into: &mesh)
                // Kerb: the small vertical step between pavement and asphalt.
                wallRibbon(line, offset: half * side, z0: Self.surfaceLift, z1: Self.surfaceLift + config.kerbHeight, facingOut: side < 0, .kerb, into: &mesh)
                // Outer face so the pavement reads as a raised slab against the grass.
                wallRibbon(line, offset: outer * side, z0: 0, z1: Self.surfaceLift + config.kerbHeight, facingOut: side > 0, .pavement, into: &mesh)
            }
        }

        for road in data.roads {
            let line = DioramaPolygon.densify(road.line, maxStep: 6)
            let half = road.width / 2
            let surface: DioramaSwatch = road.isPaved ? .asphalt : .roadEarth
            ribbon(line, from: -half, to: half, lift: Self.surfaceLift, surface, into: &mesh)
            if !road.isPaved {
                // Unpaved lanes sit in a slightly lower sandy shoulder instead of a pavement.
                for side in [-1.0, 1.0] {
                    ribbon(line, from: half * side, to: (half + 1.0) * side, lift: Self.surfaceLift * 0.5, .earth, into: &mesh)
                }
            }
            // Round caps at free ends hide the hard rectangular cut-off of each ribbon.
            for (end, dir) in endCaps(line) where data.rect.expanded(by: -0.5).contains(end) {
                if !roads.isOnCarriageway(end, margin: -0.5, excluding: road.id) {
                    disc(at: end, radius: half, lift: Self.surfaceLift, surface, into: &mesh)
                    _ = dir
                }
            }
        }

        for road in data.roads where road.isPaved {
            markings(road, into: &mesh)
        }
        crossings(into: &mesh)
    }

    // MARK: Ribbons

    private func surfaceHeight(_ p: DV2, lift: Double) -> Double { terrain.height(p) + lift }

    /// Horizontal strip between two signed offsets from the centreline (positive = right of travel).
    private func ribbon(_ line: [DV2], from o0: Double, to o1: Double, lift: Double, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        let n = line.count
        guard n >= 2 else { return }
        let normals = mitredNormals(line)
        for i in 0..<(n - 1) {
            let a0 = line[i] + normals[i].vector * (o0 * normals[i].scale), a1 = line[i] + normals[i].vector * (o1 * normals[i].scale)
            let b0 = line[i + 1] + normals[i + 1].vector * (o0 * normals[i + 1].scale), b1 = line[i + 1] + normals[i + 1].vector * (o1 * normals[i + 1].scale)
            let za0 = surfaceHeight(line[i], lift: lift), zb0 = surfaceHeight(line[i + 1], lift: lift)
            mesh.quad(DV3(a0, za0), DV3(b0, zb0), DV3(b1, zb0), DV3(a1, za0), s, normal: .up)
        }
    }

    /// Vertical face along one offset of the centreline.
    private func wallRibbon(_ line: [DV2], offset o: Double, z0: Double, z1: Double, facingOut: Bool, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        let n = line.count
        guard n >= 2 else { return }
        let normals = mitredNormals(line)
        for i in 0..<(n - 1) {
            let a = line[i] + normals[i].vector * (o * normals[i].scale)
            let b = line[i + 1] + normals[i + 1].vector * (o * normals[i + 1].scale)
            let ha = terrain.height(line[i]), hb = terrain.height(line[i + 1])
            let out = DV3((b - a).normalized.right * (facingOut ? 1 : -1), 0)
            mesh.quad(DV3(a, ha + z0), DV3(b, hb + z0), DV3(b, hb + z1), DV3(a, ha + z1), s, normal: out)
        }
    }

    private func disc(at c: DV2, radius: Double, lift: Double, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        let z = surfaceHeight(c, lift: lift)
        var ring: [DV2] = []
        for k in 0..<10 {
            let a = Double(k) / 10 * 2 * Double.pi
            ring.append(c + DV2(cos(a), sin(a)) * radius)
        }
        mesh.polygon(ring, z: z, s)
    }

    /// Per-vertex right-hand normals, mitred at bends so ribbon edges stay parallel.
    private func mitredNormals(_ line: [DV2]) -> [(vector: DV2, scale: Double)] {
        let n = line.count
        var out: [(DV2, Double)] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let prev = i > 0 ? (line[i] - line[i - 1]).normalized.right : nil
            let next = i < n - 1 ? (line[i + 1] - line[i]).normalized.right : nil
            switch (prev, next) {
            case let (p?, q?):
                let m = (p + q).normalized
                let cosHalf = max(m.dot(p), 0.5)
                out.append((m, 1 / cosHalf))
            case let (p?, nil): out.append((p, 1))
            case let (nil, q?): out.append((q, 1))
            default: out.append((DV2(0, 1), 1))
            }
        }
        return out
    }

    private func endCaps(_ line: [DV2]) -> [(DV2, DV2)] {
        guard line.count >= 2 else { return [] }
        return [(line[0], (line[0] - line[1]).normalized), (line[line.count - 1], (line[line.count - 1] - line[line.count - 2]).normalized)]
    }

    // MARK: Markings

    private func markings(_ road: DioramaRoadFeature, into mesh: inout DioramaMesh) {
        let line = road.line
        let length = DioramaPolygon.length(line)
        guard length > 8 else { return }
        let half = road.width / 2
        let z = Self.surfaceLift + 0.015
        // Dashed centre line on streets wide enough for two lanes.
        if road.width >= 6 {
            var d = 1.5
            while d + config.dashLength < length - 1.5 {
                defer { d += config.dashLength + config.dashGap }
                guard let s0 = DioramaPolygon.sample(line, at: d), let s1 = DioramaPolygon.sample(line, at: d + config.dashLength) else { break }
                // Skip dashes that fall inside another carriageway (junction boxes stay clean).
                let mid = (s0.point + s1.point) * 0.5
                guard !roads.isOnCarriageway(mid, margin: 0.5, excluding: road.id) else { continue }
                strip(s0.point, s1.point, halfWidth: 0.09, lift: z, .marking, into: &mesh)
            }
        }
        // Solid edge lines just inside the kerb.
        let dense = DioramaPolygon.densify(line, maxStep: 6)
        for side in [-1.0, 1.0] {
            ribbon(dense, from: (half - 0.42) * side, to: (half - 0.28) * side, lift: z, .marking, into: &mesh)
        }
    }

    private func strip(_ a: DV2, _ b: DV2, halfWidth: Double, lift: Double, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        let n = (b - a).normalized.right * halfWidth
        let za = surfaceHeight(a, lift: lift), zb = surfaceHeight(b, lift: lift)
        mesh.quad(DV3(a - n, za), DV3(b - n, zb), DV3(b + n, zb), DV3(a + n, za), s, normal: .up)
    }

    /// Zebra crossings on each paved arm a few metres back from a junction with another paved road.
    private func crossings(into mesh: inout DioramaMesh) {
        var placed: [DV2] = []
        for road in data.roads where road.isPaved && road.width >= 6 {
            let line = road.line
            let length = DioramaPolygon.length(line)
            for (end, isStart) in [(line[0], true), (line[line.count - 1], false)] {
                guard data.rect.expanded(by: -6).contains(end) else { continue }
                guard let other = roads.nearest(to: end, within: 2.5), other.road.id != road.id, other.road.isPaved else { continue }
                let back = other.road.width / 2 + 2.6
                guard length > back + 4 else { continue }
                guard let s = DioramaPolygon.sample(line, at: isStart ? back : length - back) else { continue }
                guard !placed.contains(where: { $0.distance(to: s.point) < 6 }) else { continue }
                placed.append(s.point)
                let across = s.direction.right
                let half = road.width / 2 - 0.5
                let stripes = max(Int(road.width / 0.9), 4)
                let step = (half * 2) / Double(stripes)
                for k in stride(from: 0, to: stripes, by: 2) {
                    let o0 = -half + Double(k) * step + 0.08, o1 = -half + Double(k + 1) * step - 0.08
                    let c0 = s.point + across * o0, c1 = s.point + across * o1
                    let z = Self.surfaceLift + 0.02
                    let w = s.direction * 1.3
                    let za = surfaceHeight(c0, lift: z), zb = surfaceHeight(c1, lift: z)
                    mesh.quad(DV3(c0 - w, za), DV3(c1 - w, zb), DV3(c1 + w, zb), DV3(c0 + w, za), .crossing, normal: .up)
                }
            }
        }
    }
}
