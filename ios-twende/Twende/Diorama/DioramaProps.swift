import Foundation

/// Every prop type is built once as a tiny mesh at the origin (facing +x, standing on z = 0) and
/// stamped around the tile with `DioramaMesh.append`, so tile geometry stays small.
nonisolated struct DioramaPropLibrary: Sendable {
    let palm: DioramaMesh
    /// Broad-leaf shade trees in several silhouettes (round, layered, umbrella, tall, small ornamental).
    let trees: [DioramaMesh]
    let cypress: DioramaMesh
    let flamboyant: DioramaMesh
    let bushes: [DioramaMesh]
    let flowerBushes: [DioramaMesh]
    let bougainvillea: [DioramaMesh]
    let bajaji: [DioramaMesh]
    let boda: DioramaMesh
    let dalaDala: DioramaMesh
    let cars: [DioramaMesh]
    let dhow: DioramaMesh
    let lamp: DioramaMesh
    let lampGlow: DioramaMesh
    let lampHalo: DioramaMesh
    let kiosk: [DioramaMesh]
    let kioskGlow: DioramaMesh

    init(config: DioramaConfig) {
        palm = Self.makePalm()
        trees = [
            Self.makeRoundTree(seed: 1, scale: 1.0), Self.makeRoundTree(seed: 2, scale: 1.15), Self.makeRoundTree(seed: 3, scale: 0.85),
            Self.makeLayeredTree(seed: 4), Self.makeLayeredTree(seed: 5),
            Self.makeUmbrellaTree(seed: 6), Self.makeTallTree(seed: 7), Self.makeOrnamentalTree(seed: 8),
        ]
        cypress = Self.makeCypress()
        flamboyant = Self.makeFlamboyant()
        bushes = [Self.makeBush(seed: 11, .hedge), Self.makeBush(seed: 12, .leafOlive), Self.makeBush(seed: 13, .leafBright), Self.makeBush(seed: 14, .leafDark)]
        flowerBushes = [Self.makeFlowerBush(seed: 21, .flowerPink), Self.makeFlowerBush(seed: 22, .flowerYellow), Self.makeFlowerBush(seed: 23, .flowerRed), Self.makeFlowerBush(seed: 24, .flowerWhite)]
        bougainvillea = [Self.makeBougainvillea(.bougainvilleaMagenta), Self.makeBougainvillea(.bougainvilleaOrange)]
        bajaji = [Self.makeBajaji(.bajajiBlue), Self.makeBajaji(.bajajiRed), Self.makeBajaji(.bajajiYellow)]
        boda = Self.makeBoda()
        dalaDala = Self.makeDalaDala()
        cars = [Self.makeCar(.carSilver), Self.makeCar(.carRed), Self.makeCar(.carWhite), Self.makeCar(.sunflower)]
        dhow = Self.makeDhow()
        (lamp, lampGlow) = Self.makeLamp()
        lampHalo = Self.makeHalo(radius: 2.4, .lampGlow)
        kiosk = config.canopyColors.map { Self.makeKiosk(canopy: $0) }
        kioskGlow = Self.makeKioskGlow()
    }

    // MARK: Trees

    /// Trunk with a few short branches disappearing into the canopy.
    private static func trunk(_ m: inout DioramaMesh, height h: Double, radius r: Double, branches: Int, rng: inout DioramaRandom) {
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, h), r0: r, r1: r * 0.7, sides: 7, .trunk, cap: false)
        m.cylinder(centre: .zero, z0: 0, z1: 0.12, r0: r * 1.5, r1: r * 1.1, sides: 7, .trunk)
        for _ in 0..<branches {
            let a = rng.range(0...6.28)
            let dir = DV2(cos(a), sin(a))
            let z0 = h * rng.range(0.7...0.95)
            m.tube(from: DV3(0, 0, z0), to: DV3(dir * rng.range(0.8...1.4), z0 + rng.range(0.6...1.2)), r0: r * 0.45, r1: r * 0.2, sides: 4, .trunk, cap: false)
        }
    }

    /// Classic rounded canopy made of a large core and several overlapping lobes in three greens.
    private static func makeRoundTree(seed: UInt64, scale: Double) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 21)
        let h = rng.range(2.6...3.4) * scale
        trunk(&m, height: h + 0.8, radius: 0.3 * scale, branches: 3, rng: &rng)
        let R = rng.range(2.4...3.0) * scale
        m.sphere(centre: DV3(0, 0, h + R * 0.75), radii: DV3(R, R * 0.95, R * 0.85), .leafMid)
        let lobes = rng.int(5...7)
        for k in 0..<lobes {
            let a = Double(k) / Double(lobes) * 2 * Double.pi + rng.range(0...0.4)
            let r = R * rng.range(0.45...0.7)
            let s = R * rng.range(0.45...0.62)
            let z = h + R * rng.range(0.45...1.0)
            let swatch: DioramaSwatch = k % 3 == 0 ? .leafDark : (k % 3 == 1 ? .leafLight : .leafMid)
            m.sphere(centre: DV3(cos(a) * r, sin(a) * r, z), radii: DV3(s, s, s * 0.85), swatch, detail: 1)
        }
        m.sphere(centre: DV3(rng.range(-0.3...0.3), rng.range(-0.3...0.3), h + R * 1.35), radii: DV3(R * 0.5, R * 0.5, R * 0.4), .leafLight, detail: 1)
        return m
    }

    /// Three stacked tiers of foliage, each a flattened blob, like a clipped ornamental tree.
    private static func makeLayeredTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 22)
        let h = rng.range(2.2...2.8)
        trunk(&m, height: h + 2.6, radius: 0.24, branches: 2, rng: &rng)
        let tiers: [(Double, Double, DioramaSwatch)] = [(0, 2.4, .leafDark), (1.5, 1.9, .leafMid), (2.8, 1.3, .leafLight)]
        for (dz, r, s) in tiers {
            let off = DV2(rng.range(-0.3...0.3), rng.range(-0.3...0.3))
            m.sphere(centre: DV3(off, h + dz), radii: DV3(r, r * 0.95, r * 0.55), s)
            m.sphere(centre: DV3(off * -0.6 + DV2(r * 0.4, 0), h + dz + r * 0.15), radii: DV3(r * 0.55, r * 0.55, r * 0.35), s == .leafDark ? .leafMid : .leafLight, detail: 0)
        }
        return m
    }

    /// Wide, flat umbrella canopy (acacia / neem).
    private static func makeUmbrellaTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 23)
        let h = rng.range(3.6...4.4)
        trunk(&m, height: h, radius: 0.28, branches: 4, rng: &rng)
        m.sphere(centre: DV3(0, 0, h + 0.6), radii: DV3(4.2, 3.9, 1.1), .leafOlive)
        m.sphere(centre: DV3(0.9, 0.4, h + 1.0), radii: DV3(2.3, 2.1, 0.8), .leafMid, detail: 0)
        m.sphere(centre: DV3(-1.3, -0.5, h + 0.9), radii: DV3(2.0, 2.2, 0.7), .leafLight, detail: 0)
        m.sphere(centre: DV3(0.2, -1.4, h + 0.5), radii: DV3(1.6, 1.4, 0.6), .leafDark, detail: 0)
        return m
    }

    /// Tall slender tree with a narrow, slightly ragged crown.
    private static func makeTallTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 24)
        let h = rng.range(5.0...6.0)
        trunk(&m, height: h + 1.5, radius: 0.22, branches: 2, rng: &rng)
        m.sphere(centre: DV3(0, 0, h + 1.6), radii: DV3(1.6, 1.6, 2.4), .leafMid)
        m.sphere(centre: DV3(0.7, 0.3, h + 0.9), radii: DV3(1.1, 1.0, 1.3), .leafDark, detail: 0)
        m.sphere(centre: DV3(-0.6, -0.4, h + 2.6), radii: DV3(1.0, 1.0, 1.1), .leafLight, detail: 0)
        return m
    }

    /// Small garden tree: short trunk, dense bright ball.
    private static func makeOrnamentalTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 25)
        let h = rng.range(1.3...1.7)
        trunk(&m, height: h + 0.4, radius: 0.14, branches: 0, rng: &rng)
        m.sphere(centre: DV3(0, 0, h + 1.2), radii: DV3(1.35, 1.35, 1.3), .leafBright)
        m.sphere(centre: DV3(0.5, 0.2, h + 1.6), radii: DV3(0.7, 0.7, 0.6), .leafLight, detail: 0)
        m.sphere(centre: DV3(-0.4, -0.5, h + 0.9), radii: DV3(0.7, 0.6, 0.6), .leafMid, detail: 0)
        return m
    }

    /// Italian cypress column for driveways and compound corners.
    private static func makeCypress() -> DioramaMesh {
        var m = DioramaMesh()
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, 0.5), r0: 0.12, r1: 0.1, sides: 5, .trunk, cap: false)
        m.sphere(centre: DV3(0, 0, 2.6), radii: DV3(0.75, 0.75, 2.3), .cypress)
        m.sphere(centre: DV3(0, 0, 4.4), radii: DV3(0.45, 0.45, 1.2), .cypress, detail: 0)
        m.sphere(centre: DV3(0.15, 0.1, 1.6), radii: DV3(0.6, 0.55, 0.9), .leafDark, detail: 0)
        return m
    }

    private static func makePalm() -> DioramaMesh {
        var m = DioramaMesh()
        let top = DV3(0.9, 0.3, 7.5)
        var prev = DV3(0, 0, 0)
        for k in 1...4 {
            let t = Double(k) / 4
            let p = DV3(top.x * t * t, top.y * t * t, top.z * t)
            m.tube(from: prev, to: p, r0: 0.28 - 0.04 * Double(k - 1), r1: 0.24 - 0.04 * Double(k - 1), sides: 6, .palmTrunk, cap: k == 4)
            prev = p
        }
        for k in 0..<9 {
            let a = Double(k) / 9 * 2 * Double.pi + 0.3
            let dir = DV2(cos(a), sin(a))
            let tip = top + DV3(dir * 3.0, -1.4)
            let mid = top + DV3(dir * 1.6, 0.5)
            let w = dir.left * 0.5
            m.quad(top + DV3(w * 0.4, 0), mid + DV3(w, 0), tip, mid - DV3(w, 0), k % 2 == 0 ? .leafMid : .leafBright, normal: .up)
            m.quad(top + DV3(w * 0.4, 0), mid + DV3(w, 0), tip, mid - DV3(w, 0), .leafDark, normal: DV3(0, 0, -1))
        }
        for k in 0..<3 {
            let a = Double(k) / 3 * 2 * Double.pi
            m.sphere(centre: top + DV3(cos(a) * 0.35, sin(a) * 0.35, -0.3), radii: DV3(0.22, 0.22, 0.26), .coconut, detail: 0)
        }
        return m
    }

    private static func makeFlamboyant() -> DioramaMesh {
        var m = DioramaMesh()
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, 3.4), r0: 0.34, r1: 0.22, sides: 6, .trunk, cap: false)
        for k in 0..<3 {
            let a = Double(k) / 3 * 2 * Double.pi
            m.tube(from: DV3(0, 0, 3.2), to: DV3(cos(a) * 2.2, sin(a) * 2.2, 4.6), r0: 0.16, r1: 0.08, sides: 4, .trunk, cap: false)
        }
        m.sphere(centre: DV3(0, 0, 5.0), radii: DV3(4.4, 4.2, 1.3), .flamboyant)
        m.sphere(centre: DV3(0.8, 0.5, 5.5), radii: DV3(2.4, 2.2, 1.0), .flamboyant, detail: 0)
        m.sphere(centre: DV3(-1.2, -0.6, 4.6), radii: DV3(2.0, 2.0, 0.9), .leafDark, detail: 0)
        return m
    }

    // MARK: Shrubs and flowers

    /// Low shrub: a cluster of 4–6 blobs.
    private static func makeBush(seed: UInt64, _ s: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 26)
        let blobs = rng.int(4...6)
        m.sphere(centre: DV3(0, 0, 0.55), radii: DV3(0.9, 0.85, 0.6), s, detail: 1)
        for k in 0..<blobs {
            let a = Double(k) / Double(blobs) * 2 * Double.pi + rng.range(0...0.5)
            let r = rng.range(0.4...0.7)
            let size = rng.range(0.35...0.55)
            m.sphere(centre: DV3(cos(a) * r, sin(a) * r, rng.range(0.3...0.6)), radii: DV3(size, size, size * 0.8), k % 2 == 0 ? s : .leafLight, detail: 0)
        }
        return m
    }

    /// Flowering shrub: green mound studded with small coloured blooms.
    private static func makeFlowerBush(seed: UInt64, _ flower: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 27)
        m.sphere(centre: DV3(0, 0, 0.42), radii: DV3(0.8, 0.75, 0.45), .hedge, detail: 1)
        for _ in 0..<9 {
            let a = rng.range(0...6.28), r = rng.range(0.1...0.65)
            let p = DV3(cos(a) * r, sin(a) * r, 0.42 + 0.42 * (1 - (r / 0.8) * (r / 0.8)).squareRoot() * 0.9)
            m.sphere(centre: p, radii: DV3(0.14, 0.14, 0.12), flower, detail: 0)
        }
        return m
    }

    private static func makeBougainvillea(_ color: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        m.sphere(centre: DV3(0, 0.1, 2.35), radii: DV3(1.5, 0.9, 0.6), color)
        m.sphere(centre: DV3(0.7, 0.45, 1.9), radii: DV3(0.8, 0.5, 0.7), color, detail: 0)
        m.sphere(centre: DV3(-0.8, 0.5, 1.75), radii: DV3(0.7, 0.45, 0.8), .leafDark, detail: 0)
        m.sphere(centre: DV3(0.1, 0.55, 1.5), radii: DV3(0.6, 0.35, 0.9), color, detail: 0)
        return m
    }

    // MARK: Vehicles

    private static func makeBajaji(_ color: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: DV2(0.1, 0), z0: 0.35, halfLength: 1.1, halfWidth: 0.65, height: 0.55, color, top: color, bevel: 0.1, bottom: true)
        m.box(centre: DV2(-0.1, 0), z0: 0.9, halfLength: 0.8, halfWidth: 0.6, height: 0.75, .glass, top: color, bevel: 0.08)
        m.box(centre: DV2(-0.05, 0), z0: 1.62, halfLength: 0.95, halfWidth: 0.72, height: 0.12, color, bevel: 0.05)
        m.tube(from: DV3(0.9, 0, 0.9), to: DV3(1.25, 0, 0.55), r0: 0.42, r1: 0.25, sides: 6, color)
        wheel(&m, at: DV2(1.05, 0), r: 0.26)
        wheel(&m, at: DV2(-0.75, 0.62), r: 0.28)
        wheel(&m, at: DV2(-0.75, -0.62), r: 0.28)
        return m
    }

    private static func makeBoda() -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: DV2(0, 0), z0: 0.45, halfLength: 0.75, halfWidth: 0.16, height: 0.3, .bajajiRed, bevel: 0.05)
        m.box(centre: DV2(-0.2, 0), z0: 0.75, halfLength: 0.4, halfWidth: 0.18, height: 0.12, .tyre, bevel: 0.03)
        m.tube(from: DV3(0.55, 0, 0.75), to: DV3(0.7, 0, 1.0), r0: 0.08, r1: 0.06, sides: 4, .metalCharcoal)
        m.quad(DV3(0.72, -0.3, 1.0), DV3(0.72, 0.3, 1.0), DV3(0.72, 0.3, 1.05), DV3(0.72, -0.3, 1.05), .metalCharcoal)
        m.sphere(centre: DV3(-0.15, 0, 1.15), radii: DV3(0.22, 0.26, 0.35), .skyBlue, detail: 0)
        m.sphere(centre: DV3(-0.05, 0, 1.6), radii: DV3(0.19, 0.19, 0.19), .sunflower, detail: 0)
        wheel(&m, at: DV2(0.72, 0), r: 0.3, width: 0.12)
        wheel(&m, at: DV2(-0.7, 0), r: 0.3, width: 0.12)
        return m
    }

    private static func makeDalaDala() -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: DV2(0, 0), z0: 0.45, halfLength: 2.4, halfWidth: 0.95, height: 1.0, .dalaWhite, top: .dalaWhite, bevel: 0.12, bottom: true)
        m.box(centre: DV2(-0.1, 0), z0: 1.45, halfLength: 2.2, halfWidth: 0.9, height: 0.75, .glass, top: .dalaWhite, bevel: 0.1)
        m.box(centre: DV2(0, 0), z0: 0.95, halfLength: 2.42, halfWidth: 0.97, height: 0.3, .signBlue, bevel: 0.05)
        m.box(centre: DV2(0, 0), z0: 1.25, halfLength: 2.42, halfWidth: 0.97, height: 0.08, .sunflower)
        m.box(centre: DV2(-0.3, 0), z0: 2.2, halfLength: 1.2, halfWidth: 0.6, height: 0.25, .metalCharcoal, bevel: 0.06)
        for x in [1.5, -1.5] {
            wheel(&m, at: DV2(x, 0.9), r: 0.38)
            wheel(&m, at: DV2(x, -0.9), r: 0.38)
        }
        return m
    }

    private static func makeCar(_ color: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: DV2(0, 0), z0: 0.4, halfLength: 2.1, halfWidth: 0.9, height: 0.65, color, top: color, bevel: 0.16, bottom: true)
        m.box(centre: DV2(-0.25, 0), z0: 1.05, halfLength: 1.15, halfWidth: 0.8, height: 0.6, .glass, top: color, bevel: 0.16)
        // Headlights and tail lights as small pale/red blocks.
        for y in [-0.55, 0.55] {
            m.box(centre: DV2(2.05, y), z0: 0.7, halfLength: 0.06, halfWidth: 0.16, height: 0.14, .trimWhite)
            m.box(centre: DV2(-2.05, y), z0: 0.7, halfLength: 0.06, halfWidth: 0.16, height: 0.14, .signRed)
        }
        for x in [1.3, -1.3] {
            wheel(&m, at: DV2(x, 0.82), r: 0.34)
            wheel(&m, at: DV2(x, -0.82), r: 0.34)
        }
        return m
    }

    private static func wheel(_ m: inout DioramaMesh, at p: DV2, r: Double, width: Double = 0.22) {
        m.tube(from: DV3(p.x, p.y - width / 2, r), to: DV3(p.x, p.y + width / 2, r), r0: r, r1: r, sides: 8, .tyre)
        m.tube(from: DV3(p.x, p.y + width / 2 - 0.01, r), to: DV3(p.x, p.y - width / 2 + 0.01, r), r0: r, r1: r, sides: 8, .tyre)
    }

    // MARK: Water

    private static func makeDhow() -> DioramaMesh {
        var m = DioramaMesh()
        let hull: [DV2] = [DV2(-3.2, 0), DV2(-2.2, -0.9), DV2(1.6, -1.0), DV2(3.4, -0.3), DV2(3.4, 0.3), DV2(1.6, 1.0), DV2(-2.2, 0.9)]
        m.extrude(hull, z0: -0.1, z1: 0.9, .hullWood, top: .deckWood)
        m.polygon(hull, z: -0.1, .hullWood, dark: true, facingUp: false)
        m.tube(from: DV3(0.3, 0, 0.9), to: DV3(0.3, 0, 6.2), r0: 0.08, r1: 0.05, sides: 4, .trunk)
        m.tube(from: DV3(-3.0, 0, 2.2), to: DV3(2.6, 0, 7.4), r0: 0.06, r1: 0.04, sides: 4, .trunk)
        m.triangle(DV3(-2.9, 0.02, 2.3), DV3(2.5, 0.02, 7.2), DV3(1.2, 0.02, 1.4), .sailCream, normal: DV3(0, 1, 0))
        m.triangle(DV3(-2.9, -0.02, 2.3), DV3(2.5, -0.02, 7.2), DV3(1.2, -0.02, 1.4), .sailCream, normal: DV3(0, -1, 0))
        return m
    }

    // MARK: Street furniture

    /// Height of the lamp's light source above its base.
    static let lampHeadHeight: Double = 4.6

    private static func makeLamp() -> (DioramaMesh, DioramaMesh) {
        var m = DioramaMesh()
        var glow = DioramaMesh()
        let h = lampHeadHeight
        m.cylinder(centre: .zero, z0: 0, z1: 0.35, r0: 0.3, r1: 0.22, sides: 8, .lampPole)
        m.tube(from: DV3(0, 0, 0.35), to: DV3(0, 0, h - 0.6), r0: 0.11, r1: 0.08, sides: 6, .lampPole, cap: false)
        m.cylinder(centre: .zero, z0: h - 0.6, z1: h - 0.45, r0: 0.2, r1: 0.14, sides: 6, .lampPole)
        m.box(centre: .zero, z0: h - 0.45, halfLength: 0.3, halfWidth: 0.3, height: 0.08, .lampPole, bevel: 0.03)
        glow.box(centre: .zero, z0: h - 0.37, halfLength: 0.24, halfWidth: 0.24, height: 0.62, .lampGlow, bevel: 0.05, bottom: true)
        for (dx, dy) in [(0.26, 0.26), (-0.26, 0.26), (0.26, -0.26), (-0.26, -0.26)] {
            m.tube(from: DV3(dx, dy, h - 0.37), to: DV3(dx, dy, h + 0.25), r0: 0.03, r1: 0.03, sides: 4, .lampPole, cap: false)
        }
        m.box(centre: .zero, z0: h + 0.25, halfLength: 0.36, halfWidth: 0.36, height: 0.1, .lampPole, bevel: 0.05)
        m.tube(from: DV3(0, 0, h + 0.35), to: DV3(0, 0, h + 0.7), r0: 0.12, r1: 0.02, sides: 6, .lampPole)
        return (m, glow)
    }

    /// Camera-facing halo sprite centred on the light. Appearance code 5 in the shader; the corner offsets
    /// are packed in the normal so the vertex stage can billboard it.
    static func makeHalo(radius: Double, _ s: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        m.reserve(4)
        let uv = DioramaAtlas.uv(s, dark: false)
        let corners: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let base = m.positions.count
        for (cx, cy) in corners {
            m.vertex(DV3(0, 0, 0), DV3(cx, cy, radius), uv)
        }
        m.rawTriangles([UInt32(base), UInt32(base + 1), UInt32(base + 2), UInt32(base), UInt32(base + 2), UInt32(base + 3)])
        return m
    }

    private static func makeKiosk(canopy: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: DV2(0.6, 0), z0: 0, halfLength: 0.35, halfWidth: 1.3, height: 1.0, .deck, top: .deck, ao: 0.3, bevel: 0.05)
        m.box(centre: DV2(-0.9, 0), z0: 0, halfLength: 0.12, halfWidth: 1.3, height: 2.2, .ochre, ao: 0.4, bevel: 0.04)
        for y in [-1.25, 1.25] {
            m.tube(from: DV3(0.95, y, 0), to: DV3(0.95, y, 2.1), r0: 0.06, r1: 0.06, sides: 4, .trunk, cap: false)
        }
        m.quad(DV3(-1.1, -1.5, 2.45), DV3(-1.1, 1.5, 2.45), DV3(1.25, 1.5, 2.05), DV3(1.25, -1.5, 2.05), canopy)
        m.quad(DV3(-1.1, -1.5, 2.45), DV3(-1.1, 1.5, 2.45), DV3(1.25, 1.5, 2.05), DV3(1.25, -1.5, 2.05), canopy, dark: true, normal: DV3(0, 0, -1))
        m.quad(DV3(1.25, -1.5, 2.05), DV3(1.25, 1.5, 2.05), DV3(1.25, 1.5, 1.8), DV3(1.25, -1.5, 1.8), .trimWhite, normal: DV3(1, 0, 0))
        let goods: [DioramaSwatch] = [.signRed, .signGreen, .sunflower, .signBlue, .coral]
        for (k, g) in goods.enumerated() {
            m.box(centre: DV2(0.55, -1.0 + Double(k) * 0.5), z0: 1.0, halfLength: 0.18, halfWidth: 0.18, height: 0.3 + Double(k % 2) * 0.15, g, bevel: 0.03)
        }
        return m
    }

    private static func makeKioskGlow() -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: DV2(-0.75, 0), z0: 1.3, halfLength: 0.03, halfWidth: 0.9, height: 0.5, .kioskGlow)
        return m
    }
}

