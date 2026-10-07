import CryptoKit
import Foundation

/// Genuine driving directions, kept in a small durable cache for downloaded-only sessions.
actor MapboxRoadDirectionsService {
    static let shared = MapboxRoadDirectionsService()
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RoadDirections", isDirectory: true)
    }
    nonisolated private struct Response: Decodable {
        nonisolated struct Route: Decodable {
            nonisolated struct Geometry: Decodable { let coordinates: [[Double]] }
            let distance: Double
            let geometry: Geometry
        }
        let code: String
        let routes: [Route]
    }
    func route(from: GeoPoint, to: GeoPoint, token: String) async -> RouteResult? {
        guard from.latitude.isFinite, from.longitude.isFinite, to.latitude.isFinite, to.longitude.isFinite else { return nil }
        let coordinates = "\(from.longitude),\(from.latitude);\(to.longitude),\(to.latitude)"
        let hash = SHA256.hash(data: Data(coordinates.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(hash + ".json")
        if let bytes = try? Data(contentsOf: file), let route = try? JSONDecoder().decode(RouteResult.self, from: bytes),
           route.isRoadMatched == true, route.points.count > 1 { return route }
        guard !UserDefaults.standard.bool(forKey: "maps.downloadedOnly"), !token.isEmpty,
              var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/driving/\(coordinates)") else { return nil }
        components.queryItems = [URLQueryItem(name: "access_token", value: token),
                                 URLQueryItem(name: "geometries", value: "geojson"),
                                 URLQueryItem(name: "overview", value: "full"),
                                 URLQueryItem(name: "exclude", value: "ferry"),
                                 URLQueryItem(name: "radiuses", value: "150;150")]
        guard let url = components.url else { return nil }
        do {
            let request = URLRequest(url: url, timeoutInterval: 12)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_194_304 else { return nil }
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard result.code == "Ok", let best = result.routes.first, best.distance.isFinite else { return nil }
            let points = best.geometry.coordinates.compactMap { pair -> GeoPoint? in
                guard pair.count == 2, pair[0].isFinite, pair[1].isFinite else { return nil }
                return GeoPoint(latitude: pair[1], longitude: pair[0])
            }
            guard points.count > 1 else { return nil }
            let km = max(0.3, (best.distance / 100).rounded() / 10)
            let route = RouteResult(points: points, distanceKm: km, durationMinutes: RoutingService.duration(forKm: km), isRoadMatched: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let bytes = try? JSONEncoder().encode(route) { try? bytes.write(to: file, options: .atomic) }
            // Separate route cache, never touch user-owned scenery or map packages.
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            if files.count > 40 {
                let sorted = files.sorted { a, b in
                    ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                for old in sorted.prefix(files.count - 40) { try? FileManager.default.removeItem(at: old) }
            }
            return route
        } catch {
            if !Task.isCancelled { print("[RoadRouting] Driving directions unavailable; checking saved road geometry") }
            return nil
        }
    }
}
