import Foundation

/// Footprint-driven roof kit for Dar's irregular houses.
///
/// Every roof here is a *plane envelope* evaluated over the real eave polygon's own triangulation:
/// the surface height is the minimum (or, for butterfly roofs, the maximum) of a few planes derived
/// from the footprint's minimum-area rectangle. Each eave triangle is convex, so clipping it by the
/// plane-ownership half-planes always gives exact convex facets. That makes the kit valid on concave,
/// notched and skewed footprints: there is no shrinking contour, no fan from a centroid outside the
/// shape, and no face that can invert or be back-face culled. Where a facet meets the eave above the
/// wall top, a vertical infill (gable end / lean-to cheek) closes it, so every roof is watertight.
nonisolated enum DioramaRoofKit {
    nonisolated enum Form: String, Sendable, CaseIterable {
        /// Mono-pitch lean-to, rising across the short axis (kiosks, annexes, servants' quarters, shops).
        case shed
        /// Two planes meeting at a ridge on the long axis.
        case gable
        /// Gable with steep clipped ends (jerkinhead / half-hip).
        case jerkinhead
        /// Hip on the bounding rectangle: four planes, valid on any outline.
        case hipEnvelope
        /// Inverted V with a central valley gutter (modern Masaki villas).
        case butterfly
        /// Four equal planes rising to one apex (compact square plans).
        case pyramid
    }

    /// Shape metrics used to choose a fitting form.
    nonisolated struct Shape: Sendable {
        let area: Double
        let rectangularity: Double
        let aspect: Double
        let shortSide: Double
        let isConvex: Bool
    }

    static func shape(of ring: [DV2]) -> Shape {
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let area = DioramaPolygon.area(ring)
        let boxArea = max(4 * box.halfLength * box.halfWidth, 0.01)
        let ccw = DioramaPolygon.counterClockwise(ring)
        let convex = ccw.indices.allSatisfy { i in
            let a = ccw[(i + ccw.count - 1) % ccw.count], b = ccw[i], c = ccw[(i + 1) % ccw.count]
            return (b - a).cross(c - b) >= -0.00001
        }
        return Shape(area: area, rectangularity: area / boxArea, aspect: box.halfLength / max(box.halfWidth, 0.01),
                     shortSide: 2 * box.halfWidth, isConvex: convex)
    }

    /// Ordered list of forms to try for a house footprint: the first that validates is built.
    /// `roll` is a stable 0…1 per-building value, `modern` favours contemporary villa forms.
    static func candidates(for shape: Shape, roll: Double, modern: Bool) -> [Form] {
        if shape.area < 45 || shape.shortSide < 4.2 {
            return roll < 0.68 ? [.shed, .gable] : [.gable, .shed]
        }
        if shape.aspect > 2.2 {
            return roll < 0.55 ? [.gable, .shed] : (roll < 0.8 ? [.shed, .gable] : [.jerkinhead, .gable, .shed])
        }
        if shape.rectangularity > 0.9 && shape.aspect < 1.35 {
            if modern && roll < 0.22 { return [.butterfly, .pyramid, .gable] }
            return roll < 0.6 ? [.pyramid, .hipEnvelope, .gable] : [.gable, .pyramid, .shed]
        }
        if shape.rectangularity > 0.82 {
            if modern && roll < 0.15 { return [.butterfly, .gable, .shed] }
            return roll < 0.45 ? [.hipEnvelope, .gable] : (roll < 0.75 ? [.gable, .hipEnvelope] : [.jerkinhead, .gable, .shed])
        }
        // Odd, notched or skewed outlines: bounding-rectangle envelopes still fit exactly.
        return roll < 0.5 ? [.hipEnvelope, .gable, .shed] : [.gable, .hipEnvelope, .shed]
    }

    /// Planes (height above the eave as a function of plan position) for one form.
    static func planes(_ form: Form, ring: [DV2], pitch: Double, maxRise: Double) -> (planes: [DioramaRoofBuilder.Plane], useMax: Bool) {
        typealias Plane = DioramaRoofBuilder.Plane
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        let u = box.axis.normalized, v = u.left, c = box.centre
        let slope = tan(pitch)
        let cap = Plane(gradient: .zero, offset: maxRise)
        // Plane rising from a line through `origin` along direction `dir` with `rate` metres per metre.
        func rising(from origin: DV2, toward dir: DV2, rate: Double, base: Double = 0) -> Plane {
            Plane(gradient: dir * rate, offset: base - (dir * rate).dot(origin))
        }
        let hl = box.halfLength, hw = box.halfWidth
        switch form {
        case .shed:
            let rate = min(tan(10 * Double.pi / 180), maxRise / max(2 * hw, 0.5))
            return ([rising(from: c - v * hw, toward: v, rate: rate, base: 0.05)], false)
        case .gable:
            return ([rising(from: c - v * hw, toward: v, rate: slope), rising(from: c + v * hw, toward: -v, rate: slope), cap], false)
        case .jerkinhead:
            // Ends start at 60 % of the ridge height and rise steeply, clipping the gable tips.
            let ridge = min(maxRise, slope * hw)
            let endRate = slope * 1.9
            return ([rising(from: c - v * hw, toward: v, rate: slope), rising(from: c + v * hw, toward: -v, rate: slope),
                     rising(from: c - u * hl, toward: u, rate: endRate, base: ridge * 0.6),
                     rising(from: c + u * hl, toward: -u, rate: endRate, base: ridge * 0.6), cap], false)
        case .hipEnvelope, .pyramid:
            return ([rising(from: c - v * hw, toward: v, rate: slope), rising(from: c + v * hw, toward: -v, rate: slope),
                     rising(from: c - u * hl, toward: u, rate: slope), rising(from: c + u * hl, toward: -u, rate: slope), cap], false)
        case .butterfly:
            let valley = 0.35
            let rate = min(tan(9 * Double.pi / 180), (maxRise - valley) / max(hw, 0.5))
            return ([rising(from: c, toward: v, rate: rate, base: valley), rising(from: c, toward: -v, rate: rate, base: valley)], true)
        }
    }

    /// Builds `form` on the eave polygon. Commits only a complete, finite partition; returns false
    /// (mesh untouched) so the caller can try the next form or its flat fallback.
    @discardableResult
    static func build(_ form: Form, ring: [DV2], flags: [Bool], z: Double, pitch: Double, overhang: Double, maxRise: Double,
                      color: DioramaSwatch, fascia: DioramaSwatch, gable: DioramaSwatch, into mesh: inout DioramaMesh) -> Bool {
        let ccw = DioramaPolygon.counterClockwise(ring)
        guard !Task.isCancelled, !flags.contains(true), (3...160).contains(ccw.count), z.isFinite, maxRise > 0.2,
              let eaves = abs(overhang) < 1e-6 ? ccw : DioramaPolygon.offset(ccw, by: overhang) else { return false }
        // Planes come from the eave outline's rectangle so every eave point sits at or above height 0.
        let (planes, useMax) = planes(form, ring: eaves, pitch: pitch, maxRise: maxRise)
        guard !planes.isEmpty, planes.allSatisfy({ $0.offset.isFinite && $0.gradient.x.isFinite && $0.gradient.y.isFinite }) else { return false }
        let triangles = DioramaPolygon.triangulate(eaves)
        let expectedArea = DioramaPolygon.area(eaves)
        let triangleArea = triangles.reduce(0.0) { sum, t in sum + abs((eaves[t.1] - eaves[t.0]).cross(eaves[t.2] - eaves[t.0])) * 0.5 }
        guard expectedArea > 0.5, abs(triangleArea - expectedArea) < expectedArea * 0.00001 else { return false }

        var facets: [(polygon: [DV2], plane: DioramaRoofBuilder.Plane)] = []
        var covered = 0.0
        for triangle in triangles {
            let base = [eaves[triangle.0], eaves[triangle.1], eaves[triangle.2]]
            for (i, plane) in planes.enumerated() {
                var piece = base
                for (j, other) in planes.enumerated() where j != i {
                    // Ownership: min-envelope keeps where this plane is lowest, max where highest.
                    // Ties go to the lower index so coincident regions are never doubled.
                    var keep = useMax ? plane.minus(other) : other.minus(plane)
                    if j < i { keep = DioramaRoofBuilder.Plane(gradient: keep.gradient, offset: keep.offset - 1e-9) }
                    piece = DioramaRoofBuilder.clip(piece, by: keep)
                    if piece.count < 3 { break }
                }
                guard piece.count >= 3 else { continue }
                let area = DioramaPolygon.area(piece)
                guard area > 1e-8 else { continue }
                guard piece.allSatisfy({ let h = plane.height($0); return h.isFinite && h >= -0.001 && h <= maxRise + 0.001 }) else { return false }
                covered += area
                facets.append((piece, plane))
                if facets.count > 6000 { return false }
            }
        }
        guard abs(covered - expectedArea) <= max(0.0005, expectedArea * 0.00005) else { return false }

        let eaveZ = z + 0.22
        mesh.extrude(eaves, z0: z - 0.05, z1: eaveZ, fascia)
        mesh.polygon(eaves, z: z - 0.05, fascia, dark: true, facingUp: false)
        mesh.polygon(ccw, z: z + 0.01, color)
        for facet in facets {
            let p = facet.polygon, plane = facet.plane
            let normal = DV3(-plane.gradient.x, -plane.gradient.y, 1).normalized
            func lifted(_ point: DV2) -> DV3 { DV3(point, eaveZ + max(0, plane.height(point))) }
            for i in 1..<(p.count - 1) {
                mesh.triangle(lifted(p[0]), lifted(p[i]), lifted(p[i + 1]), color, normal: normal)
            }
            // Gable ends and lean-to cheeks: close every facet edge that lies on the eave above eave level.
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                guard a.distance(to: b) > 1e-6, max(plane.height(a), plane.height(b)) > 0.02,
                      eaves.indices.contains(where: { edge in
                          let start = eaves[edge], end = eaves[(edge + 1) % eaves.count]
                          return DioramaPolygon.distanceToSegment(a, start, end) < 1e-6
                              && DioramaPolygon.distanceToSegment(b, start, end) < 1e-6
                      }) else { continue }
                mesh.quad(DV3(a, eaveZ), DV3(b, eaveZ), lifted(b), lifted(a), gable, normal: DV3((b - a).normalized.right, 0))
            }
        }
        return true
    }
}
