import CoreGraphics
import Foundation

/// Roads are paint. Pavements, carriageways, lane dashes, edge lines, crossings and give-way marks are
/// drawn into the tile's ground image in that order, so later fills cover earlier ones with smooth
/// anti-aliased edges and nothing is stacked as geometry. The only road geometry left is the kerb
/// stone: a low strip along exposed carriageway boundaries, dropped at crossings and driveways.
nonisolated struct DioramaRoadGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain
    let layout: DioramaStreetLayout
    let compounds: [DioramaCompound]
    let painter: DioramaGroundPainter

    private struct Ramp {
        let point: DV2
        let along: DV2
        let outward: DV2
        let halfWidth: Double
        let depth: Double
        var driveway: Bool = false
        func covers(_ p: DV2) -> Bool {
            let v = p - point
            return abs(v.dot(along)) <= halfWidth + 0.7 && v.dot(outward) >= -0.3 && v.dot(outward) <= depth + 0.1
        }
    }

    func generate(into mesh: inout DioramaMesh) {
        paintSurfaces()
        for road in data.roads where road.isPaved && road.width >= 5.5 { markings(road) }
        junctionPaint()
        kerbs(into: &mesh)
    }

    // MARK: Paint

    private func isPaved(near p: DV2) -> Bool {
        roads.nearest(to: p, within: 20)?.road.isPaved ?? false
    }

    private func paintSurfaces() {
        // Rasterize each union in ONE fill. Separately antialiasing boolean fragments exposes
        // the previous paint at every shared edge, especially through round road joins.
        for (surface, isCarriageway) in [(layout.corridor, false), (layout.carriageway, true)] {
            for paved in [false, true] {
                let pieces = surface.polygons.filter { isPaved(near: DioramaPolygon.centroid($0)) == paved }
                let swatch: DioramaSwatch = isCarriageway ? (paved ? .asphalt : .roadEarth) : (paved ? .pavement : .earth)
                painter.fillPieces(pieces, swatch)
            }
        }
    }

    /// Centre dashes keyed to the shared station across split ways, with legible edge paint on
    /// two-lane-width streets. Narrow access lanes remain unmarked; junction interiors stay clear.
    private func markings(_ road: DioramaRoadFeature) {
        let length = DioramaPolygon.length(road.line)
        let period = config.dashLength + config.dashGap
        let station = layout.paintStations[road.id] ?? (offset: 0, direction: 1)
        var run: [(point: DV2, distance: Double, direction: DV2)] = []
        func flush() {
            defer { run.removeAll() }
            guard run.count >= 2 else { return }
            let points = run.map(\.point)
            let phase: Double
            let ordered: [DV2]
            if station.direction >= 0 {
                ordered = points
                phase = station.offset + run[0].distance
            } else {
                ordered = Array(points.reversed())
                phase = station.offset - run[run.count - 1].distance
            }
            let wrapped = (phase.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
            painter.stroke(ordered, width: 0.32, .marking, dashes: [config.dashLength, config.dashGap], phase: wrapped, cap: .butt)
            if road.width >= 6 {
                for side in [-1.0, 1.0] {
                    let offset = (road.width / 2 - 0.38) * side
                    painter.stroke(run.map { $0.point + $0.direction.right * offset }, width: 0.25, .marking, cap: .butt)
                }
            }
        }
        var d = 0.0
        while true {
            guard let s = DioramaPolygon.sample(road.line, at: min(d, length)) else { break }
            if layout.paintIsClear(s.point), data.rect.contains(s.point) {
                run.append((s.point, d, s.direction))
            } else {
                flush()
            }
            if d >= length { break }
            d = min(d + 0.5, length)
        }
        flush()
        laneArrows(road)
    }

    /// Illustrative left-hand traffic paint, not routing instructions or inferred turn restrictions.
    private func laneArrows(_ road: DioramaRoadFeature) {
        guard road.width >= 6, road.roadClass != "service" else { return }
        let length = DioramaPolygon.length(road.line)
        for distance in stride(from: 18.0, to: length - 10, by: 42) {
            guard let sample = DioramaPolygon.sample(road.line, at: distance),
                  let before = DioramaPolygon.sample(road.line, at: distance - 5),
                  let after = DioramaPolygon.sample(road.line, at: distance + 5),
                  before.direction.dot(after.direction) > 0.96 else { continue }
            for sign in [-1.0, 1.0] {
                let forward = sample.direction * sign
                let centre = sample.point + forward.left * (road.width * 0.25)
                let outline: [DV2] = [DV2(-0.2, -2.2), DV2(0.2, -2.2), DV2(0.2, 0.45),
                                     DV2(0.8, 0.1), DV2(0, 2.2), DV2(-0.8, 0.1), DV2(-0.2, 0.45)]
                let ring = outline.map { centre + forward.right * $0.x + forward * $0.y }
                guard ring.allSatisfy({ data.rect.contains($0) && layout.paintIsClear($0) && roads.isOnRoad($0, margin: 0) }) else { continue }
                painter.fill(ring, .marking)
            }
        }
    }

    private func junctionPaint() {
        for approach in layout.approaches {
            let across = approach.toward.right
            let half = approach.width / 2 - 0.4
            if approach.crossing {
                for x in stride(from: -half, to: half - 0.4, by: 0.95) {
                    painter.bar(at: approach.point + across * (x + 0.23), along: approach.toward, length: 2.4, width: 0.46, .crossing)
                }
            }
            // Inferred minor-road priority, not a claim of surveyed traffic-control signage.
            if approach.yields {
                let centre = approach.point - approach.toward * (approach.crossing ? 2.1 : 0)
                for row in [0.0, 0.4] {
                    for x in stride(from: -half, to: -0.3, by: 0.85) {
                        let a = centre + across * (x + 0.25) - approach.toward * row
                        painter.bar(at: a, along: across, length: 0.5, width: 0.28, .marking)
                    }
                }
            }
        }
    }

    // MARK: Kerb stone

    private func accessRamps() -> [Ramp] {
        var result: [Ramp] = []
        for approach in layout.approaches where approach.crossing {
            for side in [-1.0, 1.0] {
                let out = approach.toward.right * side
                result.append(Ramp(point: approach.point + out * (approach.width / 2), along: approach.toward,
                                   outward: out, halfWidth: 1.25, depth: config.pavementWidth))
            }
        }
        for compound in compounds {
            guard let gate = compound.gate, let road = roads.nearest(to: gate.point, within: 20), road.road.isPaved else { continue }
            let out = (gate.point - road.point).normalized
            let point = road.point + out * (road.road.width / 2)
            guard layout.paintIsClear(point), !result.contains(where: { $0.point.distance(to: point) < 4 }) else { continue }
            result.append(Ramp(point: point, along: road.direction, outward: out, halfWidth: config.gateWidth / 2, depth: config.pavementWidth, driveway: true))
        }
        return result
    }

    /// Closed 24 cm-wide curbs follow connected exposed boundaries. Shared corner sections fill
    /// both sides of bends; capped ends occur only at deliberate access/obstacle openings.
    private func kerbs(into mesh: inout DioramaMesh) {
        let ramps = accessRamps()
        let occupied = data.buildings.map(\.ring) + data.water.compactMap { $0.rings.first }
        let obstacles = DioramaStreetSurface(occupied.flatMap { ring in
            let ccw = DioramaPolygon.counterClockwise(ring)
            return DioramaPolygon.triangulate(ccw).map { [ccw[$0.0], ccw[$0.1], ccw[$0.2]] }
        })
        var spans: [(DV2, DV2)] = []
        for edge in layout.carriageway.boundary() {
            let mid = (edge.a + edge.b) * 0.5
            guard isPaved(near: mid) else { continue }
            for segment in obstacles.outsideSegments(edge.a, edge.b, within: data.rect.expanded(by: -0.3)) {
                let line = DioramaPolygon.densify([segment.0, segment.1], maxStep: 0.75)
                for (a, b) in zip(line, line.dropFirst()) {
                    guard !ramps.contains(where: { $0.covers((a + b) * 0.5) }) else { continue }
                    spans.append((a, b))
                }
            }
        }
        for line in DioramaLinearGeometry.chains(spans) {
            mesh.mouldedStrip(line, halfWidth: 0.12, height: config.kerbHeight + 0.08,
                radius: 0.045, lateralOffset: 0.07, swatch: .kerb,
                base: { terrain.height($0) - 0.08 })
        }
    }
}
