import Foundation
import simd

/// Building kit after the project's `stylized-map-renderer` skill (Fenn / Zenly look), sized to the
/// harbour's triangle budget.
///
/// - Footprints are repaired first (skill §1): no near-duplicate, collinear or spike vertices, no
///   edge under 0.3 m, near-right angles snapped square. Every removed vertex is a wall quad, a
///   column of trim quads and a roof triangle fewer.
/// - Square corners are rounded by the facade shader's normal bend (the skill's shader bevel, zero
///   triangles). Only large design radii (curtain-wall and ribbon towers) get a geometric fillet
///   (skill §2, LOD1 form: one segment, two from 1.5 m) whose vertex normals are the neighbouring
///   walls' normals (the tangent rule), so it shades as a quarter cylinder.
/// - Walls stay one shader-facade quad per edge; windows, doors and slab lines are drawn by the
///   fragment shader (the skill's far-LOD facade, used everywhere so windows cost no triangles).
/// - Trims are 2D profiles swept along the outline with smooth normals (skill §4). Hard corners
///   split their normals instead of adding support loops, so a sweep costs 2 triangles per profile
///   segment per outline point.
/// - Flat decks carry a baked occlusion ring along the parapet (skill §5, §8), written into the
///   vertex colour.
/// - Roof props are fixed-size library meshes placed as GPU instances (skill §7).
nonisolated enum DioramaFennKit {
    // MARK: Footprint repair

    /// Repaired copy of a counter-clockwise footprint, or the footprint itself when repair would
    /// move a corner more than 0.45 m, change the area by more than 6 % or break the outline.
    static func repair(_ input: [DV2]) -> [DV2] {
        let original = DioramaPolygon.counterClockwise(input)
        guard original.count >= 4 else { return original }
        let area = DioramaPolygon.area(original)
        guard area > 2 else { return original }
        var ring = simplify(original)
        if let square = orthogonalize(ring) { ring = simplify(square) }
        guard ring.count >= 3, DioramaPolygon.signedArea(ring) > 0, DioramaPolygon.isSimple(ring),
              abs(DioramaPolygon.area(ring) - area) <= area * 0.06 else { return original }
        return ring
    }

    /// Removes duplicate, collinear (within 8 cm of the chord) and spike vertices and merges edges
    /// shorter than 0.3 m into their midpoint. Curved outlines keep their curve within 8 cm.
    private static func simplify(_ input: [DV2]) -> [DV2] {
        var ring = input
        var changed = true
        while changed && ring.count > 3 {
            changed = false
            let n = ring.count
            for i in 0..<n {
                let prev = ring[(i + n - 1) % n], cur = ring[i], next = ring[(i + 1) % n]
                let incoming = cur - prev, outgoing = next - cur
                if incoming.length < 0.05 { ring.remove(at: i); changed = true; break }
                let turn = abs(atan2(incoming.cross(outgoing), incoming.dot(outgoing)))
                if turn < 1 * .pi / 180 || (turn < 12 * .pi / 180 && DioramaPolygon.distanceToSegment(cur, prev, next) < 0.08) {
                    ring.remove(at: i); changed = true; break
                }
                // A spike doubles back on itself: drop its tip.
                if turn > 165 * .pi / 180 { ring.remove(at: i); changed = true; break }
                if outgoing.length < 0.3, n > 4 {
                    ring[i] = (cur + next) * 0.5
                    ring.remove(at: (i + 1) % n)
                    changed = true; break
                }
            }
        }
        return ring
    }

    /// Snaps edges within 6° of the footprint's main axis (or its perpendicular) onto it and
    /// re-intersects neighbouring edge lines. Nil when nothing needs snapping or a corner would
    /// move more than 0.45 m.
    private static func orthogonalize(_ ring: [DV2]) -> [DV2]? {
        let n = ring.count
        guard n >= 4 else { return nil }
        let axis = DioramaPolygon.minimumAreaRectangle(ring).axis.normalized
        let across = axis.left
        let tolerance = 6 * Double.pi / 180
        var lines: [(p: DV2, d: DV2)] = []
        var moved = false
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            let d = (b - a).normalized
            let u = d.dot(axis), v = d.dot(across)
            let angle = atan2(abs(v), abs(u))
            var direction = d
            if angle < tolerance {
                direction = axis * (u >= 0 ? 1 : -1)
                moved = moved || angle > 1e-4
            } else if angle > Double.pi / 2 - tolerance {
                direction = across * (v >= 0 ? 1 : -1)
                moved = moved || angle < Double.pi / 2 - 1e-4
            }
            lines.append(((a + b) * 0.5, direction))
        }
        guard moved else { return nil }
        var out: [DV2] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let l0 = lines[(i + n - 1) % n], l1 = lines[i]
            let denominator = l0.d.cross(l1.d)
            guard abs(denominator) > 0.05 else { out.append(ring[i]); continue }
            let t = (l1.p - l0.p).cross(l1.d) / denominator
            let p = l0.p + l0.d * t
            guard p.distance(to: ring[i]) < 0.45 else { return nil }
            out.append(p)
        }
        return out
    }

    // MARK: Rounded shell

    /// Outline of a building shell. Edge `i` runs from `points[i]` to `points[i + 1]`.
    struct Shell: Sendable {
        var points: [DV2]
        /// Tile cut or ownership boundary: no wall, no trim.
        var cut: [Bool]
        /// Corner fillet standing in for an arc.
        var fillet: [Bool]

        var wallFlags: [Bool] { zip(cut, fillet).map { $0 || $1 } }
    }

    /// Rounds convex corners (35°–150° of turn) whose neighbouring edges are real walls.
    static func shell(_ ring: [DV2], cut: [Bool]? = nil, radius: Double, segments: Int = 1) -> Shell {
        let n = ring.count
        let flags = cut?.count == n ? cut ?? [] : Array(repeating: false, count: n)
        guard n >= 3, radius > 0 else { return Shell(points: ring, cut: flags, fillet: Array(repeating: false, count: n)) }
        var points: [DV2] = [], outCut: [Bool] = [], fillet: [Bool] = []
        let steps = max(1, min(segments, 3))
        for i in 0..<n {
            let c = ring[i], prev = ring[(i + n - 1) % n], next = ring[(i + 1) % n]
            let incoming = c - prev, outgoing = next - c
            let turn = atan2(incoming.cross(outgoing), incoming.dot(outgoing))
            let reach = min(radius, incoming.length * 0.3, outgoing.length * 0.3)
            let round = turn > 35 * Double.pi / 180 && turn < 150 * Double.pi / 180
                && !flags[(i + n - 1) % n] && !flags[i] && reach >= 0.2
            guard round else {
                points.append(c); outCut.append(flags[i]); fillet.append(false)
                continue
            }
            let a = c - incoming.normalized * reach, b = c + outgoing.normalized * reach
            for k in 0...steps {
                let t = Double(k) / Double(steps)
                points.append(a * ((1 - t) * (1 - t)) + c * (2 * (1 - t) * t) + b * (t * t))
                outCut.append(k == steps ? flags[i] : false)
                fillet.append(k < steps)
            }
        }
        return Shell(points: points, cut: outCut, fillet: fillet)
    }

    /// Shader-facade walls of a shell. Fillets are plain render with the neighbouring walls'
    /// normals at their ends; real walls take the caller's facade.
    static func walls(_ shell: Shell, bottom: (DV2) -> Double, top: Double, _ s: DioramaSwatch, front: Int,
                      facade: (Int) -> DioramaFacade, into mesh: inout DioramaMesh) {
        let n = shell.points.count
        guard n >= 3 else { return }
        let normals = edgeNormals(shell.points)
        for i in 0..<n where !shell.cut[i] {
            guard shell.fillet[i] else {
                mesh.facadeWall(shell.points, edge: i, bottom: bottom, top: top, s, facade: facade(i),
                                front: i == front, skip: shell.cut)
                continue
            }
            let j = (i + 1) % n
            let previous = (i + n - 1) % n
            let na = shell.fillet[previous] ? (normals[previous] + normals[i]).normalized : normals[previous]
            let nb = shell.fillet[j] ? (normals[j] + normals[i]).normalized : normals[j]
            var plain = facade(i)
            plain.style = .plain
            let a = shell.points[i], b = shell.points[j]
            mesh.facadeWall(a, b, bottomA: bottom(a), bottomB: bottom(b), top: top, s, facade: plain,
                            sharpStart: true, sharpEnd: true, front: false, normalA: DV3(na, 0), normalB: DV3(nb, 0))
        }
    }

    // MARK: Profiles

    /// One point of a swept section: `o` metres outward of the wall line (negative is inward),
    /// `y` metres above the sweep base, shading normal as (outward, up), baked occlusion.
    struct Section: Sendable {
        let o: Double
        let y: Double
        let n: DV2
        let ao: Float

        init(_ o: Double, _ y: Double, normal nx: Double, _ ny: Double, ao: Float = 1) {
            self.o = o; self.y = y; self.ao = ao
            n = DV2(nx, ny).normalized
        }
    }

    enum Role: Sendable { case wall, trim, deck }

    /// Colour multipliers per role on top of the mesh tint (skyline recipes recolour swatches).
    struct RoleTints: Sendable {
        var wall: SIMD3<Float> = SIMD3(repeating: 1)
        var trim: SIMD3<Float> = SIMD3(repeating: 1)
        var deck: SIMD3<Float> = SIMD3(repeating: 1)
        static let neutral = RoleTints()

        func callAsFunction(_ role: Role) -> SIMD3<Float> {
            switch role {
            case .wall: wall
            case .trim: trim
            case .deck: deck
            }
        }
    }

    struct Segment: Sendable {
        let from: Section
        let to: Section
        let role: Role
    }

    struct Profile: Sendable {
        let segments: [Segment]
        /// Inset and height of the deck the profile ends on.
        var deckInset: Double { -(segments.last?.to.o ?? 0) }
        var deckHeight: Double { segments.last?.to.y ?? 0 }
        /// Same profile without its occlusion strip on the deck (the deck is then drawn from the
        /// inner face's foot).
        var withoutDeckStrip: Profile { Profile(segments: segments.filter { $0.role != .deck }) }
        var trianglesPerPoint: Int { segments.count * 2 }
    }

    /// Rounded parapet in three faces: the render band leaning out to a `lip` overhang, a rolled
    /// trim cap whose normals sweep from the street over the top to the roof, and the inner face;
    /// then the occlusion strip on the deck (inner foot 0.72, `ao` metres further in 1.0).
    /// 8 triangles per outline point (6 without the strip), the cost of the old three-face box.
    static func parapet(rise: Double = 0.5, lip: Double = 0.09, thickness: Double = 0.28, ao: Double = 0.6) -> Profile {
        let capTop = rise + 0.1
        return Profile(segments: [
            Segment(from: Section(0, 0, normal: 1, 0), to: Section(lip, rise, normal: 0.85, 0.35), role: .wall),
            Segment(from: Section(lip, rise, normal: 0.85, 0.35), to: Section(-thickness, capTop, normal: -0.5, 0.86), role: .trim),
            Segment(from: Section(-thickness, capTop, normal: -0.5, 0.86), to: Section(-thickness, 0, normal: -1, 0, ao: 0.72), role: .trim),
            Segment(from: Section(-thickness, 0, normal: 0, 1, ao: 0.72), to: Section(-thickness - ao, 0, normal: 0, 1), role: .deck),
        ])
    }

    // MARK: Sweep

    private struct Station {
        let p: DV2
        let displacement: DV2
        let shade: DV2
        let breakBefore: Bool
    }

    static func edgeNormals(_ ring: [DV2]) -> [DV2] {
        let n = ring.count
        return (0..<n).map { (ring[($0 + 1) % n] - ring[$0]).normalized.right }
    }

    /// Stations along every run of uncut edges. Gentle bends (< 50°) share one station whose
    /// shading follows the tangent rule; hard corners split into two stations at the same mitred
    /// position (crisp, no extra triangles). Open runs end square on their cut edges.
    private static func stations(_ ring: [DV2], cut: [Bool], fillet: [Bool]) -> [(stations: [Station], closed: Bool)] {
        let n = ring.count
        guard n >= 3 else { return [] }
        let normals = edgeNormals(ring)
        let open = cut.contains(true)
        var runs: [[Int]] = []
        if open {
            guard let first = cut.firstIndex(of: true) else { return [] }
            var current: [Int] = []
            for k in 1...n {
                let e = (first + k) % n
                if cut[e] {
                    if !current.isEmpty { runs.append(current); current = [] }
                } else {
                    current.append(e)
                }
            }
            if !current.isEmpty { runs.append(current) }
        } else {
            runs = [Array(0..<n)]
        }
        var result: [(stations: [Station], closed: Bool)] = []
        for run in runs {
            var list: [Station] = []
            func emit(_ v: Int, incoming: Int?, outgoing: Int?) {
                let p = ring[v]
                switch (incoming, outgoing) {
                case let (i?, o?):
                    let a = normals[i], b = normals[o]
                    let sum = a + b
                    let miter = sum.length > 1e-6 ? sum.normalized : b
                    let displacement = miter * (1 / max(miter.dot(b), 0.35))
                    if a.dot(b) > cos(50 * Double.pi / 180) {
                        let inWall = !fillet[i], outWall = !fillet[o]
                        let shade = inWall && !outWall ? a : (!inWall && outWall ? b : miter)
                        list.append(Station(p: p, displacement: displacement, shade: shade, breakBefore: false))
                    } else {
                        list.append(Station(p: p, displacement: displacement, shade: a, breakBefore: false))
                        list.append(Station(p: p, displacement: displacement, shade: b, breakBefore: true))
                    }
                case let (i?, nil):
                    list.append(Station(p: p, displacement: normals[i], shade: normals[i], breakBefore: false))
                case let (nil, o?):
                    list.append(Station(p: p, displacement: normals[o], shade: normals[o], breakBefore: false))
                default:
                    break
                }
            }
            for (k, e) in run.enumerated() {
                let incoming: Int? = (!open || k > 0) ? (e + n - 1) % n : nil
                emit(e, incoming: incoming, outgoing: e)
            }
            if open, let last = run.last {
                emit((last + 1) % n, incoming: last, outgoing: nil)
            } else if let first = list.first {
                list.append(Station(p: first.p, displacement: first.displacement, shade: first.shade, breakBefore: false))
            }
            result.append((list, !open))
        }
        return result
    }

    /// The deck outline a profile ends on, when it is a valid simple counter-clockwise polygon.
    static func deckRing(_ shell: Shell, profile: Profile) -> [DV2]? {
        guard !shell.cut.contains(true) else { return nil }
        let inset = profile.deckInset
        guard let runs = stations(shell.points, cut: shell.cut, fillet: shell.fillet).first?.stations else { return nil }
        var ring: [DV2] = []
        for station in runs.dropLast() {
            let p = station.p - station.displacement * inset
            if let last = ring.last, last.distance(to: p) < 0.02 { continue }
            ring.append(p)
        }
        guard ring.count >= 3, DioramaPolygon.signedArea(ring) > 1, DioramaPolygon.isSimple(ring) else { return nil }
        return ring
    }

    /// Sweeps `profile` along the shell's uncut edges at height `z`. Returns triangles added.
    @discardableResult
    static func sweep(_ shell: Shell, z: Double, profile: Profile, wall: DioramaSwatch, trim: DioramaSwatch,
                      deck: DioramaSwatch, tints: RoleTints = .neutral, into mesh: inout DioramaMesh) -> Int {
        let base = mesh.tint
        defer { mesh.tint = base }
        var triangles = 0
        for run in stations(shell.points, cut: shell.cut, fillet: shell.fillet) {
            let list = run.stations
            guard list.count >= 2 else { continue }
            for segment in profile.segments {
                let swatch: DioramaSwatch = segment.role == .wall ? wall : (segment.role == .trim ? trim : deck)
                let uv = DioramaAtlas.uv(swatch, dark: false)
                let roleTint = base * tints(segment.role)
                mesh.reserve(list.count * 2)
                var previous: (UInt32, UInt32)? = nil
                for station in list {
                    func vertex(_ section: Section) -> UInt32 {
                        mesh.tint = roleTint * section.ao
                        let position = DV3(station.p + station.displacement * section.o, z + section.y)
                        let normal = DV3(station.shade * section.n.x, section.n.y).normalized
                        return mesh.vertex(position, normal, uv)
                    }
                    let a = vertex(segment.from), b = vertex(segment.to)
                    if let (pa, pb) = previous, !station.breakBefore {
                        mesh.tri(pa, a, b)
                        mesh.tri(pa, b, pb)
                        triangles += 2
                    }
                    previous = (a, b)
                }
            }
        }
        return triangles
    }

    // MARK: Roofs

    /// What a flat roof finished with.
    struct Deck {
        /// Walkable deck outline, for roof props (nil on cut shells).
        let ring: [DV2]?
        let z: Double
    }

    /// Flat roof on top of walls at `z`: the parapet (with its occlusion ring where the outline
    /// allows it), else a lid whose rim normals lean outward so its edge shades as a roll.
    static func flatRoof(_ shell: Shell, z: Double, parapet wantsParapet: Bool, parapetProfile: Profile = parapet(),
                         wall: DioramaSwatch, trim: DioramaSwatch, deck: DioramaSwatch, tints: RoleTints = .neutral,
                         into mesh: inout DioramaMesh) -> Deck {
        let isCut = shell.cut.contains(true)
        let base = mesh.tint
        defer { mesh.tint = base }
        func lid(_ ring: [DV2], _ height: Double) {
            mesh.tint = base * tints.deck
            mesh.polygon(ring, z: height, deck)
            mesh.tint = base
        }
        func run(_ profile: Profile) {
            sweep(shell, z: z, profile: profile, wall: wall, trim: trim, deck: deck, tints: tints, into: &mesh)
        }
        if wantsParapet, isCut {
            lid(shell.points, z)
            run(parapetProfile.withoutDeckStrip)
            return Deck(ring: nil, z: z)
        }
        if wantsParapet {
            for profile in [parapetProfile, parapetProfile.withoutDeckStrip] {
                guard let ring = deckRing(shell, profile: profile) else { continue }
                run(profile)
                lid(ring, z + profile.deckHeight)
                return Deck(ring: ring, z: z + profile.deckHeight)
            }
        }
        if isCut {
            lid(shell.points, z)
            return Deck(ring: nil, z: z)
        }
        mesh.tint = base * tints.deck
        mesh.softLid(shell.points, z: z, lean: 0.6, deck)
        return Deck(ring: shell.points, z: z)
    }

    /// Fixed-size roof props on a deck, each a shared library mesh drawn as an instance: water
    /// tanks, a stair head and rounded condenser boxes, at least 1 m inside the deck edge.
    /// Returns the number placed.
    @discardableResult
    static func roofProps(on deck: [DV2], z: Double, seed: UInt64, tanks: Int, stairHead: Bool, condensers: Int,
                          kit: DioramaBuildingKit, into mesh: inout DioramaMesh) -> Int {
        guard deck.count >= 3 else { return 0 }
        let box = DioramaPolygon.minimumAreaRectangle(deck)
        guard box.halfLength > 2.2, box.halfWidth > 1.8 else { return 0 }
        let savedTint = mesh.tint
        mesh.tint = SIMD3(repeating: 1)
        defer { mesh.tint = savedTint }
        var rng = DioramaRandom(seed: seed, salt: 0x50_52_4F_50)
        var taken: [DioramaOrientedRect] = []
        var placed = 0
        func spot(halfLength: Double, halfWidth: Double) -> DioramaOrientedRect? {
            let us: [Double] = [-0.55, 0.55, 0, -0.25, 0.25]
            let vs: [Double] = [0, -0.4, 0.4]
            let start = rng.int(0...(us.count - 1))
            for k in 0..<us.count {
                let u = us[(start + k) % us.count]
                for v in vs {
                    let centre = box.centre + box.axis * (box.halfLength * u) + box.across * (box.halfWidth * v)
                    let candidate = DioramaOrientedRect(centre: centre, axis: box.axis, halfLength: halfLength, halfWidth: halfWidth)
                    let reach = (halfLength * halfLength + halfWidth * halfWidth).squareRoot()
                    guard DarArchitecturePlan.fits(candidate.corners, inside: deck, clearance: 1.0),
                          taken.allSatisfy({ other in
                              other.centre.distance(to: centre) > reach + (other.halfLength * other.halfLength + other.halfWidth * other.halfWidth).squareRoot() + 0.3
                          })
                    else { continue }
                    taken.append(candidate)
                    return candidate
                }
            }
            return nil
        }
        if stairHead, let head = spot(halfLength: 1.4, halfWidth: 1.1) {
            kit.roofHead(at: head.centre, axis: head.axis, z0: z, into: &mesh)
            placed += 1
        }
        for _ in 0..<tanks {
            guard let place = spot(halfLength: 0.8, halfWidth: 0.8) else { break }
            kit.waterTank(at: place.centre, z0: z, color: rng.chance(0.7) ? .tankBlack : .tankBlue, into: &mesh)
            placed += 1
        }
        for _ in 0..<condensers {
            guard let place = spot(halfLength: 0.5, halfWidth: 0.36) else { break }
            mesh.box(centre: place.centre, z0: z, axis: box.axis, halfLength: 0.45, halfWidth: 0.32, height: 0.55,
                     .trimWhite, top: .mastGrey, bevel: 0.07)
            placed += 1
        }
        return placed
    }

    // MARK: Helpers

    /// Vertex tint that turns `swatch` into `color` (the skyline recipes give hex colours).
    static func tint(_ color: SIMD3<Float>, over swatch: DioramaSwatch) -> SIMD3<Float> {
        let v = DioramaSwatch.defaultPalette[swatch] ?? 0xFFFFFF
        let base = SIMD3(Float((v >> 16) & 255), Float((v >> 8) & 255), Float(v & 255)) / 255
        return color / simd_max(base, SIMD3(repeating: 0.05))
    }

    /// Walls follow the terrain at every corner 0.25 m into the ground; a foundation skirt is only
    /// needed where the ground between corners dips further than that.
    static func needsSkirt(_ ring: [DV2], terrain: DioramaTerrain) -> Bool {
        guard let first = ring.first else { return false }
        var low = Double.greatestFiniteMagnitude, high = -Double.greatestFiniteMagnitude
        for p in DioramaPolygon.densify(ring + [first], maxStep: 2) {
            let h = terrain.height(p)
            low = min(low, h); high = max(high, h)
        }
        return high - low > 0.2
    }
}
