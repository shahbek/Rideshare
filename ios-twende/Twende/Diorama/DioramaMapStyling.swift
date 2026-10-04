import Foundation
@_spi(Experimental) import MapboxMaps

/// Debug-only Mapbox layers for the diorama (dashed tile outline). The basemap itself stays untouched
/// Mapbox Standard; everything 3D is drawn by `DioramaRenderLayer`.
@MainActor
struct DioramaMapStyling {
    static let layerIDs = ["zuri-diorama-tile-bounds"]
    private static let debugSource = "zuri-diorama-debug"

    let config: DioramaConfig

    func remove(from map: MapboxMap) {
        for id in Self.layerIDs where map.layerExists(withId: id) {
            try? map.removeLayer(withId: id)
        }
        if map.sourceExists(withId: Self.debugSource) { try? map.removeSource(withId: Self.debugSource) }
    }

    /// Dashed outlines of the loaded tiles.
    func setTileBounds(_ tiles: [DioramaTileID], visible: Bool, on map: MapboxMap) {
        let features = visible ? tiles.map { Feature(geometry: .lineString(LineString($0.outline))) } : []
        let collection = FeatureCollection(features: features)
        if map.sourceExists(withId: Self.debugSource) {
            map.updateGeoJSONSource(withId: Self.debugSource, geoJSON: .featureCollection(collection))
        } else {
            var source = GeoJSONSource(id: Self.debugSource)
            source.data = .featureCollection(collection)
            try? map.addSource(source)
        }
        if !map.layerExists(withId: "zuri-diorama-tile-bounds") {
            var line = LineLayer(id: "zuri-diorama-tile-bounds", source: Self.debugSource)
            line.slot = .top
            line.lineColor = .constant(StyleColor(rawValue: "#FF2D95"))
            line.lineWidth = .constant(2)
            line.lineDasharray = .constant([2, 2])
            line.lineEmissiveStrength = .constant(1)
            try? map.addLayer(line)
        }
    }
}
