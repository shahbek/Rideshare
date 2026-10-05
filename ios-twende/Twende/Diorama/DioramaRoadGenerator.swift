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
        for road in data.roads where road.isPaved && road.width >= 6 { markings(road) }
        junctionPaint()
        kerbs(into: &mesh)
    }

    // MARK: Paint

    private func isPaved(near p: DV2) -> Bool {
        roads.nearest(to: p, within: 20)?.road.isPaved ?? false
    }

    private func paintSurfaces() {
        // Pavements and sandy shoulders first, then every carriageway over them.
        for piece in layout.corridor.pieces() {
            let paved = isPaved(near: DioramaPolygon.centroid(piece))
            painter.fill(DioramaPolygon.clipPolygon(piece, to: data.rect), paved ? .pavement : .earth)
        }
        for piece in layout.carriageway.pieces() {
            let paved = isPaved(near: DioramaPolygon.centroid(piece))
            painter.fill(DioramaPolygon.clipPolygon(piece, to: data.rect), paved ? .asphalt : .roadEarth)
        }
    }

    /// Centre dashes keyed to the shared station so they continue across split ways; edge lines on
    /// main roads only. Paint stops short of junction circles.
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
            painter.stroke(ordered, width: 0.18, .marking, dashes: [config.dashLength, config.dashGap], phase: wrapped, cap: .butt)
            if road.isMain {
                for side in [-1.0, 1.0] {
                    let offset = (road.width / 2 - 0.38) * side
                    painter.stroke(run.map { $0.point + $0.direction.right * offset }, width: 0.14, .marking, cap: .butt)
                }
            }
        }
        var d = 0.0
        while d <= length {
            guard let s = DioramaPolygon.sample(road.line, at: min(d, length)) else { break }
            if layout.paintIsClear(s.point), data.rect.contains(s.point) {
                run.append((s.point, d, s.direction))
            } else {
                flush()
            }
            d += 0.5
        }
        flush()
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
                        painter.bar(at: a, along: across, length: 0.5, width: 0.18, .marking)
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

    /// A 24 cm kerb stone along every exposed paved carriageway edge: top, road face and pavement
    /// face. The terrain is sampled at 2 m so the strip follows the ground.
    private func kerbs(into mesh: inout DioramaMesh) {
        let ramps = accessRamps()
        let occupied = data.buildings.map(\.ring) + data.water.compactMap { $0.rings.first }
        let obstacles = DioramaStreetSurface(occupied.flatMap { ring in
            let ccw = DioramaPolygon.counterClockwise(ring)
            return DioramaPolygon.triangulate(ccw).map { [ccw[$0.0], ccw[$0.1], ccw[$0.2]] }
        })
        let h = config.kerbHeight
        for edge in layout.carriageway.boundary() {
            let mid = (edge.a + edge.b) * 0.5
            guard isPaved(near: mid) else { continue }
            let out = (edge.b - edge.a).normalized.right
            for segment in obstacles.outsideSegments(edge.a, edge.b, within: data.rect.expanded(by: -0.3)) {
                let line = DioramaPolygon.densify([segment.0, segment.1], maxStep: 2)
                for (a, b) in zip(line, line.dropFirst()) {
                    guard !ramps.contains(where: { $0.covers((a + b) * 0.5) }) else { continue }
                    let za = terrain.height(a), zb = terrain.height(b)
                    let ia = a - out * 0.05, ib = b - out * 0.05, oa = a + out * 0.19, ob = b + out * 0.19
                    mesh.quad(DV3(ia, za + h), DV3(ib, zb + h), DV3(ob, zb + h), DV3(oa, za + h), .kerb, normal: .up)
                    mesh.quad(DV3(ia, za), DV3(ib, zb), DV3(ib, zb + h), DV3(ia, za + h), .kerb, normal: DV3(-out, 0))
                    mesh.quad(DV3(ob, zb), DV3(oa, za), DV3(oa, za + h), DV3(ob, zb + h), .kerb, dark: true, normal: DV3(out, 0))
                }
            }
        }
    }
}
