import Foundation

/// Everything in the tile that is neither a road nor a house, built from the mapped amenities so the
/// diorama matches the real Slipway: padel and sports courts with lines, nets and glass; the hotel car
/// park with marked bays; the two fuel forecourts with canopies and pumps; the DoubleTree and Slipway
/// pools with loungers; structural timber terraces with parasols; paved footways, steps and the
/// mapped wooden pier; telecom masts, a playground, a sculpture and the mosque's minaret.
nonisolated struct DioramaAmenityGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let library: DioramaPropLibrary
    let buildings: [DioramaBuilt]
    let terrain: DioramaTerrain
    let painter: DioramaGroundPainter

    private func z(_ p: DV2) -> Double { terrain.height(p) }

    private func isWater(_ p: DV2) -> Bool {
        data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) }
    }

    func generate(ground: inout DioramaMesh, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        // Every mapped terrace and pool owns its surface and furniture. Courtyard paving clips
        // around them; it must never disable an entire amenity based on its centroid.
        for area in data.landuse {
            guard let outer = area.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect.expanded(by: -0.3))
            guard ring.count >= 3, DioramaPolygon.area(ring) > (area.kind == "pool" ? 3 : 15) else { continue }
            var rng = DioramaRandom(seed: area.id, salt: 51)
            switch area.kind {
            case "pitch": court(ring, areaID: area.id, sport: area.sport, rng: &rng, ground: &ground, props: &props)
            case "parking": carPark(ring, areaID: area.id, rng: &rng, ground: &ground, props: &props)
            case "fuel": fuelStation(ring, areaID: area.id, rng: &rng, ground: &ground, props: &props, glow: &glow, lights: &lights)
            case "pool": pool(ring, areaID: area.id, isPrivate: area.sport == "private", rng: &rng, ground: &ground, props: &props)
            case "terrace": terrace(ring, areaID: area.id, rng: &rng, ground: &ground, props: &props, glow: &glow, lights: &lights)
            default: break
            }
        }
        footways()
        for path in data.paths {
            switch path.kind {
            case "pier": pier(path.line, props: &props)
            // The mapped slipway line is not a surveyed ramp footprint. Do not stretch an
            // inferred 8 m slab across its entire 65 m line and invent offshore sidewalls.
            case "slipway": break
            case "steps":
                // Remove only the two rejected pale hotel flights; the clay courtyard stair is authored separately.
                guard ![UInt64(1_128_219_564), 1_128_219_566].contains(path.sourceID ?? path.id) else { continue }
                let stairRing = DioramaHotelGrounds.stairOutline(data: data)
                if !path.line.contains(where: { DioramaPolygon.contains(stairRing, $0) || DioramaPolygon.distanceToRing(stairRing, $0) < 2 }) {
                    steps(path.line, ground: &ground)
                }
            default: break
            }
        }
        for poi in data.pois {
            var rng = DioramaRandom(seed: poi.id, salt: 53)
            switch poi.kind {
            case "tower": mast(at: poi.point, props: &props, glow: &glow, lights: &lights)
            case "playground": playground(at: poi.point, rng: &rng, ground: &ground, props: &props)
            case "artwork": sculpture(at: poi.point, ground: &ground, props: &props)
            case "mosque": minaret(near: poi.point, props: &props, glow: &glow, lights: &lights)
            default: break
            }
        }
    }

    /// A structural slab owns only its unoccupied plan. It cannot cover a road, another amenity
    /// or a building merely because its plateau is higher than those surfaces.
    @discardableResult
    private func ownedSlab(_ ring: [DV2], areaID: UInt64, top: Double, side: DioramaSwatch,
                           finish: DioramaSwatch, ground: inout DioramaMesh) -> [[DV2]] {
        let masks = DioramaGroundCutouts(data: data, pavementWidth: config.pavementWidth,
            additionalMasks: data.water.compactMap { $0.rings.first }, excludedAreaIDs: [areaID])
        let pieces = masks.subtract(from: ring)
        for piece in pieces {
            terrain.foundation(piece, top: top, swatch: side, into: &ground)
            ground.polygon(piece, z: top, finish)
        }
        return pieces
    }

    // MARK: Courts

    /// Padel court (blue, glass back walls, net) or a general pitch (green, white lines, goals).
    private func court(_ ring: [DV2], areaID: UInt64, sport: String?, rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let base = terrain.foundationHeight(box.expanded(by: 1).corners)
        let isPadel = sport == "padel"
        let surface: DioramaSwatch = isPadel ? .courtBlue : .pitchGreen
        // Slab with a pale kerb, then the playing surface a touch higher.
        let pieces = ownedSlab(ring, areaID: areaID, top: base + 0.16, side: .kerb, finish: .kerb, ground: &ground)
        let inner = box.expanded(by: -0.35)
        let playing = DioramaStreetSurface(pieces).intersection(inner.corners)
        for piece in playing { ground.polygon(piece, z: base + 0.18, surface) }
        func onCourt(_ p: DV2) -> Bool { playing.contains { DioramaPolygon.contains($0, p) } }
        let top = base + 0.18 + DioramaSurfaceLevel.structuralPaintClearance
        let a = inner.axis, c = inner.across
        let L = inner.halfLength, W = inner.halfWidth
        func line(_ p: DV2, _ q: DV2, width: Double = 0.07) {
            let n = (q - p).normalized.right * width
            guard [p - n, q - n, q + n, p + n].allSatisfy(onCourt) else { return }
            ground.quad(DV3(p - n, top), DV3(q - n, top), DV3(q + n, top), DV3(p + n, top), .courtLine, normal: .up)
        }
        // Boundary lines, centre line.
        let corners = inner.expanded(by: -0.3).corners
        for i in 0..<4 { line(corners[i], corners[(i + 1) % 4]) }
        line(inner.centre - c * (W - 0.3), inner.centre + c * (W - 0.3))
        if isPadel {
            // Service lines and the centre service line.
            for s in [-1.0, 1.0] {
                let sl = inner.centre + a * (s * L * 0.68)
                line(sl - c * (W - 0.3), sl + c * (W - 0.3))
                line(inner.centre + a * (s * L * 0.68), inner.centre)
            }
            // Net: posts and a dark mesh panel.
            for s in [-1.0, 1.0] {
                let post = inner.centre + c * (s * (W - 0.2))
                props.cylinder(centre: post, z0: top, z1: top + 1.0, r0: 0.05, r1: 0.05, sides: 5, .metalCharcoal)
            }
            let n0 = inner.centre - c * (W - 0.2), n1 = inner.centre + c * (W - 0.2)
            props.quad(DV3(n0, top + 0.05), DV3(n1, top + 0.05), DV3(n1, top + 0.9), DV3(n0, top + 0.9), .metalCharcoal, normal: DV3(a, 0))
            props.box(centre: inner.centre, z0: top + 0.88, axis: c, halfLength: W - 0.2, halfWidth: 0.02, height: 0.06, .trimWhite)
            // Glass back walls (3 m) and mesh side fences (4 m posts).
            let glassH = 3.0
            for s in [-1.0, 1.0] {
                let e0 = inner.centre + a * (s * L) - c * W, e1 = inner.centre + a * (s * L) + c * W
                let out = (s > 0 ? a : -a)
                props.quad(DV3(e0, top), DV3(e1, top), DV3(e1, top + glassH), DV3(e0, top + glassH), .glassPale, normal: DV3(out, 0))
                props.box(centre: (e0 + e1) * 0.5, z0: top + glassH - 0.05, axis: c, halfLength: W, halfWidth: 0.05, height: 0.1, .metalCharcoal)
                // Glass returns 2 m along each side.
                for t in [-1.0, 1.0] {
                    let r0 = inner.centre + a * (s * L) + c * (t * W), r1 = r0 - a * (s * 2.0)
                    props.quad(DV3(r0, top), DV3(r1, top), DV3(r1, top + glassH), DV3(r0, top + glassH), .glassPale, normal: DV3(c * t, 0))
                }
            }
            let postStep = 2.0
            var d = -L
            while d <= L + 0.01 {
                for t in [-1.0, 1.0] {
                    let p = inner.centre + a * d + c * (t * W)
                    props.cylinder(centre: p, z0: top, z1: top + 4.0, r0: 0.06, r1: 0.05, sides: 5, .metalCharcoal)
                }
                let q0 = inner.centre + a * d, q1 = inner.centre + a * min(d + postStep, L)
                if q1.distance(to: q0) > 0.2 {
                    for t in [-1.0, 1.0] {
                        let s0 = q0 + c * (t * W), s1 = q1 + c * (t * W)
                        props.box(centre: (s0 + s1) * 0.5, z0: top + 3.95, axis: a, halfLength: s0.distance(to: s1) / 2, halfWidth: 0.03, height: 0.06, .metalCharcoal)
                    }
                }
                d += postStep
            }
            // Floodlights on the corners.
            for (s, t) in [(-1.0, -1.0), (1.0, 1.0)] {
                let p = inner.centre + a * (s * (L - 0.3)) + c * (t * (W + 0.5))
                props.cylinder(centre: p, z0: top, z1: top + 6.0, r0: 0.08, r1: 0.06, sides: 5, .lampPole)
                props.box(centre: p - c * (t * 0.3), z0: top + 5.8, axis: a, halfLength: 0.35, halfWidth: 0.2, height: 0.25, .lampPole, bevel: 0.04)
            }
        } else {
            // Penalty boxes, centre circle and two goals.
            for s in [-1.0, 1.0] {
                let gl = inner.centre + a * (s * (L - 0.3))
                let boxDepth = min(L * 0.3, 4.0), boxHalf = min(W * 0.6, 5.0)
                line(gl - c * boxHalf, gl - a * (s * boxDepth) - c * boxHalf)
                line(gl + c * boxHalf, gl - a * (s * boxDepth) + c * boxHalf)
                line(gl - a * (s * boxDepth) - c * boxHalf, gl - a * (s * boxDepth) + c * boxHalf)
                let goalHalf = min(W * 0.3, 1.8)
                let g0 = gl - c * goalHalf, g1 = gl + c * goalHalf
                for g in [g0, g1] { props.cylinder(centre: g, z0: top, z1: top + 1.4, r0: 0.05, r1: 0.05, sides: 5, .goalWhite) }
                props.box(centre: gl, z0: top + 1.36, axis: c, halfLength: goalHalf, halfWidth: 0.04, height: 0.08, .goalWhite)
                let back = gl + a * (s * 0.8)
                props.quad(DV3(g0, top + 1.4), DV3(g1, top + 1.4), DV3(back + c * goalHalf, top), DV3(back - c * goalHalf, top), .goalWhite)
            }
            let segments = 14
            for k in 0..<segments {
                let t0 = Double(k) / Double(segments) * 2 * Double.pi, t1 = Double(k + 1) / Double(segments) * 2 * Double.pi
                let r = min(W * 0.4, 2.5)
                line(inner.centre + a * (cos(t0) * r) + c * (sin(t0) * r), inner.centre + a * (cos(t1) * r) + c * (sin(t1) * r), width: 0.06)
            }
            // Low fence and corner floodlights.
            let fence = inner.expanded(by: 0.2).corners
            for i in 0..<4 {
                let p0 = fence[i], p1 = fence[(i + 1) % 4]
                let dir = (p1 - p0).normalized
                var d = 0.0
                let length = p0.distance(to: p1)
                while d < length - 0.5 {
                    props.cylinder(centre: p0 + dir * d, z0: top, z1: top + 1.2, r0: 0.04, r1: 0.04, sides: 4, .metalCharcoal)
                    d += 2.5
                }
                props.box(centre: (p0 + p1) * 0.5, z0: top + 1.15, axis: dir, halfLength: length / 2, halfWidth: 0.025, height: 0.05, .metalCharcoal)
            }
            for (s, t) in [(-1.0, -1.0), (1.0, 1.0), (-1.0, 1.0), (1.0, -1.0)] where rng.chance(0.6) {
                let p = inner.centre + a * (s * (L + 0.6)) + c * (t * (W + 0.6))
                props.cylinder(centre: p, z0: top, z1: top + 7.0, r0: 0.09, r1: 0.06, sides: 5, .lampPole)
                props.box(centre: p - a * (s * 0.3), z0: top + 6.8, axis: c, halfLength: 0.35, halfWidth: 0.22, height: 0.25, .lampPole, bevel: 0.04)
            }
        }
    }

    // MARK: Car park

    private func carPark(_ ring: [DV2], areaID: UInt64, rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let base = terrain.foundationHeight(ring)
        let pieces = ownedSlab(ring, areaID: areaID, top: base + 0.1, side: .kerb, finish: .asphalt, ground: &ground)
        func onParking(_ p: DV2) -> Bool { pieces.contains { DioramaPolygon.contains($0, p) } }
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let top = base + 0.1 + DioramaSurfaceLevel.structuralPaintClearance
        // Bays 2.6 m wide along both long sides, nose-in from a central aisle.
        let bayDepth = min(box.halfWidth - 0.5, 5.0)
        guard bayDepth > 2.5 else { return }
        let a = box.axis, c = box.across
        var u = -box.halfLength + 1.5
        while u <= box.halfLength - 1.5 {
            for s in [-1.0, 1.0] {
                let p0 = box.centre + a * u + c * (s * box.halfWidth), p1 = box.centre + a * u + c * (s * (box.halfWidth - bayDepth))
                guard DioramaPolygon.contains(ring, p0 + c * (-s * 0.3)), DioramaPolygon.contains(ring, p1) else { continue }
                let n = c * 0.06
                if [p0 - n, p1 - n, p1 + n, p0 + n].allSatisfy(onParking) {
                    ground.quad(DV3(p0 - n, top), DV3(p1 - n, top), DV3(p1 + n, top), DV3(p0 + n, top), .marking, normal: .up)
                }
                let bayCentre = box.centre + a * (u + 1.3) + c * (s * (box.halfWidth - bayDepth / 2))
                if u + 2.6 <= box.halfLength - 1.5, DioramaOrientedRect(centre: bayCentre, axis: c, halfLength: 2.2, halfWidth: 1.0).corners.allSatisfy(onParking), rng.chance(0.55) {
                    let heading = (c * -s).angle + rng.range(-0.04...0.04)
                    props.instance(rng.pick(library.cars), DioramaTransform(rotation: heading, translation: DV3(bayCentre, top)))
                }
            }
            u += 2.6
        }
        // A planter island with a tree in the middle of long car parks.
        if box.halfLength > 14 {
            let island = DioramaOrientedRect(centre: box.centre, axis: a, halfLength: 2.0, halfWidth: 0.9)
            ground.extrude(island.corners, z0: top, z1: top + 0.25, .kerb, top: .soil)
            props.instance(library.trees[8], DioramaTransform(rotation: rng.range(0...6.28), translation: DV3(box.centre, top + 0.25)))
        }
    }

    // MARK: Fuel station

    private func fuelStation(_ ring: [DV2], areaID: UInt64, rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let base = terrain.foundationHeight(ring)
        let pieces = ownedSlab(ring, areaID: areaID, top: base + 0.1, side: .kerb, finish: .concrete, ground: &ground)
        DioramaFuelStation(config: config, terrain: terrain, roads: roads, library: library)
            .build(ring: ring, pieces: pieces, top: base + 0.1, rng: &rng, props: &props, glow: &glow, lights: &lights)
    }

    // MARK: Pools and terraces

    /// Swimming pool: pale coping deck, a tiled basin and turquoise water (the shader adds the caustic
    /// shimmer). Hotel pools get rows of loungers and parasols; the small private garden pools surveyed
    /// from satellite imagery get a narrow deck and a lounger or two.
    private func pool(_ sourceRing: [DV2], areaID: UInt64, isPrivate: Bool, rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let ring = DioramaPolygon.rounded(sourceRing, flags: Array(repeating: false, count: sourceRing.count),
                                          radius: isPrivate ? 0.45 : 0.8, segments: 12).points
        let deckWidth = isPrivate ? 1.1 : 2.2
        let deck = DioramaPolygon.offset(ring, by: deckWidth) ?? ring
        // Keep the entire basin above continuous land; no hidden floor beneath grass.
        let base = terrain.foundationHeight(deck) + 0.55
        let deckTop = base + 0.12
        let excluded = Set(data.landuse.filter { $0.kind == "terrace" || $0.id == areaID }.map(\.id))
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: config.pavementWidth,
                                           additionalMasks: [ring], excludedAreaIDs: excluded)
        let deckPieces = cutouts.subtract(from: deck)
        // Boolean annulus, clipped to neighbours and roads; no assumed offset-vertex correspondence.
        for piece in deckPieces {
            terrain.foundation(piece, top: deckTop, swatch: .poolCoping, into: &ground)
            ground.polygon(piece, z: deckTop, .poolCoping)
        }
        func onDeck(_ p: DV2) -> Bool { deckPieces.contains { DioramaPolygon.contains($0, p) } }
        // Basin walls in pale tile, the floor a step lower, then the water sheet just under the coping.
        ground.extrude(ring, z0: base - 0.5, z1: deckTop + 0.01, .skyBlue, top: nil)
        ground.polygon(ring, z: base - 0.5, .skyBlue)
        ground.polygon(ring, z: deckTop - 0.08, .poolBlue)
        // Rounded coping lip so the edge catches the light.
        // A rounded swept lip, open in the centre; never cap the basin with a solid slab.
        ground.band(ring, offset: 0.18, z0: deckTop, z1: deckTop + 0.05, .trimWhite)
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        if isPrivate {
            // A pool ladder on one short end and up to two loungers where the deck has room.
            let end = box.centre + box.axis * (box.halfLength - 0.3)
            for s in [-0.25, 0.25] {
                let p = end + box.across * s
                props.tube(from: DV3(p, deckTop - 0.4), to: DV3(p, deckTop + 0.7), r0: 0.03, r1: 0.03, sides: 4, .trimWhite)
            }
            props.tube(from: DV3(end - box.across * 0.25, deckTop + 0.7), to: DV3(end + box.across * 0.25, deckTop + 0.7), r0: 0.03, r1: 0.03, sides: 4, .trimWhite)
            var placed = 0
            for s in [-1.0, 1.0] where placed < 2 {
                let p = box.centre + box.across * (s * (box.halfWidth + 0.7)) + box.axis * rng.range(-0.6...0.6)
                let clear = DioramaPolygon.distanceToRing(ring, p) > 0.45 && !DioramaPolygon.contains(ring, p)
                guard clear, onDeck(p), !buildings.contains(where: { $0.box.expanded(by: 0.3).contains(p) }), !roads.isOnCarriageway(p, margin: 0.5) else { continue }
                props.instance(library.lounger, DioramaTransform(rotation: (box.across * -s).angle, scale: DV3(0.85, 0.85, 0.85), translation: DV3(p, deckTop)))
                placed += 1
            }
            return
        }
        // Loungers and parasols along the long sides of hotel pools.
        let step = 2.4
        var u = -box.halfLength + 1.0
        while u <= box.halfLength - 1.0 {
            for s in [-1.0, 1.0] {
                let p = box.centre + box.axis * u + box.across * (s * (box.halfWidth + 1.3))
                guard onDeck(p), !DioramaPolygon.contains(ring, p) else { continue }
                guard !buildings.contains(where: { $0.box.expanded(by: 0.3).contains(p) }) else { continue }
                props.instance(library.lounger, DioramaTransform(rotation: (box.across * -s).angle, translation: DV3(p, deckTop)))
                if rng.chance(0.4) {
                    let q = p + box.axis * 1.1
                    if onDeck(q), !DioramaPolygon.contains(ring, q) {
                        props.instance(rng.pick(library.parasol), DioramaTransform(rotation: rng.range(0...6.28), scale: DV3(0.8, 0.8, 0.8), translation: DV3(q, deckTop)))
                    }
                }
            }
            u += step
        }
    }

    private func terrace(_ ring: [DV2], areaID: UInt64, rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let base = terrain.foundationHeight(ring)
        let top = max(connectedBuildingLevel(near: ring, within: 4) ?? base, max(base, terrain.pierLevel))
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: config.pavementWidth, excludedAreaIDs: [areaID])
        let pieces = cutouts.subtract(from: ring)
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        DioramaDeckGenerator(config: config, data: data, terrain: terrain)
            .build(pieces: pieces, top: top, axis: box.axis, props: &props)
        func onDeck(_ p: DV2) -> Bool { pieces.contains { DioramaPolygon.contains($0, p) } }
        // Parasols with tables, spaced on a grid.
        var y = -box.halfWidth + 1.8
        var k = 0
        while y < box.halfWidth - 1.2 {
            var x = -box.halfLength + 1.8 + Double(k % 2) * 1.6
            while x < box.halfLength - 1.2 {
                let p = box.centre + box.axis * x + box.across * y
                let footprint = DioramaOrientedRect(centre: p, axis: box.axis, halfLength: 1.4, halfWidth: 1.4)
                if onDeck(p), footprint.corners.allSatisfy(onDeck), DioramaPolygon.distanceToRing(ring, p) > 1.4, !buildings.contains(where: { $0.box.expanded(by: 1.4).contains(p) }) {
                    props.instance(rng.pick(library.parasol), DioramaTransform(rotation: rng.range(0...6.28), translation: DV3(p, top)))
                }
                x += 3.4
            }
            y += 3.2
            k += 1
        }
        // String lights: a warm wash over the terrace.
        if lights.count < config.maxLights {
            lights.append(DioramaLight(position: DV3(box.centre, top + 3.2), color: SIMD3<Float>(1.0, 0.78, 0.5), radius: max(box.halfLength, box.halfWidth) + 4, intensity: 0.8))
        }
    }

    // MARK: Paths, pier, slipway

    /// Footways are painted 1.6 m paving strokes; the courtyard and sea are painted after them.
    private func footways() {
        for path in data.paths where !["pier", "slipway", "steps"].contains(path.kind) {
            painter.stroke(path.line, width: 1.6, .paving)
        }
    }

    private func steps(_ line: [DV2], ground: inout DioramaMesh) {
        guard line.count >= 2 else { return }
        let a = line[0], b = line[line.count - 1]
        let length = a.distance(to: b)
        guard length > 0.5 else { return }
        let dir = (b - a).normalized
        let count = max(Int(length / 0.4), 2)
        let across = dir.right * 1.2
        let base = terrain.foundationHeight([a - across, b - across, b + across, a + across])
        for k in 0..<count {
            let p = a + dir * (length * (Double(k) + 0.5) / Double(count))
            let rise = 0.12 * Double(min(k, 5) + 1)
            let tread = DioramaOrientedRect(centre: p, axis: dir, halfLength: length / Double(count) / 2 + 0.01, halfWidth: 1.2)
            terrain.foundation(tread.corners, top: base + rise, swatch: .concrete, into: &ground)
            ground.box(centre: p, z0: base, axis: dir, halfLength: tread.halfLength, halfWidth: 1.2, height: rise, .concrete, top: .paving)
        }
    }

    /// Nearby mapped architecture supplies the floor datum, not a separate highest-ground slab.
    private func connectedBuildingLevel(near points: [DV2], within reach: Double) -> Double? {
        let nearest = buildings.map { building in
            let distance = points.map { p in
                DioramaPolygon.contains(building.feature.ring, p) ? 0 : DioramaPolygon.distanceToRing(building.feature.ring, p)
            }.min() ?? Double.infinity
            return (feature: building.feature, distance: distance)
        }.min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= reach else { return nil }
        return terrain.buildingHeight(nearest.feature)
    }

    /// Wooden pier on piles over the bay with a railing.
    private func pier(_ line: [DV2], props: inout DioramaMesh) {
        guard line.count >= 2 else { return }
        let deck = terrain.pierHeight(line)
        let half = 1.8
        // Orient from shore to sea regardless of the source way's ordering.
        let shoreFirst = terrain.height(line[0]) >= terrain.height(line[line.count - 1])
        let oriented = shoreFirst ? line : Array(line.reversed())
        let dense = DioramaPolygon.densify(oriented, maxStep: config.deckPostSpacing)
        let joins = DioramaShoreline.frames(dense)
        let left = dense.indices.map { dense[$0] + joins[$0] * half }
        let right = dense.indices.reversed().map { dense[$0] - joins[$0] * half }
        let outline = DioramaPolygon.counterClockwise(left + right)
        let pieces = DioramaGroundCutouts(polygons: data.buildings.map(\.ring)).subtract(from: outline)
        DioramaDeckGenerator(config: config, data: data, terrain: terrain)
            .build(pieces: pieces, top: deck, axis: (line[1] - line[0]).normalized, props: &props)
        // A pair of dhows moored at the head of the pier.
        let head = dense[dense.count - 1]
        let dir = (head - dense[dense.count - 2]).normalized
        for s in [-1.0, 1.0] {
            let p = head + dir.right * (s * 4.5) - dir * 3
            if isWater(p) {
                props.instance(library.dhow, DioramaTransform(rotation: dir.angle + s * 0.2, scale: DV3(0.8, 0.8, 0.8), translation: DV3(p, terrain.waterLevel)))
            }
        }
    }

    // MARK: Points of interest

    /// Lattice telecom mast with a red aircraft light.
    private func mast(at p: DV2, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let footing = DioramaOrientedRect(centre: p, axis: DV2(1, 0), halfLength: 1.6, halfWidth: 1.6).corners
        let base = terrain.foundationHeight(footing)
        terrain.foundation(footing, top: base, swatch: .concrete, into: &props)
        let h = 28.0
        props.box(centre: p, z0: base, halfLength: 1.6, halfWidth: 1.6, height: 0.5, .concrete)
        let legs = 3
        for k in 0..<legs {
            let a = Double(k) / Double(legs) * 2 * Double.pi
            let foot = p + DV2(cos(a), sin(a)) * 1.1
            let top = p + DV2(cos(a), sin(a)) * 0.35
            props.tube(from: DV3(foot, base + 0.5), to: DV3(top, base + h), r0: 0.09, r1: 0.06, sides: 4, .mastGrey, cap: false)
        }
        var zz = base + 3.0
        var k = 0
        while zz < base + h - 1 {
            let t = (zz - base) / h
            let r = 1.1 * (1 - t) + 0.35 * t
            for i in 0..<legs {
                let a0 = Double(i) / Double(legs) * 2 * Double.pi, a1 = Double(i + 1) / Double(legs) * 2 * Double.pi
                let q0 = DV3(p + DV2(cos(a0), sin(a0)) * r, zz), q1 = DV3(p + DV2(cos(a1), sin(a1)) * r, zz)
                props.tube(from: q0, to: q1, r0: 0.03, r1: 0.03, sides: 3, .mastGrey, cap: false)
                let q2 = DV3(p + DV2(cos(a1), sin(a1)) * (r - 0.1), zz + 3.0)
                if k % 2 == 0 { props.tube(from: q0, to: q2, r0: 0.025, r1: 0.025, sides: 3, .mastGrey, cap: false) }
            }
            zz += 3.0
            k += 1
        }
        // Antenna panels and dishes near the top.
        for i in 0..<3 {
            let a = Double(i) / 3 * 2 * Double.pi + 0.5
            let d = DV2(cos(a), sin(a))
            props.box(centre: p + d * 0.8, z0: base + h - 4, axis: d.left, halfLength: 0.35, halfWidth: 0.1, height: 2.2, .trimWhite)
        }
        props.sphere(centre: DV3(p + DV2(0.9, 0), base + h - 8), radii: DV3(0.5, 0.5, 0.5), .dishWhite, detail: 0)
        props.tube(from: DV3(p, base + h), to: DV3(p, base + h + 2.5), r0: 0.06, r1: 0.02, sides: 4, .mastGrey)
        glow.sphere(centre: DV3(p, base + h + 2.6), radii: DV3(0.3, 0.3, 0.3), .signRed, detail: 0)
        if lights.count < config.maxLights {
            lights.append(DioramaLight(position: DV3(p, base + h + 2.6), color: SIMD3<Float>(1.0, 0.2, 0.15), radius: 7, intensity: 0.9))
        }
    }

    private func playground(at p: DV2, rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let candidates = [0.0, Double.pi / 4, Double.pi / 2, Double.pi * 3 / 4]
        let pad = candidates.map { angle in
            DioramaOrientedRect(centre: p, axis: DV2(cos(angle), sin(angle)), halfLength: 5.3, halfWidth: 4.1)
        }.first { rect in
            let ring = rect.corners
            let samples = DioramaPolygon.densify(ring + [ring[0]], maxStep: 0.4) + [p]
            return samples.allSatisfy { q in
                !roads.isOnCarriageway(q, margin: 0.5) && !isWater(q) &&
                !buildings.contains { DioramaPolygon.contains($0.feature.ring, q) || DioramaPolygon.distanceToRing($0.feature.ring, q) < 0.4 }
            } && !buildings.contains { $0.feature.ring.contains(where: rect.contains) }
        }
        guard let pad else {
            #if DEBUG
            print("[Diorama] playground footprint blocked; retaining mapped point without overlapping equipment")
            #endif
            return
        }
        let base = terrain.foundationHeight(pad.corners)
        ground.extrude(pad.corners, z0: terrain.footingHeight(pad.corners), z1: base + 0.1, .coralStone, top: .earth)
        props.instance(library.playground, DioramaTransform(rotation: pad.axis.angle, translation: DV3(p, base + 0.1)))
    }

    private func sculpture(at p: DV2, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let footing = DioramaOrientedRect(centre: p, axis: DV2(1, 0), halfLength: 1, halfWidth: 1).corners
        let base = terrain.foundationHeight(footing)
        guard !roads.isOnRoad(p, margin: 1), !buildings.contains(where: { $0.box.expanded(by: 0.5).contains(p) }) else { return }
        terrain.foundation(footing, top: base, swatch: .concrete, into: &ground)
        ground.cylinder(centre: p, z0: base, z1: base + 0.9, r0: 1.0, r1: 0.9, sides: 10, .concrete)
        props.sphere(centre: DV3(p, base + 1.9), radii: DV3(0.7, 0.7, 0.9), .bronze)
        props.tube(from: DV3(p, base + 0.9), to: DV3(p, base + 2.9), r0: 0.18, r1: 0.1, sides: 6, .bronze)
        props.sphere(centre: DV3(p + DV2(0.5, 0.2), base + 2.6), radii: DV3(0.35, 0.35, 0.45), .bronze, detail: 0)
    }

    /// Minaret and dome for the mosque: placed on the nearest building's roof corner when the mapped
    /// point falls on a building, else standing beside it.
    private func minaret(near p: DV2, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        // Enclosing mosques are now complete footprint-led buildings, not rooftop add-ons.
        if buildings.contains(where: { DioramaPolygon.contains($0.feature.ring, p) }) { return }
        let host: DioramaBuilt? = nil
        var spot = p
        var baseZ = z(p)
        if let host, host.feature.centroid.distance(to: p) < 30 {
            let corner = host.box.corners[0]
            spot = corner + (host.box.centre - corner).normalized * 1.6
            baseZ = terrain.buildingHeight(host.feature) + host.height + (host.flatRoof ? config.roofBevel : 0)
            // Green dome in the middle of the roof.
            props.cylinder(centre: host.box.centre, z0: baseZ, z1: baseZ + 1.0, r0: 2.6, r1: 2.6, sides: 12, .whitewash)
            props.sphere(centre: DV3(host.box.centre, baseZ + 1.0), radii: DV3(2.6, 2.6, 2.3), .domeGreen)
            props.tube(from: DV3(host.box.centre, baseZ + 3.2), to: DV3(host.box.centre, baseZ + 4.6), r0: 0.12, r1: 0.03, sides: 5, .sunflower)
        } else {
            guard !roads.isOnRoad(spot, margin: 1.5) else { return }
            let footing = DioramaOrientedRect(centre: spot, axis: DV2(1, 0), halfLength: 0.9, halfWidth: 0.9).corners
            baseZ = terrain.foundationHeight(footing)
            terrain.foundation(footing, top: baseZ, swatch: .concrete, into: &props)
        }
        let h = 14.0
        props.cylinder(centre: spot, z0: baseZ, z1: baseZ + h, r0: 0.9, r1: 0.75, sides: 8, .whitewash)
        props.cylinder(centre: spot, z0: baseZ + h, z1: baseZ + h + 0.5, r0: 1.2, r1: 1.2, sides: 8, .trimWhite)
        props.cylinder(centre: spot, z0: baseZ + h + 0.5, z1: baseZ + h + 2.6, r0: 0.6, r1: 0.6, sides: 8, .whitewash, cap: false)
        props.sphere(centre: DV3(spot, baseZ + h + 2.6), radii: DV3(0.85, 0.85, 0.8), .domeGreen)
        props.tube(from: DV3(spot, baseZ + h + 3.3), to: DV3(spot, baseZ + h + 4.4), r0: 0.08, r1: 0.02, sides: 5, .sunflower)
        for k in 0..<4 {
            let a = Double(k) / 4 * 2 * Double.pi
            let d = DV2(cos(a), sin(a))
            glow.box(centre: spot + d * 0.62, z0: baseZ + h + 1.0, axis: d.left, halfLength: 0.18, halfWidth: 0.03, height: 0.8, .lampGlow)
        }
        if lights.count < config.maxLights {
            lights.append(DioramaLight(position: DV3(spot, baseZ + h + 1.4), color: SIMD3<Float>(0.6, 1.0, 0.7), radius: 12, intensity: 0.9))
        }
    }
}
