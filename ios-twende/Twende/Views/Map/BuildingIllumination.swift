@_spi(Experimental) import MapboxMaps
import SwiftUI
import SceneKit

/// Sculpted roof/facade meshes on real footprints, with a subdued cool-slate selection rim.
/// Architecture is illustrative; the map supplies the footprint and available building height.
@MainActor
final class BuildingIllumination {
    private let sourceID = "twende-destination-building"
    private let layerID = "twende-destination-building-light"
    private let roofID = "twende-destination-building-roof"
    private let detailLayerID = "twende-building-architecture-mesh"
    private var renderLayer: BuildingRenderLayer?
    private let neighbourhood = BuildingNeighbourhood()
    var neighbourCount: Int { neighbourhood.buildingCount }
    func refreshNeighbours(on map: MapboxMap) {
        if !renderedBuildings.isEmpty { neighbourhood.refresh(excluding: renderedBuildings, on: map) }
    }
    private var renderedBuildings: [StandardBuildingsFeature] = []
    private var isInstalled: Bool = false
    /// Missing tile heights use a modest illustrative envelope.
    private static let fallbackHeight: Double = 12
    /// The shell sits outside the native walls and above the native roof; coplanar geometry loses the
    /// depth test to the theme's native building and the new facade would stay hidden underneath.
    private static let wallOffsetMeters: Double = 0.7
    private static let roofLift: Double = 0

    func show(_ buildings: [StandardBuildingsFeature], on map: MapboxMap) {
        let boundedBuildings = Array(buildings.filter { !DarLandmarkSite.isBespoke($0.geometry) }.prefix(12))
        if isInstalled, renderedBuildings.count == boundedBuildings.count,
           zip(renderedBuildings, boundedBuildings).allSatisfy({ $0.geometry == $1.geometry && $0.properties == $1.properties }) { return }
        guard let first = boundedBuildings.first else { remove(from: map); return }
        let coordinates: [LocationCoordinate2D]
        switch first.geometry {
        case .polygon(let polygon): coordinates = polygon.coordinates.first ?? []
        case .multiPolygon(let multi): coordinates = multi.coordinates.first?.first ?? []
        default: coordinates = []
        }
        guard let origin = coordinates.first, origin.latitude.isFinite, origin.longitude.isFinite else { remove(from: map); return }
        let identity = BuildingIdentity(geometry: first.geometry)
        let scene = Self.scene()
        let fragmentBudget = BuildingArchitecture.windowBudget / max(1, boundedBuildings.count)
        let features: [Feature] = boundedBuildings.compactMap { building in
            switch building.geometry {
            case .polygon, .multiPolygon: break
            default: return nil
            }
            let related = boundedBuildings.filter { other in
                (building.id != nil && other.id == building.id) || other.geometry == building.geometry
            }.compactMap { $0.properties["height"]??.number }
            let height = BuildingEnvelope.roof(height: building.properties["height"]??.number, relatedHeights: related)
            var base = building.properties["min_height"]??.number ?? 0
            if !base.isFinite || base < 0 || base >= height { base = 0 }
            let footprint = Self.expanded(building.geometry, by: Self.wallOffsetMeters)
            scene.rootNode.addChildNode(BuildingArchitecture.make(
                geometry: footprint, origin: origin, base: base, roof: height + Self.roofLift,
                windowLimit: fragmentBudget,
                roofStyle: (building.properties["roof:shape"]??.string).map { BuildingRoof.style(roofShape: $0) },
                isFragmented: boundedBuildings.count > 1, identity: identity
            ))
            // An inset native envelope remains as a graceful fallback if the GPU layer is unavailable.
            // Keep the safety envelope behind the deepest 32cm window recess, not across its glass.
            var feature = Feature(geometry: Self.expanded(building.geometry, by: Self.wallOffsetMeters - 0.45))
            feature.properties = ["roof": .number(height + Self.roofLift - 0.06), "base": .number(base), "color": .string(identity.wallHex)]
            return feature
        }
        guard !features.isEmpty else { remove(from: map); return }
        let collection = FeatureCollection(features: features)
        // Replace only after the complete new scene exists. No partial buildings during budget exhaustion.
        if isInstalled { remove(from: map) }
        do {
            var source = GeoJSONSource(id: sourceID)
            source.data = .featureCollection(collection)
            try map.addSource(source)

            var light = FillExtrusionLayer(id: layerID, source: sourceID)
            light.slot = .middle
            light.fillExtrusionHeight = .expression(Exp(.get) { "roof" })
            light.fillExtrusionBase = .expression(Exp(.get) { "base" })
            light.fillExtrusionColor = .expression(Exp(.toColor) { Exp(.get) { "color" } })
            light.fillExtrusionColorUseTheme = .constant(.none)
            light.fillExtrusionEmissiveStrength = .constant(0.08)
            light.fillExtrusionVerticalGradient = .constant(true)
            light.fillExtrusionAmbientOcclusionIntensity = .constant(0.35)
            light.fillExtrusionCastShadows = .constant(false)
            light.fillExtrusionFloodLightIntensity = .constant(0)
            try map.addLayer(light)

            let host = BuildingRenderLayer(origin: origin, scene: scene)
            try map.addCustomLayer(withId: detailLayerID, layerHost: host, layerPosition: nil)
            try map.setLayerProperty(for: detailLayerID, property: "slot", value: "middle")
            renderLayer = host

            var roof = LineLayer(id: roofID, source: sourceID)
            roof.slot = .middle
            roof.lineElevationReference = .constant(.ground)
            roof.lineZOffset = .expression(Exp(.get) { "roof" })
            roof.lineColor = .constant(StyleColor(BuildingSurfaces.color("#7C94AB")))
            roof.lineColorUseTheme = .constant(.none)
            roof.lineEmissiveStrength = .constant(0)
            roof.lineWidth = .constant(0.75)
            roof.lineBlur = .constant(0.4)
            roof.lineOpacity = .constant(0.35)
            try map.addLayer(roof)
            isInstalled = true
            renderedBuildings = boundedBuildings
            refreshNeighbours(on: map)
        } catch {
            remove(from: map)
            print("[BuildingIllumination] Architecture layer unavailable; native buildings retained")
        }
    }

