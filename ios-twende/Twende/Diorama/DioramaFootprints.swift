import Foundation

/// Shared authored landmark plans: walls, roofs, paving masks and stair clearances use one outline.
nonisolated enum DioramaFootprints {
    static let stairGap: Double = 6.5

    static func make(_ f: DioramaBuildingFeature, ring: [DV2], flags: [Bool]) -> DioramaBuildingFeature? {
        var (pts, fl) = DioramaPolygon.clean(ring, flags: flags)
        (pts, fl) = DioramaPolygon.counterClockwise(pts, flags: fl)
        guard pts.count >= 3, DioramaPolygon.area(pts) > 12 else { return nil }
        return DioramaBuildingFeature(id: f.id, ring: pts, clipped: fl, area: DioramaPolygon.area(pts),
                                      centroid: DioramaPolygon.centroid(pts), height: f.height, type: f.type)
    }

    /// OSM supplies only the landmark's location, orientation and approximate scale. The bespoke
    /// gallery/pavilion plans are authored clean masses, not extrusions of Standard's footprint.
    static func landmarkPlan(_ f: DioramaBuildingFeature) -> DioramaBuildingFeature {
        guard f.id == DioramaHotelGenerator.gallery || DioramaSlipwayPavilion.buildingIDs.contains(f.id) else { return f }
        let anchor = DioramaPolygon.minimumAreaRectangle(f.ring)
        let plan = DioramaOrientedRect(centre: anchor.centre, axis: anchor.axis,
                                      halfLength: anchor.halfLength * 0.96, halfWidth: anchor.halfWidth * 0.94)
        return make(f, ring: plan.corners, flags: [false, false, false, false]) ?? f
    }

    static func facingEdge(hotel: DioramaBuildingFeature, white: DioramaBuildingFeature) -> (a: DV2, b: DV2)? {
        let candidates = hotel.ring.indices.filter { i in
            let a = hotel.ring[i], b = hotel.ring[(i + 1) % hotel.ring.count]
            // The photographed shared passage is NNW of Hotel Slipway, not its west dining front.
            return a.distance(to: b) > 5 && (b - a).normalized.right.dot(DV2(-0.22, 1).normalized) > 0.8
        }
        guard let i = candidates.min(by: { i, j in
            func distance(_ k: Int) -> Double {
                DioramaPolygon.distanceToSegment(white.centroid, hotel.ring[k], hotel.ring[(k + 1) % hotel.ring.count])
            }
            return distance(i) < distance(j)
        }) else { return nil }
        return (hotel.ring[i], hotel.ring[(i + 1) % hotel.ring.count])
    }

    /// Recede the white pavilion's complete south face without relocating it into its neighbours.
    static func carveStairGap(_ buildings: inout [UInt64: DioramaBuildingFeature]) {
        guard let hotel = buildings[DioramaHotelGenerator.gallery],
              let white = buildings[DioramaSlipwayPavilion.arcadeBlockID],
              let edge = facingEdge(hotel: hotel, white: white) else { return }
        let out = (edge.b - edge.a).normalized.right
        let ring = DioramaGroundCutouts.halfPlane(white.ring, a: edge.a + out * stairGap,
                                                 b: edge.b + out * stairGap, inside: false)
        buildings[white.id] = make(white, ring: ring, flags: [Bool](repeating: false, count: ring.count)) ?? white
    }

    static func softened(_ f: DioramaBuildingFeature) -> DioramaBuildingFeature {
        let landmark = DioramaHotelGenerator.ids.contains(f.id) || DioramaSlipwayPavilion.buildingIDs.contains(f.id)
        let r = DioramaCoastline.rounded(f.ring, flags: f.clipped, maxReach: landmark ? 2.4 : 0.95,
                                        fraction: 0.22, samples: landmark ? 16 : 6, minimumTurn: 0.35)
        return make(f, ring: r.points, flags: r.flags) ?? f
    }
}
