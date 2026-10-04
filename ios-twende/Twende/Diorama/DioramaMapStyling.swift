import Foundation
@_spi(Experimental) import MapboxMaps

/// Styled Mapbox layers for the flat parts of the scene: toy roads (asphalt with white edge lines and
/// dashed centre line, red earth for unpaved lanes), turquoise water with a sand shoreline, parks and
/// road labels in the diorama's palette. Mapbox lines were chosen over road geometry in the model so
/// they stay crisp at any zoom, get anti-aliasing for free and keep Mapbox's collision-aware labels.
@MainActor
struct DioramaMapStyling {
    static let layerIDs = [
        "zuri-diorama-sand", "zuri-diorama-park", "zuri-diorama-water", "zuri-diorama-shore",
        "zuri-diorama-earth-road", "zuri-diorama-road-shoulder", "zuri-diorama-road", "zuri-diorama-road-edge",
        "zuri-diorama-road-centre", "zuri-diorama-road-label", "zuri-diorama-tile-bounds",
    ]
    private static let source = DioramaDataLoader.sourceID
    private static let debugSource = "zuri-diorama-debug"

    let config: DioramaConfig

    func install(on map: MapboxMap) throws {
        guard !map.layerExists(withId: "zuri-diorama-road") else { return }
        let minZoom: Double = config.minimumZoom - 0.5

        // Warm sandy ground under everything the model does not cover.
        var sand = BackgroundLayer(id: "zuri-diorama-sand")
        sand.slot = .bottom
        sand.minZoom = minZoom
        sand.backgroundColor = .constant(StyleColor(rawValue: config.sandColor))
        sand.backgroundEmissiveStrength = .constant(0.35)
        try map.addLayer(sand)

        var park = FillLayer(id: "zuri-diorama-park", source: Self.source)
        park.sourceLayer = "landuse"
        park.slot = .bottom
        park.minZoom = minZoom
        park.filter = Exp(.inExpression) { Exp(.get) { "class" }; ["park", "grass", "pitch", "cemetery", "wood", "scrub", "garden"] }
        park.fillColor = .constant(StyleColor(rawValue: config.parkColor))
        park.fillEmissiveStrength = .constant(0.3)
        try map.addLayer(park)

        var shore = LineLayer(id: "zuri-diorama-shore", source: Self.source)
        shore.sourceLayer = "water"
        shore.slot = .bottom
        shore.minZoom = minZoom
        shore.lineColor = .constant(StyleColor(rawValue: config.shoreSandColor))
        shore.lineWidth = .expression(Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 15; 6; 18; 40 })
        shore.lineOffset = .expression(Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 15; -3; 18; -20 })
        shore.lineEmissiveStrength = .constant(0.4)
        try map.addLayer(shore)

        var water = FillLayer(id: "zuri-diorama-water", source: Self.source)
        water.sourceLayer = "water"
        water.slot = .bottom
        water.minZoom = minZoom
        water.fillColor = .constant(StyleColor(rawValue: config.waterDeepColor))
        water.fillEmissiveStrength = .constant(0.25)
        try map.addLayer(water)

        // Shallow turquoise band just off the shoreline.
        var shallow = LineLayer(id: "zuri-diorama-water-shallow", source: Self.source)
        shallow.sourceLayer = "water"
        shallow.slot = .bottom
        shallow.minZoom = minZoom
        shallow.lineColor = .constant(StyleColor(rawValue: config.waterShallowColor))
        shallow.lineWidth = .expression(Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 15; 5; 18; 36 })
        shallow.lineOffset = .expression(Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 15; 2.5; 18; 18 })
        shallow.lineBlur = .constant(6)
        shallow.lineEmissiveStrength = .constant(0.4)
        try map.addLayer(shallow)

        let roadFilter = Exp(.all) {
            Exp(.not) { Exp(.inExpression) { Exp(.get) { "class" }; ["path", "pedestrian", "ferry", "aerialway", "golf", "track"] } }
            Exp(.not) { Exp(.eq) { Exp(.get) { "structure" }; "tunnel" } }
        }
        let widthStops: (Double, Double) -> Exp = { base, scale in
            Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 14; base; 18; base * scale }
        }
        let classWidth = Exp(.match) {
            Exp(.get) { "class" }
            ["motorway", "trunk", "primary"]; 12
            "secondary"; 10
            "tertiary"; 8
            ["street", "street_limited"]; 6
            "service"; 4
            5
        }
        let roadWidth = Exp(.interpolate) {
            Exp(.exponential) { 2 }
            Exp(.zoom)
            14; Exp(.product) { classWidth; 0.3 }
            18; Exp(.product) { classWidth; 4.2 }
        }
        _ = widthStops

        var earth = LineLayer(id: "zuri-diorama-earth-road", source: Self.source)
        earth.sourceLayer = "road"
        earth.slot = .bottom
        earth.minZoom = minZoom
        earth.filter = Exp(.all) { roadFilter; Exp(.eq) { Exp(.get) { "surface" }; "unpaved" } }
        earth.lineColor = .constant(StyleColor(rawValue: config.earthRoadColor))
        earth.lineWidth = .expression(roadWidth)
        earth.lineCap = .constant(.round)
        earth.lineJoin = .constant(.round)
        earth.lineEmissiveStrength = .constant(0.3)
        try map.addLayer(earth)

        let pavedFilter = Exp(.all) { roadFilter; Exp(.not) { Exp(.eq) { Exp(.get) { "surface" }; "unpaved" } } }

        var shoulder = LineLayer(id: "zuri-diorama-road-shoulder", source: Self.source)
        shoulder.sourceLayer = "road"
        shoulder.slot = .bottom
        shoulder.minZoom = minZoom
        shoulder.filter = pavedFilter
        shoulder.lineColor = .constant(StyleColor(rawValue: config.shoulderColor))
        shoulder.lineWidth = .expression(Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 14; Exp(.product) { classWidth; 0.42 }; 18; Exp(.product) { classWidth; 5.6 } })
        shoulder.lineCap = .constant(.round)
        shoulder.lineJoin = .constant(.round)
        shoulder.lineEmissiveStrength = .constant(0.3)
        try map.addLayer(shoulder)

        var road = LineLayer(id: "zuri-diorama-road", source: Self.source)
        road.sourceLayer = "road"
        road.slot = .bottom
        road.minZoom = minZoom
        road.filter = pavedFilter
        road.lineColor = .constant(StyleColor(rawValue: config.asphaltColor))
        road.lineWidth = .expression(roadWidth)
        road.lineCap = .constant(.round)
        road.lineJoin = .constant(.round)
        road.lineEmissiveStrength = .constant(0.2)
        try map.addLayer(road)

        var edge = LineLayer(id: "zuri-diorama-road-edge", source: Self.source)
        edge.sourceLayer = "road"
        edge.slot = .bottom
        edge.minZoom = config.minimumZoom
        edge.filter = Exp(.all) { pavedFilter; Exp(.inExpression) { Exp(.get) { "class" }; ["motorway", "trunk", "primary", "secondary", "tertiary", "street"] } }
        edge.lineColor = .constant(StyleColor(rawValue: "#F6F1E6"))
        edge.lineWidth = .expression(Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 16; 0.8; 18; 2.2 })
        edge.lineGapWidth = .expression(Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 14; Exp(.product) { classWidth; 0.26 }; 18; Exp(.product) { classWidth; 3.7 } })
        edge.lineEmissiveStrength = .constant(0.6)
        try map.addLayer(edge)

        var centre = LineLayer(id: "zuri-diorama-road-centre", source: Self.source)
        centre.sourceLayer = "road"
        centre.slot = .bottom
        centre.minZoom = config.minimumZoom
        centre.filter = Exp(.all) { pavedFilter; Exp(.inExpression) { Exp(.get) { "class" }; ["motorway", "trunk", "primary", "secondary", "tertiary", "street"] } }
        centre.lineColor = .constant(StyleColor(rawValue: "#F6F1E6"))
        centre.lineWidth = .expression(Exp(.interpolate) { Exp(.exponential) { 2 }; Exp(.zoom); 16; 0.7; 18; 1.8 })
        centre.lineDasharray = .constant([3, 3])
        centre.lineEmissiveStrength = .constant(0.6)
        try map.addLayer(centre)

        var label = SymbolLayer(id: "zuri-diorama-road-label", source: Self.source)
        label.sourceLayer = "road"
        label.slot = .top
        label.minZoom = config.minimumZoom
        label.filter = Exp(.all) { roadFilter; Exp(.has) { "name" } }
        label.symbolPlacement = .constant(.line)
        label.textField = .expression(Exp(.coalesce) { Exp(.get) { "name_en" }; Exp(.get) { "name" } })
        label.textFont = .constant(["DIN Pro Bold", "Arial Unicode MS Bold"])
        label.textSize = .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); 16; 11; 18; 14 })
        label.textLetterSpacing = .constant(0.08)
        label.textTransform = .constant(.uppercase)
        label.textColor = .constant(StyleColor(rawValue: config.roadLabelColor))
        label.textHaloColor = .constant(StyleColor(rawValue: config.roadLabelHalo))
        label.textHaloWidth = .constant(1.6)
        label.textEmissiveStrength = .constant(1)
        try map.addLayer(label)
    }

    func remove(from map: MapboxMap) {
        for id in Self.layerIDs + ["zuri-diorama-water-shallow"] where map.layerExists(withId: id) {
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
