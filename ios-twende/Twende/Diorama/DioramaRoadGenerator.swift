import CoreGraphics
import Foundation

/// Roads are paint. Pavements, carriageways, lane dashes, edge lines, crossings and give-way marks are
/// drawn into the tile's ground image in that order, so later fills cover earlier ones with smooth
/// anti-aliased edges and nothing is stacked as geometry. Kerbs are shader paint too on compact
/// tiles (`DioramaGroundPainter.kerb`): a pale top, lit face and gutter shadow drawn from the
/// distance to the road edge, dropped at crossings and driveways. Kerb geometry is only built
/// where vector paint is unavailable.
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
        paintOnly()
        kerbs(into: &mesh)
    }

    /// Stylised bakes: every road finish, lane mark and crossing is paint; no kerb geometry at all.
    func paintOnly() {
        paintSurfaces()
        DioramaRoadMarkings(config: config, data: data, roads: roads, layout: layout, painter: painter).paint()
        roadNames()
    }

    private func roadNames() {
        var placed: [(String, DV2)] = []
        for road in data.roads.sorted(by: { DioramaPolygon.length($0.line) > DioramaPolygon.length($1.line) }) {
            guard let name = road.name, !name.isEmpty, road.width >= 4 else { continue }
            let line = DioramaLinearGeometry.simplified(road.line)
            let segments = zip(line, line.dropFirst()).sorted { $0.0.distance(to: $0.1) > $1.0.distance(to: $1.1) }
            for (a, b) in segments {
                let length = a.distance(to: b)
                guard length > max(14, Double(name.count) * 0.85 + 4) else { continue }
                let direction = (b - a).normalized
                let point = (a + b) * 0.5 + direction.left * (road.width * 0.22)
                guard !placed.contains(where: { $0.0 == name && $0.1.distance(to: point) < 130 }),
                      !data.buildings.contains(where: { DioramaPolygon.contains($0.ring, point) }) else { continue }
                painter.roadName(name, centre: point, direction: direction, maximumWidth: length - 4)
                placed.append((name, point)); break
            }
        }
    }

    // MARK: Paint

    private func isPaved(near p: DV2) -> Bool {
        roads.nearest(to: p, within: 20)?.road.isPaved ?? false
    }

    /// Shared by HD and context: same union geometry, junction fillets and material precedence.
    func paintSurfaces() {
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
        let shaderKerbs = painter.paintsKerbs
        for edge in layout.carriageway.boundary() {
            let mid = (edge.a + edge.b) * 0.5
            guard isPaved(near: mid) else { continue }
            for segment in obstacles.outsideSegments(edge.a, edge.b, within: data.rect.expanded(by: -0.3)) {
                let line = DioramaPolygon.densify([segment.0, segment.1], maxStep: 0.75)
                // Carriageway rings are counter-clockwise: the road is on the left of every edge.
                let inward = (segment.1 - segment.0).normalized.left
                var run: DV2? = nil, runEnd = line[0]
                for (a, b) in zip(line, line.dropFirst()) {
                    guard !ramps.contains(where: { $0.covers((a + b) * 0.5) }) else {
                        if let start = run { painter.kerb(start, runEnd, inward: inward); run = nil }
                        continue
                    }
                    if shaderKerbs {
                        if run == nil { run = a }
                        runEnd = b
                    } else {
                        spans.append((a, b))
                    }
                }
                if let start = run { painter.kerb(start, runEnd, inward: inward) }
            }
        }
        // Compact tiles paint kerbs in the shader; geometry only where vector paint is unavailable.
        guard !shaderKerbs else { return }
        for line in DioramaLinearGeometry.chains(spans) {
            mesh.mouldedStrip(line, halfWidth: 0.12, height: config.kerbHeight + 0.08,
                radius: 0.045, lateralOffset: 0.07, swatch: .kerb,
                base: { terrain.height($0) - 0.08 })
        }
    }
}
