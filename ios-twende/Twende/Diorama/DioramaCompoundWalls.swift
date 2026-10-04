import Foundation

/// A compound (plot) around a villa, so later passes know where grass, bougainvillea and trees go.
nonisolated struct DioramaCompound: Sendable {
    let building: DioramaBuilt
    /// Counter-clockwise wall ring; `gaps[i]` marks edges removed by roads/neighbours.
    let ring: [DV2]
    let gaps: [Bool]
    /// Centre of the gate on the edge facing the nearest road.
    let gate: (point: DV2, direction: DV2)?
}

/// Painted plaster walls 5–10 m outside each villa, clipped so they never cross roads or neighbours,
/// with a cap, a metal gate facing the nearest road and sometimes a guard hut.
nonisolated struct DioramaCompoundWallGenerator {
    let config: DioramaConfig
    let roads: DioramaRoadIndex
    let buildings: [DioramaBuilt]
    let tileRect: DioramaRect
    let terrain: DioramaTerrain
    private let grid: DioramaGrid

    init(config: DioramaConfig, roads: DioramaRoadIndex, buildings: [DioramaBuilt], tileRect: DioramaRect, terrain: DioramaTerrain) {
        self.config = config
        self.roads = roads
        self.buildings = buildings
        self.tileRect = tileRect
        self.terrain = terrain
        var grid = DioramaGrid(cell: 40)
        for (i, b) in buildings.enumerated() {
            grid.insert(i, rect: DioramaRect.bounding(b.feature.ring))
        }
        self.grid = grid
    }

    func generate(into mesh: inout DioramaMesh) -> [DioramaCompound] {
        var compounds: [DioramaCompound] = []
        for (index, built) in buildings.enumerated() where built.kind == .villa {
            guard built.feature.clipped.allSatisfy({ !$0 }) else { continue }
            // Walls share the house's ground level; a plinth below z = 0 covers any slope under them.
            mesh.baseZ = terrain.height(built.feature.centroid)
            defer { mesh.baseZ = 0 }
            var rng = DioramaRandom(seed: built.feature.id, salt: 7)
            let offset = rng.range(config.wallOffset)
            // Walls follow the house's bounding rectangle: compounds in Masaki are rectangular plots.
            let plot = built.box.expanded(by: offset)
            var ring = plot.corners
            // Pull corners back inside the tile so no wall runs along a tile edge.
            let inner = tileRect.expanded(by: -1.5)
            ring = ring.map { DV2(min(max($0.x, inner.minX), inner.maxX), min(max($0.y, inner.minY), inner.maxY)) }
            guard DioramaPolygon.area(ring) > built.feature.area * 1.2 else { continue }

            // Subdivide each side so individual pieces can be dropped where they would cross something.
            var points: [DV2] = []
            for i in 0..<4 {
                let a = ring[i], b = ring[(i + 1) % 4]
                let steps = max(Int(a.distance(to: b) / 4), 1)
                for s in 0..<steps { points.append(a + (b - a) * (Double(s) / Double(steps))) }
            }
            let n = points.count
            var gaps = [Bool](repeating: false, count: n)
            let neighbours = grid.query(DioramaRect.bounding(ring).expanded(by: 2)).subtracting([index])
            for i in 0..<n {
                let a = points[i], b = points[(i + 1) % n]
                if roads.blocks(a, b, clearance: 1.2) { gaps[i] = true; continue }
                for j in neighbours {
                    let other = buildings[j]
                    if other.box.expanded(by: 0.8).contains((a + b) * 0.5) || other.box.expanded(by: 0.8).contains(a) {
                        gaps[i] = true
                        break
                    }
                    if other.kind == .villa, other.feature.id < built.feature.id, other.box.expanded(by: config.wallOffset.lowerBound).contains((a + b) * 0.5) {
                        // Let the earlier neighbour own the shared boundary.
                        gaps[i] = true
                        break
                    }
                }
            }
            let standing = gaps.filter { !$0 }.count
            guard standing >= n / 2 else { continue }

            // Gate: the standing edge whose midpoint is closest to a road.
            var gate: (DV2, DV2)? = nil
            var gateEdge = -1
            var bestDistance = Double.infinity
            for i in 0..<n where !gaps[i] {
                let mid = (points[i] + points[(i + 1) % n]) * 0.5
                if let road = roads.nearest(to: mid, within: 25), road.distance < bestDistance {
                    bestDistance = road.distance
                    gateEdge = i
                    gate = (mid, (points[(i + 1) % n] - points[i]).normalized)
                }
            }

            let wallColor: DioramaSwatch = rng.chance(0.5) ? built.wallColor : rng.pick([.whitewash, .cream, .ochre])
            let capColor: DioramaSwatch = rng.chance(0.5) ? .capTerracotta : .capCharcoal
            let gateColor: DioramaSwatch = rng.pick([.gateGreen, .gateBlue, .metalCharcoal])
            let h = config.wallHeight, t = config.wallThickness

            for i in 0..<n where !gaps[i] {
                let a = points[i], b = points[(i + 1) % n]
                let dir = (b - a).normalized
                let out = dir.right
                if i == gateEdge {
                    let length = a.distance(to: b)
                    let half = max(min(config.gateWidth, length - 0.8), 0.2) / 2
                    let mid = (a + b) * 0.5
                    let gl = mid - dir * half, gr = mid + dir * half
                    segment(a, gl, out: out, h: h, t: t, wallColor, capColor, into: &mesh)
                    segment(gr, b, out: out, h: h, t: t, wallColor, capColor, into: &mesh)
                    // Pillars and a flat metal gate, slightly recessed.
                    for p in [gl, gr] {
                        mesh.box(centre: p, z0: 0, axis: dir, halfLength: 0.3, halfWidth: 0.3, height: h + 0.4, wallColor, top: capColor, ao: 0.4, bevel: 0.06)
                    }
                    mesh.quad(DV3(gl, 0.1), DV3(gr, 0.1), DV3(gr, h - 0.15), DV3(gl, h - 0.15), gateColor, normal: DV3(out, 0))
                    mesh.quad(DV3(gl, 0.1), DV3(gr, 0.1), DV3(gr, h - 0.15), DV3(gl, h - 0.15), gateColor, dark: true, normal: DV3(-out, 0))
                    for k in 1...3 {
                        let z = 0.1 + (h - 0.25) * Double(k) / 4
                        mesh.quad(DV3(gl + out * 0.03, z - 0.04), DV3(gr + out * 0.03, z - 0.04), DV3(gr + out * 0.03, z + 0.04), DV3(gl + out * 0.03, z + 0.04), .trimWhite, normal: DV3(out, 0))
                    }
                    if rng.chance(config.guardHutChance) {
                        let hut = gr + dir * 1.6 - out * 1.4
                        if DioramaPolygon.contains(points, hut), !built.box.expanded(by: 0.5).contains(hut) {
                            mesh.box(centre: hut, z0: 0, axis: dir, halfLength: 1.0, halfWidth: 0.9, height: 2.3, .whitewash, top: .roofSlate, ao: 0.4, bevel: 0.1)
                            mesh.facadeBox(a: hut - dir * 1.0 - out * (-0.9), dir: dir, out: out, u: 1.0, width: 0.6, z0: 1.1, z1: 1.7, depth: 0.05, .glass, sides: false)
                        }
                    }
                } else {
                    segment(a, b, out: out, h: h, t: t, wallColor, capColor, into: &mesh)
                }
            }
            compounds.append(DioramaCompound(building: built, ring: points, gaps: gaps, gate: gate))
        }
        return compounds
    }

    private func segment(_ a: DV2, _ b: DV2, out: DV2, h: Double, t: Double, _ wall: DioramaSwatch, _ cap: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard a.distance(to: b) > 0.2 else { return }
        let ao = a + out * (t / 2), bo = b + out * (t / 2)
        let ai = a - out * (t / 2), bi = b - out * (t / 2)
        mesh.wall(ao, bo, z0: -1.2, z1: 0, wall, ao: 0)
        mesh.wall(bi, ai, z0: -1.2, z1: 0, wall, ao: 0)
        mesh.wall(ao, bo, z0: 0, z1: h, wall, ao: 0.45)
        mesh.wall(bi, ai, z0: 0, z1: h, wall, ao: 0.45)
        let c = config.capThickness
        let ac = a + out * (t / 2 + 0.06), bc = b + out * (t / 2 + 0.06)
        let aci = a - out * (t / 2 + 0.06), bci = b - out * (t / 2 + 0.06)
        mesh.wall(ac, bc, z0: h, z1: h + c, cap)
        mesh.wall(bci, aci, z0: h, z1: h + c, cap)
        mesh.quad(DV3(ac, h + c), DV3(bc, h + c), DV3(bci, h + c), DV3(aci, h + c), cap, normal: .up)
    }
}
