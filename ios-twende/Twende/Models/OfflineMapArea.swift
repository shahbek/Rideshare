import Foundation
import MapboxMaps

/// Explicitly bounded, versioned downloads; never an unbounded whole-country request.
nonisolated struct OfflineMapArea: Identifiable, Sendable {
    let id: String
    let title: LKey
    let detail: LKey
    let west: Double
    let south: Double
    let east: Double
    let north: Double

    var geometry: Geometry {
        let coordinates = [(west, south), (east, south), (east, north), (west, north), (west, south)]
            .map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) }
        return .polygon(Polygon([coordinates]))
    }

    static var harbour: OfflineMapArea {
        let points = DioramaOfflineStore.harbourTiles.flatMap(\.outline)
        return .init(id: "twende-harbour-v1", title: .offlineCentral, detail: .offlineCentralDetail,
            west: points.map(\.longitude).min() ?? 39.282,
            south: points.map(\.latitude).min() ?? -6.825,
            east: points.map(\.longitude).max() ?? 39.294,
            north: points.map(\.latitude).max() ?? -6.812)
    }

    static var golf: OfflineMapArea {
        let points = DioramaOfflineStore.golfTiles.flatMap(\.outline)
        return .init(id: "twende-golf-v1", title: .offlineCentral, detail: .offlineCentralDetail,
            west: points.map(\.longitude).min() ?? 39.225,
            south: points.map(\.latitude).min() ?? -6.813,
            east: points.map(\.longitude).max() ?? 39.296,
            north: points.map(\.latitude).max() ?? -6.743)
    }

    static let airport = OfflineMapArea(id: "zuri-jnia-v1", title: .offlineCentral, detail: .offlineCentralDetail,
        west: 39.187, south: -6.894, east: 39.225, north: -6.855)

    static let areas: [OfflineMapArea] = [
        .init(id: "zuri-slipway-v1", title: .offlineSlipway, detail: .offlineSlipwayDetail,
              west: 39.265, south: -6.763, east: 39.284, north: -6.743),
        .init(id: "zuri-peninsula-v1", title: .offlinePeninsula, detail: .offlinePeninsulaDetail,
              west: 39.245, south: -6.79, east: 39.305, north: -6.725),
        .init(id: "zuri-central-dar-v1", title: .offlineCentral, detail: .offlineCentralDetail,
              west: 39.20, south: -6.87, east: 39.31, north: -6.75)
    ]
}
