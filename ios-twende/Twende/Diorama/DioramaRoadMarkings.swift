import Foundation
import CoreGraphics

/// Shared resolution-independent street paint; inferred controls are scenery, not routing truth.
///
/// Styled the way real carriageways are marked (left-hand traffic, Tanzania):
/// - one dashed white centre line per carriageway (lane divider on one-way halves), made only of
///   whole dashes, never slivers; none on roundabout rings or single-lane one-way streets;
/// - continuous yellow edge lines just inside each kerb;
/// - every line stops where it would run onto another road's asphalt, so lines never cross at
///   median noses or merges, side-road mouths open the main road's edge line, and nothing is
///   painted inside a crossing; a road that merely ends at another (a T) leaves the through
///   road's centre line intact;
/// - lines stop short of give-way markings and zebra crossings;
/// - lane arrows only on the approach to a junction, one per inbound lane, on roads of 7 m+.
nonisolated struct DioramaRoadMarkings {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let layout: DioramaStreetLayout
    let painter: DioramaGroundPainter

    private typealias Sample = (point: DV2, distance: Double, direction: DV2)

    /// Which chains' asphalt covers a point. A chain whose nearest point is its own open end only
    /// abuts the point's road (a side road meeting a through road), so it does not count.
    private struct Occupancy {
        struct Segment { let a: DV2; let b: DV2; let chain: Int; let opensAtA: Bool; let opensAtB: Bool }
        let grid: DioramaGrid
        let segments: [Segment]
        let halfWidths: [Double]

        init(_ chains: [DioramaRoadFeature]) {
            var grid = DioramaGrid(cell: 24)
            var segments: [Segment] = []
            for (c, chain) in chains.enumerated() where chain.line.count >= 2 {
                let n = chain.line.count - 1
                let closed = chain.line[0].distance(to: chain.line[n]) < 0.05
                for k in 0..<n {
                    let a = chain.line[k], b = chain.line[k + 1]
                    grid.insert(segments.count, rect: DioramaRect.bounding([a, b]).expanded(by: chain.width / 2 + 1))
                    segments.append(Segment(a: a, b: b, chain: c, opensAtA: !closed && k == 0, opensAtB: !closed && k == n - 1))
                }
            }
            self.grid = grid
            self.segments = segments
            halfWidths = chains.map { $0.width / 2 }
        }

        func covers(_ p: DV2, except chain: Int, margin: Double) -> Bool {
            for i in grid.query(DioramaRect.bounding([p]).expanded(by: 0.01)) {
                let s = segments[i]
                guard s.chain != chain else { continue }
                let q = DioramaPolygon.closestPointOnSegment(p, s.a, s.b)
                guard q.distance(to: p) < halfWidths[s.chain] + margin else { continue }
                if s.opensAtA && q.distance(to: s.a) < 0.05 { continue }
                if s.opensAtB && q.distance(to: s.b) < 0.05 { continue }
                return true
            }
            return false
        }
    }

    func paint() {
        let chains = layout.chains
        let occupancy = Occupancy(chains)
        var firstPoint: [UInt64: DV2] = [:]
        for road in data.roads where road.line.count >= 2 { firstPoint[road.id] = road.line[0] }
        for (index, chain) in chains.enumerated() where chain.isPaved && chain.width >= 5.5 {
            // The chain keeps its first way's id; dash phase is measured from that way's start.
            var shift = 0.0, walked = 0.0
            if let start = firstPoint[chain.id] {
                for (a, b) in zip(chain.line, chain.line.dropFirst()) {
                    if a.distance(to: start) < 0.01 { shift = walked; break }
                    walked += a.distance(to: b)
                }
            }
            markings(chain, index: index, shift: shift, occupancy: occupancy)
        }
        junctionPaint(occupancy)
    }

    /// True just before and across a give-way line or zebra crossing: running lines stop there.
    private func nearControl(_ p: DV2) -> Bool {
        layout.approaches.contains { a in
            guard a.yields || a.crossing else { return false }
            let d = p - a.point
            let ahead = d.dot(a.toward), lateral = abs(d.dot(a.toward.right))
            return lateral < a.width / 2 + 0.3 && ahead > -1.2 && ahead < (a.crossing ? 3.6 : 1.2)
        }
    }

    private func markings(_ road: DioramaRoadFeature, index: Int, shift: Double, occupancy: Occupancy) {
        let length = DioramaPolygon.length(road.line)
        guard length > 1 else { return }
        let raw = layout.paintStations[road.id] ?? (offset: 0, direction: 1)
        let station = (offset: raw.offset - (raw.direction >= 0 ? shift : -shift), direction: raw.direction)
        let closed = road.line.count >= 4 && road.line[0].distance(to: road.line[road.line.count - 1]) < 0.05
        var samples: [Sample] = []
        var d = 0.0
        while true {
            guard let s = DioramaPolygon.sample(road.line, at: min(d, length)) else { break }
            samples.append((s.point, d, s.direction))
            if d >= length { break }
            d = min(d + 0.5, length)
        }
        func runs(_ keep: (Sample) -> Bool) -> [[Sample]] {
            var result: [[Sample]] = [], run: [Sample] = []
            for s in samples {
                if keep(s) { run.append(s) } else { if run.count >= 2 { result.append(run) }; run.removeAll() }
            }
            if run.count >= 2 { result.append(run) }
            return result
        }
        // Centre line: lane divider on two-way roads and on one-way carriageways wide enough for two lanes.
        if !closed, road.oneWay == 0 || road.width >= 6.5 {
            for run in runs({ data.rect.contains($0.point) && !nearControl($0.point) && !occupancy.covers($0.point, except: index, margin: 0.4) }) {
                dashes(run, station: station)
            }
        }
        guard road.width >= 6 else { return }
        for side in [-1.0, 1.0] {
            let offset = (road.width / 2 - 0.38) * side
            let pieces = runs { s in
                let q = s.point + s.direction.right * offset
                return data.rect.contains(q) && !nearControl(q) && !occupancy.covers(q, except: index, margin: 0.15)
            }
            for run in pieces where run[run.count - 1].distance - run[0].distance >= 2 {
                // Mitred offset of the simplified centreline: continuous through bends.
                let centre = DioramaLinearGeometry.simplified(run.map(\.point))
                painter.stroke(DioramaGroundPainter.mitredOffset(centre, by: offset), width: 0.25, .signYellow, cap: .butt)
            }
        }
    }

    /// Whole dashes only, on the road's shared dash rhythm: a dash that would be cut by a junction,
    /// a crossing or the tile edge is left out rather than painted as a sliver.
    private func dashes(_ run: [Sample], station: (offset: Double, direction: Double)) {
        let period = config.dashLength + config.dashGap
        let points = station.direction >= 0 ? run.map(\.point) : run.map(\.point).reversed()
        let phase = station.direction >= 0 ? station.offset + run[0].distance : station.offset - run[run.count - 1].distance
        var cumulative: [Double] = [0]
        for (a, b) in zip(points, points.dropFirst()) { cumulative.append(cumulative[cumulative.count - 1] + a.distance(to: b)) }
        let total = cumulative[cumulative.count - 1]
        let wrapped = (phase.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
        var start = -wrapped
        while start < total {
            let s0 = start, s1 = start + config.dashLength
            start += period
            guard s0 >= 0.25, s1 <= total - 0.25 else { continue }
            var dash: [DV2] = []
            for i in 0..<(points.count - 1) {
                let a = cumulative[i], b = cumulative[i + 1]
                guard b - a > 1e-6, b > s0, a < s1 else { continue }
                let t0 = max(0, (s0 - a) / (b - a)), t1 = min(1, (s1 - a) / (b - a))
                let p = points[i], q = points[i + 1]
                if dash.isEmpty { dash.append(p + (q - p) * t0) }
                dash.append(p + (q - p) * t1)
            }
            if dash.count >= 2 { painter.stroke(dash, width: 0.32, .marking, cap: .butt) }
        }
    }

    private func junctionPaint(_ occupancy: Occupancy) {
        var byID: [UInt64: DioramaRoadFeature] = [:]
        for road in data.roads { byID[road.id] = road }
        let outline: [DV2] = [DV2(-0.2, -2.2), DV2(0.2, -2.2), DV2(0.2, 0.45), DV2(0.8, 0.1), DV2(0, 2.2), DV2(-0.8, 0.1), DV2(-0.2, 0.45)]
        for approach in layout.approaches {
            let across = approach.toward.right, half = approach.width / 2 - 0.4
            if approach.crossing {
                for x in stride(from: -half, to: half - 0.4, by: 0.95) {
                    painter.bar(at: approach.point + across * (x + 0.25), along: approach.toward, length: 2.4, width: 0.46, .crossing)
                }
            }
            if approach.yields {
                let centre = approach.point - approach.toward * (approach.crossing ? 2.1 : 0)
                for row in [0.0, 0.4] {
                    for x in stride(from: -half, to: -0.3, by: 0.85) {
                        painter.bar(at: centre + across * (x + 0.25) - approach.toward * row, along: across, length: 0.5, width: 0.28, .marking)
                    }
                }
            }
            // Lane arrows: one per inbound lane, a little before the stop/give-way position.
            guard let road = byID[approach.roadID], road.isPaved, road.width >= 7, road.roadClass != "service" else { continue }
            let back = approach.point - approach.toward * ((approach.crossing ? 3.0 : 0) + (approach.yields ? 1.0 : 0) + 6.5)
            var lanes: [Double] = []
            if road.oneWay == 0 {
                lanes = [-road.width * 0.25]
            } else {
                // One-way: only where traffic flows toward the junction; every lane gets an arrow.
                guard let flow = Self.direction(of: road, near: back), (flow * Double(road.oneWay)).dot(approach.toward) > 0.5 else { continue }
                lanes = road.width >= 7 ? [-road.width * 0.22, road.width * 0.22] : [0]
            }
            for lane in lanes {
                // Left-hand traffic: the inbound lane is on the left of the direction of travel.
                let centre = back + across * lane
                let ring = outline.map { centre + across * $0.x + approach.toward * $0.y }
                guard ring.allSatisfy({ data.rect.contains($0) && roads.isOnRoad($0, margin: 0) && layout.paintIsClear($0) }) else { continue }
                painter.fill(ring, .marking)
            }
        }
    }

    private static func direction(of road: DioramaRoadFeature, near p: DV2) -> DV2? {
        var best: DV2?, nearest = Double.infinity
        for (a, b) in zip(road.line, road.line.dropFirst()) where a.distance(to: b) > 0.01 {
            let d = DioramaPolygon.distanceToSegment(p, a, b)
            if d < nearest { nearest = d; best = (b - a).normalized }
        }
        return best
    }
}
