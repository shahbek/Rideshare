import Foundation

/// Connected Slipway hardscape between the complex's buildings, with occupied areas subtracted.
/// The mapped garden anchors the furniture; it no longer limits the extent of the paving.
nonisolated struct DioramaHotelGrounds {
    static let courtyardID: UInt64 = 1_128_180_504
    let data: DioramaTileData
    let terrain: DioramaTerrain
    let library: DioramaPropLibrary
    let roads: DioramaRoadIndex
    let streetPolygons: [[DV2]]

    /// Inferred site envelope, not a new surveyed OSM boundary. Buildings determine its outer limits.
    static func courtyardOutline(data: DioramaTileData) -> [DV2] {
        let siteIDs: Set<UInt64> = [DioramaHotelGenerator.waterfront, DioramaHotelGenerator.gallery,
                                  DioramaHotelGenerator.yellowBlock, DioramaHotelGenerator.arcade,
                                  142_262_992, 180_607_949, 688_369_154]
        var points = data.buildings.filter { siteIDs.contains($0.id) }.flatMap(\.ring)
        points += data.landuse.filter { $0.id == courtyardID }.flatMap { $0.rings.first ?? [] }
        // Include the seafront lunch terrace and the hotel approach, then clip occupied ground.
        for water in data.water {
            guard let coast = water.rings.first else { continue }
            for i in coast.indices where !water.clipped[i] {
                let p = coast[i]
                let location = data.projection.local(longitude: 39.272, latitude: -6.7525)
                if abs(p.y - location.y) < 57 && abs(p.x - location.x) < 48 { points.append(p) }
            }
        }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return [] }
        func chain(_ points: [DV2]) -> [DV2] {
            var result: [DV2] = []
            for p in points {
                while result.count >= 2 {
                    let a = result[result.count - 2], b = result[result.count - 1]
                    if (b - a).cross(p - b) > 0.000001 { break }
                    result.removeLast()
                }
                result.append(p)
            }
            return result
        }
        let hull = Array(chain(sorted).dropLast()) + Array(chain(Array(sorted.reversed())).dropLast())
        return DioramaPolygon.offset(hull, by: 5) ?? hull
    }

    static func ownsCourtyard(_ p: DV2, data: DioramaTileData, margin: Double = 0) -> Bool {
        let ring = data.hotelCourtyardOutline
        guard ring.count >= 3 else { return false }
        return DioramaPolygon.contains(ring, p) || DioramaPolygon.distanceToRing(ring, p) < margin
    }

    func generate(ground: inout DioramaMesh, props: inout DioramaMesh, vegetation: inout DioramaMesh,
                  glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let ring = data.hotelCourtyardOutline
        if ring.count >= 3 {
            let furnitureRing = data.landuse.first(where: { $0.id == Self.courtyardID })?.rings.first ?? ring
            courtyard(ring, furnitureRing: furnitureRing, ground: &ground, props: &props, vegetation: &vegetation, glow: &glow, lights: &lights)
        }
        seawall(ground: &ground)
    }

    private func courtyard(_ pavingRing: [DV2], furnitureRing ring: [DV2], ground: inout DioramaMesh, props: inout DioramaMesh,
                           vegetation: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let box = DioramaPolygon.minimumAreaRectangle(ring), z = terrain.height(box.centre) + 0.11
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: 1.7, streetPolygons: streetPolygons,
                                           additionalMasks: data.water.compactMap { $0.rings.first },
                                           excludedAreaIDs: Self.managedTerraces(data: data))
        let pieces = cutouts.subtract(from: pavingRing)
        pave(pieces, z: z, ground: &ground)
        for t in stride(from: -box.halfLength + 1, to: box.halfLength - 1, by: 0.65) {
            let p = box.centre + box.axis * t
            guard clear(p, radius: 0.4), DioramaPolygon.contains(ring, p) else { continue }
            ground.box(centre: p, z0: z + 0.01, axis: box.axis, halfLength: 0.29, halfWidth: 0.21, height: 0.015, .concrete)
            for d in [-0.18, -0.06, 0.06, 0.18] {
                ground.box(centre: p + box.axis * d, z0: z + 0.027, axis: box.axis, halfLength: 0.022, halfWidth: 0.14, height: 0.006, .metalCharcoal)
            }
        }
        // Keep a clear through-route; furniture occupies the two margins, never the drain/walking axis.
        var occupied: [DV2] = []
        for s in [-1.0, 1.0] {
            for t in stride(from: -box.halfLength + 3, to: box.halfLength - 2, by: 6.5) {
                let p = box.centre + box.axis * t + box.across * (s * max(3, box.halfWidth - 3))
                guard DioramaPolygon.contains(ring, p), DioramaPolygon.distanceToRing(ring, p) > 1.4, clear(p, radius: 1.5) else { continue }
                guard data.trees.allSatisfy({ $0.distance(to: p) > 2 }) else { continue }
                cafe(at: p, z: z, props: &props)
                occupied.append(p)
            }
        }
        // Dining bays run along the courtyard-facing edges, not just inside the old garden polygon.
        for building in data.buildings where [DioramaHotelGenerator.gallery, DioramaHotelGenerator.waterfront, UInt64(180_607_949)].contains(building.id) {
            for i in building.ring.indices {
                let a = building.ring[i], b = building.ring[(i + 1) % building.ring.count]
                let dir = (b - a).normalized, out = dir.right
                for t in stride(from: 3.5, to: a.distance(to: b) - 3, by: 6) {
                    let p = a + dir * t + out * 3.2
                    guard DioramaPolygon.contains(pavingRing, p), clear(p, radius: 1.6),
                          !DioramaPolygon.contains(ring, p),
                          occupied.allSatisfy({ $0.distance(to: p) > 4 }),
                          data.trees.allSatisfy({ $0.distance(to: p) > 2 }) else { continue }
                    cafe(at: p, z: z, props: &props)
                    occupied.append(p)
                    let planter = p + dir * 2.2
                    if clear(planter, radius: 0.8) {
                        flowerPlanter(at: planter, z: z, props: &props, vegetation: &vegetation)
                    }
                }
            }
        }
        let trees = data.trees.filter { DioramaPolygon.contains(pavingRing, $0) && clear($0, radius: 0.8) }
        var palmPositions = trees
        // Supplement sparse mapped trees with deterministic courtyard-margin planting.
        for side in [-1.0, 1.0] {
            for t in stride(from: -box.halfLength + 4, to: box.halfLength - 3, by: 9) {
                let p = box.centre + box.axis * t + box.across * (side * max(3, box.halfWidth - 2.4))
                if clear(p, radius: 1.5), DioramaPolygon.contains(pavingRing, p),
                   palmPositions.allSatisfy({ $0.distance(to: p) > 5 }),
                   occupied.allSatisfy({ $0.distance(to: p) > 3 }) { palmPositions.append(p) }
            }
        }
        for (i, p) in palmPositions.enumerated() {
            vegetation.append(library.palms[i % library.palms.count], DioramaTransform(rotation: Double(i) * 1.7, scale: DV3(1, 1, i % 3 == 0 ? 1.25 : 1), translation: DV3(p, z)))
            if clear(p, radius: 1.4) { annularSeat(at: p, z: z, props: &props) }
        }
        for s in [-1.0, 1.0] {
            let p = box.centre + box.axis * (s * box.halfLength * 0.48) + box.across * (box.halfWidth * 0.45)
            if clear(p, radius: 1.4), DioramaPolygon.contains(ring, p),
               occupied.allSatisfy({ $0.distance(to: p) > 3 }), palmPositions.allSatisfy({ $0.distance(to: p) > 3 }) {
                annularSeat(at: p, z: z, props: &props)
                lantern(at: p, z: z, props: &props, glow: &glow)
                lights.append(DioramaLight(position: DV3(p, z + 3.6), color: SIMD3<Float>(1, 0.85, 0.65), radius: 10, intensity: 0.8))
            }
        }
        let pergolaCentre = box.centre - box.across * max(box.halfWidth - 2.2, 0)
        let length = min(box.halfLength - 1, 9)
        if length > 2 {
            for t in stride(from: -length, through: length, by: 2.5) {
                let p = pergolaCentre + box.axis * t
                guard clear(p, radius: 0.5), DioramaPolygon.contains(ring, p) else { continue }
                props.box(centre: p, z0: z, halfLength: 0.09, halfWidth: 0.09, height: 2.7, .carvedWood)
                props.box(centre: p + box.across * 0.7, z0: z + 2.7, axis: box.across, halfLength: 0.9, halfWidth: 0.07, height: 0.12, .doorWood)
                vegetation.append(library.bougainvillea[0], DioramaTransform(scale: DV3(0.55, 0.55, 0.6), translation: DV3(p, z + 1.4)))
            }
            for t in stride(from: -length, to: length, by: 0.36) {
                let p = pergolaCentre + box.axis * t
                if clear(p, radius: 0.4), DioramaPolygon.contains(ring, p) {
                    props.box(centre: p + box.across * 0.7, z0: z + 2.85, axis: box.across, halfLength: 0.9, halfWidth: 0.035, height: 0.07, .doorWood)
                }
            }
        }
        // Terracotta entrance landing with inset name, oriented with the courtyard rather than screen.
        let entry = box.centre + box.axis * (box.halfLength - 2)
        if clear(entry, radius: 2.0), DioramaPolygon.contains(ring, entry) {
            ground.box(centre: entry, z0: z + 0.015, axis: box.across, halfLength: 2.7, halfWidth: 0.65, height: 0.025, .coralStone)
            DioramaLettering.line("THE SLIPWAY", centre: DV3(entry - box.axis * 0.3, z + 0.045), up: DV3(-box.axis, 0), facing: .up, height: 0.55, swatch: .trimWhite, mesh: &ground)
        }
    }

    private func pave(_ pieces: [[DV2]], z: Double, ground: inout DioramaMesh) {
        // One disjoint terracotta surface. Pixel-filtered mortar lives in the material, not an
        // almost-coplanar second mesh that shimmers or exposes triangulation seams.
        for piece in pieces where piece.count >= 3 && DioramaPolygon.area(piece) > 0.0001 {
            ground.polygon(piece, z: z, .tileClay)
        }
    }

    static func managedTerraces(data: DioramaTileData) -> Set<UInt64> {
        Set(data.landuse.filter { $0.kind == "terrace" && ($0.rings.first.map { ownsCourtyard(DioramaPolygon.centroid($0), data: data) } ?? false) }.map(\.id))
    }

    private func flowerPlanter(at p: DV2, z: Double, props: inout DioramaMesh, vegetation: inout DioramaMesh) {
        props.cylinder(centre: p, z0: z, z1: z + 0.62, r0: 0.38, r1: 0.52, sides: 12, .terracottaWall)
        props.cylinder(centre: p, z0: z + 0.62, z1: z + 0.69, r0: 0.56, r1: 0.56, sides: 12, .tileClay)
        vegetation.append(library.bougainvillea[0], DioramaTransform(scale: DV3(0.4, 0.4, 0.42), translation: DV3(p, z + 0.62)))
    }

    private func clear(_ p: DV2, radius: Double) -> Bool {
        guard !roads.isOnRoad(p, margin: radius),
              !data.buildings.contains(where: { DioramaPolygon.contains($0.ring, p) || DioramaPolygon.distanceToRing($0.ring, p) < radius }) else { return false }
        let occupied = data.water + data.landuse.filter { ["pool", "pitch", "parking", "fuel"].contains($0.kind) || ($0.kind == "terrace" && !Self.managedTerraces(data: data).contains($0.id)) }
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
            props.box(centre: c, z0: z + 0.43, axis: dir, halfLength: 0.22, halfWidth: 0.23, height: 0.055, .doorWood)
            for s in [-1.0, 1.0] {
                for t in [-1.0, 1.0] {
                    let leg = c + dir * (s * 0.18) + dir.left * (t * 0.18)
                    props.tube(from: DV3(leg, z), to: DV3(leg, z + (s > 0 ? 0.9 : 0.43)), r0: 0.018, r1: 0.018, sides: 4, .metalCharcoal)
                }
            }
            props.box(centre: c + dir * 0.18, z0: z + 0.8, axis: dir.left, halfLength: 0.23, halfWidth: 0.025, height: 0.1, .metalCharcoal)
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

    private func seawall(ground: inout DioramaMesh) {
        let south = data.projection.local(longitude: 39.272, latitude: -6.75294).y
        let north = data.projection.local(longitude: 39.272, latitude: -6.75192).y
        let stairAnchor = data.projection.local(longitude: 39.27196, latitude: -6.75251)
        var segments: [(DV2, DV2)] = []
        for water in data.water {
            guard let ring = water.rings.first else { continue }
            for i in ring.indices where !water.clipped[i] {
                let a = ring[i], b = ring[(i + 1) % ring.count], mid = (a + b) * 0.5
                if mid.y > south && mid.y < north && a.distance(to: b) > 0.5 { segments.append((a, b)) }
            }
        }
        let stairIndex = segments.indices.min { DioramaPolygon.distanceToSegment(stairAnchor, segments[$0].0, segments[$0].1) < DioramaPolygon.distanceToSegment(stairAnchor, segments[$1].0, segments[$1].1) }
        for (index, pair) in segments.enumerated() {
            let (a, b) = pair, dir = (b - a).normalized, land = dir.right, length = a.distance(to: b)
            let base = terrain.height((a + b) * 0.5), top = base + 0.11
            let divisions = max(1, Int(ceil(length / 1.1)))
            let stepWidth = length / Double(divisions)
            for j in 0..<divisions {
                let start = a + dir * (Double(j) * stepWidth), end = start + dir * stepWidth, mid = (start + end) * 0.5
                let isStair = index == stairIndex && abs((mid - (a + b) * 0.5).dot(dir)) < min(4, length * 0.4)
                if isStair {
                    for k in 0..<6 {
                        let h = top - Double(k) * 0.16
                        ground.box(centre: mid - land * (Double(k) * 0.36 + 0.18), z0: -0.3, axis: dir, halfLength: stepWidth / 2, halfWidth: 0.185, height: h + 0.3, .coralStone, top: .paving)
                    }
                } else {
                    ground.box(centre: mid + land * 0.23, z0: -0.5, axis: dir, halfLength: stepWidth / 2, halfWidth: 0.34, height: top + 0.5, .coralStone)
                    for course in 0..<5 {
                        let z = top - Double(course + 1) * 0.25
                        ground.wall(start - land * 0.115, end - land * 0.115, z0: z, z1: z + 0.02, .earth)
                        let seam = mid + dir * (course % 2 == 0 ? 0 : stepWidth * 0.35) - land * 0.12
                        ground.wall(seam - dir * 0.012, seam + dir * 0.012, z0: z, z1: z + 0.24, .earth)
                    }
                    ground.box(centre: mid + land * 0.23, z0: top, axis: dir, halfLength: stepWidth / 2, halfWidth: 0.4, height: 0.09, .paving)
                }
                // The shared courtyard surface meets this edge at its actual datum. No independent
                // sloped strips: their unjoined corners previously made overlapping fans along shore.
            }
        }
    }
}
