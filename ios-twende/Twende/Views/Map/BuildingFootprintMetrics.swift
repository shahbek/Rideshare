import simd

/// Rotation/translation invariant measurements. Bounding rectangles classify form only; they never
/// replace the real roof footprint. Scan is capped by the validated 512-point source ring.
struct BuildingFootprintMetrics {
    let width: Double
    let length: Double
    let area: Double
    let fill: Double
    let compactness: Double
    let hasCourtyard: Bool
    let isRound: Bool
    var aspect: Double { length / max(1, width) }

    init(_ footprint: BuildingFootprint) {
        let ring = footprint.rings.first ?? []
        let origin = ring.first ?? .zero
        let local = ring.map { $0 - origin }
        let outerArea = abs(BuildingFootprint.area(local))
        area = max(0, outerArea - footprint.rings.dropFirst().reduce(0) { $0 + abs(BuildingFootprint.area($1)) })
        hasCourtyard = footprint.rings.count > 1
        var bestArea = Double.greatestFiniteMagnitude
        var dimensions = SIMD2<Double>(1, 1)
        var perimeter = 0.0
        for i in local.indices {
            let delta = local[(i + 1) % local.count] - local[i]
            let distance = simd_length(delta)
            perimeter += distance
            guard distance > 0.02 else { continue }
            let u = delta / distance, v = SIMD2(-u.y, u.x)
            var minU = Double.infinity, maxU = -Double.infinity
            var minV = Double.infinity, maxV = -Double.infinity
            for point in local {
                let x = simd_dot(point, u), y = simd_dot(point, v)
                minU = min(minU, x); maxU = max(maxU, x)
                minV = min(minV, y); maxV = max(maxV, y)
            }
            let a = maxU - minU, b = maxV - minV
            if a * b < bestArea - 0.00001 {
                bestArea = a * b
                dimensions = SIMD2(min(a, b), max(a, b))
            }
        }
        // Centimetre quantisation avoids floating-point flips near thresholds after camera-origin changes.
        width = (dimensions.x * 100).rounded() / 100
        length = (dimensions.y * 100).rounded() / 100
        fill = min(1, outerArea / max(1, width * length))
        compactness = min(1, 4 * .pi * outerArea / max(1, perimeter * perimeter))
        isRound = !hasCourtyard && ring.count >= 8 && compactness > 0.86 && length / max(1, width) < 1.3
    }
}
