import Foundation

/// Distance-indexed route sampling keeps position and heading on the same segment.
nonisolated struct RoutePolylineMotion {
    let points: [GeoPoint]
    private let distances: [Double]
    private let headings: [Double]
    private let total: Double

    init(points: [GeoPoint]) {
        var kept: [GeoPoint] = []
        var lengths: [Double] = [0]
        var bearings: [Double] = []
        var distance: Double = 0
        for point in points {
            if let previous = kept.last {
                let length = previous.distanceKm(to: point) * 1_000
                guard length.isFinite, length > 0.001 else { continue }
                distance += length
                lengths.append(distance)
                bearings.append(previous.bearing(to: point))
            }
            kept.append(point)
        }
        self.points = kept
        distances = lengths
        headings = bearings
        total = distance
    }

    func sample(at fraction: Double) -> (point: GeoPoint, heading: Double)? {
        guard points.count > 1, fraction.isFinite, total > 0 else { return nil }
        let target = min(1, max(0, fraction)) * total
        var low: Int = 0
        var high: Int = headings.count - 1
        while low < high {
            let middle = (low + high) / 2
            if target >= distances[middle + 1] { low = middle + 1 } else { high = middle }
        }
        let length = distances[low + 1] - distances[low]
        let local = min(1, max(0, (target - distances[low]) / length))
        return (points[low].interpolated(to: points[low + 1], fraction: local), headings[low])
    }

    /// Resolve fixes near this route only; off-route feeds retain their own position/heading.
    func fraction(nearest point: GeoPoint, near previous: Double? = nil) -> Double? {
        guard points.count > 1, total > 0 else { return nil }
        let northScale: Double = 111_320
        let eastScale = northScale * cos(point.latitude * .pi / 180)
        var bestDistance: Double = .infinity
        var bestProgress: Double = 0
        for index in headings.indices {
            let a = points[index]
            let b = points[index + 1]
            let ax = (a.longitude - point.longitude) * eastScale
            let ay = (a.latitude - point.latitude) * northScale
            let dx = (b.longitude - a.longitude) * eastScale
            let dy = (b.latitude - a.latitude) * northScale
            let denominator = dx * dx + dy * dy
            guard denominator > 0 else { continue }
            let t = min(1, max(0, -(ax * dx + ay * dy) / denominator))
            let error = hypot(ax + dx * t, ay + dy * t)
            let progress = (distances[index] + (distances[index + 1] - distances[index]) * t) / total
            // At crossing/overlapping segments prefer continuity, not a later route leg.
            let penalty = previous.map { max(0, abs(progress - $0) * total - 30) } ?? 0
            let score = error + penalty
            if score < bestDistance { bestDistance = score; bestProgress = progress }
        }
        return bestDistance <= 10 ? bestProgress : nil
    }
}
