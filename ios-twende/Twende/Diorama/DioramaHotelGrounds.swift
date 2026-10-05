import Foundation

/// Bounded mapped Slipway court, respecting the unmodified beach and coastal terrain.
/// Independent restaurant decks keep ownership of their surfaces and furniture.
nonisolated struct DioramaHotelGrounds {
    static let courtyardID: UInt64 = 1_128_180_504
    let data: DioramaTileData
    let terrain: DioramaTerrain
    let library: DioramaPropLibrary
    let roads: DioramaRoadIndex
    let streetPolygons: [[DV2]]

    /// Keep the court local to its mapped outline. A convex hull of the entire complex filled
    /// unrelated forecourts and the waterfront, and also suppressed their independent amenities.
    static func courtyardOutline(data: DioramaTileData) -> [DV2] {
        guard let ring = data.landuse.first(where: { $0.id == courtyardID })?.rings.first else { return [] }
        return DioramaPolygon.offset(ring, by: 1.2) ?? ring
    }

    static func ownsCourtyard(_ p: DV2, data: DioramaTileData, margin: Double = 0) -> Bool {
        for ring in [data.hotelCourtyardOutline, data.hotelDiningOutline] where ring.count >= 3 {
            if DioramaPolygon.contains(ring, p) || DioramaPolygon.distanceToRing(ring, p) < margin { return true }
        }
        return data.buildings.contains { building in
            let landmark = Self.hasSlipwayApron(building.id)
            return landmark && DioramaPolygon.distanceToRing(building.ring, p) < 6 + margin
        }
    }

    private static func hasSlipwayApron(_ id: UInt64) -> Bool {
        (DioramaHotelGenerator.ids.contains(id) && id != DioramaHotelGenerator.delta)
            || DioramaSlipwayPavilion.buildingIDs.contains(id)
    }

    /// Shared stair corridor reserved by paving, furniture and vegetation.
    static func stairOutline(data: DioramaTileData) -> [DV2] {
        guard let hotel = data.buildings.first(where: { $0.id == DioramaHotelGenerator.gallery }),
              let white = data.buildings.first(where: { $0.id == DioramaSlipwayPavilion.arcadeBlockID }),
              let edge = DioramaFootprints.facingEdge(hotel: hotel, white: white) else { return [] }
        let dir = (edge.b - edge.a).normalized, out = dir.right
        let a = edge.a + dir * 0.5 + out * 0.7
        let b = edge.b - dir * 0.5 + out * 0.7
        return DioramaPolygon.counterClockwise([a, b, b + out * 5.1, a + out * 5.1])
    }

    /// The separate blue beachfront hotel owns this west-facing dining apron, not the fish hotel.
    static func diningOutline(data: DioramaTileData) -> [DV2] {
        guard let hotel = data.buildings.first(where: { $0.id == DioramaHotelGenerator.waterfront }) else { return [] }
        let ring = hotel.ring, desired = DV2(-1, -0.22).normalized
        guard let i = ring.indices.max(by: { i, j in
            func score(_ k: Int) -> Double {
                let e = ring[(k + 1) % ring.count] - ring[k]
                return e.length * max(0, e.normalized.right.dot(desired))
            }
            return score(i) < score(j)
        }) else { return [] }
        let a = ring[i], b = ring[(i + 1) % ring.count]
        let dir = (b - a).normalized, out = dir.right
        return DioramaPolygon.counterClockwise([a - dir * 1.5, b + dir * 1.5, b + dir * 1.5 + out * 7, a - dir * 1.5 + out * 7])
    }

    func generate(ground: inout DioramaMesh, props: inout DioramaMesh, vegetation: inout DioramaMesh,
                  glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let ring = data.hotelCourtyardOutline
        if ring.count >= 3 {
            let furnitureRing = data.landuse.first(where: { $0.id == Self.courtyardID })?.rings.first ?? ring
            courtyard(ring, furnitureRing: furnitureRing, ground: &ground, props: &props, vegetation: &vegetation, glow: &glow, lights: &lights)
        }
        dining(ground: &ground, props: &props, vegetation: &vegetation)
        staircase(ground: &ground, props: &props, vegetation: &vegetation)
        surroundings(ground: &ground, props: &props, vegetation: &vegetation)
    }

    private func dining(ground: inout DioramaMesh, props: inout DioramaMesh, vegetation: inout DioramaMesh) {
        let ring = data.hotelDiningOutline
        guard ring.count >= 3 else { return }
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: 1.2, streetPolygons: streetPolygons,
                                           additionalMasks: data.water.compactMap { $0.rings.first } + DioramaGroundGenerator.beachPieces(data: data) + [data.hotelCourtyardOutline, Self.stairOutline(data: data)])
        let pieces = cutouts.subtract(from: ring)
        pave(pieces, swatch: .paving, ground: &ground)
        // No side faces around Boolean/ear-clipped pieces: internal edges made faint fan seams.
        func onPaving(_ p: DV2, _ r: Double) -> Bool {
            pieces.contains { DioramaPolygon.contains($0, p) } && clear(p, radius: r)
                && !DioramaPolygon.contains(data.hotelCourtyardOutline, p)
        }
        var placed: [DV2] = []
        for row in [2.6, 5.0] {
            for t in stride(from: -box.halfLength + 2, through: box.halfLength - 2, by: 2.8) {
                let probe = box.centre + box.axis * t
                let hotelSide = data.buildings.first(where: { $0.id == DioramaHotelGenerator.waterfront }).map { DioramaPolygon.centroid($0.ring) } ?? probe
                let away = (box.across.dot(probe - hotelSide) > 0 ? box.across : box.across * -1)
                let p = probe - away * box.halfWidth + away * row
                guard onPaving(p, 1.1), placed.allSatisfy({ $0.distance(to: p) > 2.3 }) else { continue }
                cafe(at: p, z: terrain.height(p) + 0.11, props: &props)
                if row > 4, placed.count % 2 == 0 { parasol(at: p, z: terrain.height(p) + 0.11, props: &props) }
                placed.append(p)
            }
        }
        for s in [-1.0, 1.0] {
            let p = box.centre + box.axis * (s * (box.halfLength - 0.9))
            if onPaving(p, 0.7) { flowerPlanter(at: p, z: terrain.height(p) + 0.11, props: &props, vegetation: &vegetation) }
        }
    }

    /// Terrain determines the rise; the treads are authored within the widened passage.
    private func staircase(ground: inout DioramaMesh, props: inout DioramaMesh, vegetation: inout DioramaMesh) {
        let ring = Self.stairOutline(data: data)
        guard ring.count == 4 else { return }
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        var start = box.centre - box.axis * box.halfLength
        var end = box.centre + box.axis * box.halfLength
        if terrain.height(start) > terrain.height(end) { swap(&start, &end) }
        let dir = (end - start).normalized, width = min(box.halfWidth, 2.55)
        let length = start.distance(to: end)
        guard length > 4 else { return }
        let low = terrain.height(start) + 0.11
        let high = terrain.height(end) + 0.11
        let count = max(1, Int(ceil((high - low) / 0.16)))
        let run = (length - 3) / Double(count)
        let rise = (high - low) / Double(count)
        for i in 0..<count {
            let a = start + dir * (1.5 + Double(i) * run)
            let b = a + dir * run
            let z = low + Double(i + 1) * rise
            let tread = [a - dir.left * width, b - dir.left * width, b + dir.left * width, a + dir.left * width]
            ground.polygon(tread, z: z, .tileClay)
            ground.wall(a + dir.left * width, a - dir.left * width, z0: z - rise, z1: z, .tileClay)
            for side in [-1.0, 1.0] {
                let u = a + dir.left * (side * width), v = b + dir.left * (side * width)
                let base = min(terrain.height(u), terrain.height(v)) - 0.2
                ground.wall(u, v, z0: base, z1: z + 0.32, .coralStone)
                props.tube(from: DV3(u, z + 0.92), to: DV3(v, z + 0.92), r0: 0.045, r1: 0.045, sides: 8, .doorWood)
                if i % 3 == 0 {
                    props.tube(from: DV3(u, z + 0.3), to: DV3(u, z + 0.92), r0: 0.025, r1: 0.025, sides: 6, .metalCharcoal)
                }
            }
        }
        for (p, z, sign) in [(start, low, 1.0), (end, high, -1.0)] {
            let q = p + dir * (sign * 0.75)
            ground.box(centre: q, z0: z - 0.12, axis: dir, halfLength: 0.75, halfWidth: width, height: 0.12, .tileClay)
        }
    }

    /// Local aprons, not a hull across the waterfront. Disjoint union preserves existing amenities.
    private func surroundings(ground: inout DioramaMesh, props: inout DioramaMesh, vegetation: inout DioramaMesh) {
        let landmarks = data.buildings.filter { Self.hasSlipwayApron($0.id) }
        var aprons: [[DV2]] = []
        for building in landmarks {
            let ring = building.ring
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count], out = (b - a).normalized.right
                aprons.append(DioramaPolygon.counterClockwise([a, b, b + out * 6, a + out * 6]))
            }
        }
        let preserved = data.water.compactMap { $0.rings.first }
            + DioramaGroundGenerator.beachPieces(data: data)
            + data.landuse.filter { ["pool", "pitch", "parking", "fuel", "terrace"].contains($0.kind) }.compactMap { $0.rings.first }
            + [data.hotelCourtyardOutline, data.hotelDiningOutline, Self.stairOutline(data: data)]
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: 1.2, streetPolygons: streetPolygons, additionalMasks: preserved)
        let pieces = DioramaStreetSurface(aprons).pieces().flatMap { cutouts.subtract(from: $0) }
        pave(pieces, ground: &ground)
        var planted: [DV2] = []
        for building in landmarks {
            let ring = building.ring
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count], dir = (b - a).normalized, out = dir.right
                for t in stride(from: 3.0, to: a.distance(to: b) - 2, by: 5.5) {
                    let p = a + dir * t + out * 4.5
                    guard clear(p, radius: 1.25), pieces.contains(where: { DioramaPolygon.contains($0, p) }),
                          planted.allSatisfy({ $0.distance(to: p) > 4.5 }), data.trees.allSatisfy({ $0.distance(to: p) > 3 }) else { continue }
                    let z = terrain.height(p) + 0.11
                    let index = planted.count
                    vegetation.append(library.palms[index % library.palms.count], DioramaTransform(rotation: Double(index) * 1.8, translation: DV3(p, z)))
                    annularSeat(at: p, z: z, props: &props)
                    let pot = p + dir * 1.9
                    if clear(pot, radius: 0.65) { flowerPlanter(at: pot, z: terrain.height(pot) + 0.11, props: &props, vegetation: &vegetation) }
                    planted.append(p)
                }
            }
        }
    }

    private func parasol(at p: DV2, z: Double, props: inout DioramaMesh) {
        props.cylinder(centre: p, z0: z + 0.87, z1: z + 2.4, r0: 0.03, r1: 0.03, sides: 6, .trimWhite)
        props.cylinder(centre: p, z0: z + 2.2, z1: z + 2.55, r0: 1.35, r1: 0.06, sides: 24, .cream)
    }

    private func courtyard(_ pavingRing: [DV2], furnitureRing ring: [DV2], ground: inout DioramaMesh, props: inout DioramaMesh,
                           vegetation: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: 1.7, streetPolygons: streetPolygons,
                                           additionalMasks: data.water.compactMap { $0.rings.first } + DioramaGroundGenerator.beachPieces(data: data) + [Self.stairOutline(data: data)])
        let pieces = cutouts.subtract(from: pavingRing)
        pave(pieces, ground: &ground)
        for t in stride(from: -box.halfLength + 1, to: box.halfLength - 1, by: 0.65) {
            let p = box.centre + box.axis * t
            guard clear(p, radius: 0.4), DioramaPolygon.contains(ring, p) else { continue }
            let z = terrain.height(p) + 0.11
            ground.box(centre: p, z0: z + 0.01, axis: box.axis, halfLength: 0.29, halfWidth: 0.21, height: 0.015, .concrete)
            for d in [-0.18, -0.06, 0.06, 0.18] {
                ground.box(centre: p + box.axis * d, z0: z + 0.027, axis: box.axis, halfLength: 0.022, halfWidth: 0.14, height: 0.006, .metalCharcoal)
            }
        }
        // Café tables now belong only to the separate beachfront dining apron.
        let occupied: [DV2] = []
        let trees = data.trees.filter { DioramaPolygon.contains(pavingRing, $0) && clear($0, radius: 0.8) }
        var palmPositions = trees
        // Supplement sparse mapped trees with deterministic courtyard-margin planting.
        for side in [-1.0, 1.0] {
            for t in stride(from: -box.halfLength + 4, to: box.halfLength - 3, by: 6.5) {
                let p = box.centre + box.axis * t + box.across * (side * max(3, box.halfWidth - 2.4))
                if clear(p, radius: 1.5), DioramaPolygon.contains(pavingRing, p),
                   palmPositions.allSatisfy({ $0.distance(to: p) > 5 }),
                   occupied.allSatisfy({ $0.distance(to: p) > 3 }) { palmPositions.append(p) }
            }
        }
        for (i, p) in palmPositions.enumerated() {
            let z = terrain.height(p) + 0.11
            vegetation.append(library.palms[i % library.palms.count], DioramaTransform(rotation: Double(i) * 1.7, scale: DV3(1, 1, i % 3 == 0 ? 1.25 : 1), translation: DV3(p, z)))
            if clear(p, radius: 1.4) { annularSeat(at: p, z: z, props: &props) }
        }
        for s in [-1.0, 1.0] {
            let p = box.centre + box.axis * (s * box.halfLength * 0.48) + box.across * (box.halfWidth * 0.45)
            if clear(p, radius: 1.4), DioramaPolygon.contains(ring, p),
               occupied.allSatisfy({ $0.distance(to: p) > 3 }), palmPositions.allSatisfy({ $0.distance(to: p) > 3 }) {
                let z = terrain.height(p) + 0.11
                annularSeat(at: p, z: z, props: &props)
                lantern(at: p, z: z, props: &props, glow: &glow)
                lights.append(DioramaLight(position: DV3(p, z + 3.6), color: SIMD3<Float>(1, 0.85, 0.65), radius: 10, intensity: 0.8))
            }
        }
        let pergolaCentre = box.centre - box.across * max(box.halfWidth - 2.2, 0)
        let length = min(box.halfLength - 1, 9)
        let pergolaRing = DioramaOrientedRect(centre: pergolaCentre, axis: box.axis, halfLength: max(length, 1), halfWidth: 1).corners
        let pergolaTop = terrain.foundationHeight(pergolaRing) + 2.8
        if length > 2 {
            for t in stride(from: -length, through: length, by: 2.5) {
                let p = pergolaCentre + box.axis * t
                guard clear(p, radius: 0.5), DioramaPolygon.contains(ring, p) else { continue }
                let z = terrain.height(p) + 0.11
                props.box(centre: p, z0: z, halfLength: 0.09, halfWidth: 0.09, height: pergolaTop - z, .carvedWood)
                props.box(centre: p + box.across * 0.7, z0: pergolaTop, axis: box.across, halfLength: 0.9, halfWidth: 0.07, height: 0.12, .doorWood)
                vegetation.append(library.bougainvillea[0], DioramaTransform(scale: DV3(0.55, 0.55, 0.6), translation: DV3(p, pergolaTop - 1.3)))
            }
            for t in stride(from: -length, to: length, by: 0.36) {
                let p = pergolaCentre + box.axis * t
                if clear(p, radius: 0.4), DioramaPolygon.contains(ring, p) {
                    props.box(centre: p + box.across * 0.7, z0: pergolaTop + 0.15, axis: box.across, halfLength: 0.9, halfWidth: 0.035, height: 0.07, .doorWood)
                }
            }
        }
        // Terracotta entrance landing with inset name, oriented with the courtyard rather than screen.
        let entry = box.centre + box.axis * (box.halfLength - 2)
        if clear(entry, radius: 2.0), DioramaPolygon.contains(ring, entry) {
            let z = terrain.height(entry) + 0.11
            ground.box(centre: entry, z0: z + 0.015, axis: box.across, halfLength: 2.7, halfWidth: 0.65, height: 0.025, .coralStone)
            DioramaLettering.line("THE SLIPWAY", centre: DV3(entry - box.axis * 0.3, z + 0.045), up: DV3(-box.axis, 0), facing: .up, height: 0.55, swatch: .trimWhite, mesh: &ground)
        }
    }

    private func pave(_ pieces: [[DV2]], swatch: DioramaSwatch = .tileClay, ground: inout DioramaMesh) {
        for piece in pieces {
            terrain.drape(piece, lift: DioramaSurfaceLevel.paving.rawValue, swatch: swatch, into: &ground)
        }
    }

    private func flowerPlanter(at p: DV2, z: Double, props: inout DioramaMesh, vegetation: inout DioramaMesh) {
        props.cylinder(centre: p, z0: z, z1: z + 0.62, r0: 0.38, r1: 0.52, sides: 24, .terracottaWall)
        props.cylinder(centre: p, z0: z + 0.62, z1: z + 0.69, r0: 0.56, r1: 0.56, sides: 24, .tileClay)
        vegetation.append(library.bougainvillea[0], DioramaTransform(scale: DV3(0.4, 0.4, 0.42), translation: DV3(p, z + 0.62)))
    }

    private func clear(_ p: DV2, radius: Double) -> Bool {
        let stairs = Self.stairOutline(data: data)
        guard !(stairs.count >= 3 && (DioramaPolygon.contains(stairs, p) || DioramaPolygon.distanceToRing(stairs, p) < radius)),
              !roads.isOnRoad(p, margin: radius),
              !data.buildings.contains(where: { DioramaPolygon.contains($0.ring, p) || DioramaPolygon.distanceToRing($0.ring, p) < radius }) else { return false }
        let occupied = data.water + data.landuse.filter { ["pool", "pitch", "parking", "fuel", "terrace"].contains($0.kind) }
        return !occupied.contains { area in
            DioramaPolygon.contains(polygon: area.rings, p) ||
            (area.rings.first.map { DioramaPolygon.distanceToRing($0, p) < radius } ?? false)
        }
    }

    private func annularSeat(at p: DV2, z: Double, props: inout DioramaMesh) {
        for i in 0..<32 {
            let a = Double(i) * .pi / 16, b = Double(i + 1) * .pi / 16
            let u = DV2(cos(a), sin(a)), v = DV2(cos(b), sin(b))
            props.quad(DV3(p + u * 0.72, z + 0.47), DV3(p + u * 1.35, z + 0.47), DV3(p + v * 1.35, z + 0.47), DV3(p + v * 0.72, z + 0.47), .cream, normal: .up)
            props.wall(p + u * 1.25, p + v * 1.25, z0: z, z1: z + 0.44, .coralStone)
            props.wall(p + v * 0.72, p + u * 0.72, z0: z, z1: z + 0.47, .cream)
        }
    }

    private func cafe(at p: DV2, z: Double, props: inout DioramaMesh) {
        props.cylinder(centre: p, z0: z + 0.71, z1: z + 0.77, r0: 0.56, r1: 0.56, sides: 20, .cream)
        props.cylinder(centre: p, z0: z, z1: z + 0.71, r0: 0.06, r1: 0.04, sides: 6, .metalCharcoal)
        props.cylinder(centre: p, z0: z + 0.77, z1: z + 0.87, r0: 0.065, r1: 0.055, sides: 8, .terracottaWall)
        props.sphere(centre: DV3(p, z + 0.93), radii: DV3(0.12, 0.12, 0.11), .flowerRed, detail: 0)
        for side in [-1.0, 1.0] {
            let plate = p + DV2(side * 0.31, 0)
            props.cylinder(centre: plate, z0: z + 0.775, z1: z + 0.79, r0: 0.115, r1: 0.115, sides: 12, .trimWhite)
        }
        for i in 0..<3 {
            let dir = DV2(cos(Double(i) * .pi * 2 / 3), sin(Double(i) * .pi * 2 / 3)), c = p + dir * 0.95
            let chairBase = terrain.foundationHeight(DioramaOrientedRect(centre: c, axis: dir, halfLength: 0.23, halfWidth: 0.23).corners) + 0.11
            props.box(centre: c, z0: chairBase + 0.43, axis: dir, halfLength: 0.22, halfWidth: 0.23, height: 0.055, .doorWood)
            for s in [-1.0, 1.0] {
                for t in [-1.0, 1.0] {
                    let leg = c + dir * (s * 0.18) + dir.left * (t * 0.18)
                    props.tube(from: DV3(leg, terrain.height(leg) + 0.11), to: DV3(leg, chairBase + (s > 0 ? 0.9 : 0.43)), r0: 0.018, r1: 0.018, sides: 4, .metalCharcoal)
                }
            }
            props.box(centre: c + dir * 0.18, z0: chairBase + 0.8, axis: dir.left, halfLength: 0.23, halfWidth: 0.025, height: 0.1, .metalCharcoal)
        }
    }

    private func lantern(at p: DV2, z: Double, props: inout DioramaMesh, glow: inout DioramaMesh) {
        props.cylinder(centre: p, z0: z + 0.4, z1: z + 0.95, r0: 0.25, r1: 0.12, sides: 12, .cream)
        props.cylinder(centre: p, z0: z + 0.95, z1: z + 3.7, r0: 0.07, r1: 0.045, sides: 8, .lampPole)
        for s in [-1.0, 1.0] {
            let q = p + DV2(s * 0.48, 0)
            props.tube(from: DV3(p, z + 3.05), to: DV3(q, z + 3.45), r0: 0.035, r1: 0.035, sides: 5, .lampPole)
            props.cylinder(centre: q, z0: z + 3.4, z1: z + 3.48, r0: 0.22, r1: 0.22, sides: 4, .lampPole)
            glow.box(centre: q, z0: z + 3.48, halfLength: 0.13, halfWidth: 0.13, height: 0.43, .lampGlow)
            props.cylinder(centre: q, z0: z + 3.91, z1: z + 4.12, r0: 0.25, r1: 0.02, sides: 4, .lampPole)
        }
    }

}
