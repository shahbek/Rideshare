import SceneKit
import simd

/// Joins mapped bridge graphs before constructing skins, so bends and branches have no internal frames.
enum AirportBoardingBridgeGeometry {
    private struct PointKey: Hashable {
        let x: Int64
        let y: Int64
        init(_ p: SIMD2<Double>) { x = Int64((p.x * 10_000).rounded()); y = Int64((p.y * 10_000).rounded()) }
        var point: SIMD2<Double> { SIMD2(Double(x) / 10_000, Double(y) / 10_000) }
    }

    static func add(_ data: AirportMapData, site: DarLandmarkSite, root: SCNNode) {
        var segments: [(SIMD2<Double>, SIMD2<Double>)] = []
        var neighbours: [PointKey: Set<PointKey>] = [:]
        for feature in data.features where feature.tags["aeroway"] == "jet_bridge" {
            let line = feature.local(origin: site.anchor.coordinate).map { SIMD2($0.x, $0.y) }
            for (a, b) in zip(line, line.dropFirst()) where simd_distance(a, b) > 0.1 {
                let p = PointKey(a), q = PointKey(b)
                guard neighbours[p]?.contains(q) != true else { continue }
                neighbours[p, default: []].insert(q)
                neighbours[q, default: []].insert(p)
                segments.append((p.point, q.point))
            }
        }
        guard !segments.isEmpty else { return }
        var polygons: [[SIMD2<Double>]] = []
        for (a, b) in segments {
            let direction = simd_normalize(b - a), side = SIMD2(-direction.y, direction.x) * 1.7
            polygons.append([a - side, b - side, b + side, a + side])
        }
        let keys = neighbours.keys.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        for key in keys where (neighbours[key]?.count ?? 0) > 1 {
            polygons.append((0..<16).map { i in
                let angle = Double(i) * 2 * Double.pi / 16
                return key.point + SIMD2(cos(angle), sin(angle)) * 1.7
            })
        }
        guard let rings = unionBoundary(polygons), !rings.isEmpty else {
            #if DEBUG
            print("[DarLandmarks] JNIA boarding bridge union failed; no overlapping segment fallback")
            #endif
            return
        }
        let footprint = BuildingFootprint(rings: rings)
        root.addChildNode(footprint.deck(at: 5.35, thickness: 0.35, material: DarLandmarkParts.silver, name: "airportJoinedBoardingBridgeFloor"))
        root.addChildNode(footprint.deck(at: 8.65, thickness: 0.28, material: DarLandmarkParts.plaster, name: "airportJoinedBoardingBridgeRoof"))
        let terminals = data.features.filter { [597787841, 23359828].contains($0.id) }.map { $0.local(origin: site.anchor.coordinate) }
        func atTerminal(_ p: SIMD2<Double>) -> Bool {
            let q = DV2(p.x, p.y)
            return terminals.contains { DioramaPolygon.contains($0, q) || DioramaPolygon.distanceToRing($0, q) < 0.12 }
        }
        var panes = BuildingMesh(), panels = BuildingMesh(), frames = BuildingMesh(), supports = BuildingMesh()
        for ring in rings {
            let miters = ring.indices.map { i -> SIMD2<Double> in
                let incoming = simd_normalize(ring[i] - ring[(i + ring.count - 1) % ring.count])
                let outgoing = simd_normalize(ring[(i + 1) % ring.count] - ring[i])
                let a = SIMD2(incoming.y, -incoming.x), b = SIMD2(outgoing.y, -outgoing.x)
                guard simd_length(a + b) > 0.001 else { return b }
                let normal = simd_normalize(a + b)
                return normal / max(0.35, simd_dot(normal, b))
            }
            var station = 0.0, nextPost = 0.0
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count], d = b - a, length = simd_length(d)
                guard length > 0.00001 else { continue }
                let normal = SIMD2(d.y, -d.x) / length
                if !atTerminal((a + b) / 2) {
                    // Opaque lower cladding with broad glazing above, not a stack of crossed glass boxes.
                    let ma = miters[i], mb = miters[(i + 1) % ring.count]
                    panel(&panels, a, b, bottom: 5.7, top: 6.55, inwardA: ma * 0.12, inwardB: mb * 0.12)
                    panel(&panels, a, b, bottom: 8.35, top: 8.65, inwardA: ma * 0.12, inwardB: mb * 0.12)
                    panes.quad(DarLandmarkParts.p(a, 6.55), DarLandmarkParts.p(b, 6.55), DarLandmarkParts.p(b, 8.35), DarLandmarkParts.p(a, 8.35), normal: SIMD3(normal.x, normal.y, 0))
                    for z in [6.55, 8.35] {
                        panel(&frames, a + ma * 0.02, b + mb * 0.02, bottom: z - 0.065, top: z + 0.065, inwardA: ma * 0.10, inwardB: mb * 0.10)
                    }
                    while nextPost < station + length {
                        let p = a + d * max(0, (nextPost - station) / length)
                        LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(p - normal * 0.03, 6.5), to: DarLandmarkParts.p(p - normal * 0.03, 8.4), radius: 0.10, sides: 8)
                        nextPost += 4.5
                    }
                } else {
                    nextPost = max(nextPost, station + length)
                }
                station += length
            }
        }
        var supported: [SIMD2<Double>] = []
        for key in keys {
            var p = key.point
            guard !atTerminal(p) else { continue }
            if neighbours[key]?.count == 1, let neighbour = neighbours[key]?.first {
                let inward = neighbour.point - p
                p += simd_normalize(inward) * min(1.3, simd_length(inward) * 0.5)
            }
            guard !atTerminal(p), supported.allSatisfy({ simd_distance($0, p) > 4.5 }) else { continue }
            let clearance = rings.map { DioramaPolygon.distanceToRing($0.map { DV2($0.x, $0.y) }, DV2(p.x, p.y)) }.min() ?? 0
            let capWidth = min(1.5, clearance * 1.3)
            guard capWidth > 0.25 else { continue }
            supported.append(p)
            AirportArchitectureParts.box(&supports, centre: p, width: min(0.8, capWidth * 0.65), depth: min(0.8, capWidth * 0.65), bottom: 0.2, top: 5.35)
            AirportArchitectureParts.box(&supports, centre: p, width: capWidth, depth: capWidth, bottom: 4.95, top: 5.35)
        }
        root.addChildNode(panels.node(name: "airportBoardingBridgeOpaqueCladding", material: DarLandmarkParts.plaster))
        root.addChildNode(panes.node(name: "airportBoardingBridgeJoinedWindowBands", material: AirportArchitectureParts.clearGlass(alpha: 0.13)))
        root.addChildNode(frames.node(name: "airportBoardingBridgeAlignedExteriorFrames", material: DarLandmarkParts.silver))
        root.addChildNode(supports.node(name: "airportBoardingBridgeUniqueSupports", material: DarLandmarkParts.silver))
        #if DEBUG
        print("[DarLandmarks] JNIA bridges: \(segments.count) unique segments, \(rings.count) joined rings, \(supported.count) supports")
        #endif
    }

    private static func panel(_ mesh: inout BuildingMesh, _ a: SIMD2<Double>, _ b: SIMD2<Double>, bottom: Double, top: Double, inwardA: SIMD2<Double>, inwardB: SIMD2<Double>) {
        let p = a - inwardA, q = b - inwardB
        let al = DarLandmarkParts.p(a, bottom), bl = DarLandmarkParts.p(b, bottom), ah = DarLandmarkParts.p(a, top), bh = DarLandmarkParts.p(b, top)
        let pl = DarLandmarkParts.p(p, bottom), ql = DarLandmarkParts.p(q, bottom), ph = DarLandmarkParts.p(p, top), qh = DarLandmarkParts.p(q, top)
        mesh.quad(al, bl, bh, ah); mesh.quad(ql, pl, ph, qh)
        mesh.quad(ah, bh, qh, ph); mesh.quad(pl, ql, bl, al)
        // End faces are intentionally absent: adjacent panels share exact boundary vertices.
    }

    /// Planar edge arrangement: split crossings, retain exposed half-edges, then trace wound rings.
    /// Coincident interior seams disappear before either the deck or facade is built.
    private static func unionBoundary(_ polygons: [[SIMD2<Double>]]) -> [[SIMD2<Double>]]? {
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
        var levels = Set(polygons.flatMap { $0.map(\.y) })
        var edges: [(PointKey, PointKey)] = []
        var seen: [PointKey: Set<PointKey>] = [:]
        for (owner, polygon) in polygons.enumerated() {
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count], delta = b - a
                let lengthSquared = simd_length_squared(delta)
                guard lengthSquared > 0.000000001 else { continue }
                var stops: [Double] = [0, 1]
                for (other, clip) in polygons.enumerated() where other != owner {
                    for j in clip.indices {
                        let c = clip[j], d = clip[(j + 1) % clip.count], edge = d - c
                        let denominator = cross(delta, edge)
                        if abs(denominator) > 0.000000001 {
                            let t = cross(c - a, edge) / denominator, u = cross(c - a, delta) / denominator
                            if t > 0, t < 1, u >= -0.00000001, u <= 1.00000001 { stops.append(t) }
                        } else if abs(cross(c - a, delta)) < 0.0000001 {
                            for p in [c, d] {
                                let t = simd_dot(p - a, delta) / lengthSquared
                                if t > 0, t < 1 { stops.append(t) }
                            }
                        }
                    }
                }
                stops.sort()
                let normal = SIMD2(delta.y, -delta.x) / sqrt(lengthSquared)
                for stop in stops { levels.insert((a + delta * stop).y) }
                for (t, u) in zip(stops, stops.dropFirst()) where u - t > 0.0000001 {
                    let midpoint = a + delta * ((t + u) / 2)
                    // Classify the infinitesimal right side analytically. A fixed-offset probe
                    // crosses narrow wedges between almost parallel segments and breaks the ring.
                    let hidden = polygons.enumerated().contains { other, clip in
                        other != owner && coversRightSide(clip, at: midpoint, outward: normal)
                    }
                    guard !hidden else { continue }
                    let p = PointKey(a + delta * t), q = PointKey(a + delta * u)
                    guard p != q, seen[p]?.contains(q) != true else { continue }
                    seen[p, default: []].insert(q)
                    edges.append((p, q))
                }
            }
        }
        var outgoing: [PointKey: [Int]] = [:], balance: [PointKey: Int] = [:]
        for i in edges.indices {
            outgoing[edges[i].0, default: []].append(i)
            balance[edges[i].0, default: 0] += 1
            balance[edges[i].1, default: 0] -= 1
        }
        guard balance.values.allSatisfy({ $0 == 0 }) else {
            #if DEBUG
            print("[DarLandmarks] JNIA bridge boundary has \(balance.values.filter { $0 != 0 }.count) unmatched endpoints")
            #endif
            return nil
        }
        var remaining = Set(edges.indices), rings: [[SIMD2<Double>]] = []
        while let first = remaining.min() {
            var index = first, ring: [SIMD2<Double>] = [], closed = false
            for _ in 0...edges.count {
                guard remaining.remove(index) != nil else { return nil }
                let (a, b) = edges[index]
                ring.append(a.point)
                if b == edges[first].0 { closed = true; break }
                let candidates = (outgoing[b] ?? []).filter { remaining.contains($0) }
                let previous = b.point - a.point
                // Keep separate material-left cycles separate at a point contact.
                guard let next = candidates.max(by: { left, right in
                    let l = edges[left].1.point - b.point, r = edges[right].1.point - b.point
                    return atan2(cross(previous, l), simd_dot(previous, l)) < atan2(cross(previous, r), simd_dot(previous, r))
                }) else { return nil }
                index = next
            }
            guard closed, ring.count >= 3, Set(ring.map(PointKey.init)).count == ring.count,
                  DioramaPolygon.isSimple(ring.map { DV2($0.x, $0.y) }) else { return nil }
            rings.append(ring)
        }
        // Independently integrate the input union's scanline spans. Even-odd output must
        // not accidentally cancel an overlapping ring or fill a traced bridge-network hole.
        let ys = levels.sorted()
        var expected = 0.0
        for (low, high) in zip(ys, ys.dropFirst()) where high - low > 0.000000001 {
            let y = (low + high) / 2
            var spans: [(Double, Double)] = []
            for polygon in polygons {
                var xs: [Double] = []
                for i in polygon.indices {
                    let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                    if min(a.y, b.y) < y, max(a.y, b.y) > y {
                        xs.append(a.x + (b.x - a.x) * ((y - a.y) / (b.y - a.y)))
                    }
                }
                if let a = xs.min(), let b = xs.max() { spans.append((a, b)) }
            }
            spans.sort { $0.0 < $1.0 }
            var width = 0.0, left: Double?, right = 0.0
            for span in spans {
                if let start = left {
                    if span.0 <= right { right = max(right, span.1) }
                    else { width += right - start; left = span.0; right = span.1 }
                } else { left = span.0; right = span.1 }
            }
            if let start = left { width += right - start }
            expected += width * (high - low)
        }
        let actual = rings.reduce(0.0) { $0 + BuildingFootprint.area($1) }
        let perimeter = rings.reduce(0.0) { sum, ring in
            sum + ring.indices.reduce(0.0) { $0 + simd_distance(ring[$1], ring[($1 + 1) % ring.count]) }
        }
        guard expected > 0, actual > 0, abs(expected - actual) <= max(0.0001, perimeter * 0.0002) else { return nil }
        return rings
    }

    /// Input pieces are convex and counter-clockwise; their left half-planes define the union.
    private static func coversRightSide(_ polygon: [SIMD2<Double>], at midpoint: SIMD2<Double>, outward: SIMD2<Double>) -> Bool {
        for i in polygon.indices {
            let a = polygon[i], edge = polygon[(i + 1) % polygon.count] - a
            let length = simd_length(edge)
            guard length > 0.000000001 else { continue }
            let delta = midpoint - a
            let distance = (edge.x * delta.y - edge.y * delta.x) / length
            let direction = (edge.x * outward.y - edge.y * outward.x) / length
            if distance < -0.00000001 || (abs(distance) <= 0.00000001 && direction < -0.0000000001) { return false }
        }
        return true
    }
}
