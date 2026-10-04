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

/// Toy-town houses in the Apple Maps idiom: softly rounded footprints, a pale plinth, string courses
/// between floors, a cream cornice and a bevelled slate-blue roof deck with small rooftop boxes. Windows
/// sit on a regular grid per facade: a pale frame, a recessed pane that is either dark glass or a warm
/// emissive pane. Every facade with lit windows also gets one real point light so the wall itself and the
/// ground below are washed warm, and entrances get a porch light.
nonisolated struct DioramaBuildingGenerator {
    let config: DioramaConfig
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain

    func classify(_ f: DioramaBuildingFeature) -> (DioramaBuildingKind, Int) {
        var rng = DioramaRandom(seed: f.id, salt: 1)
        let floors: Int
        if let h = f.height {
            floors = max(1, Int((h / config.floorHeight).rounded()))
        } else if f.area < 150 {
            floors = rng.int(1...2)
        } else if f.area < 400 {
            floors = rng.int(2...3)
        } else if f.area < 1200 {
            floors = rng.int(3...4)
        } else {
            floors = rng.int(4...7)
        }
        let type = f.type.lowercased()
        let nearMain = roads.nearest(to: f.centroid, within: 30).map { $0.road.isMain } ?? false
        if ["apartments", "hotel", "office", "dormitory"].contains(type) || floors >= 3 && f.area >= 250 {
            return (.apartments, max(floors, 3))
        }
        if ["commercial", "retail", "shop", "supermarket", "kiosk"].contains(type) || (nearMain && f.area > 120 && rng.chance(0.55)) {
            return (.commercial, min(max(floors, 2), 3))
        }
        return (.villa, min(max(floors, 1), 2))
    }

    /// Builds one house at z = 0 in a mesh whose `baseZ` is set to the terrain height under its centroid.
    @discardableResult
    func build(_ f: DioramaBuildingFeature, into mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: Bool, pointLights: inout [DioramaLight]) -> DioramaBuilt {
        let ground = terrain.height(f.centroid)
        let savedMesh = mesh.baseZ, savedGlow = glow.baseZ
        mesh.baseZ = ground
        glow.baseZ = ground
        defer { mesh.baseZ = savedMesh; glow.baseZ = savedGlow }

        var rng = DioramaRandom(seed: f.id, salt: 2)
        let (kind, floors) = classify(f)
        let height = Double(floors) * config.floorHeight
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        let (ring, flags) = DioramaPolygon.rounded(f.ring, flags: f.clipped, radius: config.cornerRadius)

        let wallColor: DioramaSwatch
        switch kind {
        case .villa: wallColor = rng.pick(config.wallColors)
        case .apartments: wallColor = rng.pick(config.apartmentWallColors)
        case .commercial: wallColor = rng.pick(config.commercialWallColors)
        }
        let trim: DioramaSwatch = .trimWhite

        // Plinth down into the slope so no house floats where the terrain falls away, then a pale base band.
        mesh.extrude(ring, z0: -2.5, z1: 0.02, .courtyard, skip: flags)
        mesh.band(ring, flags: flags, offset: 0.12, z0: 0, z1: 0.5, trim)
        mesh.extrude(ring, z0: 0.5, z1: height, wallColor, skip: flags)

        // String courses between floors on taller buildings.
        if floors >= 2, kind != .villa {
            for floor in 1..<floors {
                let z = Double(floor) * config.floorHeight
                mesh.band(ring, flags: flags, offset: 0.08, z0: z - 0.16, z1: z, trim)
            }
        }

        // A pitched roof is built on the footprint's bounding rectangle, so it only goes on houses whose
        // walls nearly fill that rectangle; L-shapes and clipped footprints get a flat roof that follows
        // the walls exactly.
        var flatRoof = kind != .villa
        if kind == .villa, rng.chance(1 - config.hipRoofShare) { flatRoof = true }
        if !flatRoof, f.area / max(box.area, 1) < config.hipRoofMinimumFill { flatRoof = true }
        if !flatRoof, flags.contains(true) { flatRoof = true }

        if flatRoof {
            softRoof(ring, flags: flags, z: height, color: .roofConcrete, into: &mesh)
        } else {
            hipRoof(box, z: height, color: roofColor(&rng), into: &mesh)
        }

        // Facades: regular window grid, entrance on the front, facade lights.
        let front = frontEdge(ring, flags: flags, centroid: f.centroid)
        let shutter: DioramaSwatch? = kind == .villa && rng.chance(0.4) ? rng.pick([.shutterGreen, .shutterBlue]) : nil
        let n = ring.count
        var windowBudget = config.maxWindowsPerBuilding * (kind == .villa ? 1 : 3)
        for i in 0..<n where !flags[i] {
            let a = ring[i], b = ring[(i + 1) % n]
            let length = a.distance(to: b)
            // Rounded-corner arcs are short; only real straight runs get openings.
            guard length > 2.4 else { continue }
            let dir = (b - a).normalized, out = dir.right
            let isFront = i == front
            let spacing: Double = kind == .villa ? 2.9 : 2.6
            let width: Double = kind == .villa ? 1.15 : 1.35
            let columns = max(Int((length - 1.0) / spacing), 1)
            let pitch = length / Double(columns)
            var doorColumn = -1
            if isFront { doorColumn = columns / 2 }
            var litOnFacade = 0
            var litZ = 0.0

            for floor in 0..<floors {
                let base = Double(floor) * config.floorHeight
                let z0 = base + (floor == 0 ? 1.15 : 0.95)
                let z1 = base + config.floorHeight - 0.55
                for c in 0..<columns {
                    let u = pitch * (Double(c) + 0.5)
                    if floor == 0, c == doorColumn {
                        door(a: a, dir: dir, out: out, u: u, kind: kind, into: &mesh)
                        continue
                    }
                    guard windowBudget > 0 else { break }
                    windowBudget -= 1
                    let lit = lights && rng.chance(config.litWindowRatio)
                    if lit { litOnFacade += 1; litZ += (z0 + z1) / 2 }
                    window(a: a, dir: dir, out: out, u: u, z0: z0, z1: z1, width: min(width, pitch - 0.7), shutter: shutter, lit: lit, into: &mesh, glow: &glow)
                }
            }

            // Shopfront band on commercial ground floors.
            if kind == .commercial, isFront || length > 9 {
                shopfront(a: a, b: b, out: out, rng: &rng, lights: lights, into: &mesh, glow: &glow)
                litOnFacade += 2; litZ += 3.0
            }

            // One warm facade light per lit facade, placed in front of the wall at the mean lit height.
            if lights, litOnFacade > 0 {
                let mid = (a + b) * 0.5 + out * 1.4
                let z = litZ / Double(litOnFacade)
                let radius = min(max(length * 0.55 + 3.5, 5), 14)
                let intensity = config.facadeLightIntensity * Float(min(0.5 + Double(litOnFacade) * 0.12, 1.3))
                pointLights.append(DioramaLight(position: DV3(mid, ground + z), color: SIMD3<Float>(1.0, 0.78, 0.50), radius: radius, intensity: intensity))
            }
            if lights, isFront {
                let mid = a + dir * (pitch * (Double(doorColumn) + 0.5)) + out * 1.2
                pointLights.append(DioramaLight(position: DV3(mid, ground + 2.8), color: SIMD3<Float>(1.0, 0.82, 0.58), radius: 6.5, intensity: 0.75))
            }
        }

        if kind == .villa, let front = front >= 0 ? front : nil, rng.chance(config.verandaChance) {
            let a = ring[front], b = ring[(front + 1) % n]
            if a.distance(to: b) > 5 {
                veranda(a: a, b: b, out: (b - a).normalized.right, z: config.floorHeight - 0.25, into: &mesh)
            }
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
        let eave = z + 0.22
        let ridgeA = DV3(r.centre - r.axis * ridgeHalf, eave + rise)
        let ridgeB = DV3(r.centre + r.axis * ridgeHalf, eave + rise)
        // Fascia board and a soffit that closes the gap between the overhang and the walls.
        mesh.extrude(c, z0: z - 0.05, z1: eave, .trimWhite)
        mesh.polygon(c, z: z - 0.05, .trimWhite, dark: true, facingUp: false)
        mesh.polygon(box.corners, z: z + 0.01, color)
        mesh.quad(DV3(c[0], eave), DV3(c[1], eave), ridgeB, ridgeA, color)
        mesh.quad(DV3(c[2], eave), DV3(c[3], eave), ridgeA, ridgeB, color)
        mesh.triangle(DV3(c[1], eave), DV3(c[2], eave), ridgeB, color)
        mesh.triangle(DV3(c[3], eave), DV3(c[0], eave), ridgeA, color)
        mesh.tube(from: ridgeA - DV3(r.axis, 0) * 0.2, to: ridgeB + DV3(r.axis, 0) * 0.2, r0: 0.16, r1: 0.16, sides: 5, .trimWhite)
        // Chimney.
        let chimney = r.centre + r.axis * (ridgeHalf * 0.5)
        mesh.box(centre: chimney, z0: eave + rise - 0.6, axis: r.axis, halfLength: 0.35, halfWidth: 0.3, height: 1.4, .trimWhite, top: .capCharcoal, bevel: 0.05)
    }

    /// Flat roof with a soft rounded edge: a cream cornice at the top of the wall, then a bevel curving
    /// inwards to a slate-blue deck, with a low parapet lip.
    private func softRoof(_ ring: [DV2], flags: [Bool], z: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let b = config.roofBevel
        let n = ring.count
        mesh.band(ring, flags: flags, offset: 0.18, z0: z - 0.45, z1: z, .trimWhite)
        guard let inner = DioramaPolygon.offset(ring, by: -b), inner.count == n else {
            mesh.polygon(ring, z: z, color)
            return
        }
        for i in 0..<n where !flags[i] {
            let a0 = ring[i], a1 = ring[(i + 1) % n]
            let i0 = inner[i], i1 = inner[(i + 1) % n]
            let out = DV3((a1 - a0).normalized.right, 0)
            let m0 = a0 * 0.45 + i0 * 0.55, m1 = a1 * 0.45 + i1 * 0.55
            mesh.quad(DV3(a0, z), DV3(a1, z), DV3(m1, z + b * 0.7), DV3(m0, z + b * 0.7), .trimWhite, normal: (out * 0.8 + DV3.up * 0.6).normalized)
            mesh.quad(DV3(m0, z + b * 0.7), DV3(m1, z + b * 0.7), DV3(i1, z + b), DV3(i0, z + b), .trimWhite, normal: (out * 0.3 + DV3.up).normalized)
        }
        mesh.polygon(inner, z: z + b, color)
        if let lip = DioramaPolygon.offset(inner, by: -0.25), lip.count == n {
            for i in 0..<n where !flags[i] {
                mesh.wall(lip[(i + 1) % n], lip[i], z0: z + b, z1: z + b + 0.3, .trimWhite)
                mesh.quad(DV3(inner[i], z + b + 0.3), DV3(inner[(i + 1) % n], z + b + 0.3), DV3(lip[(i + 1) % n], z + b + 0.3), DV3(lip[i], z + b + 0.3), .trimWhite, normal: .up)
                mesh.wall(inner[i], inner[(i + 1) % n], z0: z + b, z1: z + b + 0.3, .trimWhite)
            }
        }
    }

    // MARK: Facade elements

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

    private func door(a: DV2, dir: DV2, out: DV2, u: Double, kind: DioramaBuildingKind, into mesh: inout DioramaMesh) {
        let width = kind == .villa ? 1.15 : 1.7, height = kind == .villa ? 2.2 : 2.6
        // Recess: a dark reveal, then the door inside it.
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.36, z0: 0.5, z1: height + 0.2, depth: 0.1, .frame)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: 0.52, z1: height, depth: 0.12, kind == .villa ? .doorWood : .glass, sides: false)
        // Canopy over the entrance and two steps.
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 1.0, z0: height + 0.2, z1: height + 0.42, depth: 1.1, .trimWhite)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.9, z0: 0, z1: 0.5, depth: 0.55, .courtyard)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 1.3, z0: 0, z1: 0.25, depth: 0.95, .courtyard)
    }

    private func window(a: DV2, dir: DV2, out: DV2, u: Double, z0: Double, z1: Double, width: Double, shutter: DioramaSwatch?, lit: Bool, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        guard width > 0.5, z1 > z0 + 0.4 else { return }
        // Frame proud of the wall, pane recessed inside it.
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.26, z0: z0 - 0.13, z1: z1 + 0.13, depth: 0.07, .frame)
        if lit {
            glow.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, depth: 0.075, .windowGlow, sides: false)
        } else {
            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, depth: 0.075, .glass, sides: false)
        }
        // Mullion cross.
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: 0.06, z0: z0, z1: z1, depth: 0.09, .frame, sides: false)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: (z0 + z1) / 2 - 0.03, z1: (z0 + z1) / 2 + 0.03, depth: 0.09, .frame, sides: false)
        if let shutter {
            for side in [-1.0, 1.0] {
                mesh.facadeBox(a: a, dir: dir, out: out, u: u + side * (width / 2 + 0.33), width: 0.4, z0: z0 - 0.05, z1: z1 + 0.05, depth: 0.09, shutter)
            }
        }
        // Sill.
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.42, z0: z0 - 0.24, z1: z0 - 0.13, depth: 0.2, .trimWhite)
    }

    private func shopfront(a: DV2, b: DV2, out: DV2, rng: inout DioramaRandom, lights: Bool, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let dir = (b - a).normalized
        let length = a.distance(to: b)
        let units = max(Int(length / 5.0), 1)
        let unitWidth = length / Double(units)
        for k in 0..<units {
            let u = unitWidth * (Double(k) + 0.5)
            let sign = rng.pick(config.signColors)
            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: unitWidth - 0.4, z0: 2.7, z1: 3.25, depth: 0.12, sign)
            let blocks = rng.int(2...4)
            for j in 0..<blocks {
                let bu = u - (unitWidth - 1.4) / 2 + (unitWidth - 1.4) * (Double(j) + 0.5) / Double(blocks)
                mesh.facadeBox(a: a, dir: dir, out: out, u: bu, width: 0.45, z0: 2.85, z1: 3.1, depth: 0.14, .trimWhite, sides: false)
            }
            awning(a: a, dir: dir, out: out, u: u, width: unitWidth - 0.6, z: 2.6, color: rng.pick(config.canopyColors), into: &mesh)
        }
    }

    private func awning(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, z: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let l = a + dir * (u - width / 2), r = a + dir * (u + width / 2)
        let depth = 1.4
        let top = z, lip = z - 0.5
        mesh.quad(DV3(l + out * 0.1, top), DV3(r + out * 0.1, top), DV3(r + out * depth, lip), DV3(l + out * depth, lip), color)
        mesh.quad(DV3(l + out * 0.1, top), DV3(r + out * 0.1, top), DV3(r + out * depth, lip), DV3(l + out * depth, lip), color, dark: true, normal: DV3(0, 0, -1))
        mesh.quad(DV3(l + out * depth, lip), DV3(r + out * depth, lip), DV3(r + out * depth, lip - 0.22), DV3(l + out * depth, lip - 0.22), .trimWhite, normal: DV3(out, 0))
    }

    private func veranda(a: DV2, b: DV2, out: DV2, z: Double, into mesh: inout DioramaMesh) {
        let depth = 2.3
        let dir = (b - a).normalized
        let length = a.distance(to: b)
        let inset = 0.6
        let p0 = a + dir * inset, p1 = b - dir * inset
        let slab = [p0, p1, p1 + out * depth, p0 + out * depth]
        mesh.extrude(slab, z0: z, z1: z + 0.3, .trimWhite)
        mesh.polygon(slab, z: z + 0.3, .roofConcrete)
        mesh.polygon(slab, z: z, .trimWhite, dark: true, facingUp: false)
        mesh.extrude(slab, z0: 0, z1: 0.3, .courtyard)
        mesh.polygon(slab, z: 0.3, .courtyard)
        let span = length - inset * 2
        let count = max(Int(span / 2.6), 1)
        for k in 0...count {
            let u = inset + span * Double(k) / Double(count)
            let base = a + dir * u + out * (depth - 0.3)
            mesh.cylinder(centre: base, z0: 0.3, z1: z, r0: 0.17, r1: 0.15, sides: 7, .trimWhite, cap: false)
            mesh.cylinder(centre: base, z0: 0.3, z1: 0.5, r0: 0.26, r1: 0.26, sides: 7, .trimWhite)
        }
    }

    // MARK: Roof furniture

    private func roofFurniture(ring: [DV2], box: DioramaOrientedRect, height: Double, flatRoof: Bool, kind: DioramaBuildingKind, rng: inout DioramaRandom, into mesh: inout DioramaMesh) {
        guard flatRoof else { return }
        let inner = box.expanded(by: -1.6)
        guard inner.halfLength > 0.8, inner.halfWidth > 0.8 else { return }
        let deck = height + config.roofBevel
        // Small pale rooftop boxes (vents, chimneys, stair heads) are what read as "toy" from above.
        let boxes = kind == .apartments ? rng.int(3...5) : rng.int(1...3)
        for _ in 0..<boxes {
            let spot = inner.centre + inner.axis * rng.range(between: -inner.halfLength, and: inner.halfLength) + inner.across * rng.range(between: -inner.halfWidth, and: inner.halfWidth)
            guard DioramaPolygon.contains(ring, spot), DioramaPolygon.distanceToRing(ring, spot) > 1.2 else { continue }
            let w = rng.range(0.45...0.8)
            let h = rng.range(0.7...1.5)
            mesh.box(centre: spot, z0: deck, axis: inner.axis, halfLength: w, halfWidth: w * rng.range(0.7...1.0), height: h, .trimWhite, top: .capCharcoal, bevel: 0.08)
            if rng.chance(0.4) {
                mesh.cylinder(centre: spot, z0: deck + h, z1: deck + h + 0.5, r0: 0.16, r1: 0.14, sides: 6, .capCharcoal)
            }
        }
        if rng.chance(config.standTankChance * 0.6) {
            let spot = inner.centre - inner.axis * (inner.halfLength * 0.5)
            if DioramaPolygon.contains(ring, spot), DioramaPolygon.distanceToRing(ring, spot) > 1.2 {
                mesh.box(centre: spot, z0: deck, halfLength: 0.7, halfWidth: 0.7, height: 0.2, .trimWhite, dark: false)
                tank(at: DV3(spot, deck + 0.2), color: rng.chance(0.6) ? .tankBlack : .tankBlue, into: &mesh)
            }
        }
        if kind == .apartments, inner.halfLength > 4 {
            let head = inner.centre - inner.axis * (inner.halfLength - 1.6)
            if DioramaPolygon.contains(ring, head) {
                mesh.box(centre: head, z0: deck, axis: inner.axis, halfLength: 1.4, halfWidth: 1.1, height: 2.3, .trimWhite, top: .roofConcrete, bevel: config.bevel)
            }
        }
    }

    private func tank(at base: DV3, color: DioramaSwatch, radius: Double = 0.62, height: Double = 1.3, into mesh: inout DioramaMesh) {
        mesh.tube(from: base, to: base + DV3(0, 0, height), r0: radius, r1: radius, sides: 10, color, cap: false)
        mesh.tube(from: base + DV3(0, 0, height), to: base + DV3(0, 0, height + radius * 0.35), r0: radius, r1: radius * 0.3, sides: 10, color)
    }
}

extension DioramaMesh {
    /// Convenience overload: a box whose lid uses the darker swatch copy.
    nonisolated mutating func box(centre: DV2, z0: Double, halfLength: Double, halfWidth: Double, height: Double, _ s: DioramaSwatch, dark: Bool) {
        box(centre: centre, z0: z0, axis: DV2(1, 0), halfLength: halfLength, halfWidth: halfWidth, height: height, s, top: dark ? nil : s, ao: 0, bevel: 0)
    }
}
