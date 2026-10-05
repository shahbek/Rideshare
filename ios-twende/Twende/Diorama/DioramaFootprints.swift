import Foundation

/// Post-processing of surveyed building plans shared by every generator, so walls, slabs, masks
/// and ground cut-outs all agree on one outline.
nonisolated enum DioramaFootprints {
    /// Clear width between Hotel Slipway and the white arcade block for the mapped external stair.
    static let stairGap: Double = 2.8

    static func make(_ f: DioramaBuildingFeature, ring: [DV2], flags: [Bool]) -> DioramaBuildingFeature? {
        var (pts, fl) = DioramaPolygon.clean(ring, flags: flags)
        (pts, fl) = DioramaPolygon.counterClockwise(pts, flags: fl)
        guard pts.count >= 3, DioramaPolygon.area(pts) > 12 else { return nil }
        return DioramaBuildingFeature(id: f.id, ring: pts, clipped: fl, area: DioramaPolygon.area(pts),
                                      centroid: DioramaPolygon.centroid(pts), height: f.height, type: f.type)
    }

    /// The white block's mapped plan shares a wall with the hotel along the steps line. Trim only the
    /// white block back from the shared hotel edge; the hotel plan is untouched.
    static func carveStairGap(_ buildings: inout [UInt64: DioramaBuildingFeature]) {
        guard let hotel = buildings[DioramaHotelGenerator.gallery],
              let white = buildings[DioramaSlipwayPavilion.arcadeBlockID] else { return }
        let samples = DioramaPolygon.densify(white.ring + [white.ring[0]], maxStep: 0.5)
        var best = -1, bestCount = 0
        for i in hotel.ring.indices {
            let a = hotel.ring[i], b = hotel.ring[(i + 1) % hotel.ring.count]
            let count = samples.filter { DioramaPolygon.distanceToSegment($0, a, b) < 1.0 }.count
            if count > bestCount { best = i; bestCount = count }
        }
        guard best >= 0, bestCount >= 4 else { return }
        let a = hotel.ring[best], b = hotel.ring[(best + 1) % hotel.ring.count]
        let dir = (b - a).normalized, out = dir.right, length = a.distance(to: b)
        // Push back only the stretch that faces the hotel; the rest of the white plan stays surveyed.
        let dense = DioramaPolygon.densify(white.ring + [white.ring[0]], maxStep: 0.5).dropLast()
        let trimmed = dense.map { p -> DV2 in
            let v = p - a, t = v.dot(dir), d = v.dot(out)
            guard t > -0.8, t < length + 0.8, d > -0.5, d < stairGap else { return p }
            return a + dir * t + out * stairGap
        }
        guard let feature = make(white, ring: Array(trimmed), flags: [Bool](repeating: false, count: trimmed.count)) else { return }
        buildings[white.id] = feature
    }

    /// Softly radiused corners (≤0.75 m, illustrative). Clipped tile-edge corners stay sharp.
    static func softened(_ f: DioramaBuildingFeature) -> DioramaBuildingFeature {
        let r = DioramaCoastline.rounded(f.ring, flags: f.clipped, maxReach: 0.75, fraction: 0.22, samples: 4, minimumTurn: 0.35)
        return make(f, ring: r.points, flags: r.flags) ?? f
    }
}