    /// Geometry container only; the native map shader owns the broad, texture-free lighting.
    static func scene() -> SCNScene { SCNScene() }

    /// Grows a footprint outward by a metric distance, offsetting every edge along its outward normal
    /// and mitring corners (clamped so acute corners cannot spike). Holes shrink so the shell stays solid.
    static func expanded(_ geometry: Geometry, by meters: Double) -> Geometry {
        switch geometry {
        case .polygon(let polygon):
            return .polygon(Polygon(offsetRings(polygon.coordinates, by: meters)))
        case .multiPolygon(let multi):
            return .multiPolygon(MultiPolygon(multi.coordinates.map { offsetRings($0, by: meters) }))
        default:
            return geometry
        }
    }

    private static func offsetRings(_ rings: [[LocationCoordinate2D]], by meters: Double) -> [[LocationCoordinate2D]] {
        rings.enumerated().map { index, ring in offsetRing(ring, by: index == 0 ? meters : -meters) }
    }

    private static func offsetRing(_ ring: [LocationCoordinate2D], by meters: Double) -> [LocationCoordinate2D] {
        var points = ring
        if let first = points.first, let last = points.last, points.count > 1,
           first.latitude == last.latitude, first.longitude == last.longitude {
            points.removeLast()
        }
        guard points.count >= 3, let origin = points.first,
              points.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) < 85 && abs($0.longitude) <= 180 }) else { return ring }
        let metersPerLat = 110_540.0
        let metersPerLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let local: [SIMD2<Double>] = points.map {
            SIMD2(($0.longitude - origin.longitude) * metersPerLon, ($0.latitude - origin.latitude) * metersPerLat)
        }
        var area = 0.0
        for i in local.indices {
            let a = local[i], b = local[(i + 1) % local.count]
            area += a.x * b.y - b.x * a.y
        }
        // Counter-clockwise rings have outward normals to the right of travel; flip for clockwise.
        let orientation: Double = area >= 0 ? 1 : -1
        let count = local.count
        var moved: [SIMD2<Double>] = []
        moved.reserveCapacity(count + 1)
        for i in 0..<count {
            let prev = local[(i + count - 1) % count], cur = local[i], next = local[(i + 1) % count]
            var inDir = cur - prev, outDir = next - cur
            let inLen = (inDir.x * inDir.x + inDir.y * inDir.y).squareRoot()
            let outLen = (outDir.x * outDir.x + outDir.y * outDir.y).squareRoot()
            guard inLen > 0.01, outLen > 0.01 else { moved.append(cur); continue }
            inDir /= inLen; outDir /= outLen
            let n1 = SIMD2(inDir.y, -inDir.x) * orientation
            let n2 = SIMD2(outDir.y, -outDir.x) * orientation
            var bisector = n1 + n2
            let bisectorLen = (bisector.x * bisector.x + bisector.y * bisector.y).squareRoot()
            if bisectorLen < 0.001 { moved.append(cur + n1 * meters); continue }
            bisector /= bisectorLen
            let cosHalf = max(bisector.x * n1.x + bisector.y * n1.y, 0.35)
            moved.append(cur + bisector * (meters / cosHalf))
        }
        var result: [LocationCoordinate2D] = moved.map {
            LocationCoordinate2D(latitude: origin.latitude + $0.y / metersPerLat, longitude: origin.longitude + $0.x / metersPerLon)
        }
        if let first = result.first { result.append(first) }
        return result
    }

    func remove(from map: MapboxMap) {
        neighbourhood.remove(from: map)
        if map.layerExists(withId: roofID) { try? map.removeLayer(withId: roofID) }
        if map.layerExists(withId: detailLayerID) { try? map.removeLayer(withId: detailLayerID) }
        if map.layerExists(withId: layerID) { try? map.removeLayer(withId: layerID) }
        if map.sourceExists(withId: sourceID) { try? map.removeSource(withId: sourceID) }
        isInstalled = false
        renderedBuildings = []
        renderLayer = nil
    }

    func styleDidReload() {
        neighbourhood.reset()
        isInstalled = false
        renderedBuildings = []
        renderLayer = nil
    }

}
