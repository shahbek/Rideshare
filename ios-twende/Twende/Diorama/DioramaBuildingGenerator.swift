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
    /// Shared by the gate, driveway and entrance steps. Never target the building centroid.
    let entrance: DV2
    let entranceOut: DV2
}

/// Footprint-led coastal Dar buildings. Residential massing stays low unless mapped height says
/// otherwise. Walls are built around real openings; eligible houses have a recessed veranda under
/// the main roof, with its slab, beam and supports on the same structural grid.
nonisolated struct DioramaBuildingGenerator {
    let config: DioramaConfig
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain

    func classify(_ f: DioramaBuildingFeature) -> (DioramaBuildingKind, Int) {
        var rng = DioramaRandom(seed: f.id, salt: 1)
        let type = f.type.lowercased()
        let isApartment = ["apartments", "hotel", "office", "dormitory"].contains(type)
        let isCommercial = ["commercial", "retail", "shop", "supermarket", "kiosk"].contains(type)
        let floors: Int
        if let h = f.height {
            floors = max(1, Int((h / config.floorHeight).rounded()))
        } else if isApartment {
            floors = 3
        } else if isCommercial {
            floors = f.area > 700 ? 2 : 1
        } else {
            // A large roof does not imply an apartment block. Unknown residential heights are
            // explicitly inferred: predominantly bungalows, with some two-storey homes.
            floors = f.area > 140 && rng.chance(0.3) ? 2 : 1
        }
        if isCommercial { return (.commercial, floors) }
        if isApartment || floors >= 3 { return (.apartments, floors) }
        return (.villa, floors)
    }

    /// Builds in local height above a level foundation sampled across the footprint.
    @discardableResult
    func build(_ f: DioramaBuildingFeature, into mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: Bool, pointLights: inout [DioramaLight]) -> DioramaBuilt {
        let ground = terrain.foundationHeight(f.ring)
        let savedMesh = mesh.baseZ, savedGlow = glow.baseZ
        mesh.baseZ = ground
        glow.baseZ = ground
        defer { mesh.baseZ = savedMesh; glow.baseZ = savedGlow }

        var rng = DioramaRandom(seed: f.id, salt: 2)
        let (kind, floors) = classify(f)
        let height = max(f.height ?? Double(floors) * config.floorHeight, 2.8)
        let storeyHeight = height / Double(floors)
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        let (ring, flags) = DioramaPolygon.rounded(f.ring, flags: f.clipped, radius: config.cornerRadius)

        let override = config.buildingOverrides[f.id]
        var wallColor: DioramaSwatch
        switch kind {
        case .villa: wallColor = rng.pick(config.wallColors)
        case .apartments: wallColor = rng.pick(config.apartmentWallColors)
        case .commercial: wallColor = rng.pick(config.commercialWallColors)
        }
        if let forced = override?.wallColor { wallColor = forced }
        let trim: DioramaSwatch = .trimWhite

        // Plinth down into the slope so no house floats where the terrain falls away, then a pale base band.
        mesh.extrude(ring, z0: -2.5, z1: 0.02, .courtyard, skip: flags)
        mesh.band(ring, flags: flags, offset: 0.12, z0: 0, z1: 0.5, trim)
        // Facade masonry below is split at door/window openings, rather than solid walls behind panes.

        // String courses between floors on taller buildings.
        if floors >= 2, kind != .villa {
            for floor in 1..<floors {
                let z = Double(floor) * storeyHeight
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
        if let forced = override?.flatRoof {
            flatRoof = forced || flags.contains(true) || f.area / max(box.area, 1) < config.hipRoofMinimumFill
        }

        let pitchedColor = override?.roofColor ?? roofColor(&rng)
        if flatRoof {
            softRoof(ring, flags: flags, z: height, color: override?.roofColor ?? .roofConcrete, into: &mesh)
        } else {
            hipRoof(box, z: height, color: pitchedColor, into: &mesh)
        }

        // Facades: regular window grid, entrance on the front, facade lights.
        let front = frontEdge(ring, flags: flags, centroid: f.centroid)
        let verandaDepth: Double
        if kind != .commercial, front >= 0, f.area / max(box.area, 1) > 0.82, box.halfWidth > 3,
           ring[front].distance(to: ring[(front + 1) % ring.count]) > 6,
           kind == .apartments || rng.chance(config.verandaChance) {
            let a = ring[front], b = ring[(front + 1) % ring.count]
            let inward = (b - a).normalized.left
            let divisions = max(Int(ceil(a.distance(to: b))), 3)
            let probes = (0...divisions).flatMap { k in
                let t = 0.02 + 0.96 * Double(k) / Double(divisions)
                return [0.6, 1.2, 1.8].map { a * (1 - t) + b * t + inward * $0 }
            }
            verandaDepth = probes.allSatisfy { DioramaPolygon.contains(f.ring, $0) } ? 1.8 : 0
        } else {
            verandaDepth = 0
        }
        let n = ring.count
        let perimeter = zip(ring, ring.dropFirst() + [ring[0]]).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let budget = config.maxWindowsPerBuilding * (kind == .villa ? 1 : 3)
        let budgetSpacing = perimeter * Double(floors) / Double(max(budget, 1))
        var entrance = f.centroid
        var entranceOut = DV2(0, -1)
        for i in 0..<n where !flags[i] {
            let edgeA = ring[i], edgeB = ring[(i + 1) % n]
            let length = edgeA.distance(to: edgeB)
            let dir = (edgeB - edgeA).normalized, out = dir.right
            let isFront = i == front
            let recess = isFront ? verandaDepth : 0
            let a = edgeA - out * recess, b = edgeB - out * recess
            guard length > 2.4 else {
                mesh.wall(a, b, z0: 0.5, z1: height, wallColor)
                continue
            }
            if recess > 0 {
                mesh.wall(edgeA, a, z0: 0.5, z1: height, wallColor)
                mesh.wall(b, edgeB, z0: 0.5, z1: height, wallColor)
            }
            let spacing = max(kind == .commercial ? 4.6 : (kind == .villa ? 2.9 : 3.4), budgetSpacing)
            let width: Double = kind == .villa ? 1.3 : 1.6
            let rawColumns = max(Int((length - 1.0) / spacing), 1)
            let columns = isFront && rawColumns.isMultiple(of: 2) ? max(rawColumns - 1, 1) : rawColumns
            let pitch = length / Double(columns)
            var doorColumn = -1
            if isFront {
                doorColumn = columns / 2
                entrance = (edgeA + edgeB) * 0.5
                entranceOut = out
            }
            var litOnFacade = 0
            var litZ = 0.0

            for floor in 0..<floors {
                let base = Double(floor) * storeyHeight
                let wallBottom = floor == 0 ? 0.5 : base
                let wallTop = base + storeyHeight
                let z0 = base + 1.05
                let z1 = base + storeyHeight - 0.6
                for c in 0..<columns {
                    let u = pitch * (Double(c) + 0.5)
                    let isShop = kind == .commercial && isFront && floor == 0
                    let isDoor = isShop || (kind == .apartments && recess > 0) || (c == doorColumn && (floor == 0 || recess > 0))
                    let openingWidth = isShop ? max(pitch - 0.65, 0.6) : min(isDoor ? (kind == .villa ? 1.25 : 1.7) : width, pitch - 0.7)
                    let lower = isDoor ? wallBottom : z0
                    let upper = isDoor ? base + min(2.65, storeyHeight - 0.35) : z1
                    let cellA = a + dir * (pitch * Double(c))
                    let cellB = cellA + dir * pitch
                    guard openingWidth > 0.5, upper > lower else {
                        mesh.wall(cellA, cellB, z0: wallBottom, z1: wallTop, wallColor)
                        continue
                    }
                    let left = a + dir * (u - openingWidth / 2)
                    let right = a + dir * (u + openingWidth / 2)
                    mesh.wall(cellA, left, z0: wallBottom, z1: wallTop, wallColor)
                    mesh.wall(right, cellB, z0: wallBottom, z1: wallTop, wallColor)
                    mesh.wall(left, right, z0: wallBottom, z1: lower, wallColor)
                    mesh.wall(left, right, z0: upper, z1: wallTop, wallColor)
                    if isDoor {
                        door(a: a, dir: dir, out: out, u: u, width: openingWidth, bottom: lower, top: upper,
                             kind: kind, covered: recess > 0 || isShop, into: &mesh)
                        if isShop {
                            let sign = rng.pick(config.signColors)
                            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: openingWidth,
                                           z0: upper + 0.08, z1: min(upper + 0.38, wallTop - 0.05), depth: 0.12, sign)
                            awning(a: a, dir: dir, out: out, u: u, width: openingWidth + 0.15,
                                   z: upper + 0.04, color: rng.pick(config.canopyColors), into: &mesh)
                        }
                    } else {
                        let lit = lights && rng.chance(config.litWindowRatio)
                        if lit { litOnFacade += 1; litZ += (lower + upper) / 2 }
                        window(a: a, dir: dir, out: out, u: u, z0: lower, z1: upper,
                               width: openingWidth, hasGrille: kind == .villa, lit: lit, into: &mesh, glow: &glow)
                    }
                }
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

        if verandaDepth > 0, front >= 0 {
            let a = ring[front], b = ring[(front + 1) % n]
            veranda(a: a, b: b, out: (b - a).normalized.right, depth: verandaDepth,
                    storeyHeight: storeyHeight, floors: floors, spacing: max(kind == .villa ? 2.9 : 3.4, budgetSpacing), into: &mesh)
        }

        roofFurniture(ring: ring, box: box, height: height, flatRoof: flatRoof, kind: kind, rng: &rng, into: &mesh)
        return DioramaBuilt(feature: f, kind: kind, floors: floors, height: height, box: box, flatRoof: flatRoof, wallColor: wallColor, entrance: entrance, entranceOut: entranceOut)
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
        mesh.tube(from: ridgeA, to: ridgeB, r0: 0.1, r1: 0.1, sides: 6, color)
        // Hip seams follow the roof planes, rather than unrelated ornaments on top.
        for (corner, ridge) in [(c[0], ridgeA), (c[3], ridgeA), (c[1], ridgeB), (c[2], ridgeB)] {
            mesh.tube(from: DV3(corner, eave + 0.02), to: ridge, r0: 0.055, r1: 0.055, sides: 4, color)
        }
    }

    /// Flat roof with a soft rounded edge: a cream cornice at the top of the wall, then a bevel curving
    /// inwards to a neutral concrete deck, with a low parapet lip.
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

    private func door(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, bottom: Double, top: Double,
                      kind: DioramaBuildingKind, covered: Bool, into mesh: inout DioramaMesh) {
        reveal(a: a, dir: dir, out: out, u: u, width: width, z0: bottom, z1: top, into: &mesh)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: bottom, z1: top,
                       depth: -0.19, kind == .villa ? .doorWood : .glass, sides: false)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u + width * 0.3, width: 0.04,
                       z0: bottom + 0.75, z1: bottom + 1.02, depth: -0.16, .metalCharcoal, sides: false)
        guard !covered else { return }
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.45,
                       z0: top + 0.1, z1: top + 0.23, depth: 0.75, .concrete)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.4,
                       z0: 0, z1: 0.5, depth: 0.35, .courtyard)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.6,
                       z0: 0, z1: 0.25, depth: 0.65, .courtyard)
    }

    /// Four inward returns connect the plaster face to a recessed pane/door; no solid wall is behind it.
    private func reveal(a: DV2, dir: DV2, out: DV2, u: Double, width: Double,
                        z0: Double, z1: Double, into mesh: inout DioramaMesh) {
        let l = a + dir * (u - width / 2), r = a + dir * (u + width / 2)
        let li = l - out * 0.2, ri = r - out * 0.2
        mesh.quad(DV3(l, z0), DV3(li, z0), DV3(li, z1), DV3(l, z1), .frame, normal: DV3(dir, 0))
        mesh.quad(DV3(ri, z0), DV3(r, z0), DV3(r, z1), DV3(ri, z1), .frame, normal: DV3(-dir, 0))
        mesh.quad(DV3(li, z0), DV3(ri, z0), DV3(r, z0), DV3(l, z0), .frame, normal: .up)
        mesh.quad(DV3(l, z1), DV3(r, z1), DV3(ri, z1), DV3(li, z1), .frame, dark: true, normal: DV3(0, 0, -1))
    }

    private func window(a: DV2, dir: DV2, out: DV2, u: Double, z0: Double, z1: Double,
                        width: Double, hasGrille: Bool, lit: Bool, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        reveal(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, into: &mesh)
        // Always keep the dark pane: the emissive category is hidden during daylight.
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, depth: -0.19, .glass, sides: false)
        if lit {
            glow.facadeBox(a: a, dir: dir, out: out, u: u, width: width, z0: z0, z1: z1, depth: -0.18, .windowGlow, sides: false)
        }
        // Readable joinery rather than subpixel strips: jambs, lintel, mullion and a projecting sill.
        for side in [-1.0, 1.0] {
            mesh.facadeBox(a: a, dir: dir, out: out, u: u + side * (width / 2 + 0.045), width: 0.09,
                           z0: z0 - 0.08, z1: z1 + 0.09, depth: 0.07, .frame)
        }
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.18,
                       z0: z1, z1: z1 + 0.10, depth: 0.10, .frame)
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: 0.085, z0: z0, z1: z1, depth: -0.10, .frame, sides: false)
        if hasGrille {
            for fraction in [-0.3, 0.3] {
                mesh.facadeBox(a: a, dir: dir, out: out, u: u + width * fraction, width: 0.05,
                               z0: z0, z1: z1, depth: -0.035, .metalCharcoal, sides: false)
            }
            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width,
                           z0: z0 + (z1 - z0) * 0.45, z1: z0 + (z1 - z0) * 0.45 + 0.05,
                           depth: -0.03, .metalCharcoal, sides: false)
        }
        mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: width + 0.16,
                       z0: z0 - 0.1, z1: z0, depth: 0.14, .trimWhite)
    }

    private func awning(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, z: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let l = a + dir * (u - width / 2), r = a + dir * (u + width / 2)
        let depth = 1.4
        let top = z, lip = z - 0.5
        mesh.quad(DV3(l + out * 0.1, top), DV3(r + out * 0.1, top), DV3(r + out * depth, lip), DV3(l + out * depth, lip), color)
        mesh.quad(DV3(l + out * depth, lip), DV3(r + out * depth, lip), DV3(r + out * depth, lip - 0.22), DV3(l + out * depth, lip - 0.22), .trimWhite, normal: DV3(out, 0))
    }

    /// Recessed outdoor room inside the mapped envelope, not a second roof glued onto the facade.
    private func veranda(a: DV2, b: DV2, out: DV2, depth: Double, storeyHeight: Double,
                         floors: Int, spacing: Double, into mesh: inout DioramaMesh) {
        let dir = (b - a).normalized
        let length = a.distance(to: b)
        let slab = DioramaPolygon.counterClockwise([a, b, b - out * depth, a - out * depth])
        let span = length - 0.4
        // An odd bay count leaves the central doorway in a clear span; match the facade grid.
        let rawBays = max(Int((length - 1.0) / spacing), 1)
        let bays = rawBays.isMultiple(of: 2) ? max(rawBays - 1, 1) : rawBays
        for floor in 0..<floors {
            let base = floor == 0 ? 0.5 : Double(floor) * storeyHeight
            let ceiling = Double(floor + 1) * storeyHeight
            mesh.extrude(slab, z0: base - 0.18, z1: base, .concrete, top: .courtyard)
            mesh.polygon(slab, z: ceiling - 0.08, .trimWhite, dark: true, facingUp: false)
            mesh.box(centre: (a + b) * 0.5 - out * 0.12, z0: ceiling - 0.34, axis: dir,
                     halfLength: length / 2, halfWidth: 0.15, height: 0.34, .trimWhite)
            for k in 0...bays {
                let position = k == 0 ? 0.15 : (k == bays ? length - 0.15 : length * Double(k) / Double(bays))
                let p = a + dir * position - out * 0.15
                mesh.box(centre: p, z0: base, axis: dir, halfLength: 0.15, halfWidth: 0.15,
                         height: ceiling - base - 0.34, .trimWhite)
            }
            if floor > 0 {
                mesh.box(centre: (a + b) * 0.5 - out * 0.15, z0: base, axis: dir,
                         halfLength: span / 2, halfWidth: 0.1, height: 0.8, .cream)
                mesh.box(centre: (a + b) * 0.5 - out * 0.15, z0: base + 0.8, axis: dir,
                         halfLength: span / 2, halfWidth: 0.13, height: 0.08, .trimWhite)
            }
        }
        let entry = (a + b) * 0.5
        // Keep external steps off carriageways; the recessed terrace itself never leaves the footprint.
        if !roads.isOnCarriageway(entry + out * 0.65, margin: 0.5) {
            mesh.box(centre: entry + out * 0.3, z0: 0, axis: dir, halfLength: 0.95, halfWidth: 0.3, height: 0.25, .courtyard)
        }
    }

    // MARK: Roof furniture

    private func roofFurniture(ring: [DV2], box: DioramaOrientedRect, height: Double, flatRoof: Bool, kind: DioramaBuildingKind, rng: inout DioramaRandom, into mesh: inout DioramaMesh) {
        guard flatRoof else { return }
        let inner = box.expanded(by: -1.6)
        guard inner.halfLength > 0.8, inner.halfWidth > 0.8 else { return }
        let deck = height + config.roofBevel
        // Functional rooftop service elements only; no arbitrary vent/chimney scatter.
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
