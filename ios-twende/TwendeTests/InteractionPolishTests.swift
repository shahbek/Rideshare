import XCTest
import SwiftUI
import SceneKit
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class InteractionPolishTests: XCTestCase {
    func testPickerLandsWhenGestureEndsWithoutWaitingForMapIdle() {
        var lifted = false
        var landingCount = 0
        let map = MapView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), mapInitOptions: MapInitOptions(styleURI: nil))
        let coordinator = TripMapView.Coordinator(parent: TripMapView(
            camera: .constant(.automatic),
            selectionPoint: CGPoint(x: 195, y: 250),
            onCameraMoved: { _ in lifted = false; landingCount += 1 },
            onCameraWillMove: { _ in lifted = true }
        ))
        coordinator.mapView = map
        coordinator.gestureManager(map.gestures, didBegin: .pan)
        XCTAssertTrue(lifted)
        coordinator.gestureManager(map.gestures, didEnd: .pan, willAnimate: false)
        XCTAssertFalse(lifted, "Landing must not depend on a map-idle or network event")
        XCTAssertEqual(landingCount, 1)
        coordinator.cancelCameraSettlement()
    }

    func testPickerWaitsForInertiaAndConcurrentGestures() {
        var lifted = false
        let map = MapView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), mapInitOptions: MapInitOptions(styleURI: nil))
        let coordinator = TripMapView.Coordinator(parent: TripMapView(
            camera: .constant(.automatic),
            onCameraMoved: { _ in lifted = false },
            onCameraWillMove: { _ in lifted = true }
        ))
        coordinator.mapView = map
        coordinator.gestureManager(map.gestures, didBegin: .pan)
        coordinator.gestureManager(map.gestures, didBegin: .pinch)
        coordinator.gestureManager(map.gestures, didEnd: .pan, willAnimate: false)
        XCTAssertTrue(lifted, "A second gesture is still holding the map")
        coordinator.gestureManager(map.gestures, didEnd: .pinch, willAnimate: true)
        XCTAssertTrue(lifted)
        coordinator.gestureManager(map.gestures, didEndAnimatingFor: .pinch)
        XCTAssertFalse(lifted)
        coordinator.cancelCameraSettlement()
    }

    func testProceduralFacadeIsBoundedAndHasContinuousSurfaces() throws {
        let origin = DarEsSalaam.upanga
        let ring = [origin, origin.offset(eastMetres: 20, northMetres: 0), origin.offset(eastMetres: 20, northMetres: 16), origin.offset(eastMetres: 0, northMetres: 16), origin].map(\.coordinate)
        let geometry = Geometry.polygon(Polygon([ring]))
        for style in BuildingMaterialStyle.allCases {
            let building = BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: 12.6, style: style)
            XCTAssertNotNil(building.childNode(withName: "walls", recursively: true))
            XCTAssertNotNil(building.childNode(withName: "roofDeck", recursively: true))
            XCTAssertNotNil(building.childNode(withName: "reflectiveWindows", recursively: true))
            XCTAssertLessThanOrEqual(building.childNodes.count, 8, "Architecture stays batched into continuous material surfaces")
            XCTAssertNotNil(building.childNode(withName: "windowRecesses", recursively: true))
            XCTAssertNotNil(building.childNode(withName: "continuousCornices", recursively: true))
            XCTAssertNotNil(building.childNode(withName: "entranceCanopy", recursively: true))
            XCTAssertNil(building.childNode(withName: "integratedPillars", recursively: true))
            XCTAssertNil(building.childNode(withName: "windowFrames", recursively: true))
            XCTAssertNil(building.childNode(withName: "continuousDome", recursively: true), "Unknown buildings must not acquire invented domes")
            XCTAssertTrue(BuildingSurfaces.wall(style).diffuse.contents is UIColor, "Wall finishes must be solid colours, not grainy texture images")
            let glass = try XCTUnwrap(building.childNode(withName: "reflectiveWindows", recursively: true)?.geometry?.firstMaterial)
            XCTAssertEqual(glass.lightingModel, .physicallyBased)
            XCTAssertEqual(try XCTUnwrap(glass.roughness.contents as? NSNumber).doubleValue, 0.40, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(glass.metalness.contents as? NSNumber).doubleValue, 0.08, accuracy: 0.001)
            XCTAssertTrue(glass.diffuse.contents is UIColor)
            let vertices = building.childNode(withName: "reflectiveWindows", recursively: true)?.geometry?.sources(for: .vertex).first?.vectorCount ?? 0
            XCTAssertLessThanOrEqual(vertices / 6, BuildingArchitecture.windowBudget)
            XCTAssertEqual(building.boundingBox.min.z, 0, accuracy: 0.001)
            XCTAssertGreaterThan(building.boundingBox.max.z, 12.6)
        }
        let noDetail = BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: 12.6, style: .royalStone, windowLimit: 0)
        XCTAssertNotNil(noDetail.childNode(withName: "roofDeck", recursively: true), "Budget can simplify windows, never remove the roof")
        XCTAssertNil(noDetail.childNode(withName: "reflectiveWindows", recursively: true))
        XCTAssertTrue(BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: .nan, style: .rock).childNodes.isEmpty)
    }

    func testBuildingHasCompleteRoofSurfaceNotJustAnEdge() throws {
        let origin = DarEsSalaam.upanga
        let ring = [origin, origin.offset(eastMetres: 20, northMetres: 0), origin.offset(eastMetres: 20, northMetres: 16), origin.offset(eastMetres: 0, northMetres: 16), origin].map(\.coordinate)
        let footprint = try XCTUnwrap(BuildingFootprint(coordinates: [ring], origin: origin.coordinate))
        let trim = BuildingSurfaces.make("test", color: "#EEEAE0", roughness: 0.7)
        for style in BuildingRoof.Style.allCases {
            let roof = BuildingRoof.make(footprint: footprint, eave: 12, style: style, trim: trim)
            XCTAssertEqual(roof.name, "roof.\(style.rawValue)")
            let deck = try XCTUnwrap(roof.childNode(withName: "roofDeck", recursively: true))
            let scene = SCNScene()
            scene.rootNode.addChildNode(deck.clone())
            let vertices = BuildingRenderGeometry.vertices(from: scene)
            XCTAssertFalse(vertices.isEmpty, "Deck must survive CPU-to-Metal baking, not only exist as a lazy path")
            let topArea = projectedRoofArea(vertices)
            XCTAssertEqual(topArea, abs(BuildingFootprint.area(footprint.rings[0])), accuracy: 0.1, "Roof must fill the footprint, not only its edge")
            if style == .gable || style == .hip { XCTAssertNotNil(roof.childNode(withName: "continuousRoof", recursively: true)) }
            if style == .dome {
                let dome = try XCTUnwrap(roof.childNode(withName: "continuousDome", recursively: true)?.geometry)
                XCTAssertGreaterThan(dome.sources(for: .normal).first?.vectorCount ?? 0, 5_000)
                XCTAssertGreaterThan(roof.boundingBox.max.z, 15)
            }
        }
    }

    func testRoofIdentityRequiresExplicitMetadataAndFinishesHaveNoTextures() {
        XCTAssertEqual(BuildingRoof.style(roofShape: nil), .terrace)
        XCTAssertEqual(BuildingRoof.style(roofShape: "unknown"), .terrace)
        XCTAssertEqual(BuildingRoof.style(roofShape: "gabled"), .gable)
        XCTAssertEqual(BuildingRoof.style(roofShape: "hipped"), .hip)
        XCTAssertEqual(BuildingRoof.style(roofShape: "dome"), .dome)
        for surface in [BuildingSurfaces.slate, BuildingSurfaces.terracotta, BuildingSurfaces.zinc, BuildingSurfaces.membrane, BuildingSurfaces.glass] {
            XCTAssertTrue(surface.diffuse.contents is UIColor, "No photographed or generated grain on map buildings")
            XCTAssertFalse(surface.normal.contents is UIImage, "No grain or bump-map images")
        }
    }

    func testArchitecturalGeometrySupportsCourtyardsAndRaisedBases() throws {
        let origin = DarEsSalaam.upanga
        let outer = [origin, origin.offset(eastMetres: 30, northMetres: 0), origin.offset(eastMetres: 30, northMetres: 30), origin.offset(eastMetres: 0, northMetres: 30), origin].map(\.coordinate)
        let inner = [origin.offset(eastMetres: 10, northMetres: 10), origin.offset(eastMetres: 10, northMetres: 20), origin.offset(eastMetres: 20, northMetres: 20), origin.offset(eastMetres: 20, northMetres: 10), origin.offset(eastMetres: 10, northMetres: 10)].map(\.coordinate)
        let footprint = try XCTUnwrap(BuildingFootprint(coordinates: [outer, inner], origin: origin.coordinate))
        XCTAssertFalse(footprint.path.contains(CGPoint(x: 15, y: 15)))
        XCTAssertTrue(footprint.path.contains(CGPoint(x: 5, y: 5)))
        XCTAssertNil(footprint.rectangle, "Never bridge courtyard holes with a bounding-box roof")
        let geometry = Geometry.multiPolygon(MultiPolygon([[outer, inner]]))
        let building = BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 4, roof: 20, style: .brutalist, windowLimit: 70)
        XCTAssertEqual(building.boundingBox.min.z, 4, accuracy: 0.001)
        XCTAssertNotNil(building.childNode(withName: "roof.terrace", recursively: true))
        let deck = try XCTUnwrap(building.childNode(withName: "roofDeck", recursively: true))
        let scene = SCNScene()
        scene.rootNode.addChildNode(deck.clone())
        let expectedArea = BuildingContour.softened(footprint).rings.reduce(0) { $0 + BuildingFootprint.area($1) }
        XCTAssertEqual(projectedRoofArea(BuildingRenderGeometry.vertices(from: scene)), expectedArea, accuracy: 0.1, "Baked triangles must preserve the courtyard opening")
        XCTAssertGreaterThan(building.boundingBox.max.z, 20)
    }

    private func projectedRoofArea(_ vertices: [BuildingRenderVertex]) -> Double {
        var area = 0.0
        for i in stride(from: 0, to: vertices.count, by: 3) where vertices[i].normal.z > 0.9 {
            let a = vertices[i].position, b = vertices[i + 1].position, c = vertices[i + 2].position
            area += Double(abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))) / 2
        }
        return area
    }

    func testAllDemoDriversHaveAvailablePickupPortraits() {
        for driver in MockDrivers.all {
            guard let name = driver.portraitName else { return XCTFail("Demo driver missing pickup portrait") }
            XCTAssertNotNil(UIImage(named: name))
        }
    }
}
