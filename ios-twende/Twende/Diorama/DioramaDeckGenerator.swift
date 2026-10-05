import Foundation

/// Timber decks are thin framed structures with open undersides, not raised ground polygons.
nonisolated struct DioramaDeckGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let terrain: DioramaTerrain

    func build(pieces: [[DV2]], top: Double, axis: DV2, props: inout DioramaMesh) {
        guard !pieces.isEmpty else { return }
        let thickness = max(0.08, config.deckThickness)
        let across = axis.left
        let all = pieces.flatMap { $0 }
        let bounds = DioramaRect.bounding(all)
        let minimum = all.map { $0.dot(across) }.min() ?? 0
        let maximum = all.map { $0.dot(across) }.max() ?? 0
        let alongMin = (all.map { $0.dot(axis) }.min() ?? 0) - 1
        let alongMax = (all.map { $0.dot(axis) }.max() ?? 0) + 1
        // Disjoint palette bands are the planks themselves. No lines layered coplanar on a fan lid.
        var plank = 0
        for d in stride(from: minimum, to: maximum, by: 0.28) {
            let end = min(d + 0.28, maximum)
            let mask = DioramaPolygon.counterClockwise([axis * alongMin + across * d, axis * alongMax + across * d,
                axis * alongMax + across * end, axis * alongMin + across * end])
            for piece in pieces {
                var clipped = piece
                for i in mask.indices { clipped = DioramaGroundCutouts.halfPlane(clipped, a: mask[i], b: mask[(i + 1) % mask.count], inside: true) }
                if clipped.count >= 3 { props.polygon(clipped, z: top, plank % 3 == 0 ? .pierWood : .deckWood) }
            }
            plank += 1
        }
        for piece in pieces { props.polygon(piece, z: top - thickness, .pierWood, dark: true, facingUp: false) }
        let surface = DioramaStreetSurface(pieces)
        for edge in surface.boundary() {
            props.wall(edge.a, edge.b, z0: top - thickness, z1: top, .pierWood)
            let mid = (edge.a + edge.b) * 0.5, direction = (edge.b - edge.a).normalized
            let out = direction.right
            let waterfront = data.water.contains { DioramaPolygon.contains(polygon: $0.rings, mid + out * 1.2) }
                || data.shorelines.contains { DioramaShoreline.distance(mid, line: $0.points) < 4 }
            guard waterfront, !data.buildings.contains(where: { DioramaPolygon.distanceToRing($0.ring, mid) < 1 }) else { continue }
            let length = edge.a.distance(to: edge.b)
            for d in stride(from: 0.0, through: length, by: 1.5) {
                let p = edge.a + direction * d
                props.cylinder(centre: p, z0: top, z1: top + 1, r0: 0.05, r1: 0.05, sides: 12, .doorWood)
            }
            props.tube(from: DV3(edge.a, top + 0.98), to: DV3(edge.b, top + 0.98), r0: 0.055, r1: 0.055, sides: 12, .doorWood)
            props.tube(from: DV3(edge.a, top + 0.5), to: DV3(edge.b, top + 0.5), r0: 0.025, r1: 0.025, sides: 8, .doorWood)
        }
        let step = max(1, config.deckPostSpacing)
        for y in stride(from: ceil(bounds.minY / step) * step, through: bounds.maxY, by: step) {
            for x in stride(from: ceil(bounds.minX / step) * step, through: bounds.maxX, by: step) {
                let p = DV2(x, y)
                guard surface.contains(p) else { continue }
                let bottom = min(terrain.height(p) - 0.25, top - thickness - 0.1)
                props.cylinder(centre: p, z0: bottom, z1: top - thickness, r0: 0.16, r1: 0.14, sides: 16, .palmTrunk)
                // Visible bearer under each post; slim enough that the underside remains open.
                props.box(centre: p, z0: top - thickness - 0.16, axis: axis, halfLength: min(step / 2, 1.4), halfWidth: 0.09, height: 0.16, .pierWood)
            }
        }
    }
}
