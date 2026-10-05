import Foundation

/// Every prop type is built once as a tiny mesh at the origin (facing +x, standing on z = 0) and
/// stamped around the tile with `DioramaMesh.append`, so tile geometry stays small.
nonisolated struct DioramaPropLibrary: Sendable {
    let palm: DioramaMesh
    let palms: [DioramaMesh]
    /// Broad-leaf shade trees in several silhouettes (lumpy round, layered, umbrella, tall, small ornamental).
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
    let canoe: DioramaMesh
    let yacht: DioramaMesh
    let playground: DioramaMesh
    let lamp: DioramaMesh
    let lampGlow: DioramaMesh
    let lampHalo: DioramaMesh
    let bollard: DioramaMesh
    let bollardGlow: DioramaMesh
    let kiosk: [DioramaMesh]
    let kioskGlow: DioramaMesh
    let bench: DioramaMesh
    let parasol: [DioramaMesh]
    let lounger: DioramaMesh

    init(config: DioramaConfig) {
        palms = [Self.makePalm(seed: 1, lean: 0.9), Self.makePalm(seed: 2, lean: 0.4), Self.makePalm(seed: 3, lean: 1.3)]
        palm = palms[0]
        trees = [
            Self.makeLumpyTree(seed: 1, scale: 1.0), Self.makeLumpyTree(seed: 2, scale: 1.2), Self.makeLumpyTree(seed: 3, scale: 0.85),
            Self.makeLumpyTree(seed: 9, scale: 1.05, bright: true),
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
        dhow = DioramaMarineModels.dhow()
        canoe = DioramaMarineModels.canoe()
        yacht = DioramaMarineModels.yacht()
        playground = DioramaPlaygroundModel.make()
        (lamp, lampGlow) = Self.makeLamp()
        lampHalo = Self.makeHalo(radius: 2.4, .lampGlow)
        (bollard, bollardGlow) = Self.makeBollard()
        kiosk = config.canopyColors.map { Self.makeKiosk(canopy: $0) }
        kioskGlow = Self.makeKioskGlow()
        bench = Self.makeBench()
        parasol = config.canopyColors.map { Self.makeParasol($0) }
        lounger = Self.makeLounger()
    }

    // MARK: Trees

    /// Trunk with a few short branches disappearing into the canopy.
    private static func trunk(_ m: inout DioramaMesh, height h: Double, radius r: Double, branches: Int, rng: inout DioramaRandom) {
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, h), r0: r, r1: r * 0.72, sides: 7, .trunk, cap: false)
        m.cylinder(centre: .zero, z0: 0, z1: 0.14, r0: r * 1.6, r1: r * 1.1, sides: 7, .trunk)
        for _ in 0..<branches {
            let a = rng.range(0...6.28)
            let dir = DV2(cos(a), sin(a))
            let z0 = h * rng.range(0.72...0.95)
            m.tube(from: DV3(0, 0, z0), to: DV3(dir * rng.range(0.9...1.5), z0 + rng.range(0.7...1.3)), r0: r * 0.45, r1: r * 0.18, sides: 4, .trunk, cap: false)
        }
    }

    /// One moulded canopy: a single sculpted mass whose surface is pushed in and out by smooth noise, so
    /// it reads as a solid tree crown (the way Apple Maps models them) rather than a pile of balls.
    /// Shading comes from the three-tone split: shadowed underside, mid sides, sunlit top.
    private static func lumpyCanopy(_ m: inout DioramaMesh, centre: DV3, radius R: Double, squash: Double, lumps: Int, palette: [DioramaSwatch], rng: inout DioramaRandom) {
        let seed = rng.next()
        let amplitude = lumps >= 10 ? 0.16 : 0.12
        let frequency = 2.6 + Double(lumps) * 0.12
        m.blob(centre: centre, radii: DV3(R * rng.range(0.92...1.05), R * rng.range(0.92...1.05), R * squash),
               seed: seed, amplitude: amplitude, frequency: frequency,
               lower: palette[0], mid: palette[1], upper: palette[2], flattenBottom: 0.35)
    }

    /// Classic shade tree: trunk, branches and a lumpy two-tone canopy.
    private static func makeLumpyTree(seed: UInt64, scale: Double, bright: Bool = false) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 21)
        let h = rng.range(2.4...3.0) * scale
        trunk(&m, height: h + 1.0, radius: 0.3 * scale, branches: 3, rng: &rng)
        let R = rng.range(2.3...2.8) * scale
        let palette: [DioramaSwatch] = bright ? [.leafMid, .leafMid, .leafLight] : [.leafDark, .leafMid, .leafMid]
        lumpyCanopy(&m, centre: DV3(0, 0, h + R * 0.8), radius: R, squash: 0.88, lumps: 10, palette: palette, rng: &rng)
        // A second, smaller mass pushed to one side breaks the symmetry like a real crown.
        let a = rng.range(0...6.28)
        lumpyCanopy(&m, centre: DV3(cos(a) * R * 0.45, sin(a) * R * 0.45, h + R * 0.55), radius: R * 0.62, squash: 0.8, lumps: 8, palette: palette, rng: &rng)
        return m
    }

    /// Three stacked tiers of lumpy foliage, like a clipped ornamental tree.
    private static func makeLayeredTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 22)
        let h = rng.range(2.0...2.6)
        trunk(&m, height: h + 2.8, radius: 0.24, branches: 2, rng: &rng)
        let tiers: [(Double, Double, [DioramaSwatch])] = [(0, 2.2, [.leafDark, .leafDark, .leafMid]), (1.7, 1.7, [.leafDark, .leafMid, .leafMid]), (3.1, 1.2, [.leafMid, .leafMid, .leafLight])]
        for (dz, r, palette) in tiers {
            let off = DV2(rng.range(-0.25...0.25), rng.range(-0.25...0.25))
            lumpyCanopy(&m, centre: DV3(off, h + dz), radius: r, squash: 0.55, lumps: 6, palette: palette, rng: &rng)
        }
        return m
    }

    /// Wide, flat umbrella canopy (acacia / neem) made of flattened lumps.
    private static func makeUmbrellaTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 23)
        let h = rng.range(3.4...4.2)
        trunk(&m, height: h, radius: 0.3, branches: 4, rng: &rng)
        for k in 0..<3 {
            let a = Double(k) / 3 * 2 * Double.pi + 0.4
            m.tube(from: DV3(0, 0, h - 0.6), to: DV3(cos(a) * 2.4, sin(a) * 2.4, h + 0.4), r0: 0.14, r1: 0.06, sides: 4, .trunk, cap: false)
        }
        lumpyCanopy(&m, centre: DV3(0, 0, h + 0.7), radius: 3.8, squash: 0.34, lumps: 12, palette: [.leafDark, .leafOlive, .leafMid], rng: &rng)
        return m
    }

    /// Tall slender tree with a narrow, ragged crown.
    private static func makeTallTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 24)
        let h = rng.range(4.8...5.8)
        trunk(&m, height: h + 1.8, radius: 0.22, branches: 2, rng: &rng)
        lumpyCanopy(&m, centre: DV3(0, 0, h + 1.5), radius: 1.6, squash: 1.6, lumps: 8, palette: [.leafDark, .leafMid, .leafMid], rng: &rng)
        return m
    }

    /// Small garden tree: short trunk, dense bright ball.
    private static func makeOrnamentalTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 25)
        let h = rng.range(1.2...1.6)
        trunk(&m, height: h + 0.5, radius: 0.14, branches: 0, rng: &rng)
        lumpyCanopy(&m, centre: DV3(0, 0, h + 1.2), radius: 1.3, squash: 1.0, lumps: 6, palette: [.leafMid, .leafMid, .leafLight], rng: &rng)
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

    /// Coconut palm: a gently curving ringed trunk, a crown of arching fronds that rise then droop, a
    /// few young fronds pointing up and a cluster of coconuts under the crown.
    private static func makePalm(seed: UInt64, lean: Double) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 28)
        let height = rng.range(7.0...8.5)
        let leanDir = DV2(1, 0.3).normalized * lean
        let segments = 7
        var prev = DV3(0, 0, 0)
        for k in 1...segments {
            let t = Double(k) / Double(segments)
            let p = DV3(leanDir * (t * t * 1.6), height * t)
            let r0 = 0.30 - 0.12 * Double(k - 1) / Double(segments), r1 = 0.30 - 0.12 * Double(k) / Double(segments)
            // Alternating slightly fatter rings give the trunk its scaly texture.
            m.tube(from: prev, to: p, r0: k % 2 == 0 ? r0 * 1.12 : r0, r1: k % 2 == 1 ? r1 * 1.12 : r1, sides: 7, .palmTrunk, cap: k == segments)
            prev = p
        }
        let top = prev + DV3(0, 0, 0.1)
        m.sphere(centre: top - DV3(0, 0, 0.15), radii: DV3(0.42, 0.42, 0.4), .trunk, detail: 0)
        let fronds = 11
        for k in 0..<fronds {
            let a = Double(k) / Double(fronds) * 2 * Double.pi + rng.range(-0.15...0.15)
            let dir = DV2(cos(a), sin(a))
            let length = rng.range(3.4...4.2)
            let droop = rng.range(1.6...2.4)
            frond(&m, from: top, direction: dir, length: length, rise: 0.9, droop: droop, width: 0.62, k % 2 == 0 ? .leafMid : .leafBright)
        }
        for k in 0..<4 {
            let a = Double(k) / 4 * 2 * Double.pi + 0.5
            let dir = DV2(cos(a), sin(a))
            frond(&m, from: top, direction: dir, length: 2.0, rise: 1.5, droop: 0.4, width: 0.4, .leafLight)
        }
        for k in 0..<5 {
            let a = Double(k) / 5 * 2 * Double.pi
            m.sphere(centre: top + DV3(cos(a) * 0.38, sin(a) * 0.38, -0.42), radii: DV3(0.2, 0.2, 0.24), .coconut, detail: 0)
        }
        return m
    }

    /// One palm frond: a tapered two-sided strip along a parabolic spine with a central rib.
    private static func frond(_ m: inout DioramaMesh, from top: DV3, direction dir: DV2, length: Double, rise: Double, droop: Double, width: Double, _ s: DioramaSwatch) {
        let steps = 6
        let across = dir.left
        var spine: [DV3] = []
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            let z = rise * t - droop * t * t
            spine.append(top + DV3(dir * (length * t), z))
        }
        m.tube(from: spine[0], to: spine[2], r0: 0.05, r1: 0.035, sides: 4, .trunk, cap: false)
        for k in 0..<steps {
            let t0 = Double(k) / Double(steps), t1 = Double(k + 1) / Double(steps)
            let w0 = width * pow(sin(Double.pi * min(t0 + 0.12, 1)), 0.7), w1 = width * pow(sin(Double.pi * min(t1 + 0.12, 1)), 0.7)
            let a = spine[k], b = spine[k + 1]
            // Leaflets fold down from the rib, so the strip is a shallow V.
            let fold = 0.14
            let l0 = a + DV3(across * w0, -fold * w0 / max(width, 0.01)), r0 = a - DV3(across * w0, fold * w0 / max(width, 0.01))
            let l1 = b + DV3(across * w1, -fold * w1 / max(width, 0.01)), r1 = b - DV3(across * w1, fold * w1 / max(width, 0.01))
            m.quad(a, b, l1, l0, s, normal: DV3(across * 0.3, 1).normalized)
            m.quad(r0, r1, b, a, s, normal: DV3(across * -0.3, 1).normalized)
            // Only one skin: reverse coplanar faces fought for depth and made the palms black.
            // Individual drooping pinnae articulate the crown instead of a solid triangular fan.
            for j in 0..<3 {
                let t = (Double(j) + 0.4) / 3
                let root = a + (b - a) * t
                let width = w0 + (w1 - w0) * t
                for side in [-1.0, 1.0] {
                    let tip = root + DV3(across * (side * width * 1.35) + dir * 0.24, -0.25 - width * 0.18)
                    m.triangle(root, tip, root + DV3(dir * 0.12, -0.025), s, normal: DV3(across * (side * 0.25), 1).normalized)
                }
            }
        }
    }

    private static func makeFlamboyant() -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: 61, salt: 29)
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, 3.4), r0: 0.34, r1: 0.22, sides: 6, .trunk, cap: false)
        for k in 0..<3 {
            let a = Double(k) / 3 * 2 * Double.pi
            m.tube(from: DV3(0, 0, 3.2), to: DV3(cos(a) * 2.2, sin(a) * 2.2, 4.6), r0: 0.16, r1: 0.08, sides: 4, .trunk, cap: false)
        }
        lumpyCanopy(&m, centre: DV3(0, 0, 5.1), radius: 4.0, squash: 0.38, lumps: 12, palette: [.leafDark, .flamboyant, .flamboyant], rng: &rng)
        return m
    }

    // MARK: Shrubs and flowers

    /// Low shrub: a cluster of 4–6 blobs.
    private static func makeBush(seed: UInt64, _ s: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 26)
        m.blob(centre: DV3(0, 0, 0.5), radii: DV3(rng.range(0.9...1.1), rng.range(0.8...1.0), 0.6), seed: seed, amplitude: 0.18, frequency: 3.2,
               lower: .leafDark, mid: s, upper: s == .leafDark ? .leafMid : s, flattenBottom: 0.6)
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
        m.sphere(centre: DV3(0, 0.1, 1.85), radii: DV3(1.4, 0.8, 0.55), color)
        m.sphere(centre: DV3(0.7, 0.4, 1.5), radii: DV3(0.7, 0.45, 0.6), color, detail: 0)
        m.sphere(centre: DV3(-0.8, 0.45, 1.35), radii: DV3(0.65, 0.4, 0.7), .leafDark, detail: 0)
        m.sphere(centre: DV3(0.1, 0.5, 1.15), radii: DV3(0.55, 0.3, 0.8), color, detail: 0)
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

    // MARK: Street furniture

    /// Height of the lamp's light source above its base.
    static let lampHeadHeight: Double = 4.6
    /// Height of a path bollard's light.
    static let bollardHeight: Double = 1.0

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

    /// Short path light for lit footways.
    private static func makeBollard() -> (DioramaMesh, DioramaMesh) {
        var m = DioramaMesh()
        var glow = DioramaMesh()
        let h = bollardHeight
        m.cylinder(centre: .zero, z0: 0, z1: h - 0.18, r0: 0.09, r1: 0.09, sides: 6, .lampPole, cap: false)
        glow.cylinder(centre: .zero, z0: h - 0.18, z1: h, r0: 0.1, r1: 0.1, sides: 6, .lampGlow, cap: false)
        m.cylinder(centre: .zero, z0: h, z1: h + 0.06, r0: 0.12, r1: 0.1, sides: 6, .lampPole)
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

    /// Park bench facing +x.
    private static func makeBench() -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: DV2(0, 0), z0: 0.42, halfLength: 0.25, halfWidth: 0.85, height: 0.07, .deckWood, bevel: 0.02)
        m.box(centre: DV2(-0.28, 0), z0: 0.5, halfLength: 0.04, halfWidth: 0.85, height: 0.45, .deckWood, bevel: 0.02)
        for y in [-0.7, 0.7] {
            m.box(centre: DV2(0, y), z0: 0, halfLength: 0.22, halfWidth: 0.04, height: 0.42, .metalCharcoal)
        }
        return m
    }

    /// Café / beach parasol with a table and two chairs.
    private static func makeParasol(_ color: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        m.cylinder(centre: .zero, z0: 0, z1: 2.3, r0: 0.04, r1: 0.04, sides: 4, .trimWhite, cap: false)
        m.tube(from: DV3(0, 0, 2.0), to: DV3(0, 0, 2.55), r0: 1.35, r1: 0.05, sides: 8, color, cap: false)
        m.cylinder(centre: .zero, z0: 0.68, z1: 0.74, r0: 0.5, r1: 0.5, sides: 8, .trimWhite)
        for a in [0.0, Double.pi] {
            let p = DV2(cos(a), sin(a)) * 0.85
            m.box(centre: p, z0: 0.3, axis: DV2(cos(a), sin(a)), halfLength: 0.22, halfWidth: 0.22, height: 0.15, .deckWood, bevel: 0.03)
            m.box(centre: p + DV2(cos(a), sin(a)) * 0.2, z0: 0.45, axis: DV2(cos(a), sin(a)), halfLength: 0.03, halfWidth: 0.22, height: 0.4, .deckWood)
        }
        return m
    }

    /// Poolside sun lounger facing +x.
    private static func makeLounger() -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: DV2(0, 0), z0: 0.3, halfLength: 0.9, halfWidth: 0.35, height: 0.1, .trimWhite, bevel: 0.03)
        m.quad(DV3(-0.9, -0.33, 0.4), DV3(-0.9, 0.33, 0.4), DV3(-0.45, 0.33, 0.95), DV3(-0.45, -0.33, 0.95), .skyBlue)
        for x in [-0.7, 0.7] {
            for y in [-0.3, 0.3] { m.box(centre: DV2(x, y), z0: 0, halfLength: 0.03, halfWidth: 0.03, height: 0.3, .trimWhite) }
        }
        return m
    }
}

