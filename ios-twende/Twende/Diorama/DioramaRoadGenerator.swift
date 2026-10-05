import Foundation

/// Roads are one planar network. Pavements are its surrounding annulus, with a bevelled kerb
/// following only exposed boundaries; paint and dropped crossings share the junction layout.
nonisolated struct DioramaRoadGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain
    let layout: DioramaStreetLayout
    let compounds: [DioramaCompound]

    static let surfaceLift: Double = 0.12

    private struct Ramp {
        let point: DV2
        let along: DV2
        let outward: DV2
        let halfWidth: Double
        let depth: Double
        var driveway: Bool = false
        var polygon: [DV2] {
            [point - along * (halfWidth + 0.7) - outward * 0.2,
             point + along * (halfWidth + 0.7) - outward * 0.2,
             point + along * (halfWidth + 0.7) + outward * depth,
             point - along * (halfWidth + 0.7) + outward * depth]
        }
        func factor(at p: DV2) -> Double {
            let v = p - point
            guard v.dot(outward) >= -0.3, v.dot(outward) <= depth + 0.1 else { return 1 }
            let flank = max(0, min(1, (abs(v.dot(along)) - halfWidth) / 0.7))
            let rise = driveway ? 0 : max(0, min(1, v.dot(outward) / depth))
            return max(flank, rise)
        }
    }

    func generate(into mesh: inout DioramaMesh) {
        let ramps = accessRamps()
        let occupied = data.buildings.map(\.ring) + data.water.compactMap { $0.rings.first }
        let obstacles = DioramaStreetSurface(occupied.flatMap { ring in
            let ccw = DioramaPolygon.counterClockwise(ring)
            return DioramaPolygon.triangulate(ccw).map { [ccw[$0.0], ccw[$0.1], ccw[$0.2]] }
        })
        let kerbOuter = DioramaStreetSurface(layout.carriageway.polygons.compactMap { DioramaPolygon.offset($0, by: 0.24) })
        let pavementMask = DioramaStreetSurface(kerbOuter.polygons + obstacles.polygons + ramps.map(\.polygon))
        for piece in layout.carriageway.pieces(excluding: obstacles) {
            let centre = DioramaPolygon.centroid(piece)
            let swatch: DioramaSwatch = roads.nearest(to: centre, within: 20)?.road.isPaved == false ? .roadEarth : .asphalt
            surface(piece, lift: Self.surfaceLift, swatch, into: &mesh)
        }
        for piece in layout.corridor.pieces(excluding: pavementMask) {
            let centre = DioramaPolygon.centroid(piece)
            let paved = roads.nearest(to: centre, within: 20)?.road.isPaved ?? false
            surface(piece, lift: paved ? Self.surfaceLift + config.kerbHeight : 0.08, paved ? .pavement : .earth, into: &mesh)
        }
        // Kerb top: the same boolean annulus as the pavement, never a cap over asphalt.
        let kerbMask = DioramaStreetSurface(layout.carriageway.polygons + obstacles.polygons + ramps.map(\.polygon))
        for piece in kerbOuter.pieces(excluding: kerbMask) {
            let paved = roads.nearest(to: DioramaPolygon.centroid(piece), within: 20)?.road.isPaved == true
            surface(piece, lift: paved ? Self.surfaceLift + config.kerbHeight - 0.045 : 0.08, paved ? .kerb : .earth, into: &mesh)
        }
        for edge in layout.carriageway.boundary() {
            let mid = (edge.a + edge.b) * 0.5
            guard roads.nearest(to: mid, within: 20)?.road.isPaved == true else { continue }
            let out = (edge.b - edge.a).normalized.right
            for segment in obstacles.outsideSegments(edge.a, edge.b, within: data.rect.expanded(by: -0.3)) {
            let line = DioramaPolygon.densify([segment.0, segment.1], maxStep: 0.4)
            for (a, b) in zip(line, line.dropFirst()) {
                let fa = rampFactor(a, ramps), fb = rampFactor(b, ramps)
                let za = terrain.height(a) + Self.surfaceLift, zb = terrain.height(b) + Self.surfaceLift
                let ha = config.kerbHeight * fa, hb = config.kerbHeight * fb
                let faceA = fa < 0.999 ? ha : max(ha - 0.055, 0)
                let faceB = fb < 0.999 ? hb : max(hb - 0.055, 0)
                // Nose bevel leans toward the carriageway; all pieces meet on the shared top edge.
                mesh.quad(DV3(a - out * 0.045, za), DV3(b - out * 0.045, zb),
                          DV3(b - out * 0.045, zb + faceB), DV3(a - out * 0.045, za + faceA), .kerb, normal: DV3(-out, 0))
                // Access patches replace the entire kerb profile; don't lay a bevel through a ramp.
                if fa > 0.999, fb > 0.999 {
                    mesh.quad(DV3(a - out * 0.045, za + max(ha - 0.055, 0)), DV3(b - out * 0.045, zb + max(hb - 0.055, 0)),
                              DV3(b + out * 0.24, pavementHeight(b + out * 0.24, ramps)),
                              DV3(a + out * 0.24, pavementHeight(a + out * 0.24, ramps)), .kerb, normal: DV3(-out * 0.3, 1).normalized)
                }
            }
            }
        }
        for edge in layout.corridor.boundary() {
            let mid = (edge.a + edge.b) * 0.5
            guard roads.nearest(to: mid, within: 20)?.road.isPaved == true else { continue }
            for segment in obstacles.outsideSegments(edge.a, edge.b, within: data.rect.expanded(by: -0.1)) {
                let line = DioramaPolygon.densify([segment.0, segment.1], maxStep: 0.35)
                for (a, b) in zip(line, line.dropFirst()) {
                    mesh.quad(DV3(a, terrain.height(a)), DV3(b, terrain.height(b)),
                              DV3(b, pavementHeight(b, ramps)), DV3(a, pavementHeight(a, ramps)), .pavement,
                              normal: DV3((b - a).normalized.right, 0))
                }
            }
        }
        // Subdivide ramps separately so interpolation cannot flatten a whole pavement block.
        let rampMask = DioramaStreetSurface(layout.carriageway.polygons + obstacles.polygons)
        for ramp in ramps {
            let width = ramp.halfWidth + 0.7
            for x in stride(from: -width, to: width, by: 0.4) {
                for y in stride(from: 0.0, to: ramp.depth, by: 0.4) {
                    let a = ramp.point + ramp.along * x + ramp.outward * y
                    let b = ramp.point + ramp.along * min(x + 0.4, width) + ramp.outward * y
                    let c = ramp.point + ramp.along * min(x + 0.4, width) + ramp.outward * min(y + 0.4, ramp.depth)
                    let d = ramp.point + ramp.along * x + ramp.outward * min(y + 0.4, ramp.depth)
                    let clipped = DioramaPolygon.clipPolygon([a, b, c, d], to: data.rect)
                    let tile = DioramaStreetSurface(layout.corridor.intersection(clipped))
                    for piece in tile.pieces(excluding: rampMask) {
                        let ccw = DioramaPolygon.counterClockwise(piece)
                        for (i, j, k) in DioramaPolygon.triangulate(ccw) {
                            let p = ccw[i], q = ccw[j], r = ccw[k]
                            mesh.triangle(DV3(p, pavementHeight(p, ramps)), DV3(q, pavementHeight(q, ramps)), DV3(r, pavementHeight(r, ramps)), .pavement)
                        }
                    }
                }
            }
        }
        for road in data.roads where road.isPaved && road.width >= 6 { markings(road, into: &mesh) }
        junctionPaint(into: &mesh)
    }

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

    private func rampFactor(_ p: DV2, _ ramps: [Ramp]) -> Double {
        ramps.reduce(1) { min($0, $1.factor(at: p)) }
    }

    private func pavementHeight(_ p: DV2, _ ramps: [Ramp]) -> Double {
        terrain.height(p) + Self.surfaceLift + config.kerbHeight * rampFactor(p, ramps)
    }

    private func surface(_ polygon: [DV2], lift: Double, _ swatch: DioramaSwatch, into mesh: inout DioramaMesh) {
        let ring = DioramaPolygon.counterClockwise(DioramaPolygon.clipPolygon(polygon, to: data.rect))
        for (a, b, c) in DioramaPolygon.triangulate(ring) {
            mesh.triangle(DV3(ring[a], terrain.height(ring[a]) + lift), DV3(ring[b], terrain.height(ring[b]) + lift), DV3(ring[c], terrain.height(ring[c]) + lift), swatch, normal: .up)
        }
    }

    private func markings(_ road: DioramaRoadFeature, into mesh: inout DioramaMesh) {
        let length = DioramaPolygon.length(road.line)
        let period = config.dashLength + config.dashGap
        let station = layout.paintStations[road.id] ?? (offset: 0, direction: 1)
        for distance in stride(from: 0.0, to: length - 0.4, by: 0.45) {
            guard let a = DioramaPolygon.sample(road.line, at: distance),
                  let b = DioramaPolygon.sample(road.line, at: min(distance + 0.45, length)) else { continue }
            guard layout.paintIsClear(a.point), layout.paintIsClear(b.point) else { continue }
            let arc = station.offset + distance * station.direction
            let phase = (arc.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
            if phase < config.dashLength {
                strip(a.point, b.point, halfWidth: 0.09, .marking, into: &mesh)
            }
            // Quiet residential/service streets do not get motorway-style edge paint.
            if road.isMain {
                for side in [-1.0, 1.0] {
                    let offset = (road.width / 2 - 0.38) * side
                    strip(a.point + a.direction.right * offset, b.point + b.direction.right * offset, halfWidth: 0.07, .marking, into: &mesh)
                }
            }
        }
    }

    private func junctionPaint(into mesh: inout DioramaMesh) {
        for approach in layout.approaches {
            let across = approach.toward.right
            let half = approach.width / 2 - 0.4
            if approach.crossing {
                for x in stride(from: -half, to: half - 0.4, by: 0.95) {
                    let c = approach.point + across * (x + 0.23)
                    strip(c - approach.toward * 1.2, c + approach.toward * 1.2, halfWidth: 0.23, .crossing, into: &mesh)
                }
            }
            // Inferred minor-road priority, not a claim of surveyed traffic-control signage.
            if approach.yields {
                let centre = approach.point - approach.toward * (approach.crossing ? 2.1 : 0)
                for row in [0.0, 0.4] {
                    for x in stride(from: -half, to: -0.3, by: 0.85) {
                        let a = centre + across * x - approach.toward * row
                        strip(a, a + across * 0.5, halfWidth: 0.09, .marking, into: &mesh)
                    }
                }
            }
        }
    }

    private func strip(_ a: DV2, _ b: DV2, halfWidth: Double, _ swatch: DioramaSwatch, into mesh: inout DioramaMesh) {
        let n = (b - a).normalized.right * halfWidth
        guard [a - n, a + n, b - n, b + n].allSatisfy({ layout.carriageway.contains($0) && data.rect.contains($0) }) else { return }
        surface([a - n, b - n, b + n, a + n], lift: Self.surfaceLift + 0.012, swatch, into: &mesh)
    }
}
