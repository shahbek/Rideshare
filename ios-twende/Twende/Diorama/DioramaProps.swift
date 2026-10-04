import Foundation

/// Every prop type is built once as a tiny mesh at the origin (facing +x, standing on z = 0) and
/// stamped around the tile with `DioramaMesh.append`, so tile geometry stays small.
nonisolated struct DioramaPropLibrary: Sendable {
    let palm: DioramaMesh
    let mango: [DioramaMesh]
    let flamboyant: DioramaMesh
    let bougainvillea: [DioramaMesh]
    let bajaji: [DioramaMesh]
    let boda: DioramaMesh
    let dalaDala: DioramaMesh
    let cars: [DioramaMesh]
    let dhow: DioramaMesh
    let lamp: DioramaMesh
    let lampGlow: DioramaMesh
    let kiosk: [DioramaMesh]
    let kioskGlow: DioramaMesh

    init(config: DioramaConfig) {
        palm = Self.makePalm()
        mango = [Self.makeShadeTree(seed: 1), Self.makeShadeTree(seed: 2), Self.makeShadeTree(seed: 3)]
        flamboyant = Self.makeFlamboyant()
        bougainvillea = [Self.makeBougainvillea(.bougainvilleaMagenta), Self.makeBougainvillea(.bougainvilleaOrange)]
        bajaji = [Self.makeBajaji(.bajajiBlue), Self.makeBajaji(.bajajiRed), Self.makeBajaji(.bajajiYellow)]
        boda = Self.makeBoda()
        dalaDala = Self.makeDalaDala()
        cars = [Self.makeCar(.carSilver), Self.makeCar(.carRed), Self.makeCar(.carWhite)]
        dhow = Self.makeDhow()
        (lamp, lampGlow) = Self.makeLamp()
        kiosk = config.canopyColors.map { Self.makeKiosk(canopy: $0) }
        kioskGlow = Self.makeKioskGlow()
    }

    // MARK: Vegetation

    private static func makePalm() -> DioramaMesh {
        var m = DioramaMesh()
        let top = DV3(0.9, 0.3, 7.5)
        // Gently leaning segmented trunk.
        var prev = DV3(0, 0, 0)
        for k in 1...4 {
            let t = Double(k) / 4
            let p = DV3(top.x * t * t, top.y * t * t, top.z * t)
            m.tube(from: prev, to: p, r0: 0.28 - 0.04 * Double(k - 1), r1: 0.24 - 0.04 * Double(k - 1), sides: 6, .palmTrunk, cap: k == 4)
            prev = p
        }
        // Crown of drooping fronds (flat tapered blades).
        for k in 0..<8 {
            let a = Double(k) / 8 * 2 * Double.pi + 0.3
            let dir = DV2(cos(a), sin(a))
            let tip = top + DV3(dir * 2.8, -1.2)
            let mid = top + DV3(dir * 1.5, 0.5)
            let w = dir.left * 0.45
            m.quad(top + DV3(w * 0.4, 0), mid + DV3(w, 0), tip, mid - DV3(w, 0), .leafMid, normal: .up)
            m.quad(top + DV3(w * 0.4, 0), mid + DV3(w, 0), tip, mid - DV3(w, 0), .leafDark, normal: DV3(0, 0, -1))
        }
        for k in 0..<3 {
            let a = Double(k) / 3 * 2 * Double.pi
            m.sphere(centre: top + DV3(cos(a) * 0.35, sin(a) * 0.35, -0.3), radii: DV3(0.22, 0.22, 0.26), .coconut, detail: 0)
        }
        return m
    }

    private static func makeShadeTree(seed: UInt64) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 21)
        let h = rng.range(3.2...4.2)
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, h), r0: 0.38, r1: 0.26, sides: 6, .trunk, cap: false)
        // Blobby clustered canopy.
        m.sphere(centre: DV3(0, 0, h + 1.6), radii: DV3(3.2, 3.0, 2.3), .leafMid)
        let blobs = rng.int(4...6)
        for k in 0..<blobs {
            let a = Double(k) / Double(blobs) * 2 * Double.pi + rng.range(0...0.5)
            let r = rng.range(1.4...2.2)
            let s = rng.range(1.3...1.9)
            m.sphere(centre: DV3(cos(a) * r, sin(a) * r, h + rng.range(0.9...2.4)), radii: DV3(s, s, s * 0.8), k % 2 == 0 ? .leafDark : .leafLight, detail: 0)
        }
        m.sphere(centre: DV3(0.3, -0.2, h + 3.1), radii: DV3(1.6, 1.6, 1.2), .leafLight, detail: 0)
        return m
    }

    private static func makeFlamboyant() -> DioramaMesh {
        var m = DioramaMesh()
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, 3.4), r0: 0.34, r1: 0.22, sides: 6, .trunk, cap: false)
        for k in 0..<3 {
            let a = Double(k) / 3 * 2 * Double.pi
            m.tube(from: DV3(0, 0, 3.2), to: DV3(cos(a) * 2.2, sin(a) * 2.2, 4.6), r0: 0.16, r1: 0.08, sides: 4, .trunk, cap: false)
        }
        // Umbrella-shaped, wide and flat, red-orange.
        m.sphere(centre: DV3(0, 0, 5.0), radii: DV3(4.4, 4.2, 1.3), .flamboyant)
        m.sphere(centre: DV3(0.8, 0.5, 5.5), radii: DV3(2.4, 2.2, 1.0), .flamboyant, detail: 0)
        m.sphere(centre: DV3(-1.2, -0.6, 4.6), radii: DV3(2.0, 2.0, 0.9), .leafDark, detail: 0)
        return m
    }

    private static func makeBougainvillea(_ color: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        // A mound spilling over a 2.2 m wall: sits at z 1.9 and droops down the outside (+y side).
        m.sphere(centre: DV3(0, 0.1, 2.35), radii: DV3(1.5, 0.9, 0.6), color)
        m.sphere(centre: DV3(0.7, 0.45, 1.9), radii: DV3(0.8, 0.5, 0.7), color, detail: 0)
        m.sphere(centre: DV3(-0.8, 0.5, 1.75), radii: DV3(0.7, 0.45, 0.8), .leafDark, detail: 0)
        m.sphere(centre: DV3(0.1, 0.55, 1.5), radii: DV3(0.6, 0.35, 0.9), color, detail: 0)
        return m
    }

    // MARK: Vehicles

    private static func makeBajaji(_ color: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        // Cabin: a rounded box, open sides implied by dark glass panels.
        m.box(centre: DV2(0.1, 0), z0: 0.35, halfLength: 1.1, halfWidth: 0.65, height: 0.55, color, top: color, bevel: 0.1, bottom: true)
        m.box(centre: DV2(-0.1, 0), z0: 0.9, halfLength: 0.8, halfWidth: 0.6, height: 0.75, .glass, top: color, bevel: 0.08)
        // Canopy roof slightly larger, then a tiny front nose.
        m.box(centre: DV2(-0.05, 0), z0: 1.62, halfLength: 0.95, halfWidth: 0.72, height: 0.12, color, bevel: 0.05)
        m.tube(from: DV3(0.9, 0, 0.9), to: DV3(1.25, 0, 0.55), r0: 0.42, r1: 0.25, sides: 6, color)
        // Three wheels.
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
        // Rider: a chunky blob with a helmet.
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
        // Painted colour band and route stripe, the classic dala-dala look.
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
        m.box(centre: DV2(0, 0), z0: 0.4, halfLength: 2.1, halfWidth: 0.9, height: 0.65, color, top: color, bevel: 0.14, bottom: true)
        m.box(centre: DV2(-0.25, 0), z0: 1.05, halfLength: 1.15, halfWidth: 0.8, height: 0.6, .glass, top: color, bevel: 0.14)
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
        // Hull: a tapered box with raised bow and stern, deck on top.
        let hull: [DV2] = [DV2(-3.2, 0), DV2(-2.2, -0.9), DV2(1.6, -1.0), DV2(3.4, -0.3), DV2(3.4, 0.3), DV2(1.6, 1.0), DV2(-2.2, 0.9)]
        m.extrude(hull, z0: -0.1, z1: 0.9, .hullWood, top: .deckWood)
        m.polygon(hull, z: -0.1, .hullWood, dark: true, facingUp: false)
        // Mast, raked yard and lateen (triangular) sail.
        m.tube(from: DV3(0.3, 0, 0.9), to: DV3(0.3, 0, 6.2), r0: 0.08, r1: 0.05, sides: 4, .trunk)
        m.tube(from: DV3(-3.0, 0, 2.2), to: DV3(2.6, 0, 7.4), r0: 0.06, r1: 0.04, sides: 4, .trunk)
        m.triangle(DV3(-2.9, 0.02, 2.3), DV3(2.5, 0.02, 7.2), DV3(1.2, 0.02, 1.4), .sailCream, normal: DV3(0, 1, 0))
        m.triangle(DV3(-2.9, -0.02, 2.3), DV3(2.5, -0.02, 7.2), DV3(1.2, -0.02, 1.4), .sailCream, normal: DV3(0, -1, 0))
        return m
    }

    // MARK: Street furniture

    private static func makeLamp() -> (DioramaMesh, DioramaMesh) {
        var m = DioramaMesh()
        var glow = DioramaMesh()
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, 7.5), r0: 0.14, r1: 0.09, sides: 5, .lampPole, cap: false)
        m.tube(from: DV3(0, 0, 7.5), to: DV3(1.6, 0, 8.1), r0: 0.08, r1: 0.07, sides: 4, .lampPole)
        m.box(centre: DV2(1.7, 0), z0: 7.85, halfLength: 0.45, halfWidth: 0.22, height: 0.22, .lampPole, bevel: 0.04)
        glow.box(centre: DV2(1.7, 0), z0: 7.7, halfLength: 0.38, halfWidth: 0.17, height: 0.16, .lampGlow, bottom: true)
        return (m, glow)
    }

    private static func makeKiosk(canopy: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        // Counter, back wall, four posts and a sloping canopy; goods as coloured blocks.
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

/// Places vegetation (coast palms, compound shade trees, flamboyants, bougainvillea on walls) and props
/// (vehicles on roads, dhows on the water, lamps on main roads, kiosks near intersections).
nonisolated struct DioramaPropPlacer {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let library: DioramaPropLibrary
    let buildings: [DioramaBuilt]
    let compounds: [DioramaCompound]
    let reduceDetail: Bool

    private func isFree(_ p: DV2, radius: Double) -> Bool {
        guard data.rect.expanded(by: -1).contains(p) else { return false }
        if roads.isOnRoad(p, margin: radius) { return false }
        for b in buildings where b.box.expanded(by: radius).contains(p) { return false }
        return true
    }

    private func isWater(_ p: DV2) -> Bool {
        data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) }
    }

    func vegetation(into mesh: inout DioramaMesh) {
        var rng = DioramaRandom(seed: UInt64(data.tile.x) << 32 | UInt64(data.tile.y), salt: 31)
        var placed: [DV2] = []
        func tryPlace(_ p: DV2, spacing: Double) -> Bool {
            guard isFree(p, radius: 1.2), !isWater(p) else { return false }
            guard !placed.contains(where: { $0.distance(to: p) < spacing }) else { return false }
            placed.append(p)
            return true
        }

        // Coconut palms along the shoreline (inland side of real water edges).
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
                    mesh.append(library.palm, DioramaTransform(rotation: rng.range(0...6.28), scale: DV3(1, 1, rng.range(0.85...1.25)), translation: DV3(p, 0)))
                }
            }
        }

        // Shade trees and the odd palm inside compounds.
        for compound in compounds {
            var crng = DioramaRandom(seed: compound.building.feature.id, salt: 33)
            let area = DioramaPolygon.area(compound.ring)
            let count = max(Int(area / 1000 * config.treesPer1000m2), 1)
            let bounds = DioramaRect.bounding(compound.ring)
            for _ in 0..<count {
                let p = DV2(crng.range(bounds.minX...bounds.maxX), crng.range(bounds.minY...bounds.maxY))
                guard DioramaPolygon.contains(compound.ring, p), DioramaPolygon.distanceToRing(compound.ring, p) > 1.5 else { continue }
                guard !compound.building.box.expanded(by: 2.2).contains(p), tryPlace(p, spacing: 4.5) else { continue }
                let roll = crng.unit()
                if roll < 0.3 {
                    mesh.append(library.palm, DioramaTransform(rotation: crng.range(0...6.28), scale: DV3(1, 1, crng.range(0.8...1.2)), translation: DV3(p, 0)))
                } else if roll < 0.42 {
                    mesh.append(library.flamboyant, DioramaTransform(rotation: crng.range(0...6.28), scale: DV3(0.9, 0.9, 0.9), translation: DV3(p, 0)))
                } else {
                    let s = crng.range(0.75...1.1)
                    mesh.append(crng.pick(library.mango), DioramaTransform(rotation: crng.range(0...6.28), scale: DV3(s, s, s), translation: DV3(p, 0)))
                }
            }
            // Bougainvillea spilling over the walls.
            let n = compound.ring.count
            for i in 0..<n where !compound.gaps[i] {
                let a = compound.ring[i], b = compound.ring[(i + 1) % n]
                let length = a.distance(to: b)
                guard crng.chance(min(length * config.bougainvilleaChancePerMetre, 0.6)) else { continue }
                let dir = (b - a).normalized
                let p = a + dir * crng.range(0.8...max(length - 0.8, 0.9))
                mesh.append(crng.pick(library.bougainvillea), DioramaTransform(rotation: dir.angle, scale: DV3(crng.range(0.8...1.3), 1, 1), translation: DV3(p, 0)))
            }
        }

        // Parks and open green space.
        for park in data.landuse {
            guard let outer = park.rings.first else { continue }
            let area = DioramaPolygon.area(outer)
            let count = min(Int(area / 1000 * config.parkTreesPer1000m2), 60)
            let bounds = DioramaRect.bounding(outer)
            for _ in 0..<count {
                let p = DV2(rng.range(bounds.minX...bounds.maxX), rng.range(bounds.minY...bounds.maxY))
                guard DioramaPolygon.contains(polygon: park.rings, p), tryPlace(p, spacing: 6) else { continue }
                let s = rng.range(0.8...1.2)
                mesh.append(rng.chance(0.15) ? library.flamboyant : rng.pick(library.mango), DioramaTransform(rotation: rng.range(0...6.28), scale: DV3(s, s, s), translation: DV3(p, 0)))
            }
        }

        // Scattered street trees along unpaved lanes.
        for road in data.roads where !road.isMain {
            let length = DioramaPolygon.length(road.line)
            var d = rng.range(5...25)
            while d < length {
                defer { d += rng.range(18...40) }
                guard let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let side = rng.chance(0.5) ? 1.0 : -1.0
                let p = s.point + s.direction.right * side * (road.width / 2 + rng.range(2.5...4.5))
                guard tryPlace(p, spacing: 6) else { continue }
                let scale = rng.range(0.7...1.0)
                mesh.append(rng.pick(library.mango), DioramaTransform(rotation: rng.range(0...6.28), scale: DV3(scale, scale, scale), translation: DV3(p, 0)))
            }
        }
    }

    func props(into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        guard !reduceDetail else { return }
        var rng = DioramaRandom(seed: UInt64(data.tile.x) << 32 | UInt64(data.tile.y), salt: 41)

        // Vehicles: spaced along each road, offset to the left-hand lane (Tanzania drives on the left).
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
                mesh.append(model, DioramaTransform(rotation: dir.angle, translation: DV3(p, 0)))
            }
        }

        // Street lamps on main roads, alternating sides, lit at dusk/night.
        for road in data.roads where road.isMain {
            let length = DioramaPolygon.length(road.line)
            var d = rng.range(6...config.lampSpacing)
            var side = 1.0
            while d < length {
                defer { d += config.lampSpacing; side = -side }
                guard let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let p = s.point + s.direction.right * side * (road.width / 2 + 1.2)
                guard isFree(p, radius: 0.5) else { continue }
                let rotation = (s.direction.right * -side).angle
                mesh.append(library.lamp, DioramaTransform(rotation: rotation, translation: DV3(p, 0)))
                glow.append(library.lampGlow, DioramaTransform(rotation: rotation, translation: DV3(p, 0)))
            }
        }

        // Kiosks and stalls near intersections: where road pieces end close to another road.
        var kioskSpots: [DV2] = []
        for road in data.roads {
            for end in [road.line[0], road.line[road.line.count - 1]] {
                guard data.rect.expanded(by: -8).contains(end), rng.chance(config.kioskChance) else { continue }
                guard let other = roads.nearest(to: end, within: 3), other.road.id != road.id else { continue }
                guard !kioskSpots.contains(where: { $0.distance(to: end) < 25 }) else { continue }
                let away = (road.line.count > 1 ? (end - (end == road.line[0] ? road.line[1] : road.line[road.line.count - 2])) : DV2(1, 0)).normalized
                let p = end + away.right * (road.width / 2 + 3.2) - away * 3
                guard isFree(p, radius: 2), !isWater(p) else { continue }
                kioskSpots.append(end)
                let rotation = (away.right * -1).angle
                mesh.append(rng.pick(library.kiosk), DioramaTransform(rotation: rotation, translation: DV3(p, 0)))
                glow.append(library.kioskGlow, DioramaTransform(rotation: rotation, translation: DV3(p, 0)))
            }
        }

        // Dhows out on the water, well clear of the shore.
        var dhows = 0
        var attempts = 0
        while dhows < config.dhowsPerTile, attempts < 60 {
            attempts += 1
            let p = DV2(rng.range(data.rect.minX...data.rect.maxX), rng.range(data.rect.minY...data.rect.maxY))
            guard isWater(p), data.water.allSatisfy({ DioramaPolygon.distanceToRing($0.rings[0], p) > 25 }) else { continue }
            mesh.append(library.dhow, DioramaTransform(rotation: rng.range(0...6.28), translation: DV3(p, 0)))
            dhows += 1
        }
    }
}
