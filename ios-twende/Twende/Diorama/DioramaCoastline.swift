import Foundation

/// One bounded, rounded shoreline shared by land, sea, beach and the retaining wall.
/// Corner interpolation is illustrative (at most 1.2 m), not a new surveyed coastline.
nonisolated enum DioramaCoastline {
    static func rounded(_ ring: [DV2], flags: [Bool]) -> (points: [DV2], flags: [Bool]) {
        guard ring.count >= 3 else { return (ring, flags) }
        var points: [DV2] = []
        var resultFlags: [Bool] = []
        for i in ring.indices {
            let previous = (i + ring.count - 1) % ring.count
            let a = ring[previous], b = ring[i], c = ring[(i + 1) % ring.count]
            if flags[previous] || flags[i] {
                points.append(b); resultFlags.append(flags[i])
                continue
            }
            let reach = min(1.2, min(a.distance(to: b), b.distance(to: c)) * 0.18)
            let entry = b + (a - b).normalized * reach
            let exit = b + (c - b).normalized * reach
            for j in 0...8 {
                let t = Double(j) / 8, u = 1 - t
                points.append(entry * (u * u) + b * (2 * u * t) + exit * (t * t))
                resultFlags.append(false)
            }
        }
        return (points, resultFlags)
    }

    /// Shared miter at each sample, clamped to avoid spikes on tight concave turns.
    static func offset(_ ring: [DV2], by distance: Double) -> [DV2] {
        ring.indices.map { i in
            let before = (ring[i] - ring[(i + ring.count - 1) % ring.count]).normalized.right
            let after = (ring[(i + 1) % ring.count] - ring[i]).normalized.right
            let bisector = (before + after).normalized
            return ring[i] + bisector * (distance / max(0.5, bisector.dot(after)))
        }
    }
}
