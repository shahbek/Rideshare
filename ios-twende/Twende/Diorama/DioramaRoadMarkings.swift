import Foundation
import CoreGraphics

/// Shared resolution-independent street paint; inferred controls are scenery, not routing truth.
nonisolated struct DioramaRoadMarkings {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let layout: DioramaStreetLayout
    let painter: DioramaGroundPainter

    func paint() {
        for road in data.roads where road.isPaved && road.width >= 5.5 { markings(road) }
        junctionPaint()
    }

    private func markings(_ road: DioramaRoadFeature) {
        let length = DioramaPolygon.length(road.line)
        let period = config.dashLength + config.dashGap
        let station = layout.paintStations[road.id] ?? (offset: 0, direction: 1)
        var run: [(point: DV2, distance: Double, direction: DV2)] = []
        func flush() {
            defer { run.removeAll() }
            guard run.count >= 2 else { return }
            let phase = station.direction >= 0 ? station.offset + run[0].distance : station.offset - run[run.count - 1].distance
            let points = station.direction >= 0 ? run.map(\.point) : Array(run.map(\.point).reversed())
            let wrapped = (phase.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
            painter.stroke(points, width: 0.32, .marking, dashes: [config.dashLength, config.dashGap], phase: wrapped, cap: .butt)
            if road.width >= 6 {
                for side in [-1.0, 1.0] {
                    let offset = (road.width / 2 - 0.38) * side
                    painter.stroke(run.map { $0.point + $0.direction.right * offset }, width: 0.25, .signYellow, cap: .butt)
                }
            }
        }
        var d = 0.0
        while true {
            guard let s = DioramaPolygon.sample(road.line, at: min(d, length)) else { break }
            if layout.paintIsClear(s.point), data.rect.contains(s.point) { run.append((s.point, d, s.direction)) }
            else { flush() }
            if d >= length { break }
            d = min(d + 0.5, length)
        }
        flush()
        guard road.width >= 6, road.roadClass != "service" else { return }
        for distance in stride(from: 18.0, to: length - 10, by: 42) {
            guard let sample = DioramaPolygon.sample(road.line, at: distance),
                  let before = DioramaPolygon.sample(road.line, at: distance - 5),
                  let after = DioramaPolygon.sample(road.line, at: distance + 5),
                  before.direction.dot(after.direction) > 0.96 else { continue }
            let directions: [Double] = road.oneWay == 0 ? [-1, 1] : [Double(road.oneWay)]
            for sign in directions {
                let forward = sample.direction * sign
                let centre = sample.point + forward.left * (road.width * 0.25)
                let outline: [DV2] = [DV2(-0.2, -2.2), DV2(0.2, -2.2), DV2(0.2, 0.45), DV2(0.8, 0.1), DV2(0, 2.2), DV2(-0.8, 0.1), DV2(-0.2, 0.45)]
                let ring = outline.map { centre + forward.right * $0.x + forward * $0.y }
                guard ring.allSatisfy({ data.rect.contains($0) && layout.paintIsClear($0) && roads.isOnRoad($0, margin: 0) }) else { continue }
                painter.fill(ring, .marking)
            }
        }
    }

    private func junctionPaint() {
        for approach in layout.approaches {
            let across = approach.toward.right, half = approach.width / 2 - 0.4
            if approach.crossing {
                for x in stride(from: -half, to: half - 0.4, by: 0.95) {
                    painter.bar(at: approach.point + across * (x + 0.23), along: approach.toward, length: 2.4, width: 0.46, .crossing)
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
        }
    }
}
