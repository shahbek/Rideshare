import Foundation

/// Toy-town streets: a raised asphalt (or red-earth) carriageway ribbon draped over the terrain, pale
/// pavements with a kerb step on paved streets, a dashed centre line, white edge lines, stop lines, zebra
/// crossings and stop signs where streets meet. Pavement and kerb pieces that would fall inside another
/// street's carriageway are dropped, so junctions stay open asphalt instead of a tangle of kerbs.
nonisolated struct DioramaRoadGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain

    /// Height of the road surface above the terrain at a point on the centreline.
    static let surfaceLift: Double = 0.12

    /// Fine subdivision so junction cut-outs are tight.
    private let step: Double = 3

    func generate(into mesh: inout DioramaMesh) {
        // Pavements first, then carriageways on top so junctions read as continuous asphalt.
        for road in data.roads where road.isPaved {
            let line = DioramaPolygon.densify(road.line, maxStep: step)
            let half = road.width / 2
            let outer = half + config.pavementWidth
            let top = Self.surfaceLift + config.kerbHeight
            for side in [-1.0, 1.0] {
                ribbon(line, from: half * side, to: outer * side, lift: top, .pavement, exclude: road.id, into: &mesh)
                // Kerb: the small vertical step between pavement and asphalt.
                wallRibbon(line, offset: half * side, z0: Self.surfaceLift, z1: top, facingOut: side < 0, .kerb, exclude: road.id, into: &mesh)
                // Outer face so the pavement reads as a raised slab against the grass.
                wallRibbon(line, offset: outer * side, z0: 0, z1: top, facingOut: side > 0, .pavement, exclude: road.id, into: &mesh)
            }
        }

        for road in data.roads {
            let line = DioramaPolygon.densify(road.line, maxStep: step)
            let half = road.width / 2
            let surface: DioramaSwatch = road.isPaved ? .asphalt : .roadEarth
            ribbon(line, from: -half, to: half, lift: Self.surfaceLift, surface, exclude: nil, into: &mesh)
            if !road.isPaved {
                for side in [-1.0, 1.0] {
                    ribbon(line, from: half * side, to: (half + 1.0) * side, lift: Self.surfaceLift * 0.5, .earth, exclude: road.id, into: &mesh)
                }
            }
            // Round caps at free ends hide the hard rectangular cut-off of each ribbon.
            for end in [line[0], line[line.count - 1]] where data.rect.expanded(by: -0.5).contains(end) {
                if !roads.isOnCarriageway(end, margin: -0.5, excluding: road.id) {
                    disc(at: end, radius: half, lift: Self.surfaceLift, surface, into: &mesh)
                }
            }
        }

        for road in data.roads where road.isPaved {
            markings(road, into: &mesh)
        }
        junctions(into: &mesh)
    }

    // MARK: Ribbons

    private func surfaceHeight(_ p: DV2, lift: Double) -> Double { terrain.height(p) + lift }

    /// A piece of pavement/kerb is dropped when its midpoint lies on another street's carriageway.
    private func blocked(_ a: DV2, _ b: DV2, exclude: UInt64?) -> Bool {
        guard let exclude else { return false }
        let mid = (a + b) * 0.5
        return roads.isOnCarriageway(mid, margin: 0.35, excluding: exclude)
            || roads.isOnCarriageway(a, margin: -0.2, excluding: exclude)
            || roads.isOnCarriageway(b, margin: -0.2, excluding: exclude)
    }

    /// Horizontal strip between two signed offsets from the centreline (positive = right of travel).
    private func ribbon(_ line: [DV2], from o0: Double, to o1: Double, lift: Double, _ s: DioramaSwatch, exclude: UInt64?, into mesh: inout DioramaMesh) {
        let n = line.count
        guard n >= 2 else { return }
        let normals = mitredNormals(line)
        for i in 0..<(n - 1) {
            let a0 = line[i] + normals[i].vector * (o0 * normals[i].scale), a1 = line[i] + normals[i].vector * (o1 * normals[i].scale)
            let b0 = line[i + 1] + normals[i + 1].vector * (o0 * normals[i + 1].scale), b1 = line[i + 1] + normals[i + 1].vector * (o1 * normals[i + 1].scale)
            if blocked((a0 + a1) * 0.5, (b0 + b1) * 0.5, exclude: exclude) { continue }
            let za0 = surfaceHeight(line[i], lift: lift), zb0 = surfaceHeight(line[i + 1], lift: lift)
            mesh.quad(DV3(a0, za0), DV3(b0, zb0), DV3(b1, zb0), DV3(a1, za0), s, normal: .up)
        }
    }

    /// Vertical face along one offset of the centreline.
    private func wallRibbon(_ line: [DV2], offset o: Double, z0: Double, z1: Double, facingOut: Bool, _ s: DioramaSwatch, exclude: UInt64?, into mesh: inout DioramaMesh) {
        let n = line.count
        guard n >= 2 else { return }
        let normals = mitredNormals(line)
        for i in 0..<(n - 1) {
            let a = line[i] + normals[i].vector * (o * normals[i].scale)
            let b = line[i + 1] + normals[i + 1].vector * (o * normals[i + 1].scale)
            if blocked(a, b, exclude: exclude) { continue }
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

    // MARK: Markings

    private func markings(_ road: DioramaRoadFeature, into mesh: inout DioramaMesh) {
        let line = road.line
        let length = DioramaPolygon.length(line)
        guard length > 8 else { return }
        let half = road.width / 2
        let z = Self.surfaceLift + 0.015
        if road.width >= 6 {
            var d = 1.5
            while d + config.dashLength < length - 1.5 {
                defer { d += config.dashLength + config.dashGap }
                guard let s0 = DioramaPolygon.sample(line, at: d), let s1 = DioramaPolygon.sample(line, at: d + config.dashLength) else { break }
                let mid = (s0.point + s1.point) * 0.5
                guard !roads.isOnCarriageway(mid, margin: 0.5, excluding: road.id) else { continue }
                strip(s0.point, s1.point, halfWidth: 0.09, lift: z, .marking, into: &mesh)
            }
        }
        let dense = DioramaPolygon.densify(line, maxStep: step)
        for side in [-1.0, 1.0] {
            ribbon(dense, from: (half - 0.42) * side, to: (half - 0.28) * side, lift: z, .marking, exclude: road.id, into: &mesh)
        }
    }

    private func strip(_ a: DV2, _ b: DV2, halfWidth: Double, lift: Double, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        let n = (b - a).normalized.right * halfWidth
        let za = surfaceHeight(a, lift: lift), zb = surfaceHeight(b, lift: lift)
        mesh.quad(DV3(a - n, za), DV3(b - n, zb), DV3(b + n, zb), DV3(a + n, za), s, normal: .up)
    }

    /// Where a paved street arrives at another paved street: zebra crossing, stop line and a stop sign on
    /// the near-side pavement (traffic keeps left in Tanzania).
    private func junctions(into mesh: inout DioramaMesh) {
        var placed: [DV2] = []
        for road in data.roads where road.isPaved && road.width >= 6 {
            let line = road.line
            let length = DioramaPolygon.length(line)
            for isStart in [true, false] {
                let end = isStart ? line[0] : line[line.count - 1]
                guard data.rect.expanded(by: -6).contains(end) else { continue }
                guard let other = roads.nearest(to: end, within: 2.5), other.road.id != road.id, other.road.isPaved else { continue }
                let back = other.road.width / 2 + config.pavementWidth + 1.6
                guard length > back + 6 else { continue }
                guard let s = DioramaPolygon.sample(line, at: isStart ? back : length - back) else { continue }
                guard !placed.contains(where: { $0.distance(to: s.point) < 6 }) else { continue }
                placed.append(s.point)
                // Direction of travel towards the junction.
                let toward = isStart ? -s.direction : s.direction
                let across = toward.right
                let half = road.width / 2 - 0.5

                // Zebra stripes across the full width.
                let stripes = max(Int(road.width / 0.9), 4)
                let stripeStep = (half * 2) / Double(stripes)
                for k in stride(from: 0, to: stripes, by: 2) {
                    let o0 = -half + Double(k) * stripeStep + 0.08, o1 = -half + Double(k + 1) * stripeStep - 0.08
                    let c0 = s.point + across * o0, c1 = s.point + across * o1
                    let z = Self.surfaceLift + 0.02
                    let w = toward * 1.2
                    let za = surfaceHeight(c0, lift: z), zb = surfaceHeight(c1, lift: z)
                    mesh.quad(DV3(c0 - w, za), DV3(c1 - w, zb), DV3(c1 + w, zb), DV3(c0 + w, za), .crossing, normal: .up)
                }

                // Stop line across the approaching (left-hand) lane, just before the crossing.
                let stopCentre = s.point - toward * 2.0
                let laneOuter = stopCentre + across.left * 0 - across * half  // left kerb side
                _ = laneOuter
                let l0 = stopCentre + across * (-half), l1 = stopCentre + across * 0.15
                let inward = isStart ? -1.0 : 1.0
                _ = inward
                // In left-hand traffic the approaching lane is to the LEFT of `toward`, i.e. negative `across`.
                strip(l0, l1, halfWidth: 0.2, lift: Self.surfaceLift + 0.02, .marking, into: &mesh)

                // Stop sign on the left pavement, facing approaching traffic.
                let signSpot = stopCentre - across * (road.width / 2 + config.pavementWidth * 0.5)
                if data.rect.expanded(by: -1).contains(signSpot), !roads.isOnCarriageway(signSpot, margin: 0.2) {
                    stopSign(at: signSpot, facing: -toward, into: &mesh)
                }
            }
        }
    }

    private func stopSign(at p: DV2, facing out: DV2, into mesh: inout DioramaMesh) {
        let z = terrain.height(p) + Self.surfaceLift + config.kerbHeight
        mesh.tube(from: DV3(p, z), to: DV3(p, z + 2.6), r0: 0.05, r1: 0.045, sides: 5, .signPost, cap: false)
        let face = DV3(p + out * 0.06, z + 2.35)
        mesh.verticalDisc(centre: face - DV3(out * 0.03, 0), radius: 0.46, sides: 8, facing: out, .trimWhite, rotate: Double.pi / 8)
        mesh.verticalDisc(centre: face, radius: 0.38, sides: 8, facing: out, .stopRed, rotate: Double.pi / 8)
        mesh.verticalDisc(centre: face - DV3(out * 0.08, 0), radius: 0.44, sides: 8, facing: -out, .signPost, rotate: Double.pi / 8)
        // A pale "STOP" bar reads at toy scale.
        let across = out.left
        mesh.quad(face + DV3(across * -0.26, -0.06), face + DV3(across * 0.26, -0.06), face + DV3(across * 0.26, 0.06), face + DV3(across * -0.26, 0.06), .trimWhite, normal: DV3(out, 0))
    }
}
