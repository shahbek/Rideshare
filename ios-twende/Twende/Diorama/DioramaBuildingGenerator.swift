import Foundation

nonisolated enum DioramaBuildingKind: Sendable {
    case villa, apartments, commercial
}

/// Which researched Dar es Salaam street character ordinary buildings follow.
/// Masaki/Oyster Bay: white and cream villas and apartment blocks under terracotta, maroon, charcoal
/// or teal pitched roofs, stacked balcony slabs. City centre/Kisutu: dense pastel render blocks with
/// turquoise pilaster strips, window eyebrow hoods, corrugated street canopies and tank-crowded roofs.
nonisolated enum DioramaDistrict: Sendable {
    case masaki, city

    /// The harbour/city-centre tiles lie south of the Masaki peninsula store (y ≥ 34008 at z16).
    static func of(_ tile: DioramaTileID) -> DioramaDistrict {
        let y = tile.z >= 16 ? tile.y >> (tile.z - 16) : tile.y << (16 - tile.z)
        return y >= 34_008 ? .city : .masaki
    }

    func wallColors(_ kind: DioramaBuildingKind, config: DioramaConfig) -> [DioramaSwatch] {
        switch (self, kind) {
        case (.city, .villa), (.city, .apartments): [.cream, .paleYellow, .salmonRender, .paleBlueRender, .mint, .whitewash, .dustyRose, .cream]
        case (.city, .commercial): [.cream, .whitewash, .salmonRender, .paleYellow, .paleBlueRender]
        case (.masaki, .villa): [.whitewash, .cream, .whitewash, .paleYellow, .cream, .whitewash]
        case (.masaki, .apartments): [.whitewash, .cream, .whitewash, .trimWhite, .paleYellow]
        case (.masaki, .commercial): config.commercialWallColors
        }
    }

    /// Masaki pitched roofs: clay tile, stone-coated maroon/charcoal sheet and painted mabati.
    var pitchedRoofColors: [DioramaSwatch] {
        switch self {
        case .masaki: [.roofTerracotta, .roofTerracotta, .roofTerracotta, .roofMaroon, .roofMaroon, .roofCharcoal, .roofGreen, .roofTeal, .roofRust]
        case .city: [.mabatiGrey, .roofRust, .roofTerracotta, .mabatiGrey, .roofGreen]
        }
    }
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

/// Footprint-led coastal Dar buildings assembled from `DioramaBuildingKit` modules: walls and rounded
/// corners along each footprint edge, window and door units on a facade grid, cornices, parapets or
/// soft roof edges, verandas, and a hip roof traced on the real footprint. Residential massing stays
/// low unless mapped height says otherwise.
nonisolated struct DioramaBuildingGenerator {
    let config: DioramaConfig
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain
    var district: DioramaDistrict = .masaki
    private var kit: DioramaBuildingKit { DioramaBuildingKit(config: config) }

    func classify(_ f: DioramaBuildingFeature) -> (DioramaBuildingKind, Int) {
        var rng = DioramaRandom(seed: f.id, salt: 1)
        let type = f.type.lowercased()
        let isApartment = ["apartments", "hotel", "office", "dormitory"].contains(type)
        let isCommercial = ["commercial", "retail", "shop", "supermarket", "kiosk"].contains(type)
        let floors: Int
        if let h = f.height {
            floors = max(1, Int((h / config.floorHeight).rounded()))
        } else if isApartment {
            floors = district == .city ? 4 + Int(rng.unit() * 3) : 3
        } else if isCommercial {
            floors = district == .city ? 3 + Int(rng.unit() * 2) : (f.area > 700 ? 2 : 1)
        } else if district == .city {
            // Kisutu/Upanga blocks are rarely single storey; unknown heights read as 3–5 storey walk-ups.
            floors = f.area > 60 ? 3 + Int(rng.unit() * 3) : 2
        } else {
            // A large roof does not imply an apartment block. Unknown residential heights are
            // explicitly inferred: predominantly bungalows, with some two-storey homes.
            floors = f.area > 140 && rng.chance(0.3) ? 2 : 1
        }
        if isCommercial { return (.commercial, floors) }
        if isApartment || floors >= 3 { return (.apartments, floors) }
        return (.villa, floors)
    }

    /// Buildings follow their site datum without changing the underlying landform.
    @discardableResult
    func build(_ f: DioramaBuildingFeature, into mesh: inout DioramaMesh, glow: inout DioramaMesh, lights: Bool, pointLights: inout [DioramaLight]) -> DioramaBuilt {
        if !f.occupiedPieces.isEmpty {
            return DioramaClippedBuilding.build(f, terrain: terrain, config: config, mesh: &mesh, glow: &glow, lights: lights)
        }
        let ground = terrain.buildingHeight(f)
        if f.id == 165_397_124 {
            // Open timber undercroft; the pavilion floor meets the walkway's finished deck.
            mesh.extrude(f.ring, z0: ground - 0.28, z1: ground, .pierWood, top: .deckWood)
            let support = DioramaPolygon.minimumAreaRectangle(f.ring)
            for u in stride(from: -support.halfLength + 0.4, through: support.halfLength - 0.4, by: 3) {
                for v in stride(from: -support.halfWidth + 0.4, through: support.halfWidth - 0.4, by: 3) {
                    let p = support.centre + support.axis * u + support.across * v
                    guard DioramaPolygon.contains(f.ring, p) else { continue }
                    mesh.cylinder(centre: p, z0: terrain.seabed(p) - 0.5, z1: ground - 0.18,
                                  r0: 0.22, r1: 0.18, sides: 8, .pierWood)
                }
            }
        } else {
            terrain.foundation(f.ring, top: ground, swatch: .concrete, into: &mesh)
        }
        let savedMesh = mesh.baseZ, savedGlow = glow.baseZ
        mesh.baseZ = ground
        glow.baseZ = ground
        mesh.recordsHeight = true
        var rng = DioramaRandom(seed: f.id, salt: 2)
        // A slight warm/cool hue shift per building so a street of plaster never reads as one swatch.
        let shift = Float(rng.range(-1...1)) * config.hueShift
        mesh.tint = SIMD3(1 + shift, 1 + shift * 0.35, 1 - shift)
        defer { mesh.baseZ = savedMesh; glow.baseZ = savedGlow; mesh.recordsHeight = false; mesh.tint = SIMD3(1, 1, 1) }
        let (kind, floors) = classify(f)
        let height = max(f.height ?? Double(floors) * config.floorHeight, 2.8)
        let storeyHeight = height / Double(floors)
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        let (ring, flags) = DioramaPolygon.rounded(f.ring, flags: f.clipped, radius: config.cornerRadius, segments: 6)
        let kit = self.kit

        let override = config.buildingOverrides[f.id]
        var wallColor: DioramaSwatch = rng.pick(district.wallColors(kind, config: config))
        if let forced = override?.wallColor { wallColor = forced }

        // Share footprint safety, not a single facade: use-led typologies retain distinct massing.
        // Keep authored overrides, cut edges, courtyard holes and low-rise house roofs in their own recipes.
        if floors >= 4, height >= 12, override == nil, !f.clipped.contains(true), f.area > 60 {
            let recipe = architecturalRecipe(f, kind: kind, floors: floors, height: height, wallColor: wallColor)
            var generator = DarTowerGenerator(site: recipe)
            var facadeLights: [DioramaLight] = []
            if generator.build(f.ring, into: &mesh, glow: &glow, lights: &facadeLights, includesLights: lights) {
                pointLights.append(contentsOf: facadeLights)
                return DioramaBuilt(feature: f, kind: kind, floors: floors, height: height, box: box,
                    flatRoof: !generator.hasPitchedRoof, wallColor: wallColor, entrance: generator.entrance, entranceOut: generator.entranceOut)
            }
        }

        // Same-material wall bases follow the existing slope, never a separate pedestal.
        for i in ring.indices where !flags[i] {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            mesh.quad(DV3(a, terrain.height(a) - ground - 0.25), DV3(b, terrain.height(b) - ground - 0.25),
                      DV3(b, 0.5), DV3(a, 0.5), wallColor, normal: DV3((b - a).normalized.right, 0))
        }
        kit.plinth(ring, flags: flags, height: 0.5, wallColor, into: &mesh)

        // String courses between floors on taller buildings.
        if floors >= 2, kind != .villa {
            for floor in 1..<floors {
                kit.stringCourse(ring, flags: flags, z: Double(floor) * storeyHeight, into: &mesh)
            }
        }

        // Join footprint-derived hip wings; tile cuts/ownership fragments keep their safe flat decks.
        var flatRoof = kind != .villa
        if kind == .villa, rng.chance(1 - config.hipRoofShare) { flatRoof = true }
        // Oyster Bay apartment blocks often carry clay-tile or teal standing-seam hip roofs.
        if district == .masaki, kind == .apartments, floors <= 10, rng.chance(0.5) { flatRoof = false }
        if district == .city, kind == .villa, floors >= 2 { flatRoof = !rng.chance(0.25) }
        // Separate stream so roof choice never perturbs the rest of the building's random sequence.
        var roofRoll = DioramaRandom(seed: f.id, salt: 0x52_4F_4F_46)
        let roll = roofRoll.unit()
        // Low-rise shops and blocks across Kariakoo/Sinza mostly carry mabati sheds and gables.
        if flatRoof, override == nil, kind != .villa, floors <= 2, roofRoll.chance(district == .masaki ? 0.25 : 0.6) { flatRoof = false }
        if !flatRoof, flags.contains(true) { flatRoof = true }
        if let forced = override?.flatRoof { flatRoof = forced || flags.contains(true) }

        let pitchedColor = override?.roofColor ?? roofColor(&rng)
        if !flatRoof {
            let pitch = config.roofPitchDegrees * Double.pi / 180
            let shape = DioramaRoofKit.shape(of: f.ring)
            // Orthogonal L/T/U plans keep the approved joined hip wings first.
            var roofed = false
            if kind == .villa, shape.rectangularity > 0.55, roll < 0.55 || !shape.isConvex {
                roofed = DioramaRoofBuilder.hip(ring, flags: flags, z: height, pitch: pitch,
                                               overhang: config.roofOverhang, maxRise: config.hipRoofMaxRise,
                                               color: pitchedColor, fascia: .trimWhite, into: &mesh, footprint: f.ring)
            }
            if !roofed {
                let modern = district == .masaki && kind == .villa
                for form in DioramaRoofKit.candidates(for: shape, roll: roll, modern: modern) {
                    let formPitch = form == .pyramid ? pitch * 1.1 : (form == .gable || form == .jerkinhead ? pitch * 1.05 : pitch)
                    if DioramaRoofKit.build(form, ring: ring, flags: flags, z: height, pitch: formPitch,
                                            overhang: form == .shed ? config.roofOverhang * 0.7 : config.roofOverhang,
                                            maxRise: config.hipRoofMaxRise, color: pitchedColor, fascia: .trimWhite,
                                            gable: wallColor, into: &mesh) {
                        roofed = true
                        break
                    }
                }
            }
            if !roofed { flatRoof = true }
        }
        if flatRoof {
            softRoof(ring, flags: flags, z: height, color: override?.roofColor ?? .roofConcrete, kind: kind, into: &mesh)
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
                kit.wall(ring, edge: i, z0: 0.5, z1: height, wallColor, into: &mesh)
                continue
            }
            if recess > 0 {
                kit.wall(edgeA, a, z0: 0.5, z1: height, wallColor, into: &mesh)
                kit.wall(b, edgeB, z0: 0.5, z1: height, wallColor, into: &mesh)
            }
            let spacing = max(kind == .commercial ? 4.6 : (kind == .villa ? 2.9 : 3.4), budgetSpacing)
            // Oversized openings read from the map camera; metric windows looked like slots.
            // Dar casements: wide and squat (about 1.5 × 1.5 m) on a 0.95 m sill, heads 0.45 m under the slab.
            let width: Double = (kind == .villa ? 1.15 : 1.6) * config.detailExaggeration
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
                let z0 = base + (kind == .commercial ? 1.05 : 0.95)
                let z1 = base + storeyHeight - (kind == .commercial ? 0.6 : 0.45)
                for c in 0..<columns {
                    let u = pitch * (Double(c) + 0.5)
                    let isShop = kind == .commercial && isFront && floor == 0
                    let isDoor = isShop || (kind == .apartments && recess > 0) || (c == doorColumn && (floor == 0 || recess > 0))
                    let doorWidth = (kind == .villa ? 1.25 : 1.7) * config.detailExaggeration
                    let openingWidth = isShop ? max(pitch - 0.65, 0.6) : min(isDoor ? doorWidth : width, pitch - 0.7)
                    let lower = isDoor ? wallBottom : z0
                    let upper = isDoor ? base + min(2.65, storeyHeight - 0.35) : z1
                    let cellA = a + dir * (pitch * Double(c))
                    let cellB = cellA + dir * pitch
                    guard openingWidth > 0.5, upper > lower else {
                        kit.wall(cellA, cellB, z0: wallBottom, z1: wallTop, wallColor, into: &mesh)
                        continue
                    }
                    let left = a + dir * (u - openingWidth / 2)
                    let right = a + dir * (u + openingWidth / 2)
                    kit.wall(cellA, left, z0: wallBottom, z1: wallTop, wallColor, into: &mesh)
                    kit.wall(right, cellB, z0: wallBottom, z1: wallTop, wallColor, into: &mesh)
                    kit.wall(left, right, z0: wallBottom, z1: lower, wallColor, into: &mesh)
                    kit.wall(left, right, z0: upper, z1: wallTop, wallColor, into: &mesh)
                    if isShop {
                        kit.shopFront(a: a, dir: dir, out: out, u: u, width: openingWidth, bottom: lower, top: upper, wallTop: wallTop,
                                      sign: rng.pick(config.signColors), awning: rng.pick(config.canopyColors), into: &mesh)
                    } else if isDoor {
                        kit.door(a: a, dir: dir, out: out, u: u, width: openingWidth, bottom: lower, top: upper,
                                 kind: kind, covered: recess > 0, into: &mesh)
                    } else {
                        let lit = lights && rng.chance(config.litWindowRatio)
                        if lit { litOnFacade += 1; litZ += (lower + upper) / 2 }
                        kit.window(a: a, dir: dir, out: out, u: u, z0: lower, z1: upper,
                                   width: openingWidth, hasGrille: kind != .commercial, lit: lit, into: &mesh, glow: &glow)
                        // Cast-concrete eyebrow hood over each residential window (sun and rain shade).
                        if kind != .commercial, upper + 0.42 < wallTop {
                            mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: openingWidth + 0.5, z0: upper + 0.22, z1: upper + 0.32,
                                           depth: 0.42, .trimWhite)
                        }
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

        districtDetails(ring: ring, flags: flags, front: front, kind: kind, floors: floors, storeyHeight: storeyHeight,
                        height: height, flatRoof: flatRoof, wallColor: wallColor, recessed: verandaDepth > 0, rng: &rng, into: &mesh)
        roofFurniture(ring: ring, box: box, height: height, flatRoof: flatRoof, kind: kind, rng: &rng, into: &mesh)
        return DioramaBuilt(feature: f, kind: kind, floors: floors, height: height, box: box, flatRoof: flatRoof, wallColor: wallColor, entrance: entrance, entranceOut: entranceOut)
    }

    private func roofColor(_ rng: inout DioramaRandom) -> DioramaSwatch {
        rng.pick(district.pitchedRoofColors)
    }

    // MARK: District character

    /// Street details from the skyline research, all on real (unclipped) front edges.
    private func districtDetails(ring: [DV2], flags: [Bool], front: Int, kind: DioramaBuildingKind, floors: Int, storeyHeight: Double,
                                 height: Double, flatRoof: Bool, wallColor: DioramaSwatch, recessed: Bool,
                                 rng: inout DioramaRandom, into mesh: inout DioramaMesh) {
        guard front >= 0, front < ring.count, !flags[front] else { return }
        let a = ring[front], b = ring[(front + 1) % ring.count]
        let length = a.distance(to: b)
        guard length > 5 else { return }
        let dir = (b - a).normalized, out = dir.right
        let mid = (a + b) * 0.5
        switch district {
        case .city where kind != .villa || floors >= 2:
            // Turquoise pilaster strips framing the street face.
            if rng.chance(0.6) {
                for u in [0.3, length - 0.3] {
                    mesh.facadeBox(a: a, dir: dir, out: out, u: u, width: 0.4, z0: 0.5, z1: height, depth: 0.14, .kisutuTeal)
                }
            }
            // Continuous eyebrow sunshade ledges over every upper floor's windows.
            for floor in 1..<max(floors, 1) {
                let z = Double(floor) * storeyHeight + storeyHeight - 0.5
                mesh.facadeBox(a: a, dir: dir, out: out, u: length / 2, width: length - 1.0, z0: z, z1: z + 0.13, depth: 0.5, .trimWhite)
            }
            // Corrugated shop verandah on slim posts over the pavement.
            if kind == .commercial || floors >= 3, !roads.isOnCarriageway(mid + out * 1.9, margin: 0.2) {
                let l = a + dir * 0.4, r = b - dir * 0.4, depth = 1.8, z = min(3.4, storeyHeight + 0.2)
                let wasDoubleSided = mesh.doubleSided
                mesh.doubleSided = true
                mesh.quad(DV3(l, z), DV3(r, z), DV3(r + out * depth, z - 0.4), DV3(l + out * depth, z - 0.4), .mabatiGrey)
                mesh.doubleSided = wasDoubleSided
                let posts = max(Int(length / 4.5), 1)
                for k in 0...posts {
                    let p = l + (r - l) * (Double(k) / Double(posts)) + out * (depth - 0.1)
                    mesh.cylinder(centre: p, z0: 0, z1: z - 0.4, r0: 0.07, r1: 0.07, sides: 6, .metalCharcoal, cap: false)
                }
            }
            // No invented rooftop signs or stacked parapet blocks.
        case .masaki where kind == .apartments && floors >= 3 && !recessed:
            // Stacked balcony slabs with rails on the long face, the Oyster Bay apartment rhythm.
            let half = length / 2 - 0.5
            guard half > 1.2 else { return }
            for floor in 1..<floors {
                let z = Double(floor) * storeyHeight
                mesh.box(centre: mid + out * 0.7, z0: z - 0.05, axis: dir, halfLength: half, halfWidth: 0.7, height: 0.2, .trimWhite, bevel: 0.05)
                kit.balconyRail(a: mid - dir * half + out * 1.32, b: mid + dir * half + out * 1.32, out: out, z: z + 0.15, into: &mesh)
            }
        default:
            break
        }
    }

    /// Identical design identity for HD and coarse generation; never reroll a roof during handoff.
    func architecturalRecipe(_ f: DioramaBuildingFeature, kind: DioramaBuildingKind, floors: Int,
                             height: Double, wallColor: DioramaSwatch) -> DarSkylineSite {
        let family = DarBuildingDesign.ordinaryFamily(id: f.id, type: f.type, commercial: kind == .commercial,
            city: district == .city, floors: floors)
        let roof = DarBuildingDesign.ordinaryRoof(id: f.id, family: family, city: district == .city, floors: floors)
        let palette = DioramaSwatch.defaultPalette[wallColor] ?? 0xF4EFE7
        return DarSkylineSite(id: "ordinary-\(f.id)", osm: f.id, name: f.name, levels: floors, height: height,
            district: district == .city ? "city" : "masaki", style: family,
            wall: String(format: "#%06X", palette), accent: district == .city ? "#2E8A9A" : "#F4EFE7",
            glass: "#417E86", roof: roof, crown: roof == "flat" ? "integrated" : "hip",
            balconies: family == "coastal" ? "principal" : "none",
            description: "Use-led district interpretation on the mapped footprint and height", ring: [])
    }

    // MARK: Roofs

    /// Flat roof from kit modules: a thick cornice under the wall top, then either a wide rounded
    /// roof edge (villas, shops) or a parapet with coping (apartment blocks) around the deck.
    private func softRoof(_ ring: [DV2], flags: [Bool], z: Double, color: DioramaSwatch, kind: DioramaBuildingKind, into mesh: inout DioramaMesh) {
        let kit = self.kit
        kit.cornice(ring, flags: flags, z: z, into: &mesh)
        if kind == .apartments {
            mesh.polygon(ring, z: z, color)
            kit.parapet(ring, flags: flags, z: z, into: &mesh)
            return
        }
        if kit.roofEdge(ring, flags: flags, z: z, bevel: config.roofBevel, deck: color, into: &mesh) == nil {
            mesh.polygon(ring, z: z, color)
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

    /// Recessed outdoor room inside the mapped envelope, assembled from veranda bay modules.
    private func veranda(a: DV2, b: DV2, out: DV2, depth: Double, storeyHeight: Double,
                         floors: Int, spacing: Double, into mesh: inout DioramaMesh) {
        let dir = (b - a).normalized
        let length = a.distance(to: b)
        // An odd bay count leaves the central doorway in a clear span; match the facade grid.
        let rawBays = max(Int((length - 1.0) / spacing), 1)
        let bays = rawBays.isMultiple(of: 2) ? max(rawBays - 1, 1) : rawBays
        for floor in 0..<floors {
            let base = floor == 0 ? 0.5 : Double(floor) * storeyHeight
            let ceiling = Double(floor + 1) * storeyHeight
            kit.verandaBay(a: a, b: b, out: out, depth: depth, base: base, ceiling: ceiling, bays: bays, railed: floor > 0, into: &mesh)
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
        let deck = height + (kind == .apartments ? 0 : config.roofBevel)
        let kit = self.kit
        // Functional rooftop service elements only; no arbitrary vent scatter.
        // Optional open equipment; do not cover every small roof with the same tank cluster.
        let tanks = rng.chance(district == .city ? 0.45 : config.standTankChance * 0.6) ? (rng.chance(0.25) ? 2 : 1) : 0
        for k in 0..<tanks {
            let spot = inner.centre - inner.axis * (inner.halfLength * 0.5) + inner.axis.left * (Double(k) - Double(tanks - 1) / 2) * 1.7
            if DioramaPolygon.contains(ring, spot), DioramaPolygon.distanceToRing(ring, spot) > 1.4 {
                kit.waterTank(at: spot, z0: deck, color: rng.chance(0.7) ? .tankBlack : .tankBlue, into: &mesh)
            }
        }
        if kind == .apartments, inner.halfLength > 4, rng.chance(0.55) {
            let head = inner.centre - inner.axis * (inner.halfLength - 1.6)
            let headPlan = DioramaOrientedRect(centre: head, axis: inner.axis, halfLength: 1.4, halfWidth: 1.1)
            if DarArchitecturePlan.fits(headPlan.corners, inside: ring, clearance: 0.25) {
                kit.roofHead(at: head, axis: inner.axis, z0: deck, into: &mesh)
            }
        }
    }
}

extension DioramaMesh {
    /// Convenience overload: a box whose lid uses the darker swatch copy.
    nonisolated mutating func box(centre: DV2, z0: Double, halfLength: Double, halfWidth: Double, height: Double, _ s: DioramaSwatch, dark: Bool) {
        box(centre: centre, z0: z0, axis: DV2(1, 0), halfLength: halfLength, halfWidth: halfWidth, height: height, s, top: dark ? nil : s, ao: 0, bevel: 0)
    }
}
