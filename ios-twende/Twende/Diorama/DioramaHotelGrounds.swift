import Foundation

/// Site-specific paving and furniture. The mapped garden bounds keep the courtyard out of buildings;
/// seawall courses follow actual coastline edges, never the tile-closing edges.
nonisolated struct DioramaHotelGrounds {
    static let courtyardID: UInt64 = 1_128_180_504
    let data: DioramaTileData
    let terrain: DioramaTerrain
    let library: DioramaPropLibrary
    let roads: DioramaRoadIndex

    static func ownsCourtyard(_ p: DV2, data: DioramaTileData, margin: Double = 0) -> Bool {
        data.landuse.contains { $0.id == courtyardID && (DioramaPolygon.contains(polygon: $0.rings, p) || ($0.rings.first.map { DioramaPolygon.distanceToRing($0, p) < margin } ?? false)) }
    }

    func generate(ground: inout DioramaMesh, props: inout DioramaMesh, vegetation: inout DioramaMesh,
                  glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        if let area = data.landuse.first(where: { $0.id == Self.courtyardID }), let ring = area.rings.first {
            courtyard(ring, ground: &ground, props: &props, vegetation: &vegetation, glow: &glow, lights: &lights)
        }
        seawall(ground: &ground)
    }

    private func courtyard(_ ring: [DV2], ground: inout DioramaMesh, props: inout DioramaMesh,
                           vegetation: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let box = DioramaPolygon.minimumAreaRectangle(ring), z = terrain.height(box.centre) + 0.11
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: 1.7)
        let pieces = cutouts.subtract(from: ring)
        for piece in pieces { ground.polygon(piece, z: z, .coralStone) }
        // Individual joints, not texture noise. Alternating rectangular pavers around a central drain.
        let bounds = DioramaRect.bounding(ring)
        var row = 0
        for y in stride(from: bounds.minY, to: bounds.maxY, by: 0.48) {
            for x in stride(from: bounds.minX - Double(row % 2) * 0.24, to: bounds.maxX, by: 0.96) {
                let tile = [DV2(x + 0.015, y + 0.015), DV2(x + 0.945, y + 0.015), DV2(x + 0.945, y + 0.465), DV2(x + 0.015, y + 0.465)]
                for piece in pieces where DioramaRect.bounding(piece).intersects(DioramaRect.bounding(tile)) {
                    var clipped = tile
                    for i in piece.indices { clipped = DioramaGroundCutouts.halfPlane(clipped, a: piece[i], b: piece[(i + 1) % piece.count], inside: true) }
                    if clipped.count >= 3 { ground.polygon(clipped, z: z + 0.005, .tileClay) }
                }
            }
            row += 1
        }
        for t in stride(from: -box.halfLength + 1, to: box.halfLength - 1, by: 0.65) {
            let p = box.centre + box.axis * t
            guard clear(p, radius: 0.4), DioramaPolygon.contains(ring, p) else { continue }
            ground.box(centre: p, z0: z + 0.01, axis: box.axis, halfLength: 0.29, halfWidth: 0.21, height: 0.015, .concrete)
            for d in [-0.18, -0.06, 0.06, 0.18] {
                ground.box(centre: p + box.axis * d, z0: z + 0.027, axis: box.axis, halfLength: 0.022, halfWidth: 0.14, height: 0.006, .metalCharcoal)
            }
        }
        // Keep a clear through-route; furniture occupies the two margins, never the drain/walking axis.
        for s in [-1.0, 1.0] {
            for t in stride(from: -box.halfLength + 3, to: box.halfLength - 2, by: 6.5) {
                let p = box.centre + box.axis * t + box.across * (s * max(3, box.halfWidth - 3))
                guard DioramaPolygon.contains(ring, p), DioramaPolygon.distanceToRing(ring, p) > 1.4, clear(p, radius: 1.5) else { continue }
                cafe(at: p, z: z + 0.02, props: &props)
            }
        }
        let trees = data.trees.filter { DioramaPolygon.contains(ring, $0) && clear($0, radius: 0.8) }
        for (i, p) in trees.enumerated() {
            vegetation.append(library.palms[i % library.palms.count], DioramaTransform(translation: DV3(p, z)))
            annularSeat(at: p, z: z, props: &props)
        }
        for s in [-1.0, 1.0] {
            let p = box.centre + box.axis * (s * box.halfLength * 0.48) + box.across * (box.halfWidth * 0.45)
            if clear(p, radius: 1.4), DioramaPolygon.contains(ring, p) {
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
            DioramaLettering.line("THE SLIPWAY", centre: DV3(entry - box.axis * 0.3, z + 0.045), right: box.across, up: DV3(-box.axis, 0), height: 0.55, swatch: .trimWhite, mesh: &ground)
        }
    }

    private func clear(_ p: DV2, radius: Double) -> Bool {
        !roads.isOnRoad(p, margin: radius) && !data.buildings.contains { DioramaPolygon.contains($0.ring, p) || DioramaPolygon.distanceToRing($0.ring, p) < radius }
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
            let base = terrain.height((a + b) * 0.5), top = base + 0.72
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
                // Retaining edge returns to the existing flat grounds as one continuous shallow ramp.
                let rear0 = start + land * 4, rear1 = end + land * 4
                if clear((rear0 + rear1) * 0.5, radius: 0.3) {
                    ground.quad(DV3(start + land * 0.55, top), DV3(end + land * 0.55, top), DV3(rear1, base + 0.07), DV3(rear0, base + 0.07), .paving, normal: .up)
                }
            }
        }
    }
}