/// Places vegetation and landscaping (street trees, compound gardens, hedges along walls, flower beds at
/// lamp posts and building fronts, park planting, coast palms) and props (vehicles, dhows, lamps as real
/// point lights, kiosks).
nonisolated struct DioramaPropPlacer {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let library: DioramaPropLibrary
    let buildings: [DioramaBuilt]
    let compounds: [DioramaCompound]
    let reduceDetail: Bool
    let terrain: DioramaTerrain

    private func ground(_ p: DV2) -> Double { terrain.height(p) }
    private func roadSurface(_ p: DV2) -> Double { terrain.height(p) + DioramaRoadGenerator.surfaceLift }
    private func pavement(_ p: DV2) -> Double { terrain.height(p) + DioramaRoadGenerator.surfaceLift + config.kerbHeight }

    private func isFree(_ p: DV2, radius: Double) -> Bool {
        guard data.rect.expanded(by: -1).contains(p) else { return false }
        if roads.isOnRoad(p, margin: radius) { return false }
        for b in buildings where b.box.expanded(by: radius).contains(p) { return false }
        return true
    }

    private func isWater(_ p: DV2) -> Bool {
        data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) }
    }

    /// Pavement-top point: inside the pavement strip, off the carriageway, not in a building.
    private func isOnPavement(_ p: DV2) -> Bool {
        guard data.rect.expanded(by: -1).contains(p), !roads.isOnCarriageway(p, margin: 0.25) else { return false }
        for b in buildings where b.box.expanded(by: 0.4).contains(p) { return false }
        return true
    }

    func vegetation(into mesh: inout DioramaMesh) {
        var rng = DioramaRandom(seed: UInt64(data.tile.x) << 32 | UInt64(data.tile.y), salt: 31)
        var placed: [DV2] = []
        func tryPlace(_ p: DV2, spacing: Double, radius: Double = 1.2) -> Bool {
            guard isFree(p, radius: radius), !isWater(p) else { return false }
            guard !placed.contains(where: { $0.distance(to: p) < spacing }) else { return false }
            placed.append(p)
            return true
        }
        func stamp(_ model: DioramaMesh, at p: DV2, z: Double, rotation: Double, scale: Double) {
            mesh.append(model, DioramaTransform(rotation: rotation, scale: DV3(scale, scale, scale), translation: DV3(p, z)))
        }

        // Coconut palms along the shoreline.
        for water in data.water {
            guard let outer = water.rings.first else { continue }
            let n = outer.count
            for i in 0..<n where !water.clipped[i] {
                let a = outer[i], b = outer[(i + 1) % n]
                let length = a.distance(to: b)
                let dir = (b - a).normalized
                let inland = dir.right
                var d = rng.range(2...config.coastPalmSpacing)
                while d < length {
                    defer { d += config.coastPalmSpacing * rng.range(0.7...1.3) }
                    let p = a + dir * d + inland * rng.range(6...14)
                    guard tryPlace(p, spacing: 5) else { continue }
                    mesh.append(library.palm, DioramaTransform(rotation: rng.range(0...6.28), scale: DV3(1, 1, rng.range(0.85...1.25)), translation: DV3(p, ground(p))))
                }
            }
        }

        // Compound gardens: trees, a hedge inside the wall, bushes and flower beds by the gate.
        for compound in compounds {
            var crng = DioramaRandom(seed: compound.building.feature.id, salt: 33)
            let z = ground(compound.building.feature.centroid)
            let area = DioramaPolygon.area(compound.ring)
            let bounds = DioramaRect.bounding(compound.ring)
            let treeCount = max(Int(area / 1000 * config.treesPer1000m2), 1)
            for _ in 0..<treeCount {
                let p = DV2(crng.range(between: bounds.minX, and: bounds.maxX), crng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(compound.ring, p), DioramaPolygon.distanceToRing(compound.ring, p) > 1.5 else { continue }
                guard !compound.building.box.expanded(by: 2.2).contains(p), tryPlace(p, spacing: 4.5) else { continue }
                let roll = crng.unit()
                if roll < 0.22 {
                    mesh.append(library.palm, DioramaTransform(rotation: crng.range(0...6.28), scale: DV3(1, 1, crng.range(0.8...1.2)), translation: DV3(p, z)))
                } else if roll < 0.32 {
                    stamp(library.flamboyant, at: p, z: z, rotation: crng.range(0...6.28), scale: 0.9)
                } else if roll < 0.42 {
                    stamp(library.cypress, at: p, z: z, rotation: crng.range(0...6.28), scale: crng.range(0.9...1.2))
                } else {
                    stamp(crng.pick(library.trees), at: p, z: z, rotation: crng.range(0...6.28), scale: crng.range(0.75...1.05))
                }
            }
            // Bushes scattered on the lawn.
            let bushCount = max(Int(area / 1000 * config.bushesPer1000m2), 2)
            for _ in 0..<bushCount {
                let p = DV2(crng.range(between: bounds.minX, and: bounds.maxX), crng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(compound.ring, p), DioramaPolygon.distanceToRing(compound.ring, p) > 0.8 else { continue }
                guard !compound.building.box.expanded(by: 0.6).contains(p), isFree(p, radius: 0.6), !isWater(p) else { continue }
                let model = crng.chance(0.4) ? crng.pick(library.flowerBushes) : crng.pick(library.bushes)
                stamp(model, at: p, z: z, rotation: crng.range(0...6.28), scale: crng.range(0.7...1.1))
            }
            // Hedge just inside standing wall edges, and bougainvillea spilling over the top.
            let n = compound.ring.count
            for i in 0..<n where !compound.gaps[i] {
                let a = compound.ring[i], b = compound.ring[(i + 1) % n]
                let length = a.distance(to: b)
                let dir = (b - a).normalized
                let inward = dir.left
                if crng.chance(config.hedgeChancePerStretch), length > 2.5 {
                    hedge(from: a + dir * 0.4 + inward * 0.75, to: b - dir * 0.4 + inward * 0.75, z: z, into: &mesh)
                }
                guard crng.chance(min(length * config.bougainvilleaChancePerMetre, 0.6)) else { continue }
                let p = a + dir * crng.range(between: 0.8, and: max(length - 0.8, 0.9))
                mesh.append(crng.pick(library.bougainvillea), DioramaTransform(rotation: dir.angle, scale: DV3(crng.range(0.8...1.3), 1, 1), translation: DV3(p, z)))
            }
            // Flower bed flanking the gate.
            if let gate = compound.gate {
                let inward = gate.direction.left
                for side in [-1.0, 1.0] {
                    let c = gate.point + gate.direction * side * 3.0 + inward * 1.2
                    guard DioramaPolygon.contains(compound.ring, c), !compound.building.box.expanded(by: 1).contains(c) else { continue }
                    flowerBed(at: c, axis: gate.direction, halfLength: 1.2, halfWidth: 0.6, z: z, rng: &crng, into: &mesh)
                }
            }
        }

        // Building fronts without a compound (apartments, shops): planters and bushes along the facade.
        for built in buildings where built.kind != .villa {
            var brng = DioramaRandom(seed: built.feature.id, salt: 35)
            let z = ground(built.feature.centroid)
            let ring = built.feature.ring
            let n = ring.count
            for i in 0..<n where !built.feature.clipped[i] {
                let a = ring[i], b = ring[(i + 1) % n]
                let length = a.distance(to: b)
                guard length > 6, brng.chance(0.55) else { continue }
                let dir = (b - a).normalized, out = dir.right
                var d = 1.6
                while d < length - 1.6 {
                    defer { d += brng.range(2.4...3.6) }
                    let p = a + dir * d + out * 0.9
                    guard isFree(p, radius: 0.5), !isWater(p) else { continue }
                    let model = brng.chance(0.5) ? brng.pick(library.flowerBushes) : brng.pick(library.bushes)
                    stamp(model, at: p, z: z, rotation: brng.range(0...6.28), scale: brng.range(0.55...0.8))
                }
            }
        }

        // Parks: mixed trees, bushes and flower drifts.
        for park in data.landuse {
            guard let outer = park.rings.first else { continue }
            let area = DioramaPolygon.area(outer)
            let bounds = DioramaRect.bounding(outer)
            let count = min(Int(area / 1000 * config.parkTreesPer1000m2), 60)
            for _ in 0..<count {
                let p = DV2(rng.range(between: bounds.minX, and: bounds.maxX), rng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(polygon: park.rings, p), tryPlace(p, spacing: 6) else { continue }
                let roll = rng.unit()
                let z = ground(p) + 0.22
                if roll < 0.12 { stamp(library.flamboyant, at: p, z: z, rotation: rng.range(0...6.28), scale: rng.range(0.8...1.1)) }
                else if roll < 0.2 { stamp(library.cypress, at: p, z: z, rotation: 0, scale: rng.range(0.9...1.3)) }
                else { stamp(rng.pick(library.trees), at: p, z: z, rotation: rng.range(0...6.28), scale: rng.range(0.8...1.2)) }
            }
            for _ in 0..<min(Int(area / 1000 * config.bushesPer1000m2), 80) {
                let p = DV2(rng.range(between: bounds.minX, and: bounds.maxX), rng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(polygon: park.rings, p), isFree(p, radius: 0.6), !isWater(p) else { continue }
                let model = rng.chance(0.45) ? rng.pick(library.flowerBushes) : rng.pick(library.bushes)
                stamp(model, at: p, z: ground(p) + 0.22, rotation: rng.range(0...6.28), scale: rng.range(0.7...1.2))
            }
        }

        // Street trees: regular rows along paved streets just behind the pavement, scattered along lanes.
        for road in data.roads {
            let length = DioramaPolygon.length(road.line)
            let spacing = road.isPaved ? 13.0 : 26.0
            var d = rng.range(4...12)
            var side = rng.chance(0.5) ? 1.0 : -1.0
            // One species per street so avenues read as designed planting.
            let species = rng.pick(library.trees)
            while d < length {
                defer { d += spacing * rng.range(0.85...1.15); side = road.isPaved ? -side : (rng.chance(0.5) ? 1.0 : -1.0) }
                guard let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let p = s.point + s.direction.right * side * (roads.corridorHalfWidth(road) + 1.5)
                guard tryPlace(p, spacing: 5) else { continue }
                stamp(road.isPaved ? species : rng.pick(library.trees), at: p, z: ground(p), rotation: rng.range(0...6.28), scale: rng.range(0.7...0.95))
            }
        }
    }

    /// Clipped box hedge between two points with a slightly uneven top.
    private func hedge(from a: DV2, to b: DV2, z: Double, into mesh: inout DioramaMesh) {
        let length = a.distance(to: b)
        guard length > 1 else { return }
        let dir = (b - a).normalized
        let segments = max(Int(length / 2.2), 1)
        let segLength = length / Double(segments)
        for k in 0..<segments {
            let c = a + dir * (segLength * (Double(k) + 0.5))
            let h = 1.0 + 0.08 * Double(k % 3)
            mesh.box(centre: c, z0: z, axis: dir, halfLength: segLength / 2 + 0.05, halfWidth: 0.42, height: h, .hedge, top: .leafLight, bevel: 0.14)
        }
    }

    /// Raised bed: soil polygon with a pale kerb and a scatter of coloured blooms.
    private func flowerBed(at c: DV2, axis: DV2, halfLength: Double, halfWidth: Double, z: Double, rng: inout DioramaRandom, into mesh: inout DioramaMesh) {
        let rect = DioramaOrientedRect(centre: c, axis: axis, halfLength: halfLength, halfWidth: halfWidth)
        mesh.extrude(rect.corners, z0: z, z1: z + 0.28, .kerb, top: .soil)
        let colours: [DioramaSwatch] = [.flowerPink, .flowerYellow, .flowerRed, .flowerWhite]
        let primary = rng.pick(colours)
        let count = Int(halfLength * halfWidth * 7)
        for _ in 0..<max(count, 4) {
            let p = c + axis * rng.range(between: -halfLength + 0.15, and: halfLength - 0.15) + axis.left * rng.range(between: -halfWidth + 0.15, and: halfWidth - 0.15)
            mesh.sphere(centre: DV3(p, z + 0.42), radii: DV3(0.16, 0.16, 0.14), .hedge, detail: 0)
            mesh.sphere(centre: DV3(p, z + 0.55), radii: DV3(0.11, 0.11, 0.1), rng.chance(0.75) ? primary : rng.pick(colours), detail: 0)
        }
    }

    func props(into mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        guard !reduceDetail else { return }
        var rng = DioramaRandom(seed: UInt64(data.tile.x) << 32 | UInt64(data.tile.y), salt: 41)

        // Vehicles: spaced along each road in the left-hand lane (Tanzania drives on the left).
        for road in data.roads {
            let length = DioramaPolygon.length(road.line)
            let density = road.isMain ? config.vehiclesPerKm : config.vehiclesPerKm * 0.45
            var d = rng.range(4...30)
            while d < length - 3 {
                defer { d += 1000 / density * rng.range(0.6...1.6) }
                guard let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let forward = rng.chance(0.5)
                let dir = forward ? s.direction : -s.direction
                let lane = dir.left * (road.width / 4)
                let p = s.point + lane
                guard data.rect.expanded(by: -3).contains(p) else { continue }
                let roll = rng.unit()
                let model: DioramaMesh
                if roll < 0.42 { model = rng.pick(library.bajaji) }
                else if roll < 0.7 { model = library.boda }
                else if roll < 0.8, road.isMain { model = library.dalaDala }
                else { model = rng.pick(library.cars) }
                mesh.append(model, DioramaTransform(rotation: dir.angle, translation: DV3(p, roadSurface(p))))
            }
        }

        // Street lamps on every paved street, alternating sides; each a real point light + halo, with a
        // small flower bed at its foot every other lamp.
        var lampRng = DioramaRandom(seed: 77, salt: 43)
        for road in data.roads where road.isPaved {
            let length = DioramaPolygon.length(road.line)
            guard length > 12 else { continue }
            var d = rng.range(6...min(config.lampSpacing, length / 2))
            var side = 1.0
            var k = 0
            while d < length - 4 {
                defer { d += config.lampSpacing; side = -side; k += 1 }
                guard lights.count < config.maxLights else { break }
                guard let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let p = s.point + s.direction.right * side * (road.width / 2 + config.pavementWidth * 0.55)
                guard isOnPavement(p) else { continue }
                let z = pavement(p)
                let rotation = (s.direction.right * -side).angle
                mesh.append(library.lamp, DioramaTransform(rotation: rotation, translation: DV3(p, z)))
                glow.append(library.lampGlow, DioramaTransform(rotation: rotation, translation: DV3(p, z)))
                let head = DV3(p, z + DioramaPropLibrary.lampHeadHeight - 0.05)
                glow.append(library.lampHalo, DioramaTransform(translation: head))
                lights.append(DioramaLight(position: head, color: SIMD3<Float>(1.0, 0.80, 0.52), radius: config.lampLightRadius, intensity: 1.0))
                if k % 2 == 1 {
                    let bed = p + s.direction * 1.6
                    if isOnPavement(bed), isOnPavement(bed + s.direction * 0.8) {
                        flowerBed(at: bed, axis: s.direction, halfLength: 0.7, halfWidth: 0.35, z: z, rng: &lampRng, into: &mesh)
                    }
                }
            }
        }

        // Kiosks near intersections: where road pieces end close to another road.
        var kioskSpots: [DV2] = []
        for road in data.roads {
            for end in [road.line[0], road.line[road.line.count - 1]] {
                guard data.rect.expanded(by: -8).contains(end), rng.chance(config.kioskChance) else { continue }
                guard let other = roads.nearest(to: end, within: 3), other.road.id != road.id else { continue }
                guard !kioskSpots.contains(where: { $0.distance(to: end) < 25 }) else { continue }
                let away = (road.line.count > 1 ? (end - (end == road.line[0] ? road.line[1] : road.line[road.line.count - 2])) : DV2(1, 0)).normalized
                let p = end + away.right * (roads.corridorHalfWidth(road) + 3.0) - away * 3
                guard isFree(p, radius: 2), !isWater(p) else { continue }
                kioskSpots.append(end)
                let rotation = (away.right * -1).angle
                let z = ground(p)
                mesh.append(rng.pick(library.kiosk), DioramaTransform(rotation: rotation, translation: DV3(p, z)))
                glow.append(library.kioskGlow, DioramaTransform(rotation: rotation, translation: DV3(p, z)))
                if lights.count < config.maxLights {
                    lights.append(DioramaLight(position: DV3(p, z + 2.0), color: SIMD3<Float>(1.0, 0.72, 0.42), radius: 6, intensity: 0.8))
                }
            }
        }

        // Dhows out on the water, well clear of the shore.
        var dhows = 0
        var attempts = 0
        while dhows < config.dhowsPerTile, attempts < 60 {
            attempts += 1
            let p = DV2(rng.range(between: data.rect.minX, and: data.rect.maxX), rng.range(between: data.rect.minY, and: data.rect.maxY))
            guard isWater(p), data.water.allSatisfy({ DioramaPolygon.distanceToRing($0.rings[0], p) > 25 }) else { continue }
            mesh.append(library.dhow, DioramaTransform(rotation: rng.range(0...6.28), translation: DV3(p, DioramaTerrain.waterSurface)))
            dhows += 1
        }
    }
}
