import Foundation
import MapKit

/// Road routing. Apple Maps directions are used when available; a deterministic street-like polyline is the
/// instant fallback so quotes never wait on the network. Durations always come from the Dar traffic model so
/// fares stay consistent with the tariff.
nonisolated enum RoutingService {
    static let roadFactor = 1.355
    static let citySpeedKmh = 19.68

    static func route(from origin: GeoPoint, to destination: GeoPoint) -> RouteResult {
        let straight = origin.distanceKm(to: destination)
        let distanceKm = max((straight * roadFactor * 10).rounded() / 10, 0.3)
        return RouteResult(
            points: polyline(from: origin, to: destination),
            distanceKm: distanceKm,
            durationMinutes: duration(forKm: distanceKm)
        )
    }

    /// Instant estimate through every waypoint in order (pickup, stops…, destination).
    static func route(through waypoints: [GeoPoint]) -> RouteResult {
        guard waypoints.count > 1 else {
            let point = waypoints.first ?? DarEsSalaam.centre
            return RouteResult(points: [point, point], distanceKm: 0.3, durationMinutes: 2)
        }
        var legs: [RouteResult] = []
        for index in 1..<waypoints.count {
            legs.append(route(from: waypoints[index - 1], to: waypoints[index]))
        }
        return join(legs)
    }

    /// Real street directions through every waypoint in order. Nil if any leg is unavailable.
    @MainActor
    static func directions(through waypoints: [GeoPoint]) async -> RouteResult? {
        guard waypoints.count > 1 else { return nil }
        var legs: [RouteResult] = []
        for index in 1..<waypoints.count {
            guard let leg = await directions(from: waypoints[index - 1], to: waypoints[index]) else { return nil }
            legs.append(leg)
        }
        return join(legs)
    }

    /// Concatenates consecutive legs into one route, dropping the duplicated joint points.
    private static func join(_ legs: [RouteResult]) -> RouteResult {
        guard let first = legs.first else { return RouteResult(points: [], distanceKm: 0, durationMinutes: 0) }
        var points = first.points
        var distanceKm = first.distanceKm
        var durationMinutes = first.durationMinutes
        for leg in legs.dropFirst() {
            points.append(contentsOf: leg.points.dropFirst())
            distanceKm += leg.distanceKm
            durationMinutes += leg.durationMinutes
        }
        return RouteResult(points: points, distanceKm: (distanceKm * 10).rounded() / 10, durationMinutes: durationMinutes)
    }

    /// Real driving directions along Dar es Salaam streets. Returns nil when directions are unavailable.
    @MainActor
    static func directions(from origin: GeoPoint, to destination: GeoPoint) async -> RouteResult? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let best = response.routes.first, best.polyline.pointCount > 1 else { return nil }
            let buffer = UnsafeBufferPointer(start: best.polyline.points(), count: best.polyline.pointCount)
            let points = buffer.map { GeoPoint($0.coordinate) }
            let distanceKm = max((best.distance / 100).rounded() / 10, 0.3)
            return RouteResult(points: points, distanceKm: distanceKm, durationMinutes: duration(forKm: distanceKm))
        } catch {
            return nil
        }
    }

    /// Minutes for a driver to reach the pickup.
    static func pickupEtaMinutes(from driver: GeoPoint, to pickup: GeoPoint) -> Int {
        let km = driver.distanceKm(to: pickup) * roadFactor
        return max(Int((km / citySpeedKmh * 60).rounded()), 1)
    }

    static func duration(forKm distanceKm: Double) -> Int {
        max(Int((distanceKm / citySpeedKmh * 60).rounded()), 2)
    }

    /// Grid-like polyline with gentle deterministic wobble so it reads as streets rather than a straight line.
    static func polyline(from origin: GeoPoint, to destination: GeoPoint) -> [GeoPoint] {
        let straight = origin.distanceKm(to: destination)
        guard straight > 0.05 else { return [origin, destination] }

        let seed = UInt64(abs((origin.latitude * 7919 + destination.longitude * 104_729) * 1_000).rounded())
        var generator = SeededGenerator(seed: seed)
        let segments = min(max(Int(straight * 1.6), 4), 12)
        let amplitudeKm = min(straight * 0.09, 0.45)

        var points: [GeoPoint] = [origin]
        var previous = origin
        for index in 1..<segments {
            let fraction = Double(index) / Double(segments)
            let along = origin.interpolated(to: destination, fraction: fraction)
            let wave = sin(fraction * .pi * 1.7) * amplitudeKm
            let jitter = generator.signedUnit() * amplitudeKm * 0.35
            let perpendicularBearing = origin.bearing(to: destination) + 90
            let offsetKm = wave + jitter
            let radians = perpendicularBearing * .pi / 180
            let waypoint = along.offset(
                eastMetres: sin(radians) * offsetKm * 1000,
                northMetres: cos(radians) * offsetKm * 1000
            )
            if generator.next() % 3 != 0 {
                // Add an elbow so the segment turns like a street corner.
                let elbow = GeoPoint(latitude: previous.latitude, longitude: waypoint.longitude)
                points.append(elbow)
            }
            points.append(waypoint)
            previous = waypoint
        }
        points.append(destination)
        return points
    }
}
