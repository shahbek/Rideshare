import Foundation

/// Frozen v36 replay, used only to identify complete owned roofs in user-saved geometry.
nonisolated enum DioramaLegacyRoofBuilder {
    @discardableResult
    static func hip(_ ring: [DV2], flags: [Bool], z: Double, pitch: Double, overhang: Double, maxRise: Double,
                    color: DioramaSwatch, fascia: DioramaSwatch, into mesh: inout DioramaMesh) -> Bool {
        let ccw = DioramaPolygon.counterClockwise(ring)
        guard ccw.count >= 3, let eaveRing = DioramaPolygon.offset(ccw, by: overhang) else { return false }
        let slope = tan(pitch)
        let eave = z + 0.22
        mesh.extrude(eaveRing, z0: z - 0.05, z1: eave, fascia)
        mesh.polygon(eaveRing, z: z - 0.05, fascia, dark: true, facingUp: false)
        mesh.polygon(ccw, z: z + 0.01, color)
        var current = eaveRing
        var height = eave
        let step = 0.45
        var steps = 0
        while steps < 60 {
            steps += 1
            let rise = min(step * slope, max(0.05, eave + maxRise - height))
            let inset = rise / slope
            guard inset > 0.01 else { break }
            guard let next = Self.inset(current, by: inset) else { break }
            if next.count < 3 || DioramaPolygon.area(next) < 0.4 {
                let centre = DioramaPolygon.centroid(current)
                let top = height + rise * 0.6
                for i in current.indices {
                    let a = current[i], b = current[(i + 1) % current.count]
                    mesh.triangle(DV3(a, height), DV3(b, height), DV3(centre, top), color)
                }
                mesh.sphere(centre: DV3(centre, top), radii: DV3(0.16, 0.16, 0.14), color, detail: 0)
                return true
            }
            Self.band(from: current, zFrom: height, to: next, zTo: height + rise, color, into: &mesh)
            current = next
            height += rise
            if height >= eave + maxRise - 0.001 {
                mesh.polygon(current, z: height, color)
                if let lip = DioramaPolygon.offset(current, by: 0.08) {
                    mesh.extrude(lip, z0: height - 0.08, z1: height + 0.04, color, top: color)
                }
                return true
            }
        }
        mesh.polygon(current, z: height, color)
        return true
    }
    private static func inset(_ ring: [DV2], by d: Double) -> [DV2]? {
        guard let moved = DioramaPolygon.offset(ring, by: -d) else {
            guard ring.count > 3, let merged = mergeShortest(ring) else { return nil }
            return DioramaPolygon.offset(merged, by: -d).map(clean)
        }
        return clean(moved)
    }
    private static func clean(_ ring: [DV2]) -> [DV2] {
        var out: [DV2] = []
        for p in ring {
            if let last = out.last, last.distance(to: p) < 0.25 { out[out.count - 1] = (last + p) * 0.5; continue }
            out.append(p)
        }
        if out.count > 1, let first = out.first, let last = out.last, first.distance(to: last) < 0.25 { out.removeLast() }
        var result: [DV2] = []
        let n = out.count
        for i in 0..<n {
            let a = out[(i + n - 1) % n], b = out[i], c = out[(i + 1) % n]
            if abs((b - a).normalized.cross((c - b).normalized)) < 0.02, (b - a).dot(c - b) > 0 { continue }
            result.append(b)
        }
        return result.count >= 3 ? result : out
    }
    private static func mergeShortest(_ ring: [DV2]) -> [DV2]? {
        let n = ring.count
        guard n > 3 else { return nil }
        var best = 0, bestLength = Double.infinity
        for i in 0..<n {
            let length = ring[i].distance(to: ring[(i + 1) % n])
            if length < bestLength { bestLength = length; best = i }
        }
        var out = ring
        out[best] = (ring[best] + ring[(best + 1) % n]) * 0.5
        out.remove(at: (best + 1) % n)
        return out.count >= 3 ? out : nil
    }
    private static func band(from lower: [DV2], zFrom: Double, to upper: [DV2], zTo: Double, _ color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let centre = DioramaPolygon.centroid(upper)
        func nearest(_ p: DV2) -> DV2 { upper.min { $0.distance(to: p) < $1.distance(to: p) } ?? centre }
        for i in lower.indices {
            let a = lower[i], b = lower[(i + 1) % lower.count]
            let ua = nearest(a), ub = nearest(b)
            if ua.distance(to: ub) < 0.001 {
                mesh.triangle(DV3(a, zFrom), DV3(b, zFrom), DV3(ua, zTo), color)
            } else {
                mesh.quad(DV3(a, zFrom), DV3(b, zFrom), DV3(ub, zTo), DV3(ua, zTo), color)
            }
        }
    }
}
