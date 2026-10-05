import Foundation

/// Everything in the tile that is neither a road nor a house, built from the mapped amenities so the
/// diorama matches the real Slipway: padel and sports courts with lines, nets and glass; the hotel car
/// park with marked bays; the two fuel forecourts with canopies and pumps; the DoubleTree and Slipway
/// pools with loungers; restaurant terraces with parasols; paved footways, steps, the wooden pier, the
/// concrete slipway ramp; telecom masts, a playground, a sculpture and the mosque's minaret.
nonisolated struct DioramaAmenityGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let library: DioramaPropLibrary
    let buildings: [DioramaBuilt]
    let terrain: DioramaTerrain

    /// Footway surface above the ground plate.
    static let pathLift: Double = 0.08
    /// Absolute deck height of the pier over the bay.
    static let pierDeck: Double = 1.05

    private func z(_ p: DV2) -> Double { terrain.height(p) }

    private func isWater(_ p: DV2) -> Bool {
        data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) }
    }

    func generate(ground: inout DioramaMesh, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        for area in data.landuse {
            guard let outer = area.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect.expanded(by: -0.3))
            guard ring.count >= 3, DioramaPolygon.area(ring) > 15 else { continue }
            var rng = DioramaRandom(seed: area.id, salt: 51)
            switch area.kind {
            case "pitch": court(ring, sport: area.sport, rng: &rng, ground: &ground, props: &props)
            case "parking": carPark(ring, rng: &rng, ground: &ground, props: &props)
            case "fuel": fuelStation(ring, rng: &rng, ground: &ground, props: &props, glow: &glow, lights: &lights)
            case "pool": pool(ring, isPrivate: area.sport == "private", rng: &rng, ground: &ground, props: &props)
            case "terrace": terrace(ring, rng: &rng, ground: &ground, props: &props, glow: &glow, lights: &lights)
            default: break
            }
        }
        for path in data.paths {
            switch path.kind {
            case "pier": pier(path.line, props: &props)
            case "slipway": slipway(path.line, ground: &ground)
            case "steps": steps(path.line, ground: &ground)
            default: footway(path.line, ground: &ground)
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

    // MARK: Courts

    /// Padel court (blue, glass back walls, net) or a general pitch (green, white lines, goals).
    private func court(_ ring: [DV2], sport: String?, rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let base = z(box.centre)
        let isPadel = sport == "padel"
        let surface: DioramaSwatch = isPadel ? .courtBlue : .pitchGreen
        // Slab with a pale kerb, then the playing surface a touch higher.
        ground.extrude(ring, z0: base - 0.3, z1: base + 0.16, .kerb, top: .kerb)
        let inner = box.expanded(by: -0.35)
        ground.polygon(inner.corners, z: base + 0.18, surface)
        let top = base + 0.2
        let a = inner.axis, c = inner.across
        let L = inner.halfLength, W = inner.halfWidth
        func line(_ p: DV2, _ q: DV2, width: Double = 0.07) {
            let n = (q - p).normalized.right * width
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
            props.quad(DV3(n0, top + 0.05), DV3(n1, top + 0.05), DV3(n1, top + 0.9), DV3(n0, top + 0.9), .metalCharcoal, normal: DV3(-a, 0))
            props.box(centre: inner.centre, z0: top + 0.88, axis: c, halfLength: W - 0.2, halfWidth: 0.02, height: 0.06, .trimWhite)
            // Glass back walls (3 m) and mesh side fences (4 m posts).
            let glassH = 3.0
            for s in [-1.0, 1.0] {
                let e0 = inner.centre + a * (s * L) - c * W, e1 = inner.centre + a * (s * L) + c * W
                let out = (s > 0 ? a : -a)
                props.quad(DV3(e0, top), DV3(e1, top), DV3(e1, top + glassH), DV3(e0, top + glassH), .glassPale, normal: DV3(out, 0))
                props.quad(DV3(e0, top), DV3(e1, top), DV3(e1, top + glassH), DV3(e0, top + glassH), .glassPale, dark: true, normal: DV3(-out, 0))
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

    private func carPark(_ ring: [DV2], rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let base = z(DioramaPolygon.centroid(ring))
        ground.extrude(ring, z0: base - 0.3, z1: base + 0.1, .kerb, top: .asphalt)
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let top = base + 0.115
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
                ground.quad(DV3(p0 - n, top), DV3(p1 - n, top), DV3(p1 + n, top), DV3(p0 + n, top), .marking, normal: .up)
                let bayCentre = box.centre + a * (u + 1.3) + c * (s * (box.halfWidth - bayDepth / 2))
                if u + 2.6 <= box.halfLength - 1.5, DioramaPolygon.contains(ring, bayCentre), rng.chance(0.55) {
                    let heading = (c * -s).angle + rng.range(-0.04...0.04)
                    props.append(rng.pick(library.cars), DioramaTransform(rotation: heading, translation: DV3(bayCentre, top)))
                }
            }
            u += 2.6
        }
        // A planter island with a tree in the middle of long car parks.
        if box.halfLength > 14 {
            let island = DioramaOrientedRect(centre: box.centre, axis: a, halfLength: 2.0, halfWidth: 0.9)
            ground.extrude(island.corners, z0: top, z1: top + 0.25, .kerb, top: .soil)
            props.append(library.trees[8], DioramaTransform(rotation: rng.range(0...6.28), translation: DV3(box.centre, top + 0.25)))
        }
    }

    // MARK: Fuel station

    private func fuelStation(_ ring: [DV2], rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let base = z(DioramaPolygon.centroid(ring))
        ground.extrude(ring, z0: base - 0.3, z1: base + 0.1, .kerb, top: .concrete)
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let top = base + 0.1
        // Canopy over the pump island, clear of any building on the plot.
        var canopyCentre = box.centre
        let blockers = buildings.filter { DioramaPolygon.contains(ring, $0.feature.centroid) }
        if let shop = blockers.first {
            let away = (box.centre - shop.feature.centroid).normalized
            canopyCentre = shop.feature.centroid + away * (max(shop.box.halfLength, shop.box.halfWidth) + 7)
            if !DioramaPolygon.contains(ring, canopyCentre) { canopyCentre = box.centre }
        }
        let canopy = DioramaOrientedRect(centre: canopyCentre, axis: box.axis, halfLength: min(box.halfLength * 0.55, 9), halfWidth: min(box.halfWidth * 0.5, 6))
        let h = 5.2
        props.box(centre: canopy.centre, z0: top + h, axis: canopy.axis, halfLength: canopy.halfLength, halfWidth: canopy.halfWidth, height: 0.7, .trimWhite, top: .roofConcrete, bevel: 0.1, bottom: true)
        props.box(centre: canopy.centre, z0: top + h + 0.1, axis: canopy.axis, halfLength: canopy.halfLength + 0.05, halfWidth: canopy.halfWidth + 0.05, height: 0.3, .signRed, bottom: true)
        glow.box(centre: canopy.centre, z0: top + h - 0.03, axis: canopy.axis, halfLength: canopy.halfLength - 0.6, halfWidth: canopy.halfWidth - 0.6, height: 0.02, .lampGlow, bottom: true)
        for s in [-1.0, 1.0] {
            let col = canopy.centre + canopy.axis * (s * (canopy.halfLength - 1.2))
            props.box(centre: col, z0: top, axis: canopy.axis, halfLength: 0.3, halfWidth: 0.3, height: h, .trimWhite, bevel: 0.05)
        }
        // Pump island: raised kerb, pumps, a car filling up.
        let island = DioramaOrientedRect(centre: canopy.centre, axis: canopy.axis, halfLength: canopy.halfLength - 2.0, halfWidth: 0.7)
        ground.extrude(island.corners, z0: top, z1: top + 0.18, .kerb, top: .concrete)
        let pumps = max(Int(island.halfLength / 2.6), 1)
        for k in 0..<pumps {
            let u = -island.halfLength + island.halfLength * 2 * (Double(k) + 0.5) / Double(pumps)
            let p = island.centre + island.axis * u
            props.box(centre: p, z0: top + 0.18, axis: island.axis, halfLength: 0.5, halfWidth: 0.3, height: 1.7, .trimWhite, top: .signRed, bevel: 0.04)
            props.box(centre: p, z0: top + 0.9, axis: island.axis, halfLength: 0.52, halfWidth: 0.32, height: 0.35, .signRed)
            props.box(centre: p, z0: top + 1.3, axis: island.axis, halfLength: 0.4, halfWidth: 0.33, height: 0.25, .glass)
        }
        if lights.count < config.maxLights {
            lights.append(DioramaLight(position: DV3(canopy.centre, top + h - 0.2), color: SIMD3<Float>(1.0, 0.95, 0.82), radius: 14, intensity: 1.1))
        }
        let car = island.centre + island.across * 2.2
        props.append(rng.pick(library.cars), DioramaTransform(rotation: island.axis.angle, translation: DV3(car, top)))
        // Price totem by the road.
        if let road = roads.nearest(to: box.centre, within: 60) {
            let toRoad = (road.point - box.centre).normalized
            var totem = box.centre + toRoad * (max(box.halfLength, box.halfWidth) - 1.5)
            if !DioramaPolygon.contains(ring, totem) { totem = box.centre + toRoad * 3 }
            if DioramaPolygon.contains(ring, totem), !roads.isOnCarriageway(totem, margin: 1) {
                props.box(centre: totem, z0: top, axis: road.direction, halfLength: 0.9, halfWidth: 0.25, height: 5.5, .trimWhite, bevel: 0.05)
                props.box(centre: totem, z0: top + 4.0, axis: road.direction, halfLength: 0.95, halfWidth: 0.28, height: 1.4, .signRed)
                glow.box(centre: totem, z0: top + 2.4, axis: road.direction, halfLength: 0.8, halfWidth: 0.3, height: 1.4, .shopGlow)
            }
        }
    }

    // MARK: Pools and terraces

    /// Swimming pool: pale coping deck, a tiled basin and turquoise water (the shader adds the caustic
    /// shimmer). Hotel pools get rows of loungers and parasols; the small private garden pools surveyed
    /// from satellite imagery get a narrow deck and a lounger or two.
    private func pool(_ ring: [DV2], isPrivate: Bool, rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let base = z(DioramaPolygon.centroid(ring))
        let deckWidth = isPrivate ? 1.1 : 2.2
        let deck = DioramaPolygon.offset(ring, by: deckWidth) ?? ring
        let deckTop = base + 0.12
        ground.extrude(deck, z0: base - 0.2, z1: deckTop, .poolCoping, top: .poolCoping)
        // Basin walls in pale tile, the floor a step lower, then the water sheet just under the coping.
        ground.extrude(ring, z0: base - 0.5, z1: deckTop + 0.01, .skyBlue, top: nil)
        ground.polygon(ring, z: base - 0.5, .skyBlue)
        ground.polygon(ring, z: deckTop - 0.08, .poolBlue)
        // Rounded coping lip so the edge catches the light.
        if let lip = DioramaPolygon.offset(ring, by: 0.18) {
            ground.extrude(lip, z0: deckTop, z1: deckTop + 0.05, .trimWhite, top: .trimWhite)
        }
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
                guard clear, !buildings.contains(where: { $0.box.expanded(by: 0.3).contains(p) }), !roads.isOnCarriageway(p, margin: 0.5) else { continue }
                props.append(library.lounger, DioramaTransform(rotation: (box.across * -s).angle, scale: DV3(0.85, 0.85, 0.85), translation: DV3(p, deckTop)))
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
                guard DioramaPolygon.contains(deck, p), !DioramaPolygon.contains(ring, p) else { continue }
                guard !buildings.contains(where: { $0.box.expanded(by: 0.3).contains(p) }) else { continue }
                props.append(library.lounger, DioramaTransform(rotation: (box.across * -s).angle, translation: DV3(p, deckTop)))
                if rng.chance(0.4) {
                    let q = p + box.axis * 1.1
                    if DioramaPolygon.contains(deck, q), !DioramaPolygon.contains(ring, q) {
                        props.append(rng.pick(library.parasol), DioramaTransform(rotation: rng.range(0...6.28), scale: DV3(0.8, 0.8, 0.8), translation: DV3(q, deckTop)))
                    }
                }
            }
            u += step
        }
    }

    private func terrace(_ ring: [DV2], rng: inout DioramaRandom, ground: inout DioramaMesh, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let base = z(DioramaPolygon.centroid(ring))
        let top = base + 0.35
        ground.extrude(ring, z0: base - 0.4, z1: top, .pierWood, top: .deckWood)
        // Plank lines across the deck.
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        var u = -box.halfLength
        while u < box.halfLength {
            let p0 = box.centre + box.axis * u - box.across * box.halfWidth, p1 = box.centre + box.axis * u + box.across * box.halfWidth
            let n = box.axis * 0.025
            ground.quad(DV3(p0 - n, top + 0.005), DV3(p1 - n, top + 0.005), DV3(p1 + n, top + 0.005), DV3(p0 + n, top + 0.005), .pierWood, normal: .up)
            u += 0.9
        }
        // Balustrade on the edges facing water or open ground.
        let n = ring.count
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            let mid = (a + b) * 0.5
            let out = (b - a).normalized.right
            guard !buildings.contains(where: { $0.box.expanded(by: 0.8).contains(mid + out * 0.6) }) else { continue }
            let dir = (b - a).normalized
            let length = a.distance(to: b)
            var d = 0.0
            while d <= length {
                props.cylinder(centre: a + dir * d, z0: top, z1: top + 1.0, r0: 0.04, r1: 0.04, sides: 4, .trimWhite)
                d += 1.5
            }
            props.box(centre: mid, z0: top + 0.95, axis: dir, halfLength: length / 2, halfWidth: 0.03, height: 0.06, .trimWhite)
        }
        // Parasols with tables, spaced on a grid.
        var y = -box.halfWidth + 1.8
        var k = 0
        while y < box.halfWidth - 1.2 {
            var x = -box.halfLength + 1.8 + Double(k % 2) * 1.6
            while x < box.halfLength - 1.2 {
                let p = box.centre + box.axis * x + box.across * y
                if DioramaPolygon.contains(ring, p), DioramaPolygon.distanceToRing(ring, p) > 1.3, !buildings.contains(where: { $0.box.expanded(by: 1.2).contains(p) }) {
                    props.append(rng.pick(library.parasol), DioramaTransform(rotation: rng.range(0...6.28), translation: DV3(p, top)))
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

    private func footway(_ line: [DV2], ground: inout DioramaMesh) {
        let dense = DioramaPolygon.densify(line, maxStep: 4)
        let half = 0.8
        for i in 0..<(dense.count - 1) {
            let a = dense[i], b = dense[i + 1]
            let mid = (a + b) * 0.5
            guard !roads.isOnCarriageway(mid, margin: 0.2), !isWater(mid) else { continue }
            guard !buildings.contains(where: { $0.box.expanded(by: -0.2).contains(mid) }) else { continue }
            let n = (b - a).normalized.right * half
            let top = z(mid) + Self.pathLift
            ground.quad(DV3(a - n, top), DV3(b - n, top), DV3(b + n, top), DV3(a + n, top), .paving, normal: .up)
            // Kerb edges.
            for s in [-1.0, 1.0] {
                let e0 = a + n * s, e1 = b + n * s
                let out = DV3((e1 - e0).normalized.right * s, 0)
                ground.quad(DV3(e0, z(mid)), DV3(e1, z(mid)), DV3(e1, top), DV3(e0, top), .kerb, normal: out)
            }
        }
    }

    private func steps(_ line: [DV2], ground: inout DioramaMesh) {
        guard line.count >= 2 else { return }
        let a = line[0], b = line[line.count - 1]
        let length = a.distance(to: b)
        guard length > 0.5 else { return }
        let dir = (b - a).normalized
        let count = max(Int(length / 0.4), 2)
        let base = z(a)
        for k in 0..<count {
            let p = a + dir * (length * (Double(k) + 0.5) / Double(count))
            let rise = 0.12 * Double(min(k, 5) + 1)
            ground.box(centre: p, z0: base, axis: dir, halfLength: length / Double(count) / 2 + 0.01, halfWidth: 1.2, height: rise, .concrete, top: .paving)
        }
    }

    /// Wooden pier on piles over the bay with a railing.
    private func pier(_ line: [DV2], props: inout DioramaMesh) {
        guard line.count >= 2 else { return }
        let deck = Self.pierDeck
        let half = 1.8
        let dense = DioramaPolygon.densify(line, maxStep: 3)
        for i in 0..<(dense.count - 1) {
            let a = dense[i], b = dense[i + 1]
            let n = (b - a).normalized.right * half
            props.quad(DV3(a - n, deck), DV3(b - n, deck), DV3(b + n, deck), DV3(a + n, deck), .pierWood, normal: .up)
            props.quad(DV3(a - n, deck - 0.3), DV3(b - n, deck - 0.3), DV3(b + n, deck - 0.3), DV3(a + n, deck - 0.3), .pierWood, dark: true, normal: DV3(0, 0, -1))
            for s in [-1.0, 1.0] {
                let e0 = a + n * s, e1 = b + n * s
                props.quad(DV3(e0, deck - 0.3), DV3(e1, deck - 0.3), DV3(e1, deck), DV3(e0, deck), .pierWood, dark: true, normal: DV3((e1 - e0).normalized.right * s, 0))
                // Railing.
                props.cylinder(centre: e0, z0: deck, z1: deck + 1.0, r0: 0.05, r1: 0.05, sides: 4, .trimWhite)
                props.box(centre: (e0 + e1) * 0.5, z0: deck + 0.95, axis: (e1 - e0).normalized, halfLength: e0.distance(to: e1) / 2, halfWidth: 0.03, height: 0.06, .trimWhite)
                // Pile down to the seabed.
                let pile = e0 - n.normalized * (s * 0.3)
                props.cylinder(centre: pile, z0: DioramaTerrain.seabed, z1: deck - 0.3, r0: 0.16, r1: 0.14, sides: 6, .trunk, cap: false)
            }
        }
        // A pair of dhows moored at the head of the pier.
        let head = dense[dense.count - 1]
        let dir = (head - dense[dense.count - 2]).normalized
        for s in [-1.0, 1.0] {
            let p = head + dir.right * (s * 4.5) - dir * 3
            if isWater(p) {
                props.append(library.dhow, DioramaTransform(rotation: dir.angle + s * 0.2, scale: DV3(0.8, 0.8, 0.8), translation: DV3(p, DioramaTerrain.waterSurface)))
            }
        }
    }

    /// Concrete boat ramp sloping from the yard down into the water.
    private func slipway(_ line: [DV2], ground: inout DioramaMesh) {
        guard line.count >= 2 else { return }
        let a = line[0], b = line[line.count - 1]
        // The end in the water is the low end.
        let landEnd = isWater(a) && !isWater(b) ? b : a
        let seaEnd = isWater(a) && !isWater(b) ? a : b
        let dir = (seaEnd - landEnd).normalized
        let n = dir.right * 4.0
        let zLand = z(landEnd) + 0.1, zSea = DioramaTerrain.seabed + 0.4
        ground.quad(DV3(landEnd - n, zLand), DV3(seaEnd - n, zSea), DV3(seaEnd + n, zSea), DV3(landEnd + n, zLand), .concrete)
        for s in [-1.0, 1.0] {
            let e0 = landEnd + n * s, e1 = seaEnd + n * s
            ground.quad(DV3(e0, zLand - 1.2), DV3(e1, zSea - 1.2), DV3(e1, zSea), DV3(e0, zLand), .concrete, dark: true, normal: DV3((e1 - e0).normalized.right * s, 0))
        }
        // Rails down the ramp.
        for s in [-0.5, 0.5] {
            let r0 = landEnd + n * s, r1 = seaEnd + n * s
            ground.quad(DV3(r0 - dir.right * 0.08, zLand + 0.03), DV3(r1 - dir.right * 0.08, zSea + 0.03), DV3(r1 + dir.right * 0.08, zSea + 0.03), DV3(r0 + dir.right * 0.08, zLand + 0.03), .metalCharcoal)
        }
    }

    // MARK: Points of interest

    /// Lattice telecom mast with a red aircraft light.
    private func mast(at p: DV2, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let base = z(p)
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
        let base = z(p)
        guard !roads.isOnRoad(p, margin: 2), !buildings.contains(where: { $0.box.expanded(by: 2).contains(p) }) else { return }
        let pad = DioramaOrientedRect(centre: p, axis: DV2(1, 0), halfLength: 5, halfWidth: 4)
        ground.extrude(pad.corners, z0: base - 0.2, z1: base + 0.1, .kerb, top: .rubberRed)
        let top = base + 0.1
        // Swing frame.
        let s0 = p + DV2(-3.2, 1.8), s1 = p + DV2(-3.2, -1.8)
        for s in [s0, s1] {
            props.tube(from: DV3(s + DV2(-0.6, 0), top), to: DV3(s, top + 2.4), r0: 0.05, r1: 0.05, sides: 4, .signBlue, cap: false)
            props.tube(from: DV3(s + DV2(0.6, 0), top), to: DV3(s, top + 2.4), r0: 0.05, r1: 0.05, sides: 4, .signBlue, cap: false)
        }
        props.box(centre: (s0 + s1) * 0.5, z0: top + 2.36, axis: DV2(0, 1), halfLength: 1.8, halfWidth: 0.04, height: 0.08, .signBlue)
        for y in [-0.7, 0.7] {
            let seat = p + DV2(-3.2, y)
            props.tube(from: DV3(seat + DV2(0, -0.2), top + 2.3), to: DV3(seat + DV2(0, -0.2), top + 0.6), r0: 0.015, r1: 0.015, sides: 3, .metalCharcoal, cap: false)
            props.tube(from: DV3(seat + DV2(0, 0.2), top + 2.3), to: DV3(seat + DV2(0, 0.2), top + 0.6), r0: 0.015, r1: 0.015, sides: 3, .metalCharcoal, cap: false)
            props.box(centre: seat, z0: top + 0.55, halfLength: 0.15, halfWidth: 0.25, height: 0.05, .signYellow)
        }
        // Slide: platform, ladder and the chute.
        let plat = p + DV2(1.5, 0)
        props.box(centre: plat, z0: top, halfLength: 0.6, halfWidth: 0.6, height: 1.6, .signGreen, top: .signYellow, bevel: 0.04)
        for k in 0..<4 { props.box(centre: plat + DV2(-0.9, 0), z0: top + 0.35 * Double(k + 1), halfLength: 0.03, halfWidth: 0.3, height: 0.04, .metalCharcoal) }
        let chuteTop = DV3(plat + DV2(0.6, 0), top + 1.55), chuteEnd = DV3(plat + DV2(3.0, 0), top + 0.35)
        props.quad(chuteTop + DV3(0, -0.35, 0), chuteEnd + DV3(0, -0.35, 0), chuteEnd + DV3(0, 0.35, 0), chuteTop + DV3(0, 0.35, 0), .signRed)
        props.quad(chuteTop + DV3(0, -0.35, 0), chuteEnd + DV3(0, -0.35, 0), chuteEnd + DV3(0, -0.35, 0.15), chuteTop + DV3(0, -0.35, 0.15), .signRed, normal: DV3(0, -1, 0))
        props.quad(chuteTop + DV3(0, 0.35, 0), chuteEnd + DV3(0, 0.35, 0), chuteEnd + DV3(0, 0.35, 0.15), chuteTop + DV3(0, 0.35, 0.15), .signRed, normal: DV3(0, 1, 0))
        // Spring rider and a bench.
        props.sphere(centre: DV3(p + DV2(0, 2.6), top + 0.55), radii: DV3(0.35, 0.25, 0.3), .signYellow, detail: 0)
        props.cylinder(centre: p + DV2(0, 2.6), z0: top, z1: top + 0.45, r0: 0.08, r1: 0.08, sides: 5, .metalCharcoal)
        props.append(library.bench, DioramaTransform(rotation: Double.pi / 2, translation: DV3(p + DV2(0, -3.4), top)))
    }

    private func sculpture(at p: DV2, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let base = z(p)
        guard !roads.isOnRoad(p, margin: 1), !buildings.contains(where: { $0.box.expanded(by: 0.5).contains(p) }) else { return }
        ground.cylinder(centre: p, z0: base, z1: base + 0.9, r0: 1.0, r1: 0.9, sides: 10, .concrete)
        props.sphere(centre: DV3(p, base + 1.9), radii: DV3(0.7, 0.7, 0.9), .bronze)
        props.tube(from: DV3(p, base + 0.9), to: DV3(p, base + 2.9), r0: 0.18, r1: 0.1, sides: 6, .bronze)
        props.sphere(centre: DV3(p + DV2(0.5, 0.2), base + 2.6), radii: DV3(0.35, 0.35, 0.45), .bronze, detail: 0)
    }

    /// Minaret and dome for the mosque: placed on the nearest building's roof corner when the mapped
    /// point falls on a building, else standing beside it.
    private func minaret(near p: DV2, props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let host = buildings.min { $0.feature.centroid.distance(to: p) < $1.feature.centroid.distance(to: p) }
        var spot = p
        var baseZ = z(p)
        if let host, host.feature.centroid.distance(to: p) < 30 {
            let corner = host.box.corners[0]
            spot = corner + (host.box.centre - corner).normalized * 1.6
            baseZ = z(host.feature.centroid) + host.height + (host.flatRoof ? config.roofBevel : 0)
            // Green dome in the middle of the roof.
            props.cylinder(centre: host.box.centre, z0: baseZ, z1: baseZ + 1.0, r0: 2.6, r1: 2.6, sides: 12, .whitewash)
            props.sphere(centre: DV3(host.box.centre, baseZ + 1.0), radii: DV3(2.6, 2.6, 2.3), .domeGreen)
            props.tube(from: DV3(host.box.centre, baseZ + 3.2), to: DV3(host.box.centre, baseZ + 4.6), r0: 0.12, r1: 0.03, sides: 5, .sunflower)
        } else {
            guard !roads.isOnRoad(spot, margin: 1.5) else { return }
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