/// Places vegetation and landscaping (mapped trees from OSM, coast palms, compound gardens, hedges,
/// flower beds, park planting, avenue trees) and props (vehicles, dhows, lamps as real point lights,
/// bollards along lit footways, kiosks).
nonisolated struct DioramaPropPlacer {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let library: DioramaPropLibrary
    let buildings: [DioramaBuilt]
    let compounds: [DioramaCompound]
    let reduceDetail: Bool
    let terrain: DioramaTerrain

    /// Hard-surfaced amenity areas nothing may be planted on.
    private static let hardKinds: Set<String> = ["pitch", "parking", "fuel", "pool", "terrace"]

    private func ground(_ p: DV2) -> Double { terrain.height(p) }
    private func roadSurface(_ p: DV2) -> Double { terrain.height(p) + DioramaRoadGenerator.surfaceLift }
    private func pavement(_ p: DV2) -> Double { terrain.height(p) + DioramaRoadGenerator.surfaceLift + config.kerbHeight }

    private func isOnAmenity(_ p: DV2, margin: Double) -> Bool {
        for area in data.landuse where Self.hardKinds.contains(area.kind) {
            if DioramaPolygon.contains(polygon: area.rings, p) || DioramaPolygon.distanceToRing(area.rings[0], p) < margin { return true }
        }
        return false
    }

    private func isOnPath(_ p: DV2, margin: Double) -> Bool {
        for path in data.paths {
            let line = path.line
            for i in 0..<(line.count - 1) where DioramaPolygon.distanceToSegment(p, line[i], line[i + 1]) < margin { return true }
        }
        return false
    }

    private func isFree(_ p: DV2, radius: Double) -> Bool {
        guard data.rect.expanded(by: -1).contains(p) else { return false }
        if DioramaHotelGrounds.ownsCourtyard(p, data: data, margin: radius) { return false }
        if data.pois.contains(where: { $0.kind == "playground" && $0.point.distance(to: p) < 7 + radius }) { return false }
        if roads.isOnRoad(p, margin: radius) { return false }
        for b in buildings where b.box.expanded(by: radius).contains(p) { return false }
        if isOnAmenity(p, margin: radius) || isOnPath(p, margin: radius + 0.8) { return false }
        return true
    }

    private func isWater(_ p: DV2) -> Bool {
        data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) }
    }

    private func distanceToWater(_ p: DV2) -> Double {
        data.water.map { DioramaPolygon.distanceToRing($0.rings[0], p) }.min() ?? .infinity
    }

    /// Pavement-top point: inside the pavement strip, off the carriageway, not in a building.
    private func isOnPavement(_ p: DV2) -> Bool {
        guard data.rect.expanded(by: -1).contains(p), !roads.isOnCarriageway(p, margin: 0.25) else { return false }
        for b in buildings where b.box.expanded(by: 0.4).contains(p) { return false }
        return true
    }

    private func parkLift(_ p: DV2) -> Double {
        for area in data.landuse where ["park", "common", "garden"].contains(area.kind) {
            if DioramaPolygon.contains(polygon: area.rings, p) { return DioramaGroundGenerator.parkLift }
        }
        return 0
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
        func shadeTree(_ r: inout DioramaRandom) -> DioramaMesh {
            let roll = r.unit()
            if roll < 0.55 { return r.pick(Array(library.trees[0..<4])) }
            if roll < 0.68 { return r.pick(Array(library.trees[4..<6])) }
            if roll < 0.8 { return library.trees[6] }
            if roll < 0.9 { return library.trees[7] }
            return library.flamboyant
        }

        // Trees surveyed in OpenStreetMap go exactly where they are: palms by the water and around the
        // hotel grounds, shade trees inland.
        for p in data.trees {
            var trng = DioramaRandom(seed: UInt64(bitPattern: Int64((p.x * 10).rounded())) &* 31 &+ UInt64(bitPattern: Int64((p.y * 10).rounded())), salt: 32)
            guard tryPlace(p, spacing: 2.2, radius: 0.7) else { continue }
            let z = ground(p) + parkLift(p)
            let nearWater = distanceToWater(p) < 45
            if nearWater ? trng.chance(0.7) : trng.chance(0.12) {
                mesh.append(trng.pick(library.palms), DioramaTransform(rotation: trng.range(0...6.28), scale: DV3(1, 1, trng.range(0.85...1.2)), translation: DV3(p, z)))
            } else {
                stamp(shadeTree(&trng), at: p, z: z, rotation: trng.range(0...6.28), scale: trng.range(0.8...1.1))
            }
        }

        // Coconut palms along the shoreline between the mapped ones.
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
                    let p = a + dir * d + inland * rng.range(5...12)
                    guard tryPlace(p, spacing: 6) else { continue }
                    mesh.append(rng.pick(library.palms), DioramaTransform(rotation: rng.range(0...6.28), scale: DV3(1, 1, rng.range(0.85...1.25)), translation: DV3(p, ground(p))))
                }
            }
        }

        // Compound gardens: a tree or two, bushes, a hedge inside plaster walls and flower beds by the gate.
        for compound in compounds {
            var crng = DioramaRandom(seed: compound.building.feature.id, salt: 33)
            let z = ground(compound.building.feature.centroid)
            let area = DioramaPolygon.area(compound.ring)
            let bounds = DioramaRect.bounding(compound.ring)
            func blocksAccess(_ p: DV2, radius: Double) -> Bool {
                guard let gate = compound.gate else { return false }
                return DioramaPolygon.distanceToSegment(p, gate.point, compound.building.entrance) < config.gateWidth / 2 + radius
            }
            let treeCount = max(Int(area / 1000 * config.treesPer1000m2), 1)
            for _ in 0..<treeCount {
                let p = DV2(crng.range(between: bounds.minX, and: bounds.maxX), crng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(compound.ring, p), DioramaPolygon.distanceToRing(compound.ring, p) > 1.4 else { continue }
                guard !blocksAccess(p, radius: 1.5), !compound.building.box.expanded(by: 2.0).contains(p), tryPlace(p, spacing: 5) else { continue }
                let roll = crng.unit()
                if roll < 0.2 {
                    mesh.append(crng.pick(library.palms), DioramaTransform(rotation: crng.range(0...6.28), scale: DV3(1, 1, crng.range(0.8...1.1)), translation: DV3(p, z)))
                } else if roll < 0.3 {
                    stamp(library.cypress, at: p, z: z, rotation: crng.range(0...6.28), scale: crng.range(0.9...1.2))
                } else {
                    stamp(shadeTree(&crng), at: p, z: z, rotation: crng.range(0...6.28), scale: crng.range(0.7...0.95))
                }
            }
            let bushCount = max(Int(area / 1000 * config.bushesPer1000m2), 2)
            for _ in 0..<bushCount {
                let p = DV2(crng.range(between: bounds.minX, and: bounds.maxX), crng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(compound.ring, p), DioramaPolygon.distanceToRing(compound.ring, p) > 0.8 else { continue }
                guard !blocksAccess(p, radius: 0.6), !compound.building.box.expanded(by: 0.6).contains(p), isFree(p, radius: 0.6), !isWater(p) else { continue }
                let model = crng.chance(0.4) ? crng.pick(library.flowerBushes) : crng.pick(library.bushes)
                stamp(model, at: p, z: z, rotation: crng.range(0...6.28), scale: crng.range(0.7...1.1))
            }
            let n = compound.ring.count
            for i in 0..<n where !compound.gaps[i] {
                let a = compound.ring[i], b = compound.ring[(i + 1) % n]
                let length = a.distance(to: b)
                let dir = (b - a).normalized
                let inward = dir.left
                guard !blocksAccess((a + b) * 0.5, radius: 0.7) else { continue }
                if !compound.isHedge, crng.chance(config.hedgeChancePerStretch), length > 2.0 {
                    hedge(from: a + dir * 0.3 + inward * 0.7, to: b - dir * 0.3 + inward * 0.7, z: z, into: &mesh)
                }
                guard !compound.isHedge, crng.chance(min(length * config.bougainvilleaChancePerMetre, 0.5)) else { continue }
                let p = a + dir * crng.range(between: 0.6, and: max(length - 0.6, 0.7))
                mesh.append(crng.pick(library.bougainvillea), DioramaTransform(rotation: dir.angle, scale: DV3(crng.range(0.7...1.1), 1, 1), translation: DV3(p, z)))
            }
            if let gate = compound.gate {
                let inward = gate.direction.left
                for side in [-1.0, 1.0] {
                    let c = gate.point + gate.direction * side * 2.7 + inward * 1.1
                    guard DioramaPolygon.contains(compound.ring, c), !compound.building.box.expanded(by: 1).contains(c) else { continue }
                    flowerBed(at: c, axis: gate.direction, halfLength: 1.0, halfWidth: 0.5, z: z, rng: &crng, into: &mesh)
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
        for park in data.landuse where ["park", "common", "garden"].contains(park.kind) {
            guard let outer = park.rings.first else { continue }
            let area = DioramaPolygon.area(outer)
            let bounds = DioramaRect.bounding(outer)
            let count = min(Int(area / 1000 * config.parkTreesPer1000m2), 40)
            for _ in 0..<count {
                let p = DV2(rng.range(between: bounds.minX, and: bounds.maxX), rng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(polygon: park.rings, p), tryPlace(p, spacing: 6) else { continue }
                let z = ground(p) + DioramaGroundGenerator.parkLift
                if rng.chance(0.1) { stamp(library.cypress, at: p, z: z, rotation: 0, scale: rng.range(0.9...1.3)) }
                else { stamp(shadeTree(&rng), at: p, z: z, rotation: rng.range(0...6.28), scale: rng.range(0.8...1.15)) }
            }
            for _ in 0..<min(Int(area / 1000 * config.bushesPer1000m2), 60) {
                let p = DV2(rng.range(between: bounds.minX, and: bounds.maxX), rng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(polygon: park.rings, p), isFree(p, radius: 0.6), !isWater(p) else { continue }
                let model = rng.chance(0.45) ? rng.pick(library.flowerBushes) : rng.pick(library.bushes)
                stamp(model, at: p, z: ground(p) + DioramaGroundGenerator.parkLift, rotation: rng.range(0...6.28), scale: rng.range(0.7...1.2))
            }
        }

        // Avenue trees along paved streets where the survey has none: one species per street.
        for road in data.roads {
            let length = DioramaPolygon.length(road.line)
            let spacing = road.isPaved ? config.streetTreeSpacing : config.streetTreeSpacing * 2
            var d = rng.range(4...12)
            var side = rng.chance(0.5) ? 1.0 : -1.0
            let species = rng.pick(Array(library.trees[0..<4]))
            while d < length {
                defer { d += spacing * rng.range(0.85...1.15); side = road.isPaved ? -side : (rng.chance(0.5) ? 1.0 : -1.0) }
                guard let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let p = s.point + s.direction.right * side * (roads.corridorHalfWidth(road) + 1.6)
                guard tryPlace(p, spacing: 7) else { continue }
                stamp(road.isPaved ? species : shadeTree(&rng), at: p, z: ground(p), rotation: rng.range(0...6.28), scale: rng.range(0.7...0.9))
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
            let h = 0.9 + 0.08 * Double(k % 3)
            mesh.box(centre: c, z0: z, axis: dir, halfLength: segLength / 2 + 0.05, halfWidth: 0.4, height: h, .hedge, top: .leafLight, bevel: 0.14)
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

        // Bollard lights along lit footways and the pier.
        for path in data.paths where path.isLit {
            let length = DioramaPolygon.length(path.line)
            guard length > 6 else { continue }
            var d = 3.0
            var side = 1.0
            while d < length - 2 {
                defer { d += 9; side = -side }
                guard lights.count < config.maxLights else { break }
                guard let s = DioramaPolygon.sample(path.line, at: d) else { break }
                let p = s.point + s.direction.right * side * 1.1
                guard data.rect.expanded(by: -1).contains(p), !roads.isOnCarriageway(p, margin: 0.3) else { continue }
                guard !buildings.contains(where: { $0.box.expanded(by: 0.3).contains(p) }) else { continue }
                let z = path.kind == "pier" ? DioramaAmenityGenerator.pierDeck : ground(p) + DioramaAmenityGenerator.pathLift
                mesh.append(library.bollard, DioramaTransform(translation: DV3(p, z)))
                glow.append(library.bollardGlow, DioramaTransform(translation: DV3(p, z)))
                lights.append(DioramaLight(position: DV3(p, z + DioramaPropLibrary.bollardHeight), color: SIMD3<Float>(1.0, 0.84, 0.6), radius: 5, intensity: 0.55))
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

        // Deterministic mixed anchorage; keep complete hulls apart and away from mapped piers.
        var vesselSpots: [DV2] = []
        var dhows = 0
        var attempts = 0
        while dhows < config.dhowsPerTile, attempts < 60 {
            attempts += 1
            let p = DV2(rng.range(between: data.rect.minX, and: data.rect.maxX), rng.range(between: data.rect.minY, and: data.rect.maxY))
            guard isWater(p), data.water.allSatisfy({ DioramaPolygon.distanceToRing($0.rings[0], p) > 25 }),
                  !vesselSpots.contains(where: { $0.distance(to: p) < 22 }), !isOnPath(p, margin: 18) else { continue }
            vesselSpots.append(p)
            let model = dhows % 3 == 0 ? library.yacht : (dhows % 3 == 1 ? library.canoe : library.dhow)
            let heading = rng.range(0...6.28), direction = DV2(cos(heading), sin(heading))
            mesh.append(model, DioramaTransform(rotation: heading, translation: DV3(p, DioramaTerrain.waterSurface)))
            let buoy = p + direction * 8
            mesh.sphere(centre: DV3(buoy, DioramaTerrain.waterSurface + 0.12), radii: DV3(0.25, 0.25, 0.2), .sailCream)
            mesh.tube(from: DV3(p + direction * (dhows % 3 == 0 ? 5.5 : 2.8), DioramaTerrain.waterSurface + 0.5), to: DV3(buoy, DioramaTerrain.waterSurface + 0.16), r0: 0.02, r1: 0.02, sides: 4, .sailCream)
            dhows += 1
        }
    }
}
