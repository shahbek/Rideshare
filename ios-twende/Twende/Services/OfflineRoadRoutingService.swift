import Foundation

/// Road geometry routing for the demo, using verified saved Streets sources only.
/// This is not a certified navigation graph: missing topology/restrictions return no route.
actor OfflineRoadRoutingService {
    static let shared = OfflineRoadRoutingService()
    private var graph: RoadGeometryGraph?
    private var loadedAt: Date = .distantPast
    private var loading: Task<RoadGeometryGraph, Never>?

    func route(from: GeoPoint, to: GeoPoint) async -> RouteResult? {
        guard DioramaMasakiSource.contains(latitude: from.latitude, longitude: from.longitude),
              DioramaMasakiSource.contains(latitude: to.latitude, longitude: to.longitude) else { return nil }
        let graph = await roads()
        guard !Task.isCancelled, let points = graph.path(from: from, to: to) else { return nil }
        let km = zip(points, points.dropFirst()).reduce(0.0) { $0 + $1.0.distanceKm(to: $1.1) }
        return RouteResult(points: points, distanceKm: max(0.3, (km * 10).rounded() / 10),
                           durationMinutes: RoutingService.duration(forKm: km), isRoadMatched: true)
    }

    func snap(_ point: GeoPoint, within metres: Double = 60) async -> GeoPoint? {
        guard DioramaMasakiSource.contains(latitude: point.latitude, longitude: point.longitude) else { return nil }
        return await roads().nearest(point, within: metres)?.point
    }

    private func roads() async -> RoadGeometryGraph {
        if let graph, Date().timeIntervalSince(loadedAt) < 300 { return graph }
        let job: Task<RoadGeometryGraph, Never>
        if let loading { job = loading }
        else {
            job = Task.detached(priority: .utility) {
                var lines: [RoadGeometryGraph.Line] = []
                for tile in DioramaOfflineStore.tiles {
                    guard !Task.isCancelled else { break }
                    guard let bytes = await DioramaSourceStore.shared.savedData(key: "streets-\(tile.z)-\(tile.x)-\(tile.y).pbf"),
                          let features = try? DioramaVectorTile.decode(bytes) else { continue }
                    let count = pow(2.0, Double(tile.z))
                    for feature in features where feature.layer == "road" && feature.type == 2 {
                        let kind = feature.properties["class"] ?? ""
                        guard RoadGeometryGraph.drivingClasses.contains(kind),
                              !["no", "private"].contains(feature.properties["access"] ?? "") else { continue }
                        let layer = feature.properties["layer"] ?? "0"
                        let structure = feature.properties["structure"] ?? "none"
                        let oneWay = ["true", "1", "yes"].contains(feature.properties["oneway"] ?? "")
                        for path in feature.paths where path.count > 1 {
                            let points = path.map { p in
                                GeoPoint(latitude: atan(sinh(.pi * (1 - 2 * (Double(tile.y) + p.y / feature.extent) / count))) * 180 / .pi,
                                         longitude: (Double(tile.x) + p.x / feature.extent) / count * 360 - 180)
                            }
                            lines.append(.init(points: points, level: layer + ":" + structure, oneWay: oneWay))
                        }
                    }
                }
                if lines.isEmpty, let url = Bundle.main.url(forResource: DioramaBundledTile.resourceName, withExtension: "json"),
                   let bytes = try? Data(contentsOf: url),
                   let file = try? JSONDecoder().decode(DioramaBundledTile.File.self, from: bytes) {
                    for road in file.roads where RoadGeometryGraph.drivingClasses.contains(road.class) {
                        let points = road.line.compactMap { pair -> GeoPoint? in
                            guard pair.count == 2 else { return nil }
                            return GeoPoint(latitude: pair[1], longitude: pair[0])
                        }
                        lines.append(.init(points: points, level: "0:none", oneWay: false))
                    }
                }
                return RoadGeometryGraph(lines: lines)
            }
            loading = job
        }
        let value = await job.value
        graph = value; loadedAt = Date(); loading = nil
        return value
    }
}
