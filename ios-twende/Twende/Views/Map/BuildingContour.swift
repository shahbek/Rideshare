import simd

/// Conservative convex-corner fillets. Concavities and courtyard edges are never bridged.
enum BuildingContour {
    static func rounded(_ ring: [SIMD2<Double>], tangentDistance: Double, segments: Int = 8) -> [SIMD2<Double>] {
        guard ring.count >= 3, ring.count <= 128, tangentDistance.isFinite, tangentDistance > 0, segments > 0 else { return ring }
        var result: [SIMD2<Double>] = []
        for i in ring.indices {
            let previous = ring[(i + ring.count - 1) % ring.count], corner = ring[i], next = ring[(i + 1) % ring.count]
            let incoming = corner - previous, outgoing = next - corner
            let aLength = simd_length(incoming), bLength = simd_length(outgoing)
            guard aLength > 0.1, bLength > 0.1 else { result.append(corner); continue }
            let a = incoming / aLength, b = outgoing / bLength
            let turn = a.x * b.y - a.y * b.x
            let cosine = simd_dot(a, b)
            // Only convex turns between 10° and 120°; acute / re-entrant geometry remains untouched.
            guard turn > 0.17, cosine > -0.5 else { result.append(corner); continue }
            let distance = min(tangentDistance, min(aLength, bLength) * 0.20)
            let start = corner - a * distance, end = corner + b * distance
            for step in 0...segments {
                let t = Double(step) / Double(segments), s = 1 - t
                result.append(start * (s * s) + corner * (2 * s * t) + end * (t * t))
            }
        }
        return result
    }

    static func softened(_ footprint: BuildingFootprint, distance: Double = 0.9) -> BuildingFootprint {
        // Holes retain exact geometry and area. Small outer fillets stay within the 0.7m map shell.
        BuildingFootprint(rings: footprint.rings.enumerated().map { index, ring in
            index == 0 ? rounded(ring, tangentDistance: distance) : ring
        })
    }

    static func outwardNormals(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        ring.indices.map { i in
            let a = simd_normalize(ring[i] - ring[(i + ring.count - 1) % ring.count])
            let b = simd_normalize(ring[(i + 1) % ring.count] - ring[i])
            let sum = SIMD2(a.y + b.y, -a.x - b.x)
            return simd_length(sum) > 0.001 ? simd_normalize(sum) : SIMD2(b.y, -b.x)
        }
    }
}
