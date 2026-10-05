import Foundation

/// A compound (plot) around a villa, so later passes know where lawn, hedges and trees go.
nonisolated struct DioramaCompound: Sendable {
    let building: DioramaBuilt
    /// Counter-clockwise boundary ring; `gaps[i]` marks edges removed by roads, neighbours or earlier plots.
    let ring: [DV2]
    let gaps: [Bool]
    /// Centre of the gate on the edge facing the nearest road.
    let gate: (point: DV2, direction: DV2)?
    /// True when the boundary is a clipped hedge rather than a plaster wall.
    let isHedge: Bool
}

/// Low painted boundary walls or clipped hedges a few metres outside each villa. Plots are laid down
/// one at a time and every piece that would cross a road, a neighbour's house or an earlier plot's
/// boundary is dropped, so fences never overlap or run through each other. Each wall has a cap, a
/// metal gate facing the nearest road and sometimes a guard hut.
nonisolated struct DioramaCompoundWallGenerator {
    let config: DioramaConfig
    let roads: DioramaRoadIndex
    let buildings: [DioramaBuilt]
    let tileRect: DioramaRect
    let terrain: DioramaTerrain
    let landuse: [DioramaAreaFeature]
    private let grid: DioramaGrid

    init(config: DioramaConfig, roads: DioramaRoadIndex, buildings: [DioramaBuilt], tileRect: DioramaRect, terrain: DioramaTerrain, landuse: [DioramaAreaFeature] = []) {
        self.config = config
        self.roads = roads
        self.buildings = buildings
        self.tileRect = tileRect
        self.terrain = terrain
        self.landuse = landuse
        var grid = DioramaGrid(cell: 40)
        for (i, b) in buildings.enumerated() {
            grid.insert(i, rect: DioramaRect.bounding(b.feature.ring))
        }
        self.grid = grid
    }

    /// Standing boundary pieces already placed, for the overlap test.
    private struct Placed {
        let ring: [DV2]
        let pieces: [(DV2, DV2)]
    }

    func generate(into mesh: inout DioramaMesh) -> [DioramaCompound] {
        var compounds: [DioramaCompound] = []
        var placed: [Placed] = []
        // Larger villas first so the big plots claim their ground and small ones fit around them.
        let order = buildings.indices.filter { buildings[$0].kind == .villa }.sorted {
            let a = buildings[$0], b = buildings[$1]
            return a.feature.area != b.feature.area ? a.feature.area > b.feature.area : a.feature.id < b.feature.id
        }
        for index in order {
            let built = buildings[index]
            guard built.feature.clipped.allSatisfy({ !$0 }) else { continue }
            mesh.baseZ = terrain.height(built.feature.centroid)
            defer { mesh.baseZ = 0 }
            var rng = DioramaRandom(seed: built.feature.id, salt: 7)
            var offset = rng.range(config.wallOffset)
            // Shrink the plot until it stops swallowing neighbouring houses.
            let neighbours = grid.query(built.box.expanded(by: config.wallOffset.upperBound + 2).bounds).subtracting([index])
            while offset > 1.6 {
                let plot = built.box.expanded(by: offset)
                let overlapsHouse = neighbours.contains { j in
                    let other = buildings[j]
                    return plot.contains(other.feature.centroid) || other.box.expanded(by: 0.3).contains(plot.centre + plot.axis * plot.halfLength) || other.box.expanded(by: 0.3).contains(plot.centre - plot.axis * plot.halfLength)
                }
                if !overlapsHouse { break }
                offset -= 0.6
            }
            guard offset > 1.6 else { continue }
            let plot = built.box.expanded(by: offset)
            var ring = plot.corners
            let inner = tileRect.expanded(by: -1.5)
            ring = ring.map { DV2(min(max($0.x, inner.minX), inner.maxX), min(max($0.y, inner.minY), inner.maxY)) }
            guard DioramaPolygon.area(ring) > built.feature.area * 1.15 else { continue }

            // Project the actual front door onto the plot boundary. Reserve a full-width gate
            // BEFORE subdividing; the old 2.5 m pieces could never hold the configured 3.2 m gate.
            var gateSide = -1
            var gateCentre: DV2?
            var gateDistance = Double.infinity
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count], edge = b - a
                let ray = built.entranceOut
                let cross = ray.cross(edge)
                guard abs(cross) > 0.001, edge.length > config.gateWidth + 1 else { continue }
                let t = (a - built.entrance).cross(edge) / cross
                let u = (a - built.entrance).cross(ray) / cross
                guard t > 0, t < gateDistance, u >= 0, u <= 1 else { continue }
                let margin = (config.gateWidth / 2 + 0.4) / edge.length
                gateCentre = a + edge * max(margin, min(1 - margin, u))
                gateSide = i; gateDistance = t
            }
            var points: [DV2] = []
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                func appendSpan(_ p: DV2, _ q: DV2) {
                    let steps = max(Int(ceil(p.distance(to: q) / 2.5)), 1)
                    for s in 0..<steps { points.append(p + (q - p) * (Double(s) / Double(steps))) }
                }
                if i == gateSide, let centre = gateCentre {
                    let dir = (b - a).normalized
                    let l = centre - dir * (config.gateWidth / 2 + 0.3)
                    let r = centre + dir * (config.gateWidth / 2 + 0.3)
                    appendSpan(a, l)
                    points.append(l)
                    appendSpan(r, b)
                } else { appendSpan(a, b) }
            }
            let n = points.count
            var gaps = [Bool](repeating: false, count: n)
            for i in 0..<n {
                let a = points[i], b = points[(i + 1) % n]
                let mid = (a + b) * 0.5
                if roads.blocks(a, b, clearance: config.pavementWidth + 0.3) { gaps[i] = true; continue }
                if landuse.contains(where: { area in
                    guard ["pool", "pitch", "parking", "fuel", "terrace"].contains(area.kind), let ring = area.rings.first else { return false }
                    return DioramaPolygon.contains(ring, mid) || DioramaPolygon.contains(ring, a)
                        || zip(ring, ring.dropFirst() + [ring[0]]).contains { DioramaPolygon.segmentsIntersect(a, b, $0.0, $0.1) }
                }) { gaps[i] = true; continue }
                if neighbours.contains(where: { buildings[$0].box.expanded(by: 0.9).contains(mid) || buildings[$0].box.expanded(by: 0.9).contains(a) }) {
                    gaps[i] = true
                    continue
                }
                // Never run through or alongside an earlier plot's boundary.
                for prior in placed {
                    if DioramaPolygon.contains(prior.ring, mid) || DioramaPolygon.contains(prior.ring, a) {
                        gaps[i] = true
                        break
                    }
                    if prior.pieces.contains(where: { DioramaPolygon.distanceToSegment(mid, $0.0, $0.1) < 1.1 || DioramaPolygon.segmentsIntersect(a, b, $0.0, $0.1) }) {
                        gaps[i] = true
                        break
                    }
                }
            }
            let standing = gaps.filter { !$0 }.count
            guard standing >= n * 2 / 5 else { continue }

            var gate: (DV2, DV2)? = nil
            var gateEdge = -1
            if let gateCentre {
                for i in 0..<n where !gaps[i] {
                    let mid = (points[i] + points[(i + 1) % n]) * 0.5
                    if mid.distance(to: gateCentre) < 0.05 {
                        gateEdge = i
                        gate = (mid, (points[(i + 1) % n] - points[i]).normalized)
                        break
                    }
                }
            }
            // Do not enclose a home with an inaccessible, gate-less generated boundary.
            guard gate != nil else { continue }

            let isHedge = rng.chance(config.hedgeFenceShare)
            let wallColor: DioramaSwatch = rng.chance(0.5) ? built.wallColor : rng.pick([.whitewash, .cream, .paleYellow])
            let capColor: DioramaSwatch = rng.chance(0.5) ? .capTerracotta : .capCharcoal
            let gateColor: DioramaSwatch = rng.pick([.gateGreen, .gateBlue, .metalCharcoal])
            let h = config.wallHeight, t = config.wallThickness
            var pieces: [(DV2, DV2)] = []

            for i in 0..<n where !gaps[i] {
                let a = points[i], b = points[(i + 1) % n]
                let dir = (b - a).normalized
                let out = dir.right
                pieces.append((a, b))
                if i == gateEdge {
                    let length = a.distance(to: b)
                    let half = max(min(config.gateWidth, length - 0.6), 0.2) / 2
                    let mid = (a + b) * 0.5
                    let gl = mid - dir * half, gr = mid + dir * half
                    if isHedge {
                        hedge(a, gl, out: out, into: &mesh)
                        hedge(gr, b, out: out, into: &mesh)
                    } else {
                        segment(a, gl, out: out, h: h, t: t, wallColor, capColor, into: &mesh)
                        segment(gr, b, out: out, h: h, t: t, wallColor, capColor, into: &mesh)
                    }
                    // Pillars and a flat metal gate, slightly recessed.
                    for p in [gl, gr] {
                        mesh.box(centre: p, z0: 0, axis: dir, halfLength: 0.28, halfWidth: 0.28, height: h + 0.35, isHedge ? .whitewash : wallColor, top: capColor, ao: 0.4, bevel: 0.06)
                    }
                    mesh.quad(DV3(gl, 0.1), DV3(gr, 0.1), DV3(gr, h - 0.1), DV3(gl, h - 0.1), gateColor, normal: DV3(out, 0))
                    mesh.quad(DV3(gl, 0.1), DV3(gr, 0.1), DV3(gr, h - 0.1), DV3(gl, h - 0.1), gateColor, dark: true, normal: DV3(-out, 0))
                    for k in 1...2 {
                        let z = 0.1 + (h - 0.2) * Double(k) / 3
                        mesh.quad(DV3(gl + out * 0.03, z - 0.035), DV3(gr + out * 0.03, z - 0.035), DV3(gr + out * 0.03, z + 0.035), DV3(gl + out * 0.03, z + 0.035), .trimWhite, normal: DV3(out, 0))
                    }
                    if !isHedge, rng.chance(config.guardHutChance) {
                        let hut = gr + dir * 1.5 - out * 1.3
                        if DioramaPolygon.contains(points, hut), !built.box.expanded(by: 0.5).contains(hut) {
                            mesh.box(centre: hut, z0: 0, axis: dir, halfLength: 0.9, halfWidth: 0.8, height: 2.2, .whitewash, top: .roofSlate, ao: 0.4, bevel: 0.1)
                        }
                    }
                } else if isHedge {
                    hedge(a, b, out: out, into: &mesh)
                } else {
                    segment(a, b, out: out, h: h, t: t, wallColor, capColor, into: &mesh)
                }
            }
            placed.append(Placed(ring: points, pieces: pieces))
            compounds.append(DioramaCompound(building: built, ring: points, gaps: gaps, gate: gate, isHedge: isHedge))
        }
        return compounds
    }

    private func segment(_ a: DV2, _ b: DV2, out: DV2, h: Double, t: Double, _ wall: DioramaSwatch, _ cap: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard a.distance(to: b) > 0.2 else { return }
        let ao = a + out * (t / 2), bo = b + out * (t / 2)
        let ai = a - out * (t / 2), bi = b - out * (t / 2)
        mesh.wall(ao, bo, z0: -0.4, z1: h, wall, ao: 0.4)
        mesh.wall(bi, ai, z0: -0.4, z1: h, wall, ao: 0.4)
        let c = config.capThickness
        let ac = a + out * (t / 2 + 0.05), bc = b + out * (t / 2 + 0.05)
        let aci = a - out * (t / 2 + 0.05), bci = b - out * (t / 2 + 0.05)
        mesh.wall(ac, bc, z0: h, z1: h + c, cap)
        mesh.wall(bci, aci, z0: h, z1: h + c, cap)
        mesh.quad(DV3(ac, h + c), DV3(bc, h + c), DV3(bci, h + c), DV3(aci, h + c), cap, normal: .up)
    }

    /// Clipped box hedge along a boundary piece, with a slightly uneven top.
    private func hedge(_ a: DV2, _ b: DV2, out: DV2, into mesh: inout DioramaMesh) {
        let length = a.distance(to: b)
        guard length > 0.3 else { return }
        let dir = (b - a).normalized
        let c = (a + b) * 0.5
        let h = 1.25 + 0.1 * Double(Int(abs(c.x + c.y)) % 3)
        mesh.box(centre: c, z0: 0, axis: dir, halfLength: length / 2 + 0.03, halfWidth: 0.45, height: h, .hedge, top: .leafLight, ao: 0.35, bevel: 0.16)
    }
}

extension DioramaOrientedRect {
    /// Axis-aligned bounds of the rectangle.
    nonisolated var bounds: DioramaRect { DioramaRect.bounding(corners) }
}
