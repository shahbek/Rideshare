import Foundation
import simd

/// Read-time estate architecture: grand residences dressed in the style their plan suggests, and the
/// concrete compound walls that surround almost every Dar home and apartment block.
///
/// Mansions (large two/three-storey residences in gardens) get one of three period vocabularies:
/// - `neoclassical` (Greek Revival, the White House type): white walls, a pedimented portico of
///   full-height columns on a stepped podium, a bold entablature/cornice and a balustraded roof.
/// - `georgian` (British colonial): hipped clay-tile roof with deep eaves over a full-width
///   colonnaded verandah, cornice band.
/// - `french`: steep slate mansard with dormers, limestone walls, rusticated quoins and a cornice.
///
/// Compound walls are laid around each home on its own dominant axes, shrunk away from neighbours and
/// roads, merged with walls that already exist, and gated on the side facing the nearest road. Homes
/// in dense unplanned blocks have no room for a plot and stay unwalled, as do forecourt/business lots.
nonisolated enum DioramaEstate {
    nonisolated enum Style: Sendable { case neoclassical, georgian, french }

    /// A researched residence pinned to a style and front.
    nonisolated struct Site: Sendable {
        let centre: DV2
        let radius: Double
        let style: Style
        /// Unit direction the principal facade faces, if known.
        let front: DV2?
        let columns: Int
    }

    /// Geographic records (longitude, latitude).
    private static let records: [(lon: Double, lat: Double, style: Style, front: DV2?, columns: Int)] = [
        // Toure Drive residence beside the Embassy of the Islamic Republic of Iran (OSM way 767416048,
        // ~2,830 m² footprint, tagged under construction). Greek Revival, White House-like porticoed
        // front toward Toure Drive and the sea (east).
        (39.28640, -6.78180, .neoclassical, DV2(1, 0), 8)
    ]

    static func sites(projection: DioramaProjection) -> [Site] {
        records.map { Site(centre: projection.local(longitude: $0.lon, latitude: $0.lat), radius: 30, style: $0.style, front: $0.front, columns: $0.columns) }
    }

    /// Ground and painted-material queries supplied by the resident tile.
    nonisolated struct Context {
        /// Painted ground material code (0 plain, 1 grass, 2 sand, 3 asphalt, 4 paving, 5 mown, 6 dirt, 7 clay).
        let material: (DV2) -> Int?
        /// Terrain height under a point.
        let ground: (DV2) -> Double?
        let sites: [Site]
        /// Sea/lagoon level; walls never stand at or below it.
        let waterHeight: Double
    }

    /// A piece of geometry and an optional RGB override for every vertex (wall paint).
    typealias Part = (mesh: DioramaMesh, color: SIMD3<Float>?)

    // MARK: - Fronts

    /// The facade edge facing the nearest road (or the site's researched front).
    static func front(of wall: [DV2], context: Context, site: Site?) -> (a: DV2, b: DV2, out: DV2)? {
        let n = wall.count
        var best: (a: DV2, b: DV2, out: DV2)?
        var bestScore = Double.greatestFiniteMagnitude
        for i in 0..<n {
            let a = wall[i], b = wall[(i + 1) % n]
            let length = a.distance(to: b)
            guard length >= 5 else { continue }
            let out = (b - a).normalized.right
            var score: Double
            if let facing = site?.front {
                score = -out.dot(facing) * 100 - length
            } else {
                let mid = (a + b) * 0.5
                var distance = 60.0
                for step in 1...20 {
                    let d = Double(step) * 2
                    if context.material(mid + out * d) == 3 { distance = d; break }
                }
                score = distance - length * 0.15
            }
            if score < bestScore { bestScore = score; best = (a, b, out) }
        }
        return best
    }

    // MARK: - Mansions

    static func style(for site: Site?, area: Double, wings: Int, seed: Double) -> Style {
        if let site { return site.style }
        if area > 1_400 { return .neoclassical }
        if wings >= 3 { return seed < 0.5 ? .neoclassical : .georgian }
        return seed < 0.4 ? .neoclassical : (seed < 0.72 ? .georgian : .french)
    }

    static func wallPaint(_ style: Style, current: SIMD3<Float>?) -> SIMD3<Float> {
        switch style {
        case .neoclassical: return SIMD3(0.96, 0.95, 0.92)
        case .french: return SIMD3(0.93, 0.88, 0.78)
        case .georgian:
            if let c = current, min(c.x, c.y, c.z) > 0.78 { return c }
            return SIMD3(0.95, 0.91, 0.82)
        }
    }

    /// Dresses a mansion: cornice, portico/verandah, balustrade, quoins and dormers. Roofs come from
    /// `DioramaArchitectRoof` in the caller; `eave`/`curb` describe a mansard when one was built.
    static func dress(style: Style, wall: [DV2], zDeck: Double, ground: Double, front: (a: DV2, b: DV2, out: DV2)?,
                      columns: Int, plan: DioramaArchitectRoof.Plan?, flatRoof: Bool, mansard: (eave: Double, curb: Double)?,
                      context: Context, into mesh: inout DioramaMesh) {
        // Entablature and cornice around the whole building at the wall head.
        cornice(wall, z: zDeck, depth: style == .georgian ? 0.22 : 0.38, height: style == .georgian ? 0.32 : 0.6, into: &mesh)
        if flatRoof { balustrade(wall, z: zDeck, into: &mesh) }
        if let front {
            let g = context.ground(front.a * 0.5 + front.b * 0.5 + front.out * 3) ?? ground
            switch style {
            case .neoclassical:
                portico(front, z: zDeck, ground: g, columns: columns, into: &mesh)
            case .georgian:
                verandah(front, z: zDeck, ground: g, into: &mesh)
            case .french:
                portico(front, z: min(zDeck, g + 4.2), ground: g, columns: 2, into: &mesh)
            }
        }
        if style != .georgian { quoins(wall, z0: ground, z1: zDeck - (style == .neoclassical ? 0.6 : 0.32), into: &mesh) }
        if style == .french, let plan, let mansard { dormers(plan: plan, eave: mansard.eave, curb: mansard.curb, into: &mesh) }
    }

    /// Projecting entablature: frieze band, crown moulding and soffit.
    private static func cornice(_ ring: [DV2], z: Double, depth: Double, height: Double, into mesh: inout DioramaMesh) {
        guard let outer = DioramaPolygon.offset(ring, by: depth), outer.count == ring.count,
              let frieze = DioramaPolygon.offset(ring, by: 0.06), frieze.count == ring.count else { return }
        let n = ring.count
        for i in 0..<n {
            let j = (i + 1) % n
            let out = DV3((ring[j] - ring[i]).normalized.right, 0)
            // Frieze, flush-proud of the wall.
            mesh.quad(DV3(frieze[i], z - height), DV3(frieze[j], z - height), DV3(frieze[j], z - height * 0.4), DV3(frieze[i], z - height * 0.4), .trimWhite, normal: out)
            // Crown: soffit, fascia and top.
            mesh.quad(DV3(frieze[i], z - height * 0.4), DV3(outer[i], z - height * 0.4), DV3(outer[j], z - height * 0.4), DV3(frieze[j], z - height * 0.4), .trimWhite, dark: true, normal: DV3(0, 0, -1))
            mesh.quad(DV3(outer[i], z - height * 0.4), DV3(outer[j], z - height * 0.4), DV3(outer[j], z + 0.02), DV3(outer[i], z + 0.02), .trimWhite, normal: out)
            mesh.quad(DV3(ring[i], z + 0.02), DV3(ring[j], z + 0.02), DV3(outer[j], z + 0.02), DV3(outer[i], z + 0.02), .trimWhite, normal: DV3.up)
        }
    }

    /// Classical balustrade on the roof edge: plinth, balusters, pedestals and handrail.
    private static func balustrade(_ ring: [DV2], z: Double, into mesh: inout DioramaMesh) {
        guard let line = DioramaPolygon.offset(ring, by: -0.18), line.count == ring.count else { return }
        let n = line.count
        let base = z + 0.02, railLow = base + 0.18, railHigh = base + 0.92, top = base + 1.04
        for i in 0..<n {
            let a = line[i], b = line[(i + 1) % n]
            let length = a.distance(to: b)
            guard length > 0.05 else { continue }
            let dir = (b - a).normalized, out = dir.right
            for (z0, z1) in [(base, railLow), (railHigh, top)] {
                let ao = a + out * 0.13, bo = b + out * 0.13, ai = a - out * 0.13, bi = b - out * 0.13
                mesh.quad(DV3(ao, z0), DV3(bo, z0), DV3(bo, z1), DV3(ao, z1), .trimWhite, normal: DV3(out, 0))
                mesh.quad(DV3(bi, z0), DV3(ai, z0), DV3(ai, z1), DV3(bi, z1), .trimWhite, normal: DV3(out * -1, 0))
                mesh.quad(DV3(ao, z1), DV3(bo, z1), DV3(bi, z1), DV3(ai, z1), .trimWhite, normal: DV3.up)
            }
            guard length > 0.8 else { continue }
            let count = Int(length / 0.36)
            for k in 0..<count {
                let c = a + dir * (length * (Double(k) + 0.5) / Double(count))
                if k % 10 == 5 {
                    mesh.box(centre: c, z0: base, axis: dir, halfLength: 0.2, halfWidth: 0.2, height: top - base + 0.06, .trimWhite)
                    continue
                }
                let l = c - dir * 0.055, r = c + dir * 0.055
                mesh.quad(DV3(l + out * 0.05, railLow), DV3(r + out * 0.05, railLow), DV3(r + out * 0.05, railHigh), DV3(l + out * 0.05, railHigh), .trimWhite, normal: DV3(out, 0))
                mesh.quad(DV3(r - out * 0.05, railLow), DV3(l - out * 0.05, railLow), DV3(l - out * 0.05, railHigh), DV3(r - out * 0.05, railHigh), .trimWhite, normal: DV3(out * -1, 0))
            }
        }
    }

    /// Pedimented portico: stepped podium, columns with bases and capitals, entablature and pediment.
    private static func portico(_ front: (a: DV2, b: DV2, out: DV2), z: Double, ground: Double, columns: Int, into mesh: inout DioramaMesh) {
        let length = front.a.distance(to: front.b)
        guard length >= 7, z - ground > 3.5 else { return }
        let dir = (front.b - front.a).normalized, out = front.out
        let c = (front.a + front.b) * 0.5
        let width = min(length * 0.6, columns >= 8 ? 21 : (columns >= 6 ? 15 : (columns <= 2 ? 4.2 : 10.5)))
        let count = columns <= 2 ? 2 : (columns >= 8 && width >= 17 ? 8 : (width >= 12 ? 6 : 4))
        let depth = columns >= 8 ? 4.4 : (count <= 2 ? 2.2 : 3.4)
        let podium = ground + 0.6
        // Podium and two broad steps.
        mesh.box(centre: c + out * (depth / 2 + 0.2), z0: ground - 0.4, axis: dir, halfLength: width / 2 + 0.7, halfWidth: depth / 2 + 0.2, height: podium - ground + 0.4, .deltaStone, top: .paving)
        for (k, h) in [0.4, 0.2].enumerated() {
            mesh.box(centre: c + out * (depth + 0.4 + 0.35 * Double(k) + 0.17), z0: ground - 0.3, axis: dir, halfLength: width / 2 + 0.4,
                     halfWidth: 0.18, height: h + 0.3, .deltaStone, top: .paving)
        }
        let entablature = 1.0
        let columnTop = z - entablature
        let radius = min(0.42, max(0.24, (columnTop - podium) / 18))
        for k in 0..<count {
            let x = -width / 2 + 0.5 + (width - 1.0) * Double(k) / Double(max(count - 1, 1))
            let p = c + dir * x + out * (depth - 0.5)
            mesh.box(centre: p, z0: podium, axis: dir, halfLength: radius + 0.12, halfWidth: radius + 0.12, height: 0.28, .trimWhite)
            mesh.cylinder(centre: p, z0: podium + 0.28, z1: columnTop - 0.3, r0: radius, r1: radius * 0.86, sides: 12, .trimWhite, cap: false)
            mesh.box(centre: p, z0: columnTop - 0.3, axis: dir, halfLength: radius + 0.16, halfWidth: radius + 0.16, height: 0.3, .trimWhite)
        }
        // Entablature from the wall to the column line.
        mesh.box(centre: c + out * (depth / 2 - 0.1), z0: columnTop, axis: dir, halfLength: width / 2 + 0.3, halfWidth: depth / 2 + 0.1, height: entablature, .trimWhite, bottom: true)
        // Pediment: tympanum, raking roof and closed back.
        let rise = (width + 0.6) * 0.16
        let l = c - dir * (width / 2 + 0.35), r = c + dir * (width / 2 + 0.35)
        let fl = l + out * (depth + 0.1), fr = r + out * (depth + 0.1), back = out * -0.3
        let zb = z + 0.02, apex = zb + rise
        mesh.triangle(DV3(fl, zb), DV3(fr, zb), DV3(c + out * (depth + 0.1), apex), .trimWhite, normal: DV3(out, 0))
        mesh.triangle(DV3(r + back, zb), DV3(l + back, zb), DV3(c + back, apex), .trimWhite, normal: DV3(out * -1, 0))
        let slopeL = DV3(dir * -rise, width / 2).normalized, slopeR = DV3(dir * rise, width / 2).normalized
        mesh.quad(DV3(l + back, zb), DV3(fl, zb), DV3(c + out * (depth + 0.1), apex), DV3(c + back, apex), .mabatiGrey, normal: slopeL)
        mesh.quad(DV3(fr, zb), DV3(r + back, zb), DV3(c + back, apex), DV3(c + out * (depth + 0.1), apex), .mabatiGrey, normal: slopeR)
        // Raking cornice lips.
        mesh.quad(DV3(fl + out * 0.12, zb - 0.06), DV3(c + out * (depth + 0.22), apex - 0.06), DV3(c + out * (depth + 0.22), apex + 0.08), DV3(fl + out * 0.12, zb + 0.08), .trimWhite, normal: DV3(out, 0))
        mesh.quad(DV3(c + out * (depth + 0.22), apex - 0.06), DV3(fr + out * 0.12, zb - 0.06), DV3(fr + out * 0.12, zb + 0.08), DV3(c + out * (depth + 0.22), apex + 0.08), .trimWhite, normal: DV3(out, 0))
        // Paired timber doors behind the colonnade.
        mesh.quad(DV3(c - dir * 1.0 + out * 0.03, podium), DV3(c + dir * 1.0 + out * 0.03, podium), DV3(c + dir * 1.0 + out * 0.03, podium + 3.0), DV3(c - dir * 1.0 + out * 0.03, podium + 3.0), .doorWood, normal: DV3(out, 0))
        mesh.quad(DV3(c - dir * 1.15 + out * 0.04, podium + 3.0), DV3(c + dir * 1.15 + out * 0.04, podium + 3.0), DV3(c + dir * 1.15 + out * 0.04, podium + 3.3), DV3(c - dir * 1.15 + out * 0.04, podium + 3.3), .trimWhite, normal: DV3(out, 0))
    }

    /// British colonial verandah: slim columns on a raised floor under a lean-to tile roof.
    private static func verandah(_ front: (a: DV2, b: DV2, out: DV2), z: Double, ground: Double, into mesh: inout DioramaMesh) {
        let length = front.a.distance(to: front.b)
        guard length >= 6 else { return }
        let dir = (front.b - front.a).normalized, out = front.out
        let a = front.a + dir * 0.5, b = front.b - dir * 0.5
        let span = length - 1.0, depth = 2.6
        let floor = ground + 0.45
        let high = min(z - 0.3, floor + 3.3), low = high - 0.45
        guard high > floor + 2.4 else { return }
        mesh.box(centre: (a + b) * 0.5 + out * (depth / 2), z0: ground - 0.3, axis: dir, halfLength: span / 2, halfWidth: depth / 2, height: floor - ground + 0.3, .deltaStone, top: .tileClay)
        let bays = max(Int((span / 2.8).rounded()), 2)
        for k in 0...bays {
            let p = a + dir * (span * Double(k) / Double(bays)) + out * (depth - 0.25)
            mesh.cylinder(centre: p, z0: floor, z1: low, r0: 0.16, r1: 0.14, sides: 10, .trimWhite, cap: false)
            mesh.box(centre: p, z0: low - 0.18, axis: dir, halfLength: 0.22, halfWidth: 0.22, height: 0.18, .trimWhite)
            if k < bays {
                // Low railing between columns.
                let q = a + dir * (span * (Double(k) + 0.5) / Double(bays)) + out * (depth - 0.25)
                mesh.box(centre: q, z0: floor + 0.85, axis: dir, halfLength: span / Double(bays) / 2 - 0.2, halfWidth: 0.05, height: 0.08, .trimWhite)
            }
        }
        // Lean-to roof from the wall down to the colonnade beam, with fascia and soffit.
        let e0 = a - dir * 0.3, e1 = b + dir * 0.3
        let reach = depth + 0.35
        let n = DV3(out * 0.45, reach).normalized
        mesh.quad(DV3(e0, high), DV3(e0 + out * reach, low - 0.05), DV3(e1 + out * reach, low - 0.05), DV3(e1, high), .roofTerracotta, normal: n)
        mesh.quad(DV3(e1, high - 0.1), DV3(e1 + out * reach, low - 0.15), DV3(e0 + out * reach, low - 0.15), DV3(e0, high - 0.1), .trimWhite, dark: true, normal: n * -1)
        mesh.quad(DV3(e0 + out * reach, low - 0.32), DV3(e1 + out * reach, low - 0.32), DV3(e1 + out * reach, low - 0.05), DV3(e0 + out * reach, low - 0.05), .trimWhite, normal: DV3(out, 0))
    }

    /// Rusticated stone quoins at the building's square corners.
    private static func quoins(_ ring: [DV2], z0: Double, z1: Double, into mesh: inout DioramaMesh) {
        let n = ring.count
        guard z1 - z0 > 2, n >= 4 else { return }
        var placed = 0
        for i in 0..<n where placed < 8 {
            let prev = ring[(i + n - 1) % n], p = ring[i], next = ring[(i + 1) % n]
            guard prev.distance(to: p) > 3, next.distance(to: p) > 3 else { continue }
            let d0 = (p - prev).normalized, d1 = (next - p).normalized
            // Convex right-angle corners only (counter-clockwise ring turns left).
            guard d0.cross(d1) > 0.9 else { continue }
            placed += 1
            let blocks = Int((z1 - z0) / 0.62)
            for k in 0..<blocks {
                let zb = z0 + 0.62 * Double(k) + 0.05
                let long = k % 2 == 0
                // Two blocks wrap the corner: one along each face, alternating long/short.
                let la = long ? 0.62 : 0.36, lb = long ? 0.36 : 0.62
                mesh.box(centre: p - d0 * (la / 2) + d0.right * 0.03, z0: zb, axis: d0, halfLength: la / 2, halfWidth: 0.07, height: 0.52, .deltaStone)
                mesh.box(centre: p + d1 * (lb / 2) + d1.right * 0.03, z0: zb, axis: d1, halfLength: lb / 2, halfWidth: 0.07, height: 0.52, .deltaStone)
            }
        }
    }

    /// French dormers on the long steep slopes of the principal wing.
    private static func dormers(plan: DioramaArchitectRoof.Plan, eave: Double, curb: Double, into mesh: inout DioramaMesh) {
        let rect = plan.wings[0]
        let alongX = rect.width >= rect.height
        let length = alongX ? rect.width : rect.height
        let count = min(Int((length - 3) / 3.4), 7)
        guard count >= 1 else { return }
        func world(_ q: DV2) -> DV2 { plan.u * q.x + plan.v * q.y }
        for side in [-1.0, 1.0] {
            let out = world(alongX ? DV2(0, side) : DV2(side, 0))
            let dir = world(alongX ? DV2(1, 0) : DV2(0, 1))
            for k in 0..<count {
                let t = (Double(k) + 0.5) / Double(count)
                let along = (alongX ? rect.minX : rect.minY) + 1.5 + (length - 3) * t
                let edge = alongX ? DV2(along, side < 0 ? rect.minY : rect.maxY) : DV2(side < 0 ? rect.minX : rect.maxX, along)
                let face = world(edge) - out * 0.15
                let z0 = eave + 0.35, z1 = eave + min(curb - 0.2, 1.9)
                mesh.box(centre: face - out * 0.45, z0: z0, axis: dir, halfLength: 0.6, halfWidth: 0.45, height: z1 - z0, .deltaStone, top: .roofSlate)
                mesh.quad(DV3(face - dir * 0.38 + out * 0.01, z0 + 0.15), DV3(face + dir * 0.38 + out * 0.01, z0 + 0.15),
                          DV3(face + dir * 0.38 + out * 0.01, z1 - 0.12), DV3(face - dir * 0.38 + out * 0.01, z1 - 0.12), .glass, normal: DV3(out, 0))
                // Small segmental pediment over each dormer.
                mesh.triangle(DV3(face - dir * 0.7, z1), DV3(face + dir * 0.7, z1), DV3(face, z1 + 0.35), .trimWhite, normal: DV3(out, 0))
            }
        }
    }

    // MARK: - Compound walls

    /// A walled-home candidate gathered by the roof pass.
    nonisolated struct Home {
        let wall: [DV2]
        let area: Double
        let height: Double
        let ground: Double
        let color: SIMD3<Float>?
        let mansion: Bool
    }

    /// 1 m occupancy: bit 1 building, bit 2 wall.
    nonisolated struct Occupancy {
        let rect: DioramaRect
        let columns: Int
        let rows: Int
        var cells: [UInt8]
        init?(rect: DioramaRect) {
            self.rect = rect
            columns = Int(ceil(rect.width)); rows = Int(ceil(rect.height))
            guard columns > 0, rows > 0, columns * rows < 3_000_000 else { return nil }
            cells = [UInt8](repeating: 0, count: columns * rows)
        }
        func at(_ p: DV2) -> UInt8? {
            let x = Int(floor(p.x - rect.minX)), y = Int(floor(p.y - rect.minY))
            guard x >= 0, y >= 0, x < columns, y < rows else { return nil }
            return cells[y * columns + x]
        }
        mutating func mark(_ lo: DV2, _ hi: DV2, _ bit: UInt8) {
            let x0 = max(0, Int(floor(lo.x - rect.minX))), x1 = min(columns - 1, Int(floor(hi.x - rect.minX)))
            let y0 = max(0, Int(floor(lo.y - rect.minY))), y1 = min(rows - 1, Int(floor(hi.y - rect.minY)))
            guard x0 <= x1, y0 <= y1, x1 - x0 < 90, y1 - y0 < 90 else { return }
            for y in y0...y1 { for x in x0...x1 { cells[y * columns + x] |= bit } }
        }
        mutating func markSegment(_ a: DV2, _ b: DV2, _ bit: UInt8) {
            let steps = max(1, Int(ceil(a.distance(to: b) / 0.5)))
            for s in 0...steps {
                let p = a + (b - a) * (Double(s) / Double(steps))
                mark(p, p, bit)
            }
        }
    }

    /// Lays compound walls; returns parts (wall paint overrides) and the number of walled homes.
    static func compoundWalls(homes: [Home], occupancy: inout Occupancy, context: Context, tileRect: DioramaRect,
                              vertexBudget: Int) -> (parts: [Part], count: Int) {
        var parts: [Part] = []
        var walled = 0
        var vertices = 0
        let inner = tileRect.expanded(by: -1.5)
        let order = homes.indices.sorted { homes[$0].area > homes[$1].area }
        for index in order {
            let home = homes[index]
            guard home.area >= 45, home.area <= 3_500, home.height <= 22 else { continue }
            let u = DioramaArchitectRoof.dominantAxis(home.wall), v = u.left
            var lo = DV2(.greatestFiniteMagnitude, .greatestFiniteMagnitude), hi = -lo
            for p in home.wall {
                let q = DV2(p.dot(u), p.dot(v))
                lo = DV2(min(lo.x, q.x), min(lo.y, q.y)); hi = DV2(max(hi.x, q.x), max(hi.y, q.y))
            }
            func world(_ x: Double, _ y: Double) -> DV2 { u * x + v * y }
            let centre = world((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
            var rng = DioramaRandom(seed: UInt64(bitPattern: Int64(floor(centre.x * 2)) &* 73_856_093 ^ Int64(floor(centre.y * 2)) &* 19_349_663), salt: 0x57_41_4C_4C)
            // Business forecourts and car parks are not compounds.
            var hard = 0, soft = 0
            for side in 0..<4 {
                for k in 0..<5 {
                    let t = (Double(k) + 0.5) / 5
                    let p: DV2
                    switch side {
                    case 0: p = world(lo.x + (hi.x - lo.x) * t, lo.y - 3)
                    case 1: p = world(hi.x + 3, lo.y + (hi.y - lo.y) * t)
                    case 2: p = world(lo.x + (hi.x - lo.x) * t, hi.y + 3)
                    default: p = world(lo.x - 3, lo.y + (hi.y - lo.y) * t)
                    }
                    switch context.material(p) {
                    case 3?, 4?: hard += 1
                    case 0?, 1?, 6?, 7?: soft += 1
                    default: break
                    }
                }
            }
            guard hard + soft > 0, Double(hard) / Double(hard + soft) < 0.6 else { continue }

            // Each side moves in from the setback until it clears neighbours, roads, sand and water.
            let setback = home.mansion ? rng.range(7.0...12.0) : rng.range(2.4...5.5)
            var offset = [Double](repeating: setback, count: 4)
            var shared = [Bool](repeating: false, count: 4)
            func corners() -> [DV2] {
                [world(lo.x - offset[3], lo.y - offset[0]), world(hi.x + offset[1], lo.y - offset[0]),
                 world(hi.x + offset[1], hi.y + offset[2]), world(lo.x - offset[3], hi.y + offset[2])]
            }
            func clear(_ p: DV2) -> Bool {
                guard inner.contains(p), let cell = occupancy.at(p), cell & 1 == 0 else { return false }
                guard let m = context.material(p), m != 3, m != 2, m != 5 else { return false }
                return true
            }
            func dry(_ p: DV2) -> Bool {
                guard let z = context.ground(p) else { return false }
                return z > context.waterHeight + 0.3
            }
            for _ in 0..<3 {
                for side in 0..<4 where !shared[side] {
                    while offset[side] >= 1.2 {
                        let c = corners()
                        let a = c[side], b = c[(side + 1) % 4]
                        let steps = max(2, Int(a.distance(to: b) / 0.7))
                        var blocked = 0, walls = 0
                        for s in 0...steps {
                            let p = a + (b - a) * (Double(s) / Double(steps))
                            if let cell = occupancy.at(p), cell & 2 != 0 { walls += 1 }
                            if !clear(p) { blocked += 1 }
                        }
                        if Double(walls) / Double(steps + 1) > 0.4 { shared[side] = true; break }
                        if Double(blocked) / Double(steps + 1) < 0.25 { break }
                        offset[side] -= 1.0
                    }
                }
            }
            let present = (0..<4).filter { !shared[$0] && offset[$0] >= 1.2 }
            guard present.count + shared.filter({ $0 }).count >= 3, !present.isEmpty else { continue }
            let ring = corners()
            // Gate on the present side nearest a road.
            var gateSide = -1, gateDistance = 26.0
            for side in present {
                let a = ring[side], b = ring[(side + 1) % 4]
                let out = (b - a).normalized.right
                let mid = (a + b) * 0.5
                for step in 1...12 where Double(step) * 2 < gateDistance {
                    if context.material(mid + out * Double(step) * 2) == 3 { gateSide = side; gateDistance = Double(step) * 2; break }
                }
            }
            // Unpaved lanes are not always painted as road: fall back to the longest present side.
            if gateSide < 0 {
                gateSide = present.max { ring[$0].distance(to: ring[($0 + 1) % 4]) < ring[$1].distance(to: ring[($1 + 1) % 4]) } ?? -1
            }
            guard gateSide >= 0, ring.allSatisfy(dry) else { continue }

            let height = home.mansion ? 2.9 : rng.range(2.2...2.7)
            let thickness = 0.2
            let paint: SIMD3<Float> = rng.chance(0.45) ? (home.color ?? SIMD3(0.94, 0.91, 0.84))
                : rng.pick([SIMD3<Float>(0.95, 0.94, 0.90), SIMD3(0.93, 0.88, 0.76), SIMD3(0.80, 0.79, 0.76), SIMD3(0.90, 0.80, 0.62)])
            let cap: DioramaSwatch = home.mansion ? .trimWhite : rng.pick([.capCharcoal, .capTerracotta, .trimWhite, .capCharcoal])
            let gateColor: DioramaSwatch = rng.pick([.metalCharcoal, .gateGreen, .gateBlue, .metalCharcoal, .frame])
            var body = DioramaMesh(), trim = DioramaMesh()
            for side in present {
                let a = ring[side], b = ring[(side + 1) % 4]
                let dir = (b - a).normalized, out = dir.right
                let length = a.distance(to: b)
                // Clear runs along the side (0.5 m samples), minus a 3.6 m gate.
                let steps = max(2, Int(length / 0.5))
                var gate: (Double, Double)?
                if side == gateSide {
                    let along = (centre - a).dot(dir)
                    let m = min(max(along, 2.6), length - 2.6)
                    if length > 6 { gate = (m - 1.8, m + 1.8) }
                }
                var runs: [(Double, Double)] = []
                var start: Double?
                for s in 0...steps {
                    let t = length * Double(s) / Double(steps)
                    let inGate = gate.map { t > $0.0 && t < $0.1 } ?? false
                    let ok = !inGate && clear(a + dir * t) && (occupancy.at(a + dir * t).map { $0 & 2 == 0 } ?? false)
                    if ok, start == nil { start = t }
                    if !ok || s == steps, let s0 = start {
                        let end = ok ? t : t - length / Double(steps)
                        if end - s0 >= 1.2 { runs.append((s0, end)) }
                        start = nil
                    }
                }
                for run in runs {
                    let pieces = max(1, Int(ceil((run.1 - run.0) / 6)))
                    for k in 0..<pieces {
                        let t0 = run.0 + (run.1 - run.0) * Double(k) / Double(pieces)
                        let t1 = run.0 + (run.1 - run.0) * Double(k + 1) / Double(pieces)
                        let p0 = a + dir * t0, p1 = a + dir * t1
                        let g0 = context.ground(p0) ?? home.ground, g1 = context.ground(p1) ?? home.ground
                        let base = min(g0, g1) - 0.25, top = max(g0, g1) + height
                        let half = thickness / 2
                        let o0 = p0 + out * half, o1 = p1 + out * half, i0 = p0 - out * half, i1 = p1 - out * half
                        body.quad(DV3(o0, base), DV3(o1, base), DV3(o1, top - 0.12), DV3(o0, top - 0.12), .whitewash, normal: DV3(out, 0))
                        body.quad(DV3(i1, base), DV3(i0, base), DV3(i0, top - 0.12), DV3(i1, top - 0.12), .whitewash, normal: DV3(out * -1, 0))
                        let c = half + 0.03
                        let co0 = p0 + out * c, co1 = p1 + out * c, ci0 = p0 - out * c, ci1 = p1 - out * c
                        trim.quad(DV3(co0, top - 0.12), DV3(co1, top - 0.12), DV3(co1, top), DV3(co0, top), cap, normal: DV3(out, 0))
                        trim.quad(DV3(ci1, top - 0.12), DV3(ci0, top - 0.12), DV3(ci0, top), DV3(ci1, top), cap, normal: DV3(out * -1, 0))
                        trim.quad(DV3(co0, top), DV3(co1, top), DV3(ci1, top), DV3(ci0, top), cap, normal: DV3.up)
                        trim.quad(DV3(co0, top - 0.12), DV3(ci0, top - 0.12), DV3(ci1, top - 0.12), DV3(co1, top - 0.12), cap, dark: true, normal: DV3(0, 0, -1))
                        if k == 0 { body.quad(DV3(i0, base), DV3(o0, base), DV3(o0, top), DV3(i0, top), .whitewash, normal: DV3(dir * -1, 0)) }
                        if k == pieces - 1 { body.quad(DV3(o1, base), DV3(i1, base), DV3(i1, top), DV3(o1, top), .whitewash, normal: DV3(dir, 0)) }
                    }
                    occupancy.markSegment(a + dir * run.0, a + dir * run.1, 2)
                }
                if let gate {
                    let gl = a + dir * gate.0, gr = a + dir * gate.1
                    let g = context.ground((gl + gr) * 0.5) ?? home.ground
                    for p in [gl, gr] {
                        body.box(centre: p, z0: g - 0.25, axis: dir, halfLength: 0.3, halfWidth: 0.3, height: height + 0.6, .whitewash)
                        trim.box(centre: p, z0: g + height + 0.35, axis: dir, halfLength: 0.36, halfWidth: 0.36, height: 0.12, cap)
                    }
                    let l = gl + dir * 0.3, r = gr - dir * 0.3
                    trim.quad(DV3(l, g + 0.05), DV3(r, g + 0.05), DV3(r, g + height - 0.15), DV3(l, g + height - 0.15), gateColor, normal: DV3(out, 0))
                    trim.quad(DV3(r, g + 0.05), DV3(l, g + 0.05), DV3(l, g + height - 0.15), DV3(r, g + height - 0.15), gateColor, dark: true, normal: DV3(out * -1, 0))
                }
            }
            guard !body.indices.isEmpty else { continue }
            let added = body.positions.count + trim.positions.count
            guard vertices + added <= vertexBudget else { break }
            vertices += added
            parts.append((body, paint))
            parts.append((trim, nil))
            walled += 1
        }
        return (parts, walled)
    }
}
