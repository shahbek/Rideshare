import Foundation
import simd

/// Distinct building typologies share datums and construction helpers, not one repeated elevation.
/// All geometry remains footprint-contained and is drawn by its owning saved tile.
nonisolated struct DarTowerGenerator {
    let site: DarSkylineSite
    private let design: DarBuildingDesign
    private let wall: SIMD3<Float>
    private let accent: SIMD3<Float>
    private let glass: SIMD3<Float>
    private let cream = DarTowerGenerator.rgb("#F4EFE7")
    private let silver = DarTowerGenerator.rgb("#BFCBCB")
    private(set) var entrance: DV2 = .zero
    private(set) var entranceOut: DV2 = DV2(0, -1)
    private(set) var hasPitchedRoof: Bool = false
    private var includesLights: Bool = true

    init(site: DarSkylineSite) {
        self.site = site
        design = DarBuildingDesign(site: site)
        wall = Self.rgb(site.wall); accent = Self.rgb(site.accent); glass = Self.rgb(site.glass)
    }

    static func rgb(_ hex: String) -> SIMD3<Float> {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xF4EFE7
        return SIMD3(Float((value >> 16) & 255), Float((value >> 8) & 255), Float(value & 255)) / 255
    }

    private func use(_ color: SIMD3<Float>, _ swatch: DioramaSwatch, _ mesh: inout DioramaMesh) {
        let v = DioramaSwatch.defaultPalette[swatch] ?? 0xFFFFFF
        let base = SIMD3(Float((v >> 16) & 255), Float((v >> 8) & 255), Float(v & 255)) / 255
        mesh.tint = color / simd_max(base, SIMD3(repeating: 0.05))
    }

    @discardableResult
    mutating func build(_ footprint: [DV2], into mesh: inout DioramaMesh, glow: inout DioramaMesh,
                        lights: inout [DioramaLight], includesLights: Bool = true) -> Bool {
        guard let plan = DarArchitecturePlan(footprint: footprint, site: site) else { return false }
        self.includesLights = includesLights
        entrance = plan.elevations[plan.entrance].mid
        entranceOut = plan.elevations[plan.entrance].out
        let oldHeight = mesh.recordsHeight, oldTint = mesh.tint, oldGlowTint = glow.tint
        mesh.recordsHeight = true
        defer { mesh.recordsHeight = oldHeight; mesh.tint = oldTint; glow.tint = oldGlowTint }
        if DioramaConfig.shaderFacades {
            buildShaderFacades(plan, into: &mesh, lights: &lights)
            return true
        }
        use(wall, .whitewash, &mesh)
        DarArchitecturalKit.solid(plan.envelope, bottom: -0.3, top: 0.32, shoulder: 0.08, color: .whitewash, into: &mesh)
        buildGroundFloor(plan, into: &mesh, glow: &glow, lights: &lights)

        // A single occupied upper setback, not a stack of arbitrary rooftop blocks. The terrace
        // is supported by the full lower volume, and both levels retain the original floor datums.
        let inset = min(2.4, DioramaPolygon.minimumAreaRectangle(plan.envelope).halfWidth * 0.16)
        if design.hasUpperSetback,
           let upperRing = DarArchitecturePlan.inset(plan.envelope, distance: inset),
           let upper = DarArchitecturePlan(footprint: upperRing, site: site) {
            let split = max(3, plan.levels - (design.variant == 3 ? 3 : 2))
            buildFacades(plan, floors: 1..<split, into: &mesh, glow: &glow)
            use(cream, .trimWhite, &mesh)
            DarArchitecturalKit.solid(plan.envelope, bottom: plan.floor(split) - 0.28,
                top: plan.floor(split), shoulder: 0.07, color: .trimWhite, into: &mesh)
            // Solid terrace parapet follows the building perimeter; never a tank enclosure.
            DarArchitecturalKit.ribbon(plan.envelope, bottom: plan.floor(split), top: plan.floor(split) + 0.95,
                depth: 0.24, color: .trimWhite, into: &mesh)
            buildFacades(upper, floors: split..<upper.levels, into: &mesh, glow: &glow)
            buildRoof(upper, into: &mesh)
        } else {
            buildFacades(plan, floors: 1..<plan.levels, into: &mesh, glow: &glow)
            buildRoof(plan, into: &mesh)
        }
        return true
    }

    /// Coarse tiles retain the same silhouette, setbacks and pitched roof without facade cells/services.
    @discardableResult
    mutating func buildContext(_ footprint: [DV2], into mesh: inout DioramaMesh) -> Bool {
        guard let plan = DarArchitecturePlan(footprint: footprint, site: site) else { return false }
        let oldTint = mesh.tint
        defer { mesh.tint = oldTint }
        use(design.family == .glass ? glass : wall, .whitewash, &mesh)
        let inset = min(2.4, DioramaPolygon.minimumAreaRectangle(plan.envelope).halfWidth * 0.16)
        if design.hasUpperSetback, let upperRing = DarArchitecturePlan.inset(plan.envelope, distance: inset),
           let upper = DarArchitecturePlan(footprint: upperRing, site: site) {
            let split = max(3, plan.levels - (design.variant == 3 ? 3 : 2))
            mesh.extrude(plan.envelope, z0: 0, z1: plan.floor(split), .whitewash, top: .roofConcrete)
            mesh.extrude(upper.envelope, z0: plan.floor(split), z1: plan.height, .whitewash)
            buildRoof(upper, services: false, into: &mesh)
        } else {
            mesh.extrude(plan.envelope, z0: 0, z1: plan.height, .whitewash)
            buildRoof(plan, services: false, into: &mesh)
        }
        return true
    }

    /// Shader facades: each elevation is one quad from plinth to roof; the family decides which
    /// facade the shader draws (punched masonry, ribbon bands, curtain grid, coastal galleries),
    /// the taller ground floor is encoded in the wall so lobbies and shopfronts land on it.
    private mutating func buildShaderFacades(_ plan: DarArchitecturePlan, into mesh: inout DioramaMesh,
                                             lights: inout [DioramaLight]) {
        let front = plan.elevations[plan.entrance]
        let family = design.family
        func facades(_ p: DarArchitecturePlan) -> (Int) -> DioramaFacade {
            let longest = p.elevations.map(\.length).max() ?? 1
            return { i in
                let e = p.elevations[i]
                let style: DioramaFacade.Style
                if e.length < 3 {
                    style = .plain
                } else {
                    switch family {
                    case .glass: style = .curtain
                    case .ribbon: style = .ribbon
                    case .modernist: style = e.length < longest * 0.48 ? .plain : .masonry
                    case .kisutu, .tiled: style = .masonry
                    case .coastal: style = e.length >= 5 && abs(e.out.dot(front.out)) > 0.8 ? .gallery : .masonry
                    }
                }
                return DioramaFacade(style: style, storey: p.storey, groundFloor: p.groundFloor)
            }
        }
        // Curtain walls tint their glass with the vertex colour; every other facade is the render.
        let skin = family == .glass ? glass : wall
        use(skin, .whitewash, &mesh)
        let inset = min(2.4, DioramaPolygon.minimumAreaRectangle(plan.envelope).halfWidth * 0.16)
        if design.hasUpperSetback,
           let upperRing = DarArchitecturePlan.inset(plan.envelope, distance: inset),
           let upper = DarArchitecturePlan(footprint: upperRing, site: site) {
            let split = max(3, plan.levels - (design.variant == 3 ? 3 : 2))
            mesh.facadeRing(plan.envelope, bottom: { _ in -0.3 }, top: plan.floor(split), .whitewash,
                            front: plan.entrance, facade: facades(plan))
            use(cream, .trimWhite, &mesh)
            mesh.polygon(plan.envelope, z: plan.floor(split), .trimWhite)
            DarArchitecturalKit.ribbon(plan.envelope, bottom: plan.floor(split), top: plan.floor(split) + 0.95,
                depth: 0.24, color: .trimWhite, into: &mesh)
            use(skin, .whitewash, &mesh)
            mesh.facadeRing(upper.envelope, bottom: { _ in plan.floor(split) }, top: upper.height, .whitewash,
                            front: upper.entrance, facade: facades(upper))
            buildRoof(upper, into: &mesh)
        } else {
            mesh.facadeRing(plan.envelope, bottom: { _ in -0.3 }, top: plan.height, .whitewash,
                            front: plan.entrance, facade: facades(plan))
            buildRoof(plan, into: &mesh)
        }
        // Lobby glazing is drawn on the ground floor; a canopy would leave the mapped footprint.
        if includesLights {
            lights.append(.init(position: DV3(front.mid + front.out * 0.6, mesh.baseZ + 2.9),
                color: SIMD3(1, 0.82, 0.58), radius: 7, intensity: 0.55))
        }
    }

    private func buildGroundFloor(_ plan: DarArchitecturePlan, into mesh: inout DioramaMesh,
                                  glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let office = [.glass, .ribbon, .modernist].contains(design.family)
        let front = plan.elevations[plan.entrance]
        for e in plan.elevations {
            let activeFront = e.index == plan.entrance || (office && e.length > front.length * 0.65)
            if e.length < 3 || !activeFront {
                use(wall, .whitewash, &mesh)
                mesh.mouldedWall(plan.envelope, edge: e.index, z0: 0.32, z1: plan.groundFloor, .whitewash)
                continue
            }
            let recess = min(plan.recess, office ? 0.65 : 0.35)
            for bay in 0..<e.bays {
                let a = e.a + e.dir * (Double(bay) * e.pitch)
                let b = a + e.dir * e.pitch
                let opening = office ? 0.82 : 0.68
                openingBay(a: a, b: b, out: e.out, low: 0.32, high: plan.groundFloor,
                    sill: 0.03, lintel: 0.45, share: opening, recess: recess, pigment: wall,
                    lit: includesLights && bay == e.bays / 2, into: &mesh, glow: &glow)
            }
        }
        use(wall, .whitewash, &mesh)
        DarArchitecturalKit.solid(plan.envelope, bottom: plan.groundFloor - 0.22,
            top: plan.groundFloor, shoulder: 0.055, color: .whitewash, into: &mesh)
        // Only office lobbies receive a canopy; residential entrances use their lintel/recess.
        if office {
            let canopy = DarArchitecturalKit.roundedPlan(.init(centre: front.mid - front.out * 0.55, axis: front.dir,
                halfLength: min(front.length * 0.28, 4.5), halfWidth: 0.55), radius: 0.3)
            if DarArchitecturePlan.fits(canopy, inside: plan.source, clearance: -0.02) {
                use(cream, .trimWhite, &mesh)
                DarArchitecturalKit.solid(canopy, bottom: plan.groundFloor - 0.6,
                    top: plan.groundFloor - 0.3, shoulder: 0.075, color: .trimWhite, into: &mesh)
            }
        }
        if includesLights {
            lights.append(.init(position: DV3(front.mid - front.out * 0.15, mesh.baseZ + 2.9),
                color: SIMD3(1, 0.82, 0.58), radius: 7, intensity: 0.55))
        }
    }

    private func buildFacades(_ plan: DarArchitecturePlan, floors: Range<Int>,
                              into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        guard !floors.isEmpty else { return }
        switch design.family {
        case .kisutu, .tiled: masonry(plan, floors: floors, into: &mesh, glow: &glow)
        case .glass: curtain(plan, floors: floors, into: &mesh, glow: &glow)
        case .ribbon, .modernist: framedOffice(plan, floors: floors, into: &mesh, glow: &glow)
        case .coastal: apartments(plan, floors: floors, into: &mesh, glow: &glow)
        }
    }

    /// Rendered masonry surrounds actual punched openings; no full-height glass behind opaque walls.
    private func masonry(_ plan: DarArchitecturePlan, floors: Range<Int>, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        for e in plan.elevations {
            if e.length < 3 {
                use(wall, .whitewash, &mesh)
                mesh.mouldedWall(plan.envelope, edge: e.index, z0: plan.floor(floors.lowerBound), z1: plan.floor(floors.upperBound), .whitewash)
                continue
            }
            for f in floors {
                let low = plan.floor(f), high = plan.floor(f + 1)
                for bay in 0..<e.bays {
                    let a = e.a + e.dir * (Double(bay) * e.pitch), b = a + e.dir * e.pitch
                    let stair = design.family == .kisutu && e.index == plan.entrance && bay == (design.variant % max(1, e.bays))
                    let share = stair ? 0.26 : design.windowShare
                    openingBay(a: a, b: b, out: e.out, low: low, high: high,
                        sill: stair ? 0.55 : (design.family == .tiled ? 0.65 : 0.9),
                        lintel: stair ? 0.45 : 0.55, share: share, recess: plan.recess,
                        pigment: stair ? accent : wall, lit: isLit(e.index, bay, f), into: &mesh, glow: &glow)
                    // Narrow flush tile courses vs isolated plaster window hoods, not identical floor rings.
                    if design.family == .kisutu && !stair && design.variant % 2 == 0 {
                        use(cream, .whitewash, &mesh)
                        let left = a + e.dir * (e.pitch * (1 - share) / 2)
                        let right = b - e.dir * (e.pitch * (1 - share) / 2)
                        panel(a: left + e.out * 0.06, b: right + e.out * 0.06, out: e.out,
                            lower: high - 0.64, upper: high - 0.5, depth: max(0.1, plan.recess + 0.06), into: &mesh)
                    }
                }
                if design.family == .tiled {
                    use(accent, .whitewash, &mesh)
                    mesh.wall(e.a + e.out * 0.012, e.b + e.out * 0.012, z0: high - 0.28, z1: high - 0.08, .whitewash)
                }
            }
        }
    }

    /// Curtain-wall towers read as glazing with vertical seams, not white balcony stacks.
    private func curtain(_ plan: DarArchitecturePlan, floors: Range<Int>, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        for e in plan.elevations {
            let a = plan.glazing[e.index], b = plan.glazing[(e.index + 1) % plan.glazing.count]
            for f in floors {
                let low = plan.floor(f), high = plan.floor(f + 1)
                use(glass * 0.67, .glassPale, &mesh)
                mesh.wall(a, b, z0: low, z1: low + 0.38, .glassPale)
                for bay in 0..<e.bays {
                    let pa = a + (b - a) * (Double(bay) / Double(e.bays))
                    let pb = a + (b - a) * (Double(bay + 1) / Double(e.bays))
                    pane(pa, pb, out: e.out, low: low + 0.38, high: high,
                        lit: isLit(e.index, bay, f), mullion: false, into: &mesh, glow: &glow)
                }
                use(silver * 0.8, .mastGrey, &mesh)
                mesh.wall(a + e.out * 0.015, b + e.out * 0.015, z0: low + 0.35, z1: low + 0.41, .mastGrey)
            }
            if e.length < 3 { continue }
            use(silver, .mastGrey, &mesh)
            for k in 0...e.bays {
                let p = a + (b - a) * (Double(k) / Double(e.bays)) + e.out * 0.025
                mesh.facadeBox(a: p, dir: e.dir, out: e.out, u: 0, width: design.variant == 1 ? 0.16 : 0.09,
                    z0: plan.floor(floors.lowerBound), z1: plan.floor(floors.upperBound), depth: 0, .mastGrey, sides: false)
            }
        }
        // Opaque return and soffit close the inset facade to the original occupied envelope.
        use(silver, .mastGrey, &mesh)
        DarArchitecturalKit.ribbon(plan.envelope, bottom: plan.floor(floors.upperBound) - 0.16,
            top: plan.floor(floors.upperBound), depth: max(0.22, plan.recess + 0.05), color: .mastGrey, into: &mesh)
    }

    /// Ribbon offices have broad horizontal windows; modernist blocks have deep concrete eggcrates
    /// and quieter end walls. Neither receives residential railings or an invented crown.
    private func framedOffice(_ plan: DarArchitecturePlan, floors: Range<Int>, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let longest = plan.elevations[plan.entrance].length
        for e in plan.elevations {
            let endWall = e.length < 3 || (design.family == .modernist && e.length < longest * 0.48)
            if endWall {
                use(wall, .whitewash, &mesh)
                mesh.mouldedWall(plan.envelope, edge: e.index, z0: plan.floor(floors.lowerBound), z1: plan.floor(floors.upperBound), .whitewash)
                continue
            }
            for f in floors {
                let low = plan.floor(f), high = plan.floor(f + 1)
                for bay in 0..<e.bays {
                    let a = e.a + e.dir * (Double(bay) * e.pitch), b = a + e.dir * e.pitch
                    openingBay(a: a, b: b, out: e.out, low: low, high: high,
                        sill: design.family == .ribbon ? 0.82 : 0.32,
                        lintel: design.family == .ribbon ? 0.25 : 0.38,
                        share: design.windowShare, recess: plan.recess,
                        pigment: wall, lit: isLit(e.index, bay, f), into: &mesh, glow: &glow)
                }
            }
        }
    }

    /// Galleries only occupy the principal elevations. Solid end walls, alternating solid/glass
    /// balustrades and vertical room dividers replace the former all-sides wraparound cage.
    private func apartments(_ plan: DarArchitecturePlan, floors: Range<Int>, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let front = plan.elevations[plan.entrance]
        for e in plan.elevations {
            let gallery = e.length >= 5 && abs(e.out.dot(front.out)) > 0.8 && plan.recess >= 0.9
            if e.length < 3 {
                use(wall, .whitewash, &mesh)
                mesh.mouldedWall(plan.envelope, edge: e.index, z0: plan.floor(floors.lowerBound), z1: plan.floor(floors.upperBound), .whitewash)
                continue
            }
            for f in floors {
                let low = plan.floor(f), high = plan.floor(f + 1)
                for bay in 0..<e.bays {
                    let a = e.a + e.dir * (Double(bay) * e.pitch), b = a + e.dir * e.pitch
                    openingBay(a: a, b: b, out: e.out, low: low, high: high,
                        sill: gallery ? 0.08 : 0.88, lintel: gallery ? 0.28 : 0.48,
                        share: gallery ? 0.87 : design.windowShare, recess: gallery ? plan.recess : min(0.25, plan.recess),
                        pigment: wall, lit: isLit(e.index, bay, f), into: &mesh, glow: &glow)
                    if gallery {
                        let left = a + e.dir * (e.pitch * 0.065), right = b - e.dir * (e.pitch * 0.065)
                        use(cream, .whitewash, &mesh)
                        panel(a: left, b: right, out: e.out, lower: low + 0.08, upper: low + 0.16, depth: plan.recess + 0.03, into: &mesh)
                        // Closed balustrade panels are separated by structural room dividers.
                        let solidRail = design.variant == 0 || (design.variant == 2 && bay % 2 == 0)
                        let material: DioramaSwatch = solidRail ? .whitewash : .glassPale
                        use(solidRail ? cream : glass * 1.08, material, &mesh)
                        panel(a: left - e.out * 0.12, b: right - e.out * 0.12, out: e.out,
                            lower: low + 0.16, upper: low + 1.08, depth: 0.1, color: material, into: &mesh)
                    }
                }
            }
        }
    }

    private func isLit(_ edge: Int, _ bay: Int, _ floor: Int) -> Bool {
        includesLights && (bay * 3 + floor * 7 + edge + Int(site.osm % 29)) % 13 == 2
    }

    private func pane(_ a: DV2, _ b: DV2, out: DV2, low: Double, high: Double, lit: Bool,
                      mullion: Bool, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        guard high > low else { return }
        use(glass, .glassPale, &mesh)
        mesh.wall(a, b, z0: low, z1: high, .glassPale)
        if lit { glow.wall(a + out * 0.008, b + out * 0.008, z0: low + 0.06, z1: high - 0.06, .windowGlow) }
        if mullion {
            use(silver, .mastGrey, &mesh)
            mesh.facadeBox(a: (a + b) * 0.5 + out * 0.018, dir: (b - a).normalized, out: out, u: 0,
                width: 0.07, z0: low, z1: high, depth: 0, .mastGrey, sides: false)
        }
    }

    /// A genuine recessed opening in a solid wall: only the faces the map camera can see are built.
    /// The wall around the opening is four flat quads, the opening shows its two jamb returns and the
    /// top of its sill. The lintel's soffit, the backs of the wall, the ends shared with the next bay
    /// and the undersides are never visible, so the bay costs 7 quads instead of four closed blocks.
    private func openingBay(a: DV2, b: DV2, out: DV2, low: Double, high: Double, sill: Double, lintel: Double,
                            share: Double, recess: Double, pigment: SIMD3<Float>, lit: Bool,
                            into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let left = a + (b - a) * ((1 - share) * 0.5)
        let right = b - (b - a) * ((1 - share) * 0.5)
        let depth = max(0.08, recess)
        let dir = (b - a).normalized
        let face = DV3(out, 0)
        let sillZ = low + sill, headZ = high - lintel
        use(pigment, .whitewash, &mesh)
        if left.distance(to: a) > 0.005 {
            mesh.quad(DV3(a, low), DV3(left, low), DV3(left, high), DV3(a, high), .whitewash, normal: face)
        }
        if b.distance(to: right) > 0.005 {
            mesh.quad(DV3(right, low), DV3(b, low), DV3(b, high), DV3(right, high), .whitewash, normal: face)
        }
        guard headZ > sillZ, right.distance(to: left) > 0.005 else { return }
        if sill > 0.005 {
            mesh.quad(DV3(left, low), DV3(right, low), DV3(right, sillZ), DV3(left, sillZ), .whitewash, normal: face)
        }
        if lintel > 0.005 {
            mesh.quad(DV3(left, headZ), DV3(right, headZ), DV3(right, high), DV3(left, high), .whitewash, normal: face)
        }
        let innerLeft = left - out * depth, innerRight = right - out * depth
        mesh.quad(DV3(left, sillZ), DV3(innerLeft, sillZ), DV3(innerLeft, headZ), DV3(left, headZ), .whitewash, normal: DV3(dir, 0))
        mesh.quad(DV3(right, sillZ), DV3(innerRight, sillZ), DV3(innerRight, headZ), DV3(right, headZ), .whitewash, normal: DV3(-dir, 0))
        mesh.quad(DV3(left, sillZ), DV3(right, sillZ), DV3(innerRight, sillZ), DV3(innerLeft, sillZ), .whitewash, normal: .up)
        pane(innerLeft, innerRight, out: out, low: sillZ, high: headZ,
            lit: lit, mullion: true, into: &mesh, glow: &glow)
    }

    /// Balustrade panel: a closed block without its underside, which faces the gallery floor.
    private func panel(a: DV2, b: DV2, out: DV2, lower: Double, upper: Double, depth: Double,
                       color: DioramaSwatch = .whitewash, into mesh: inout DioramaMesh) {
        guard upper > lower, a.distance(to: b) > 0.005 else { return }
        let ring = DioramaPolygon.counterClockwise([a, b, b - out * depth, a - out * depth])
        mesh.extrude(ring, z0: lower, z1: upper, color, top: color)
    }

    private mutating func buildRoof(_ plan: DarArchitecturePlan, services: Bool = true, into mesh: inout DioramaMesh) {
        if site.crown == "hip", ["teal", "terracotta"].contains(site.roof) {
            mesh.tint = SIMD3(repeating: 1)
            if DioramaRoofBuilder.hip(plan.source, flags: Array(repeating: false, count: plan.source.count), z: plan.height,
                pitch: 22 * .pi / 180, overhang: 0, maxRise: 5, color: site.roof == "teal" ? .roofTeal : .roofTerracotta,
                fascia: .trimWhite, into: &mesh, footprint: plan.source) { hasPitchedRoof = true; return }
        }
        use(Self.rgb("#C9C2B6"), .roofConcrete, &mesh)
        if DioramaConfig.shaderFacades {
            // The facade wall already reaches the roof; a slab ring here would sit in its plane.
            mesh.polygon(plan.envelope, z: plan.height, .roofConcrete)
        } else {
            DarArchitecturalKit.solid(plan.envelope, bottom: plan.height - 0.16, top: plan.height,
                shoulder: 0.04, color: .roofConcrete, into: &mesh)
        }
        let parapet = design.family == .glass ? 0.25 : (design.family == .modernist ? 0.42 : 0.65)
        use(design.family == .glass ? silver : wall, .trimWhite, &mesh)
        DarArchitecturalKit.ribbon(plan.envelope, bottom: plan.height, top: plan.height + parapet,
            depth: design.family == .kisutu ? 0.3 : 0.22, color: .trimWhite, into: &mesh)
        // No service court geometry: this rectangle is only a collision/clearance workspace.
        guard services, let zone = plan.serviceZone else { return }
        mesh.tint = SIMD3(repeating: 1)
        if design.hasRoofAccess, zone.halfLength > 3.5 {
            let p = zone.centre + zone.axis * (zone.halfLength - 1.5)
            let access = DarArchitecturalKit.roundedPlan(.init(centre: p, axis: zone.axis,
                halfLength: 1.2, halfWidth: 1.0), radius: 0.18)
            if DarArchitecturePlan.fits(access, inside: plan.envelope, clearance: 0.5) {
                use(wall, .whitewash, &mesh)
                DarArchitecturalKit.solid(access, bottom: plan.height, top: plan.height + 2.25,
                    shoulder: 0.12, color: .whitewash, into: &mesh)
                use(Self.rgb("#3E3E40"), .mastGrey, &mesh)
                mesh.facadeBox(a: p - zone.across * 1.005, dir: zone.axis, out: -zone.across, u: 0,
                    width: 0.8, z0: plan.height + 0.02, z1: plan.height + 1.95, depth: 0, .mastGrey, sides: false)
            }
        }
        mesh.tint = SIMD3(repeating: 1)
        for k in 0..<design.tankCount {
            let p = zone.centre - zone.axis * min(1.6, zone.halfLength * 0.45)
                + zone.across * (Double(k) - Double(design.tankCount - 1) * 0.5) * 1.75
            let footprint = DioramaOrientedRect(centre: p, axis: DV2(1, 0), halfLength: 0.85, halfWidth: 0.7)
            if DarArchitecturePlan.fits(footprint.corners, inside: plan.envelope, clearance: 0.4) {
                DarArchitecturalKit.tank(at: p, bottom: plan.height, color: .tankBlack, into: &mesh)
            }
        }
    }
}
