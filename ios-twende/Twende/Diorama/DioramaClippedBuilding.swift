import Foundation

/// Courtyard and ownership-cut buildings use the same facade kit as ordinary buildings.
/// Boundary loops, not triangulation pieces, own walls and trim; roof caps retain every hole.
nonisolated enum DioramaClippedBuilding {
    static func build(_ f: DioramaBuildingFeature, terrain: DioramaTerrain, config: DioramaConfig,
                      mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: Bool, includesWindows: Bool = true) -> DioramaBuilt {
        let ground = terrain.buildingHeight(f)
        let height = max(2.8, f.height ?? 3.2)
        let floors = max(1, Int((height / config.floorHeight).rounded()))
        let storey = height / Double(floors)
        let kit = DioramaBuildingKit(config: config)
        var rng = DioramaRandom(seed: f.id, salt: 2)
        let color = config.buildingOverrides[f.id]?.wallColor ?? rng.pick(floors > 2 ? config.apartmentWallColors : config.wallColors)
        let savedBase = mesh.baseZ, savedGlow = glow.baseZ
        let savedTint = mesh.tint, savedHeight = mesh.recordsHeight
        mesh.baseZ = ground; glow.baseZ = ground; mesh.recordsHeight = true
        let shift = Float(rng.range(-1...1)) * config.hueShift
        mesh.tint = SIMD3(1 + shift, 1 + shift * 0.35, 1 - shift)
        defer { mesh.baseZ = savedBase; glow.baseZ = savedGlow; mesh.tint = savedTint; mesh.recordsHeight = savedHeight }

        let original = DioramaStreetSurface(f.occupiedPieces)
        let rawLoops = loops(original.boundary())
        // Only shave genuine exterior corners; never expand into another owner's cutout.
        let exclusions = DioramaGroundCutouts(polygons: f.occupiedPieces).subtract(from: f.ring)
        let rounded = DioramaPolygon.rounded(f.ring, flags: f.clipped, radius: config.cornerRadius, segments: 6).points
        let pieces = DioramaGroundCutouts(polygons: exclusions).subtract(from: rounded)
        let surface = DioramaStreetSurface(pieces)
        let boundaries = loops(surface.boundary())
        let rings = boundaries.isEmpty ? rawLoops : boundaries
        for piece in pieces { mesh.polygon(piece, z: height, .roofConcrete) }
        let perimeter = rings.reduce(0.0) { total, ring in
            total + ring.indices.reduce(0.0) { $0 + ring[$1].distance(to: ring[($1 + 1) % ring.count]) }
        }
        let spacing = max(3.4, perimeter * Double(floors) / Double(max(config.maxWindowsPerBuilding * 3, 1)))
        var entrance = f.centroid, entranceOut = DV2(1, 0), entranceLength = 0.0
        for ring in rings {
            let n = ring.count
            let inward: [DV2]?
            if DioramaPolygon.signedArea(ring) > 0 {
                inward = DioramaPolygon.offset(ring, by: -0.32)
            } else {
                inward = DioramaPolygon.offset(Array(ring.reversed()), by: 0.32).map { Array($0.reversed()) }
            }
            for i in ring.indices {
                let j = (i + 1) % n, a = ring[i], b = ring[j]
                let length = a.distance(to: b), dir = (b - a).normalized, out = dir.right
                let midpoint = (a + b) * 0.5
                let isTileCut = f.ring.indices.contains { edge in
                    (f.clipped.indices.contains(edge) && f.clipped[edge])
                        && DioramaPolygon.distanceToSegment(midpoint, f.ring[edge], f.ring[(edge + 1) % f.ring.count]) < 0.15
                }
                let isSource = !isTileCut && DioramaPolygon.distanceToRing(f.ring, midpoint) < 0.15
                mesh.quad(DV3(a, terrain.height(a) - ground - 0.25), DV3(b, terrain.height(b) - ground - 0.25),
                          DV3(b, 0.35), DV3(a, 0.35), color, normal: DV3(out, 0))
                if isSource && length > entranceLength { entrance = midpoint; entranceOut = out; entranceLength = length }
                if !includesWindows || !isSource || length < 3 {
                    mesh.mouldedWall(ring, edge: i, z0: 0.35, z1: height, color)
                } else {
                    let columns = max(1, Int(length / spacing)), pitch = length / Double(columns)
                    let width = min(1.6 * config.detailExaggeration, pitch - 0.85)
                    for floor in 0..<floors {
                        let base = Double(floor) * storey, bottom = max(0.35, base), top = base + storey
                        let lower = base + 0.95, upper = top - 0.65
                        for column in 0..<columns {
                            let u = pitch * (Double(column) + 0.5)
                            let left = a + dir * (u - width / 2), right = a + dir * (u + width / 2)
                            let cellA = a + dir * (pitch * Double(column)), cellB = cellA + dir * pitch
                            guard width > 0.5, upper > lower else {
                                kit.wall(cellA, cellB, z0: bottom, z1: top, color, into: &mesh); continue
                            }
                            kit.wall(cellA, left, z0: bottom, z1: top, color, into: &mesh)
                            kit.wall(right, cellB, z0: bottom, z1: top, color, into: &mesh)
                            kit.wall(left, right, z0: bottom, z1: lower, color, into: &mesh)
                            kit.wall(left, right, z0: upper, z1: top, color, into: &mesh)
                            kit.window(a: a, dir: dir, out: out, u: u, z0: lower, z1: upper, width: width,
                                       hasGrille: floors < 3, lit: lights && rng.chance(config.litWindowRatio), into: &mesh, glow: &glow)
                        }
                    }
                }
                // A continuous inward parapet with a rounded crown; no lid across the courtyard.
                if !isTileCut, let inward, inward.count == n,
                   surface.contains((inward[i] + inward[j]) * 0.5) {
                    let innerA = inward[i], innerB = inward[j]
                    let crown = height + 0.48
                    mesh.mouldedWall(ring, edge: i, z0: height, z1: crown, .trimWhite)
                    mesh.wall(innerB, innerA, z0: height, z1: crown, .trimWhite)
                    let uv = DioramaAtlas.uv(.trimWhite, dark: false)
                    for step in 0..<6 {
                        let t0 = Double(step) / 6, t1 = Double(step + 1) / 6
                        func vertex(_ outer: DV2, _ inner: DV2, _ t: Double) -> UInt32 {
                            let angle = t * Double.pi
                            let point = outer * (1 - t) + inner * t
                            return mesh.vertex(DV3(point, crown + sin(angle) * 0.14),
                                               (DV3(out, 0) * cos(angle) + DV3.up * sin(angle)).normalized, uv)
                        }
                        let v0 = vertex(a, innerA, t0), v1 = vertex(b, innerB, t0)
                        let v2 = vertex(b, innerB, t1), v3 = vertex(a, innerA, t1)
                        mesh.face(v0, v1, v2, outward: .up); mesh.face(v0, v2, v3, outward: .up)
                    }
                }
            }
            // Joined string courses on genuine exterior loops, excluding ownership-cut facades.
            if DioramaPolygon.signedArea(ring) > 0 {
                let flags = ring.indices.map { i in
                    let midpoint = (ring[i] + ring[(i + 1) % n]) * 0.5
                    return DioramaPolygon.distanceToRing(f.ring, midpoint) > config.cornerRadius || f.ring.indices.contains { edge in
                        (f.clipped.indices.contains(edge) && f.clipped[edge])
                            && DioramaPolygon.distanceToSegment(midpoint, f.ring[edge], f.ring[(edge + 1) % f.ring.count]) < 0.15
                    }
                }
                for floor in 1..<floors { kit.stringCourse(ring, flags: flags, z: Double(floor) * storey, into: &mesh) }
            }
        }
        return DioramaBuilt(feature: f, kind: floors > 2 ? .apartments : .villa, floors: floors, height: height,
            box: DioramaPolygon.minimumAreaRectangle(f.ring), flatRoof: true, wallColor: color,
            entrance: entrance, entranceOut: entranceOut)
    }

    /// Join exact union edges and discard collinear subdivision vertices before placing modules.
    private static func loops(_ edges: [(a: DV2, b: DV2)]) -> [[DV2]] {
        func key(_ p: DV2) -> String { "\(Int64((p.x * 10000).rounded())):\(Int64((p.y * 10000).rounded()))" }
        var outgoing: [String: [Int]] = [:]
        for i in edges.indices { outgoing[key(edges[i].a), default: []].append(i) }
        var used: Set<Int> = [], result: [[DV2]] = []
        for start in edges.indices where !used.contains(start) {
            var ring: [DV2] = [], current = start, closed = false
            while used.insert(current).inserted {
                let edge = edges[current]; ring.append(edge.a)
                if key(edge.b) == key(edges[start].a) { closed = true; break }
                guard let next = outgoing[key(edge.b)]?.first(where: { !used.contains($0) }) else { break }
                current = next
            }
            guard closed, ring.count >= 3 else { continue }
            // Unlike source cleanup, this must not shave off short fillet vertices: the roof
            // has already been triangulated against precisely this boundary.
            var changed = true
            while changed && ring.count > 3 {
                changed = false
                for i in ring.indices {
                    let before = ring[i] - ring[(i + ring.count - 1) % ring.count]
                    let after = ring[(i + 1) % ring.count] - ring[i]
                    if before.length < 1e-7 || (abs(before.normalized.cross(after.normalized)) < 1e-9 && before.dot(after) > 0) {
                        ring.remove(at: i); changed = true; break
                    }
                }
            }
            result.append(ring)
        }
        return result
    }
}
