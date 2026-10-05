import Foundation

/// Kit of parts for buildings: every visible piece is designed once here and placed along footprints
/// by the generator. Dimensions are multiplied by the configured exaggeration so windows, cornices
/// and chimneys read from the map camera. Modules build at `mesh.baseZ` (the floor datum).
nonisolated struct DioramaBuildingKit {
    let config: DioramaConfig

    private var detail: Double { config.detailExaggeration }

    // MARK: Walls and corners

    /// Plain plaster wall segment with smooth normals on short radiused edges (rounded corners).
    func wall(_ ring: [DV2], edge i: Int, z0: Double, z1: Double, _ color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let a = ring[i], b = ring[(i + 1) % ring.count]
        if a.distance(to: b) < config.cornerRadius * 1.2 {
            mesh.mouldedWall(ring, edge: i, z0: z0, z1: z1, color)
        } else {
            mesh.wall(a, b, z0: z0, z1: z1, color)
        }
    }

    /// Wall segment between two arbitrary points (openings split the module grid).
    func wall(_ a: DV2, _ b: DV2, z0: Double, z1: Double, _ color: DioramaSwatch, into mesh: inout DioramaMesh) {
        mesh.wall(a, b, z0: z0, z1: z1, color)
    }

    /// Thick plinth: a chunky base band with a rounded top edge.
    func plinth(_ ring: [DV2], flags: [Bool], height: Double, _ color: DioramaSwatch, into mesh: inout DioramaMesh) {
        mesh.band(ring, flags: flags, offset: 0.12 * detail, z0: 0, z1: height, color)
    }

    /// String course between floors.
    func stringCourse(_ ring: [DV2], flags: [Bool], z: Double, into mesh: inout DioramaMesh) {
        let h = 0.16 * detail
        mesh.band(ring, flags: flags, offset: 0.10 * detail, z0: z - h, z1: z, .trimWhite)
    }

    /// Cornice: two stepped bands under the roof edge, thick enough to catch a highlight.
    func cornice(_ ring: [DV2], flags: [Bool], z: Double, into mesh: inout DioramaMesh) {
        let h = 0.45 * detail
        mesh.band(ring, flags: flags, offset: 0.14 * detail, z0: z - h, z1: z - h * 0.45, .trimWhite)
        mesh.band(ring, flags: flags, offset: 0.26 * detail, z0: z - h * 0.45, z1: z, .trimWhite)
    }

    /// Parapet with a rounded coping around a flat roof.
    func parapet(_ ring: [DV2], flags: [Bool], z: Double, into mesh: inout DioramaMesh) {
        let n = ring.count
        let thickness = 0.28 * detail, height = 0.55 * detail
        guard let inner = DioramaPolygon.offset(ring, by: -thickness), inner.count == n else { return }
        for i in 0..<n where !flags[i] {
            let j = (i + 1) % n
            mesh.wall(ring[i], ring[j], z0: z, z1: z + height, .trimWhite)
            mesh.wall(inner[j], inner[i], z0: z, z1: z + height, .trimWhite)
            // Rounded coping: a middle crown slightly higher than the two edges.
            let ma = (ring[i] + inner[i]) * 0.5, mb = (ring[j] + inner[j]) * 0.5
            let crown = z + height + 0.06 * detail
            let outN = DV3((ring[j] - ring[i]).normalized.right, 0)
            mesh.quad(DV3(ring[i], z + height), DV3(ring[j], z + height), DV3(mb, crown), DV3(ma, crown), .trimWhite, normal: (outN * 0.5 + DV3.up).normalized)
            mesh.quad(DV3(ma, crown), DV3(mb, crown), DV3(inner[j], z + height), DV3(inner[i], z + height), .trimWhite, normal: (outN * -0.5 + DV3.up).normalized)
        }
    }

    /// Soft roof edge: a wide rounded bevel curving in from the wall top to the roof deck.
    func roofEdge(_ ring: [DV2], flags: [Bool], z: Double, bevel: Double, deck: DioramaSwatch, into mesh: inout DioramaMesh) -> [DV2]? {
        let n = ring.count
        guard let inner = DioramaPolygon.offset(ring, by: -bevel), inner.count == n else { return nil }
        // A quarter-circle profile with analytic vertex normals, including the plan fillets.
        let stops = (0...6).map { Double($0) / 6 * Double.pi / 2 }
        func outward(_ index: Int) -> DV3 {
            let before = (ring[index] - ring[(index + n - 1) % n]).normalized.right
            let after = (ring[(index + 1) % n] - ring[index]).normalized.right
            return DV3((before + after).normalized, 0)
        }
        let uv = DioramaAtlas.uv(.trimWhite, dark: false)
        for i in 0..<n where !flags[i] {
            let j = (i + 1) % n
            let out = DV3((ring[j] - ring[i]).normalized.right, 0)
            for k in 0..<(stops.count - 1) {
                let a = stops[k], b = stops[k + 1]
                func vertex(_ index: Int, _ angle: Double) -> UInt32 {
                    let t = 1 - cos(angle)
                    let p = ring[index] * (1 - t) + inner[index] * t
                    return mesh.vertex(DV3(p, z + bevel * sin(angle)),
                                       (outward(index) * cos(angle) + DV3.up * sin(angle)).normalized, uv)
                }
                mesh.reserve(4)
                let v0 = vertex(i, a), v1 = vertex(j, a), v2 = vertex(j, b), v3 = vertex(i, b)
                mesh.face(v0, v1, v2, outward: out + .up)
                mesh.face(v0, v2, v3, outward: out + .up)
            }
        }
        mesh.polygon(inner, z: z + bevel, deck)
        return inner
    }

    // MARK: Openings

    /// Window unit: deep reveal, recessed dark pane (plus glow when lit), chunky frame, lintel and sill.
    func window(a: DV2, dir: DV2, out: DV2, u: Double, z0: Double, z1: Double, width: Double,
                hasGrille: Bool, lit: Bool, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        reveal(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, into: &mesh)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, depth: -0.19, .glass, sides: false)
        if lit {
            glow.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, depth: -0.18, .windowGlow, sides: false)
        }
        let frame = 0.11 * detail, projection = 0.09 * detail
        for side in [-1.0, 1.0] {
            mesh.facadeBox(a: a, dir: dir, out: out, u: u + side * (width / 2 + frame / 2), width: frame,
                           z0: z0 - frame, z1: z1 + frame, depth: projection, .frame)
        }
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + frame * 2, z0: z1, z1: z1 + frame * 1.2, depth: projection * 1.2, .frame)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: 0.085 * detail, z0: z0, z1: z1, depth: -0.10, .frame, sides: false)
        if hasGrille {
            for fraction in [-0.3, 0.3] {
                mesh.facadeBox(a: a, dir: dir, out: out, u: u + width * fraction, width: 0.05, z0: z0, z1: z1, depth: -0.035, .metalCharcoal, sides: false)
            }
            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0 + (z1 - z0) * 0.45, z1: z0 + (z1 - z0) * 0.45 + 0.05, depth: -0.03, .metalCharcoal, sides: false)
        }
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + frame * 2, z0: z0 - frame * 1.1, z1: z0, depth: projection * 1.6, .trimWhite)
    }

    /// Door unit: reveal, recessed leaf, handle; an uncovered door gets a canopy and two steps.
    func door(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, bottom: Double, top: Double,
              kind: DioramaBuildingKind, covered: Bool, into mesh: inout DioramaMesh) {
        reveal(a: a, dir: dir, out: out, u: u, width: width, z0: bottom, z1: top, into: &mesh)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: bottom, z1: top, depth: -0.19, kind == .villa ? .doorWood : .glass, sides: false)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u + width * 0.3, width: 0.05 * detail, z0: bottom + 0.75, z1: bottom + 1.02, depth: -0.16, .metalCharcoal, sides: false)
        guard !covered else { return }
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.5 * detail, z0: top + 0.1, z1: top + 0.26 * detail, depth: 0.8 * detail, .concrete)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.4, z0: 0, z1: 0.5, depth: 0.35, .courtyard)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.6, z0: 0, z1: 0.25, depth: 0.65, .courtyard)
    }

    /// Shop front: wide glazed opening with a fascia sign and a canvas awning.
    func shopFront(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, bottom: Double, top: Double, wallTop: Double,
                   sign: DioramaSwatch, awning awningColor: DioramaSwatch, into mesh: inout DioramaMesh) {
        door(a: a, dir: dir, out: out, u: u, width: width, bottom: bottom, top: top, kind: .commercial, covered: true, into: &mesh)
        let signHeight = 0.34 * detail
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: top + 0.08, z1: min(top + 0.08 + signHeight, wallTop - 0.05), depth: 0.14 * detail, sign)
        awning(a: a, dir: dir, out: out, u: u, width: width + 0.15, z: top + 0.04, color: awningColor, into: &mesh)
    }

    private func awning(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, z: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let l = a + dir * (u - width / 2), r = a + dir * (u + width / 2)
        let depth = 1.4 * detail
        let lip = z - 0.5 * detail
        let wasDoubleSided = mesh.doubleSided
        mesh.doubleSided = true
        mesh.quad(DV3(l + out * 0.1, z), DV3(r + out * 0.1, z), DV3(r + out * depth, lip), DV3(l + out * depth, lip), color)
        mesh.doubleSided = wasDoubleSided
        mesh.quad(DV3(l + out * depth, lip), DV3(r + out * depth, lip), DV3(r + out * depth, lip - 0.22 * detail), DV3(l + out * depth, lip - 0.22 * detail), .trimWhite, normal: DV3(out, 0))
    }

    /// Four inward returns connect the plaster face to a recessed pane/door.
    private func reveal(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, z0: Double, z1: Double, into mesh: inout DioramaMesh) {
        let l = a + dir * (u - width / 2), r = a + dir * (u + width / 2)
        let li = l - out * 0.2, ri = r - out * 0.2
        mesh.quad(DV3(l, z0), DV3(li, z0), DV3(li, z1), DV3(l, z1), .frame, normal: DV3(dir, 0))
        mesh.quad(DV3(ri, z0), DV3(r, z0), DV3(r, z1), DV3(ri, z1), .frame, normal: DV3(-dir, 0))
        mesh.quad(DV3(li, z0), DV3(ri, z0), DV3(r, z0), DV3(l, z0), .frame, normal: .up)
        mesh.quad(DV3(l, z1), DV3(r, z1), DV3(ri, z1), DV3(li, z1), .frame, dark: true, normal: DV3(0, 0, -1))
    }

    // MARK: Veranda and balconies

    /// Veranda bay: recessed slab, round columns, beam and (upper floors) a balustrade.
    func verandaBay(a: DV2, b: DV2, out: DV2, depth: Double, base: Double, ceiling: Double, bays: Int, railed: Bool, into mesh: inout DioramaMesh) {
        let dir = (b - a).normalized
        let length = a.distance(to: b)
        let slab = DioramaPolygon.counterClockwise([a, b, b - out * depth, a - out * depth])
        mesh.extrude(slab, z0: base - 0.18, z1: base, .concrete, top: .courtyard)
        mesh.polygon(slab, z: ceiling - 0.08, .trimWhite, dark: true, facingUp: false)
        let beam = 0.34 * detail
        mesh.box(centre: (a + b) * 0.5 - out * 0.12, z0: ceiling - beam, axis: dir, halfLength: length / 2, halfWidth: 0.16 * detail, height: beam, .trimWhite, bevel: 0.05)
        let column = 0.14 * detail
        for k in 0...bays {
            let position = k == 0 ? 0.2 : (k == bays ? length - 0.2 : length * Double(k) / Double(bays))
            let p = a + dir * position - out * 0.18
            mesh.cylinder(centre: p, z0: base, z1: ceiling - beam, r0: column, r1: column * 0.9, sides: 10, .trimWhite)
            mesh.cylinder(centre: p, z0: base, z1: base + 0.12, r0: column * 1.4, r1: column * 1.1, sides: 10, .trimWhite)
            mesh.cylinder(centre: p, z0: ceiling - beam - 0.12, z1: ceiling - beam, r0: column * 1.1, r1: column * 1.4, sides: 10, .trimWhite)
        }
        if railed { balconyRail(a: a, b: b, out: out, z: base, into: &mesh) }
    }

    /// Balcony rail: solid upstand with a rounded cap and a few balusters showing above.
    func balconyRail(a: DV2, b: DV2, out: DV2, z: Double, into mesh: inout DioramaMesh) {
        let dir = (b - a).normalized
        let span = a.distance(to: b) - 0.4
        let centre = (a + b) * 0.5 - out * 0.15
        let height = 0.85 * detail
        mesh.box(centre: centre, z0: z, axis: dir, halfLength: span / 2, halfWidth: 0.09 * detail, height: height * 0.7, .cream)
        mesh.box(centre: centre, z0: z + height * 0.7, axis: dir, halfLength: span / 2 + 0.05, halfWidth: 0.13 * detail, height: 0.09 * detail, .trimWhite, bevel: 0.03)
        for t in stride(from: -span / 2 + 0.3, through: span / 2 - 0.3, by: 0.6) {
            mesh.cylinder(centre: centre + dir * t, z0: z + height * 0.7, z1: z + height, r0: 0.03, r1: 0.03, sides: 6, .trimWhite)
        }
        mesh.box(centre: centre, z0: z + height, axis: dir, halfLength: span / 2 + 0.05, halfWidth: 0.06 * detail, height: 0.06, .trimWhite)
    }

    // MARK: Roof furniture

    /// Chunky chimney with a cap.
    func chimney(at p: DV2, axis: DV2, z0: Double, into mesh: inout DioramaMesh) {
        let w = 0.42 * detail, h = 1.3 * detail
        mesh.box(centre: p, z0: z0, axis: axis, halfLength: w, halfWidth: w * 0.8, height: h, .cream, top: .cream, bevel: 0.06)
        mesh.box(centre: p, z0: z0 + h, axis: axis, halfLength: w * 1.2, halfWidth: w, height: 0.14 * detail, .capTerracotta, bevel: 0.04)
        mesh.cylinder(centre: p, z0: z0 + h + 0.14 * detail, z1: z0 + h + 0.4 * detail, r0: 0.14 * detail, r1: 0.12 * detail, sides: 10, .capCharcoal)
    }

    /// Rooftop water tank on a low stand.
    func waterTank(at p: DV2, z0: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let radius = 0.62 * detail, height = 1.3 * detail
        mesh.box(centre: p, z0: z0, axis: DV2(1, 0), halfLength: radius * 1.1, halfWidth: radius * 1.1, height: 0.2, .trimWhite, bevel: 0.03)
        let base = DV3(p, z0 + 0.2)
        mesh.tube(from: base, to: base + DV3(0, 0, height), r0: radius, r1: radius, sides: 14, color, cap: false)
        mesh.tube(from: base + DV3(0, 0, height), to: base + DV3(0, 0, height + radius * 0.35), r0: radius, r1: radius * 0.3, sides: 14, color)
    }

    /// Stair head / lift motor room on apartment roofs.
    func roofHead(at p: DV2, axis: DV2, z0: Double, into mesh: inout DioramaMesh) {
        mesh.box(centre: p, z0: z0, axis: axis, halfLength: 1.4, halfWidth: 1.1, height: 2.3, .trimWhite, top: .roofConcrete, bevel: config.bevel)
    }
}
