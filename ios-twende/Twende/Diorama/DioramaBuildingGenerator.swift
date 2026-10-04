import Foundation

nonisolated enum DioramaBuildingKind: Sendable {
    case villa, apartments, commercial
}

/// What the other generators need to know about a built house.
nonisolated struct DioramaBuilt: Sendable {
    let feature: DioramaBuildingFeature
    let kind: DioramaBuildingKind
    let floors: Int
    let height: Double
    let box: DioramaOrientedRect
    let flatRoof: Bool
    let wallColor: DioramaSwatch
}

/// Turns footprints into toy houses: bevelled plaster volumes, hipped metal roofs, verandas, water tanks,
/// framed windows (lit ones go to the emissive mesh), Swahili doors and barazas; apartment blocks with
/// balcony bands; shopfronts with painted sign panels and awnings along main roads.
nonisolated struct DioramaBuildingGenerator {
    let config: DioramaConfig
    let roads: DioramaRoadIndex

    func classify(_ f: DioramaBuildingFeature) -> (DioramaBuildingKind, Int) {
        var rng = DioramaRandom(seed: f.id, salt: 1)
        let floors: Int
        if let h = f.height {
            floors = max(1, Int((h / config.floorHeight).rounded()))
        } else if f.area < 150 {
            floors = 1
        } else if f.area < 400 {
            floors = rng.int(1...2)
        } else if f.area < 1200 {
            floors = rng.int(2...4)
        } else {
            floors = rng.int(4...8)
        }
        let type = f.type.lowercased()
        let nearMain = roads.nearest(to: f.centroid, within: 30).map { $0.road.isMain } ?? false
        if ["apartments", "hotel", "office", "dormitory"].contains(type) || floors >= 3 && f.area >= 250 {
            return (.apartments, max(floors, 3))
        }
        if ["commercial", "retail", "shop", "supermarket", "kiosk"].contains(type) || (nearMain && f.area > 120 && rng.chance(0.55)) {
            return (.commercial, min(max(floors, 1), 3))
        }
        return (.villa, min(floors, 2))
    }

    func build(_ f: DioramaBuildingFeature, into mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: Bool) -> DioramaBuilt {
        var rng = DioramaRandom(seed: f.id, salt: 2)
        let (kind, floors) = classify(f)
        let height = Double(floors) * config.floorHeight
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        let (ring, flags) = DioramaPolygon.chamfer(f.ring, flags: f.clipped, by: config.bevel)

        let wallColor: DioramaSwatch
        switch kind {
        case .villa: wallColor = rng.pick(config.wallColors)
        case .apartments: wallColor = rng.pick(config.apartmentWallColors)
        case .commercial: wallColor = rng.pick([.whitewash, .cream, .sunflower, .skyBlue, .mint])
        }

        mesh.extrude(ring, z0: 0, z1: height, wallColor, ao: config.aoBandHeight, skip: flags)

        var flatRoof = kind != .villa
        if kind == .villa, rng.chance(1 - config.hipRoofShare) { flatRoof = true }
        // Hipped roofs need a footprint that is roughly its own rectangle; sprawling L-shapes stay flat.
        if !flatRoof, f.area / max(box.area, 1) < 0.62 { flatRoof = true }

        if flatRoof {
            mesh.polygon(ring, z: height, kind == .villa ? .roofConcrete : wallColor)
            parapet(ring, flags: flags, z: height, color: wallColor, into: &mesh)
        } else {
            hipRoof(box, z: height, color: roofColor(&rng), into: &mesh)
        }

        switch kind {
        case .villa:
            villaDetails(f, ring: ring, flags: flags, box: box, height: height, floors: floors, wall: wallColor, flatRoof: flatRoof, rng: &rng, into: &mesh, glow: &glow, lights: lights)
        case .apartments:
            apartmentDetails(ring: ring, flags: flags, height: height, floors: floors, wall: wallColor, rng: &rng, into: &mesh, glow: &glow, lights: lights)
        case .commercial:
            commercialDetails(f, ring: ring, flags: flags, height: height, floors: floors, rng: &rng, into: &mesh, glow: &glow, lights: lights)
        }

        roofFurniture(ring: ring, box: box, height: height, flatRoof: flatRoof, kind: kind, rng: &rng, into: &mesh)
        return DioramaBuilt(feature: f, kind: kind, floors: floors, height: height, box: box, flatRoof: flatRoof, wallColor: wallColor)
    }

    private func roofColor(_ rng: inout DioramaRandom) -> DioramaSwatch {
        rng.chance(config.terracottaRoofShare) ? .roofTerracotta : rng.pick(config.metalRoofColors)
    }

    // MARK: Roofs

    private func hipRoof(_ box: DioramaOrientedRect, z: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let r = box.expanded(by: config.roofOverhang)
        let pitch = config.roofPitchDegrees * Double.pi / 180
        let rise = min(r.halfWidth * tan(pitch), 3.2)
        let ridgeHalf = max(r.halfLength - r.halfWidth, 0.3)
        let c = r.corners
        let eave = z + 0.18
        let ridgeA = DV3(r.centre - r.axis * ridgeHalf, eave + rise)
        let ridgeB = DV3(r.centre + r.axis * ridgeHalf, eave + rise)
        // Fascia board under the eave.
        mesh.extrude(c, z0: z - 0.05, z1: eave, .trimWhite)
        mesh.polygon(c, z: z - 0.05, color, dark: true, facingUp: false)
        // Long slopes.
        mesh.quad(DV3(c[0], eave), DV3(c[1], eave), ridgeB, ridgeA, color)
        mesh.quad(DV3(c[2], eave), DV3(c[3], eave), ridgeA, ridgeB, color)
        // Hip ends.
        mesh.triangle(DV3(c[1], eave), DV3(c[2], eave), ridgeB, color)
        mesh.triangle(DV3(c[3], eave), DV3(c[0], eave), ridgeA, color)
        // Ridge cap.
        mesh.tube(from: ridgeA - DV3(r.axis, 0) * 0.2, to: ridgeB + DV3(r.axis, 0) * 0.2, r0: 0.16, r1: 0.16, sides: 5, .trimWhite)
    }

    private func parapet(_ ring: [DV2], flags: [Bool], z: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard let inner = DioramaPolygon.offset(ring, by: -0.3) else { return }
        let n = ring.count
        for i in 0..<n where !flags[i] {
            let a = ring[i], b = ring[(i + 1) % n]
            let ia = inner[i], ib = inner[(i + 1) % n]
            mesh.wall(a, b, z0: z, z1: z + 0.8, color)
            mesh.wall(ib, ia, z0: z, z1: z + 0.8, color)
            mesh.quad(DV3(a, z + 0.8), DV3(b, z + 0.8), DV3(ib, z + 0.8), DV3(ia, z + 0.8), .trimWhite, normal: .up)
        }
    }

    // MARK: Villas

    private func villaDetails(_ f: DioramaBuildingFeature, ring: [DV2], flags: [Bool], box: DioramaOrientedRect, height: Double, floors: Int, wall: DioramaSwatch, flatRoof: Bool, rng: inout DioramaRandom, into mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: Bool) {
        let front = frontEdge(ring, flags: flags, centroid: f.centroid)
        let shutter: DioramaSwatch? = rng.chance(0.5) ? rng.pick([.shutterGreen, .shutterBlue]) : nil
        var windowBudget = config.maxWindowsPerBuilding
        let swahili = rng.chance(config.swahiliTouchChance)

        for i in 0..<ring.count where !flags[i] {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let length = a.distance(to: b)
            guard length > 2.2 else { continue }
            let dir = (b - a).normalized
            let out = dir.right
            let isFront = i == front
            var doorU: Double? = nil

            if isFront {
                doorU = length / 2
                door(a: a, dir: dir, out: out, u: length / 2, arched: swahili, carved: swahili, into: &mesh)
                if swahili, length > 6 {
                    // Baraza: low plastered bench either side of the entrance.
                    for side in [-1.0, 1.0] {
                        mesh.facadeBox(a: a, dir: dir, out: out, u: length / 2 + side * 1.9, width: 1.6, z0: 0, z1: 0.45, depth: 0.55, wall)
                    }
                }
            }

            for floor in 0..<floors {
                let z0 = Double(floor) * config.floorHeight + 1.0
                let z1 = z0 + 1.25
                var u = config.windowSpacing / 2 + rng.range(0...0.6)
                while u < length - 1.0, windowBudget > 0 {
                    defer { u += config.windowSpacing }
                    if floor == 0, let doorU, abs(u - doorU) < 1.6 { continue }
                    windowBudget -= 1
                    window(a: a, dir: dir, out: out, u: u, z0: z0, z1: z1, width: 1.1, shutter: shutter, arched: swahili && rng.chance(0.4), lit: lights && rng.chance(config.litWindowRatio), into: &mesh, glow: &glow)
                }
            }

            if isFront, length > 5, rng.chance(config.verandaChance) {
                veranda(a: a, b: b, out: out, z: config.floorHeight - 0.25, roofColor: flatRoof ? .roofConcrete : roofColor(&rng), into: &mesh)
            }
        }

        // Water tank on a stand beside the house, so characteristic of Dar.
        if rng.chance(config.standTankChance) {
            let corner = box.corners[rng.int(0...3)]
            let away = (corner - box.centre).normalized
            let spot = corner + away * 1.6
            if !roads.isOnRoad(spot, margin: 1.5), !DioramaPolygon.contains(ring, spot) {
                tankStand(at: spot, color: rng.chance(0.6) ? .tankBlack : .tankBlue, into: &mesh)
            }
        }
    }

    /// The real side of the house facing the nearest road, else the longest real edge.
    private func frontEdge(_ ring: [DV2], flags: [Bool], centroid: DV2) -> Int {
        let n = ring.count
        if let road = roads.nearest(to: centroid, within: 60) {
            var best = -1
            var bestScore = -Double.infinity
            for i in 0..<n where !flags[i] {
                let a = ring[i], b = ring[(i + 1) % n]
                let length = a.distance(to: b)
                guard length > 2.5 else { continue }
                let mid = (a + b) * 0.5
                let out = (b - a).normalized.right
                let toRoad = (road.point - mid).normalized
                let score = out.dot(toRoad) * 10 - mid.distance(to: road.point) * 0.1 + min(length, 12) * 0.2
                if score > bestScore { bestScore = score; best = i }
            }
            if best >= 0 { return best }
        }
        var best = -1
        var bestLength = 0.0
        for i in 0..<n where !flags[i] {
            let length = ring[i].distance(to: ring[(i + 1) % n])
            if length > bestLength { bestLength = length; best = i }
        }
        return best
    }

    private func door(a: DV2, dir: DV2, out: DV2, u: Double, arched: Bool, carved: Bool, into mesh: inout DioramaMesh) {
        let width = 1.15, height = 2.15
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.3, z0: 0, z1: height + 0.15, depth: 0.08, .frame)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: 0.02, z1: arched ? height - width / 2 : height, depth: 0.1, carved ? .carvedWood : .doorWood, sides: false)
        if arched {
            arch(a: a, dir: dir, out: out, u: u, radius: width / 2, z: height - width / 2, depth: 0.1, carved ? .carvedWood : .doorWood, into: &mesh)
        }
        if carved {
            // Raised centre post and lintel, the signature of a Zanzibar-style door.
            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: 0.14, z0: 0.1, z1: height - 0.1, depth: 0.16, .capTerracotta)
            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.5, z0: height + 0.15, z1: height + 0.45, depth: 0.16, .capTerracotta)
        }
        // Step.
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.8, z0: 0, z1: 0.16, depth: 0.5, .courtyard)
    }

    private func arch(a: DV2, dir: DV2, out: DV2, u: Double, radius: Double, z: Double, depth: Double, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        let centre = a + dir * u + out * depth
        let steps = 6
        var previous = DV3(centre + dir * radius, z)
        for k in 1...steps {
            let angle = Double(k) / Double(steps) * Double.pi
            let point = DV3(centre + dir * (radius * cos(angle)), z + radius * sin(angle))
            mesh.triangle(DV3(centre, z), previous, point, s, normal: DV3(out, 0))
            previous = point
        }
    }

    private func window(a: DV2, dir: DV2, out: DV2, u: Double, z0: Double, z1: Double, width: Double, shutter: DioramaSwatch?, arched: Bool, lit: Bool, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.24, z0: z0 - 0.12, z1: z1 + 0.12, depth: 0.07, .frame)
        if lit {
            glow.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, depth: 0.09, .windowGlow, sides: false)
        } else {
            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, depth: 0.09, .glass, sides: false)
        }
        if arched {
            arch(a: a, dir: dir, out: out, u: u, radius: width / 2, z: z1, depth: 0.09, lit ? .glass : .frame, into: &mesh)
        }
        if let shutter {
            for side in [-1.0, 1.0] {
                mesh.facadeBox(a: a, dir: dir, out: out, u: u + side * (width / 2 + 0.3), width: 0.42, z0: z0 - 0.05, z1: z1 + 0.05, depth: 0.1, shutter)
            }
        } else {
            // Security grille bars.
            for k in 0..<3 {
                let bar = u - width / 2 + width * (Double(k) + 1) / 4
                mesh.facadeBox(a: a, dir: dir, out: out, u: bar, width: 0.05, z0: z0, z1: z1, depth: 0.12, .metalCharcoal, sides: false)
            }
        }
        // Sill.
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.4, z0: z0 - 0.2, z1: z0 - 0.1, depth: 0.18, .trimWhite)
    }

    private func veranda(a: DV2, b: DV2, out: DV2, z: Double, roofColor: DioramaSwatch, into mesh: inout DioramaMesh) {
        let depth = 2.3
        let dir = (b - a).normalized
        let length = a.distance(to: b)
        let inset = 0.6
        let p0 = a + dir * inset, p1 = b - dir * inset
        let slab = [p0, p1, p1 + out * depth, p0 + out * depth]
        // Shade roof slab with a soft fascia.
        mesh.extrude(slab, z0: z, z1: z + 0.3, .trimWhite)
        mesh.polygon(slab, z: z + 0.3, roofColor)
        mesh.polygon(slab, z: z, .trimWhite, dark: true, facingUp: false)
        // Floor.
        mesh.extrude(slab, z0: 0, z1: 0.3, .courtyard)
        mesh.polygon(slab, z: 0.3, .courtyard)
        // Round columns.
        let span = length - inset * 2
        let count = max(Int(span / 2.6), 1)
        for k in 0...count {
            let u = inset + span * Double(k) / Double(count)
            let base = a + dir * u + out * (depth - 0.3)
            mesh.cylinder(centre: base, z0: 0.3, z1: z, r0: 0.17, r1: 0.15, sides: 7, .trimWhite, cap: false)
            mesh.cylinder(centre: base, z0: 0.3, z1: 0.5, r0: 0.26, r1: 0.26, sides: 7, .trimWhite)
        }
    }

    private func tankStand(at p: DV2, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let legH = 2.4
        for dx in [-0.45, 0.45] {
            for dy in [-0.45, 0.45] {
                mesh.cylinder(centre: p + DV2(dx, dy), z0: 0, z1: legH, r0: 0.07, r1: 0.07, sides: 4, .metalCharcoal, cap: false)
            }
        }
        mesh.box(centre: p, z0: legH, halfLength: 0.6, halfWidth: 0.6, height: 0.12, .metalCharcoal)
        tank(at: DV3(p, legH + 0.12), color: color, into: &mesh)
    }

    private func tank(at base: DV3, color: DioramaSwatch, radius: Double = 0.62, height: Double = 1.3, into mesh: inout DioramaMesh) {
        mesh.tube(from: base, to: base + DV3(0, 0, height), r0: radius, r1: radius, sides: 10, color, cap: false)
        mesh.tube(from: base + DV3(0, 0, height), to: base + DV3(0, 0, height + radius * 0.35), r0: radius, r1: radius * 0.3, sides: 10, color)
    }

    // MARK: Apartments

    private func apartmentDetails(ring: [DV2], flags: [Bool], height: Double, floors: Int, wall: DioramaSwatch, rng: inout DioramaRandom, into mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: Bool) {
        let accent = rng.pick(config.apartmentAccents)
        var windowBudget = config.maxWindowsPerBuilding * 2
        let n = ring.count
        let balconyEdge = frontEdge(ring, flags: flags, centroid: DioramaPolygon.centroid(ring))
        for i in 0..<n where !flags[i] {
            let a = ring[i], b = ring[(i + 1) % n]
            let length = a.distance(to: b)
            guard length > 3 else { continue }
            let dir = (b - a).normalized
            let out = dir.right
            let hasBalconies = i == balconyEdge || (length > 10 && rng.chance(0.5))
            for floor in 0..<floors {
                let base = Double(floor) * config.floorHeight
                if hasBalconies, floor > 0 {
                    // Horizontal balcony band with an accent-colour rail.
                    mesh.facadeBox(a: a, dir: dir, out: out, u: length / 2, width: length - 1.2, z0: base, z1: base + 0.25, depth: 1.1, .trimWhite)
                    mesh.facadeBox(a: a, dir: dir, out: out, u: length / 2, width: length - 1.2, z0: base + 0.25, z1: base + 1.05, depth: 0.08, accent, sides: false)
                    mesh.wall(a + dir * 0.6 + out * 1.1, b - dir * 0.6 + out * 1.1, z0: base + 0.25, z1: base + 1.05, accent)
                    mesh.wall(a + dir * 0.6, a + dir * 0.6 + out * 1.1, z0: base + 0.25, z1: base + 1.05, accent)
                    mesh.wall(b - dir * 0.6 + out * 1.1, b - dir * 0.6, z0: base + 0.25, z1: base + 1.05, accent)
                }
                var u = 1.6 + rng.range(0...0.5)
                while u < length - 1.2, windowBudget > 0 {
                    defer { u += 2.6 }
                    windowBudget -= 1
                    let lit = lights && rng.chance(config.litWindowRatio)
                    let z0 = base + (hasBalconies && floor > 0 ? 1.1 : 1.0)
                    let z1 = base + config.floorHeight - 0.5
                    mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: 1.6, z0: z0 - 0.08, z1: z1 + 0.08, depth: 0.05, .frame)
                    if lit {
                        glow.facadeBox(a: a, dir: dir, out: out, u: u, width: 1.45, z0: z0, z1: z1, depth: 0.07, .windowGlow, sides: false)
                    } else {
                        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: 1.45, z0: z0, z1: z1, depth: 0.07, .glass, sides: false)
                    }
                }
            }
            // Ground-floor accent plinth.
            mesh.wall(a, b, z0: 0, z1: 0.9, accent, ao: 0.4)
        }
        // Entrance canopy on the balcony side.
        if balconyEdge >= 0 {
            let a = ring[balconyEdge], b = ring[(balconyEdge + 1) % n]
            let dir = (b - a).normalized, out = dir.right
            let length = a.distance(to: b)
            mesh.facadeBox(a: a, dir: dir, out: out, u: length / 2, width: 3.2, z0: 2.6, z1: 2.85, depth: 1.8, accent)
            mesh.facadeBox(a: a, dir: dir, out: out, u: length / 2, width: 1.8, z0: 0.02, z1: 2.4, depth: 0.08, .glass, sides: false)
        }
    }

    // MARK: Commercial

    private func commercialDetails(_ f: DioramaBuildingFeature, ring: [DV2], flags: [Bool], height: Double, floors: Int, rng: inout DioramaRandom, into mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: Bool) {
        let n = ring.count
        let front = frontEdge(ring, flags: flags, centroid: f.centroid)
        var windowBudget = config.maxWindowsPerBuilding
        for i in 0..<n where !flags[i] {
            let a = ring[i], b = ring[(i + 1) % n]
            let length = a.distance(to: b)
            guard length > 3 else { continue }
            let dir = (b - a).normalized, out = dir.right
            let isFront = i == front || (length > 9 && roads.nearest(to: (a + b) * 0.5, within: 20) != nil)
            if isFront {
                // Shopfronts: units of ~4 m with a painted sign panel, glass front and a canvas awning.
                let units = max(Int(length / 4.2), 1)
                let unitWidth = length / Double(units)
                for k in 0..<units {
                    let u = unitWidth * (Double(k) + 0.5)
                    let sign = rng.pick(config.signColors)
                    mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: unitWidth - 0.3, z0: 2.55, z1: 3.15, depth: 0.12, sign)
                    // Painted lettering as pale blocks (no real brand names).
                    let blocks = rng.int(2...4)
                    for j in 0..<blocks {
                        let bu = u - (unitWidth - 1.2) / 2 + (unitWidth - 1.2) * (Double(j) + 0.5) / Double(blocks)
                        mesh.facadeBox(a: a, dir: dir, out: out, u: bu, width: 0.45, z0: 2.72, z1: 2.98, depth: 0.14, .trimWhite, sides: false)
                    }
                    if lights {
                        glow.facadeBox(a: a, dir: dir, out: out, u: u, width: unitWidth - 0.8, z0: 0.3, z1: 2.3, depth: 0.08, .shopGlow, sides: false)
                    } else {
                        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: unitWidth - 0.8, z0: 0.3, z1: 2.3, depth: 0.08, .glass, sides: false)
                    }
                    awning(a: a, dir: dir, out: out, u: u, width: unitWidth - 0.5, z: 2.45, color: rng.pick(config.canopyColors), into: &mesh)
                }
            }
            for floor in 1..<max(floors, 1) {
                let z0 = Double(floor) * config.floorHeight + 1.0
                var u = 1.8
                while u < length - 1.2, windowBudget > 0 {
                    defer { u += 2.8 }
                    windowBudget -= 1
                    window(a: a, dir: dir, out: out, u: u, z0: z0, z1: z0 + 1.3, width: 1.3, shutter: nil, arched: false, lit: lights && rng.chance(config.litWindowRatio), into: &mesh, glow: &glow)
                }
            }
        }
    }

    private func awning(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, z: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let l = a + dir * (u - width / 2), r = a + dir * (u + width / 2)
        let depth = 1.4
        let top = z, lip = z - 0.55
        mesh.quad(DV3(l + out * 0.1, top), DV3(r + out * 0.1, top), DV3(r + out * depth, lip), DV3(l + out * depth, lip), color)
        mesh.quad(DV3(l + out * 0.1, top), DV3(r + out * 0.1, top), DV3(r + out * depth, lip), DV3(l + out * depth, lip), color, dark: true, normal: DV3(0, 0, -1))
        mesh.quad(DV3(l + out * depth, lip), DV3(r + out * depth, lip), DV3(r + out * depth, lip - 0.22), DV3(l + out * depth, lip - 0.22), .trimWhite, normal: DV3(out, 0))
    }

    // MARK: Roof furniture

    private func roofFurniture(ring: [DV2], box: DioramaOrientedRect, height: Double, flatRoof: Bool, kind: DioramaBuildingKind, rng: inout DioramaRandom, into mesh: inout DioramaMesh) {
        guard flatRoof else {
            if rng.chance(config.dishChance) {
                let c = box.corners[rng.int(0...3)]
                let spot = c + (box.centre - c).normalized * 1.6
                dish(at: DV3(spot, height + 0.9), into: &mesh)
            }
            return
        }
        let inner = box.expanded(by: -1.4)
        guard inner.halfLength > 0.8, inner.halfWidth > 0.8 else { return }
        let tanks = kind == .apartments ? rng.int(2...4) : rng.int(1...2)
        for k in 0..<tanks {
            let spot = inner.centre + inner.axis * rng.range(-inner.halfLength...inner.halfLength) + inner.across * rng.range(-inner.halfWidth...inner.halfWidth)
            guard DioramaPolygon.contains(ring, spot), DioramaPolygon.distanceToRing(ring, spot) > 1.0 else { continue }
            let color: DioramaSwatch = rng.chance(0.6) ? .tankBlack : .tankBlue
            let scale = kind == .apartments ? 1.25 : 1.0
            mesh.box(centre: spot, z0: height, halfLength: 0.7 * scale, halfWidth: 0.7 * scale, height: 0.22, .roofConcrete, dark: false)
            tank(at: DV3(spot, height + 0.22), color: color, radius: 0.62 * scale, height: 1.3 * scale, into: &mesh)
            if k == 0, rng.chance(config.solarChance) {
                let panel = spot + inner.axis * 2.2
                if DioramaPolygon.contains(ring, panel), DioramaPolygon.distanceToRing(ring, panel) > 1.2 {
                    solar(at: panel, axis: inner.axis, z: height, into: &mesh)
                }
            }
        }
        if rng.chance(config.dishChance) {
            let edge = inner.centre + inner.across * (inner.halfWidth - 0.2)
            if DioramaPolygon.contains(ring, edge) { dish(at: DV3(edge, height + 0.3), into: &mesh) }
        }
        // Stairwell head on larger flat roofs.
        if kind == .apartments, inner.halfLength > 4 {
            let head = inner.centre - inner.axis * (inner.halfLength - 1.6)
            if DioramaPolygon.contains(ring, head) {
                mesh.box(centre: head, z0: height, axis: inner.axis, halfLength: 1.4, halfWidth: 1.1, height: 2.4, .whitewash, top: .roofConcrete, bevel: config.bevel)
            }
        }
    }

    private func dish(at p: DV3, into mesh: inout DioramaMesh) {
        mesh.tube(from: p, to: p + DV3(0, 0, 0.7), r0: 0.05, r1: 0.05, sides: 4, .metalCharcoal, cap: false)
        mesh.tube(from: p + DV3(0.18, 0, 0.75), to: p + DV3(0.42, 0, 1.0), r0: 0.5, r1: 0.1, sides: 9, .dishWhite)
    }

    private func solar(at p: DV2, axis: DV2, z: Double, into mesh: inout DioramaMesh) {
        let across = axis.left
        let lowZ = z + 0.35, highZ = z + 0.95
        let a = p - axis * 1.0 - across * 0.8, b = p + axis * 1.0 - across * 0.8
        let c = p + axis * 1.0 + across * 0.8, d = p - axis * 1.0 + across * 0.8
        mesh.quad(DV3(a, lowZ), DV3(b, lowZ), DV3(c, highZ), DV3(d, highZ), .solarNavy)
        mesh.quad(DV3(a, lowZ - 0.08), DV3(b, lowZ - 0.08), DV3(c, highZ - 0.08), DV3(d, highZ - 0.08), .metalCharcoal, normal: DV3(0, 0, -1))
        mesh.cylinder(centre: p + across * 0.6, z0: z, z1: highZ - 0.1, r0: 0.05, r1: 0.05, sides: 4, .metalCharcoal, cap: false)
    }
}

extension DioramaMesh {
    /// Convenience overload: a box whose lid uses the darker swatch copy.
    nonisolated mutating func box(centre: DV2, z0: Double, halfLength: Double, halfWidth: Double, height: Double, _ s: DioramaSwatch, dark: Bool) {
        box(centre: centre, z0: z0, axis: DV2(1, 0), halfLength: halfLength, halfWidth: halfWidth, height: height, s, top: dark ? nil : s, ao: 0, bevel: 0)
    }
}
