import Foundation

/// Continuous upper envelope of hipped roof wings. No shrinking contour or concave centroid fan.
nonisolated enum DioramaRoofBuilder {
    nonisolated struct Plane: Sendable {
        let gradient: DV2
        let offset: Double
        func height(_ p: DV2) -> Double { gradient.dot(p) + offset }
        func minus(_ other: Plane) -> Plane { Plane(gradient: gradient - other.gradient, offset: offset - other.offset) }
    }
    nonisolated struct Wing: Sendable {
        let outline: [DV2]
        let planes: [Plane]
    }

    /// Commits only a fully covered, finite roof. Unsupported/uncertain footprints use the caller's flat fallback.
    @discardableResult
    static func hip(_ ring: [DV2], flags: [Bool], z: Double, pitch: Double, overhang: Double, maxRise: Double,
                    color: DioramaSwatch, fascia: DioramaSwatch, into mesh: inout DioramaMesh,
                    footprint: [DV2]? = nil) -> Bool {
        let ccw = DioramaPolygon.counterClockwise(ring)
        let slope = tan(pitch)
        guard !Task.isCancelled, !flags.contains(true), (3...128).contains(ccw.count),
              z.isFinite, slope.isFinite, slope > 0.01, maxRise > 0,
              let eaves = DioramaPolygon.offset(ccw, by: overhang),
              let wings = wings(for: footprint ?? ccw, eaves: eaves, slope: slope, overhang: overhang, maxRise: maxRise),
              !wings.isEmpty else { return false }
        let triangles = DioramaPolygon.triangulate(eaves)
        let triangleArea = triangles.reduce(0.0) { sum, t in
            sum + abs((eaves[t.1] - eaves[t.0]).cross(eaves[t.2] - eaves[t.0])) * 0.5
        }
        let expectedArea = DioramaPolygon.area(eaves)
        guard expectedArea > 0.1, abs(triangleArea - expectedArea) < expectedArea * 0.00001 else { return false }
        var surfaces: [(polygon: [DV2], plane: Plane)] = []
        var coveredArea = 0.0
        for (wingIndex, wing) in wings.enumerated() {
            for (planeIndex, plane) in wing.planes.enumerated() {
                if Task.isCancelled { return false }
                var face = wing.outline
                // A hip is the minimum of its inward slope planes and maximum-rise cap.
                for (index, other) in wing.planes.enumerated() where index != planeIndex {
                    face = clip(face, by: other.minus(plane))
                }
                guard face.count >= 3, DioramaPolygon.area(face) > 1e-8 else { continue }
                var visible = [face]
                // Remove regions hidden by another wing's entire roof volume, not just its box.
                for (otherIndex, other) in wings.enumerated() where otherIndex != wingIndex {
                    let constraints = other.planes.map { $0.minus(plane) }
                    // Coplanar ties have one deterministic owner, never doubled coincident faces.
                    if otherIndex > wingIndex && constraints.contains(where: {
                        $0.gradient.length < 1e-8 && abs($0.offset) < 1e-8
                    }) { continue }
                    visible = visible.flatMap { subtract($0, volume: constraints) }
                    if visible.isEmpty { break }
                    if visible.count > 256 { return false }
                }
                for piece in visible {
                    for triangle in triangles {
                        var clipped = piece
                        let mask = [eaves[triangle.0], eaves[triangle.1], eaves[triangle.2]]
                        for i in mask.indices {
                            let a = mask[i], inward = (mask[(i + 1) % 3] - a).normalized.left
                            clipped = clip(clipped, by: Plane(gradient: inward, offset: -inward.dot(a)))
                        }
                        guard clipped.count >= 3 else { continue }
                        let area = DioramaPolygon.area(clipped)
                        guard area > 1e-8 else { continue }
                        guard clipped.allSatisfy({ plane.height($0).isFinite && plane.height($0) >= -0.001 && plane.height($0) <= maxRise + 0.001 }) else { return false }
                        coveredArea += area
                        surfaces.append((clipped, plane))
                        if surfaces.count > 4096 { return false }
                    }
                }
            }
        }
        // Reject incomplete or overlapping partitions before touching the destination mesh.
        guard abs(coveredArea - expectedArea) <= max(0.0001, expectedArea * 0.00001) else { return false }
        let eaveZ = z + 0.22
        mesh.extrude(eaves, z0: z - 0.05, z1: eaveZ, fascia)
        mesh.polygon(eaves, z: z - 0.05, fascia, dark: true, facingUp: false)
        mesh.polygon(ccw, z: z + 0.01, color)
        for surface in surfaces {
            let p = surface.polygon, plane = surface.plane
            let normal = DV3(-plane.gradient.x, -plane.gradient.y, 1).normalized
            func lifted(_ point: DV2) -> DV3 { DV3(point, eaveZ + max(0, plane.height(point))) }
            for i in 1..<(p.count - 1) {
                mesh.triangle(lifted(p[0]), lifted(p[i]), lifted(p[i + 1]), color, normal: normal)
            }
            // Rounded actual eaves can lie inside a sharp wing. Close the resulting raised edge.
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                guard a.distance(to: b) > 1e-7, max(plane.height(a), plane.height(b)) > 1e-6,
                      eaves.indices.contains(where: { edge in
                          let start = eaves[edge], end = eaves[(edge + 1) % eaves.count]
                          return DioramaPolygon.distanceToSegment(a, start, end) < 1e-6
                              && DioramaPolygon.distanceToSegment(b, start, end) < 1e-6
                      }) else { continue }
                mesh.quad(DV3(a, eaveZ), DV3(b, eaveZ), lifted(b), lifted(a), fascia,
                          normal: DV3((b - a).normalized.right, 0))
            }
        }
        return true
    }

    private static func volume(_ ring: [DV2], slope: Double, maxRise: Double) -> Wing {
        let ccw = DioramaPolygon.counterClockwise(ring)
        let slopes: [Plane] = ccw.indices.map { i in
            let a = ccw[i], inward = (ccw[(i + 1) % ccw.count] - a).normalized.left * slope
            return Plane(gradient: inward, offset: -inward.dot(a))
        }
        return Wing(outline: ccw, planes: slopes + [Plane(gradient: .zero, offset: maxRise)])
    }

    /// Rotated L/T/U plans become overlapping maximal rectangles. Their overlaps create joined valleys.
    private static func wings(for footprint: [DV2], eaves: [DV2], slope: Double, overhang: Double, maxRise: Double) -> [Wing]? {
        let ring = DioramaPolygon.counterClockwise(DioramaPolygon.clean(footprint, flags: []).points)
        guard ring.count >= 3 else { return nil }
        let convex = ring.indices.allSatisfy { i in
            let a = ring[(i + ring.count - 1) % ring.count], b = ring[i], c = ring[(i + 1) % ring.count]
            return (b - a).cross(c - b) >= -0.00001
        }
        if convex { return [volume(eaves, slope: slope, maxRise: maxRise)] }
        guard ring.count <= 32 else { return nil }
        let edge = ring.indices.max { i, j in
            ring[i].distance(to: ring[(i + 1) % ring.count]) < ring[j].distance(to: ring[(j + 1) % ring.count])
        } ?? 0
        let origin = ring[edge], axis = (ring[(edge + 1) % ring.count] - origin).normalized, across = axis.left
        let local = ring.map { DV2(($0 - origin).dot(axis), ($0 - origin).dot(across)) }
        // Do not force skewed footprints into fabricated rectangular roofs.
        guard local.indices.allSatisfy({ i in
            let delta = local[(i + 1) % local.count] - local[i]
            return min(abs(delta.x), abs(delta.y)) < 0.18
        }) else { return nil }
        func coordinates(_ values: [Double]) -> [Double] {
            var groups: [[Double]] = []
            for value in values.sorted() {
                if let last = groups.last, value - (last.first ?? value) < 0.18 { groups[groups.count - 1].append(value) }
                else { groups.append([value]) }
            }
            return groups.map { $0.reduce(0, +) / Double($0.count) }
        }
        let xs = coordinates(local.map(\.x)), ys = coordinates(local.map(\.y))
        guard (2...20).contains(xs.count), (2...20).contains(ys.count) else { return nil }
        let width = xs.count - 1, height = ys.count - 1
        let occupied: [[Bool]] = (0..<height).map { y in
            (0..<width).map { x in DioramaPolygon.contains(local, DV2((xs[x] + xs[x + 1]) * 0.5, (ys[y] + ys[y + 1]) * 0.5)) }
        }
        func filled(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Bool {
            for y in y0..<y1 { for x in x0..<x1 where !occupied[y][x] { return false } }
            return true
        }
        var rectangles: [DioramaRect] = []
        for x0 in 0..<width {
            for x1 in (x0 + 1)...width {
                for y0 in 0..<height {
                    for y1 in (y0 + 1)...height {
                        guard filled(x0, x1, y0, y1) else { break }
                        if x0 > 0 && filled(x0 - 1, x1, y0, y1) { continue }
                        if x1 < width && filled(x0, x1 + 1, y0, y1) { continue }
                        if y0 > 0 && filled(x0, x1, y0 - 1, y1) { continue }
                        if y1 < height && filled(x0, x1, y0, y1 + 1) { continue }
                        rectangles.append(DioramaRect(minX: xs[x0], minY: ys[y0], maxX: xs[x1], maxY: ys[y1]))
                    }
                }
            }
        }
        guard !rectangles.isEmpty, rectangles.count <= 16 else { return nil }
        return rectangles.sorted { $0.width * $0.height > $1.width * $1.height }.map { rect in
            let outline = [DV2(rect.minX - overhang, rect.minY - overhang), DV2(rect.maxX + overhang, rect.minY - overhang),
                           DV2(rect.maxX + overhang, rect.maxY + overhang), DV2(rect.minX - overhang, rect.maxY + overhang)]
                .map { origin + axis * $0.x + across * $0.y }
            return volume(outline, slope: slope, maxRise: maxRise)
        }
    }

    /// Clips a convex polygon to one half-plane, retaining exact intersection points.
    private static func clip(_ ring: [DV2], by plane: Plane) -> [DV2] {
        guard ring.count >= 3 else { return [] }
        var output: [DV2] = []
        var previous = ring[ring.count - 1], previousHeight = plane.height(previous)
        for point in ring {
            let height = plane.height(point)
            if (height >= 0) != (previousHeight >= 0) {
                let t = previousHeight / (previousHeight - height)
                output.append(previous + (point - previous) * t)
            }
            if height >= 0 { output.append(point) }
            previous = point; previousHeight = height
        }
        var clean: [DV2] = []
        for point in output where clean.last.map({ $0.distance(to: point) > 1e-7 }) ?? true { clean.append(point) }
        if clean.count > 1, let first = clean.first, let last = clean.last, first.distance(to: last) < 1e-7 { clean.removeLast() }
        return clean
    }

    /// Subtracts a convex volume; the retained pieces are convex, so fan triangulation is safe.
    private static func subtract(_ ring: [DV2], volume: [Plane]) -> [[DV2]] {
        var remaining = ring
        var outside: [[DV2]] = []
        for plane in volume {
            guard remaining.count >= 3 else { break }
            if plane.gradient.length < 1e-8 {
                if plane.offset < -1e-8 { outside.append(remaining); return outside }
                continue
            }
            let piece = clip(remaining, by: Plane(gradient: plane.gradient * -1, offset: -plane.offset))
            if piece.count >= 3, DioramaPolygon.area(piece) > 1e-8 { outside.append(piece) }
            remaining = clip(remaining, by: plane)
        }
        return outside
    }
}
