@_spi(Experimental) import MapboxMaps
import SceneKit
import simd

/// Closed, wound rings in local metres; courtyard holes are preserved in every deck.
struct BuildingFootprint {
    let rings: [[SIMD2<Double>]]

    init?(coordinates: [[LocationCoordinate2D]], origin: LocationCoordinate2D) {
        guard !coordinates.isEmpty, coordinates.count <= 32 else { return nil }
        let scale = Double(Projection.metersPerPoint(for: origin.latitude, zoom: 0))
        let anchor = Projection.project(origin, zoomScale: 1)
        var result: [[SIMD2<Double>]] = []
        for (index, coordinates) in coordinates.enumerated() {
            guard coordinates.count >= 4, coordinates.count <= 512,
                  coordinates.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) < 85 && abs($0.longitude) <= 180 }) else { return nil }
            var ring = coordinates.map { point -> SIMD2<Double> in
                let p = Projection.project(point, zoomScale: 1)
                return SIMD2((p.x - anchor.x) * scale, (anchor.y - p.y) * scale)
            }
            if let first = ring.first, let last = ring.last, simd_distance(first, last) < 0.001 { ring.removeLast() }
            ring = ring.enumerated().filter { i, p in simd_distance(p, ring[(i + 1) % ring.count]) > 0.02 }.map(\.element)
            guard ring.count >= 3, ring.allSatisfy({ simd_length($0) < 5_000 }), abs(Self.area(ring)) > 0.2 else { return nil }
            if (Self.area(ring) > 0) != (index == 0) { ring.reverse() }
            result.append(ring)
        }
        rings = result
    }

    /// Internal metric footprint for validated inset roof volumes.
    init(rings: [[SIMD2<Double>]]) { self.rings = rings }

    var path: UIBezierPath {
        let path = UIBezierPath()
        path.usesEvenOddFillRule = true
        for ring in rings {
            guard let first = ring.first else { continue }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in ring.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            path.close()
        }
        return path
    }

    static func area(_ ring: [SIMD2<Double>]) -> Double {
        guard ring.count >= 3 else { return 0 }
        return ring.indices.reduce(0) { sum, i in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return sum + a.x * b.y - b.x * a.y
        } / 2
    }

    func deck(at height: Double, thickness: Double, material: SCNMaterial, name: String = "roofDeck") -> SCNNode {
        // Explicit triangles are required: SCNShape's lazily tessellated path can expose no CPU
        // vertex sources, silently dropping the roof when the scene is baked into Metal buffers.
        var mesh = BuildingMesh()
        let levels = Array(Set(rings.flatMap { $0.map(\.y) })).sorted()
        guard thickness > 0, levels.count >= 2 else { return SCNNode() }
        let edges = rings.flatMap { ring in
            ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) }
        }
        func point(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> { SIMD3(x, y, z) }
        // Even-odd scanline trapezoids handle concave footprints and all courtyard holes without
        // bridging them. Every band boundary lies exactly on an original polygon vertex.
        for band in 0..<(levels.count - 1) {
            let low = levels[band], high = levels[band + 1]
            guard high - low > 0.000001 else { continue }
            let mid = (low + high) / 2
            let crossing = edges.filter { min($0.0.y, $0.1.y) < mid && max($0.0.y, $0.1.y) > mid }
            func x(_ edge: (SIMD2<Double>, SIMD2<Double>), _ y: Double) -> Double {
                edge.0.x + (edge.1.x - edge.0.x) * ((y - edge.0.y) / (edge.1.y - edge.0.y))
            }
            let sorted = crossing.sorted { x($0, mid) < x($1, mid) }
            for pair in stride(from: 0, to: max(0, sorted.count - 1), by: 2) {
                let left = sorted[pair], right = sorted[pair + 1]
                let a = point(x(left, low), low, height + thickness)
                let b = point(x(right, low), low, height + thickness)
                let c = point(x(right, high), high, height + thickness)
                let d = point(x(left, high), high, height + thickness)
                mesh.quad(a, b, c, d, normal: SIMD3(0, 0, 1))
                let drop = SIMD3(0.0, 0.0, thickness)
                mesh.quad(d - drop, c - drop, b - drop, a - drop, normal: SIMD3(0, 0, -1))
            }
        }
        for (a, b) in edges {
            mesh.quad(point(a.x, a.y, height), point(b.x, b.y, height), point(b.x, b.y, height + thickness), point(a.x, a.y, height + thickness))
        }
        return mesh.node(name: name, material: material)
    }

    /// A conservative interior circle; concave footprints and courtyard holes cannot acquire floating domes.
    var domeSite: (centre: SIMD2<Double>, radius: Double)? {
        guard let outer = rings.first, let first = outer.first else { return nil }
        let minX = outer.map(\.x).min() ?? first.x, maxX = outer.map(\.x).max() ?? first.x
        let minY = outer.map(\.y).min() ?? first.y, maxY = outer.map(\.y).max() ?? first.y
        var best = (centre: first, radius: 0.0)
        for x in 1..<16 {
            for y in 1..<16 {
                let point = SIMD2(minX + (maxX - minX) * Double(x) / 16, minY + (maxY - minY) * Double(y) / 16)
                guard path.contains(CGPoint(x: point.x, y: point.y)) else { continue }
                var distance = Double.greatestFiniteMagnitude
                for ring in rings {
                    for i in ring.indices {
                        let a = ring[i], delta = ring[(i + 1) % ring.count] - a
                        let t = max(0, min(1, simd_dot(point - a, delta) / max(0.001, simd_dot(delta, delta))))
                        distance = min(distance, simd_distance(point, a + delta * t))
                    }
                }
                if distance > best.radius { best = (point, distance) }
            }
        }
        return best.radius >= 3 ? (best.centre, min(9, best.radius * 0.72)) : nil
    }

    /// Only truly rectangular, hole-free footprints get ridge roofs. Never bridge a concavity or courtyard.
    var rectangle: [SIMD2<Double>]? {
        guard rings.count == 1, var ring = rings.first else { return nil }
        var changed = true
        while changed && ring.count > 4 {
            changed = false
            for i in ring.indices {
                let a = ring[(i + ring.count - 1) % ring.count], b = ring[i], c = ring[(i + 1) % ring.count]
                let u = simd_normalize(b - a), v = simd_normalize(c - b)
                if simd_dot(u, v) > 0.9999 { ring.remove(at: i); changed = true; break }
            }
        }
        guard ring.count == 4 else { return nil }
        for i in ring.indices {
            let a = simd_normalize(ring[(i + 1) % 4] - ring[i])
            let b = simd_normalize(ring[(i + 2) % 4] - ring[(i + 1) % 4])
            guard abs(simd_dot(a, b)) < 0.025 else { return nil }
        }
        if simd_distance(ring[0], ring[1]) < simd_distance(ring[1], ring[2]) { ring = Array(ring.dropFirst()) + [ring[0]] }
        return ring
    }
}
