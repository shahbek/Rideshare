import XCTest
import SceneKit
import simd
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class AirtelBuildingTests: XCTestCase {
    func testSignsReadLeftToRightFromOutsideAndRecessIsOnPhotoRight() throws {
        let geometry = try XCTUnwrap(AirtelBuildingSite.geometry)
        let scene = AirtelBuildingGeometry.make(geometry: geometry)
        for name in ["airtelNorthSign", "airtelWestSign"] {
            let sign = try XCTUnwrap(scene.rootNode.childNode(withName: name, recursively: true))
            let m = sign.simdWorldTransform
            let right = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
            let up = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            let front = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            XCTAssertGreaterThan(simd_dot(simd_cross(right, up), front), 0.99, "Exterior lettering must not be reflected")
        }
        let ring = BuildingContour.rounded(try XCTUnwrap(AirtelBuildingSite.footprint(geometry)?.rings.first), tangentDistance: 3.2, segments: 10)
        let edge = AirtelBuildingSite.frontEdge(ring)
        let recessed = AirtelBuildingGeometry.recessed(ring, edge: edge, depth: 2.2)
        let fraction = simd_distance(ring[edge], recessed[edge + 1]) / simd_distance(ring[edge], ring[(edge + 1) % ring.count])
        XCTAssertGreaterThan(fraction, 0.55, "Photo shows the recess right of centre when viewed from the road")
    }

    func testVerifiedFootprintAndNorthRoadOrientation() throws {
        let geometry = try XCTUnwrap(AirtelBuildingSite.geometry)
        let footprint = try XCTUnwrap(AirtelBuildingSite.footprint(geometry))
        let ring = try XCTUnwrap(footprint.rings.first)
        XCTAssertEqual(ring.count, 11)
        XCTAssertEqual(abs(BuildingFootprint.area(ring)), 1542, accuracy: 20)
        XCTAssertEqual(AirtelBuildingSite.anchor.latitude, -6.77784798, accuracy: 0.00000001)
        XCTAssertEqual(AirtelBuildingSite.anchor.longitude, 39.26466405, accuracy: 0.00000001)
        let edge = AirtelBuildingSite.frontEdge(ring)
        let d = simd_normalize(ring[(edge + 1) % ring.count] - ring[edge])
        let bearing = (atan2(d.y, -d.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        XCTAssertEqual(bearing, 356.3, accuracy: 0.5)
        XCTAssertGreaterThan(simd_distance(ring[edge], ring[(edge + 1) % ring.count]), 58)
        XCTAssertTrue(AirtelBuildingSite.matches(geometry))
    }

    func testNativeFitRejectsNearbyBuildingsAndPartialFootprints() throws {
        let geometry = try XCTUnwrap(AirtelBuildingSite.geometry)
        guard case .polygon(let polygon) = geometry else { return XCTFail("Missing polygon") }
        let nearby = Geometry.polygon(Polygon(polygon.coordinates.map { ring in ring.map {
            GeoPoint($0).offset(eastMetres: 65, northMetres: 0).coordinate
        } }))
        XCTAssertFalse(AirtelBuildingSite.matches(nearby))
        let fragment = Geometry.polygon(Polygon(polygon.coordinates.map { ring in ring.map { p in
            CLLocationCoordinate2D(latitude: AirtelBuildingSite.anchor.latitude + (p.latitude - AirtelBuildingSite.anchor.latitude) * 0.3,
                                   longitude: AirtelBuildingSite.anchor.longitude + (p.longitude - AirtelBuildingSite.anchor.longitude) * 0.3)
        } }))
        XCTAssertTrue(AirtelBuildingSite.matches(fragment))
        XCTAssertEqual(AirtelBuildingSite.fittedGeometry(candidates: [nearby, fragment]), geometry)
        XCTAssertEqual(AirtelBuildingSite.fittedGeometry(candidates: [geometry]), geometry)
    }

    func testPhotoFeaturesMaterialsAndFiniteBoundedMesh() throws {
        let geometry = try XCTUnwrap(AirtelBuildingSite.geometry)
        let scene = AirtelBuildingGeometry.make(geometry: geometry)
        for name in ["airtelHouse", "airtelCurtainWall", "airtelPodium", "airtelCantileverCanopy", "airtelRoofScreen", "airtelCanopyBraces", "airtelNorthSign", "airtelWestSign", "airtelCommunicationsMast", "airtelMicrowaveDishes", "airtelClosedRoof"] {
            XCTAssertNotNil(scene.rootNode.childNode(withName: name, recursively: true), name)
        }
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertGreaterThan(vertices.count, 10000)
        XCTAssertLessThan(vertices.count, 150000)
        XCTAssertTrue(vertices.allSatisfy { v in
            v.position.x.isFinite && v.position.y.isFinite && v.position.z.isFinite &&
            v.normal.x.isFinite && v.normal.y.isFinite && v.normal.z.isFinite && abs(simd_length(v.normal) - 1) < 0.001
        })
        XCTAssertTrue(vertices.allSatisfy { abs($0.position.x) < 36 && abs($0.position.y) < 27 && $0.position.z >= 0 && $0.position.z < 43 })
        let glass = vertices.filter { $0.appearance.w == 1 }
        XCTAssertGreaterThan(glass.count, 3000)
        XCTAssertTrue(glass.allSatisfy { $0.color.y > $0.color.x && $0.color.z >= $0.color.y && $0.appearance.x == 0.4 })
        XCTAssertTrue(vertices.contains { $0.color.x > 0.8 && $0.color.y < 0.2 })
        XCTAssertFalse(vertices.contains { $0.appearance.w == -4 || $0.appearance.w == 2 })
        XCTAssertGreaterThan(vertices.filter { $0.appearance.w == 4 }.count, 1000)
        XCTAssertGreaterThan(vertices.filter { $0.appearance.w == 3 }.count, 1000)
        XCTAssertTrue(vertices.filter { $0.appearance.w == 4 }.allSatisfy { $0.appearance.z == 1 && $0.color.x > 0.8 && $0.color.y < 0.2 })
        let repeatMesh = BuildingRenderGeometry.vertices(from: AirtelBuildingGeometry.make(geometry: geometry))
        XCTAssertEqual(vertices.map(\.position), repeatMesh.map(\.position))
    }

    func testFacadeRecessAndRaisedLetteringAreRealGeometry() throws {
        let geometry = try XCTUnwrap(AirtelBuildingSite.geometry)
        let ring = try XCTUnwrap(AirtelBuildingSite.footprint(geometry)?.rings.first)
        let rounded = BuildingContour.rounded(ring, tangentDistance: 3.2, segments: 10)
        let edge = AirtelBuildingSite.frontEdge(rounded)
        let recessed = AirtelBuildingGeometry.recessed(rounded, edge: edge, depth: 2.2)
        XCTAssertEqual(recessed.count, rounded.count + 4)
        XCTAssertEqual(simd_distance(recessed[edge + 1], recessed[edge + 2]), 2.2, accuracy: 0.00001)
        XCTAssertLessThan(BuildingFootprint.area(recessed), BuildingFootprint.area(rounded))
        let scene = SCNScene()
        scene.rootNode.addChildNode(AirtelSignage.make(width: 13, material: AirtelBuildingGeometry.red))
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertGreaterThan(vertices.count, 1000)
        XCTAssertEqual(vertices.map { $0.position.z }.max() ?? 0, 0.16, accuracy: 0.001)
        for i in 0..<6 { XCTAssertNotNil(scene.rootNode.childNode(withName: "airtelLetter.\(i)", recursively: true)) }
    }

    func testLandmarkRendersAtMoroccoFromBothRoadSides() async {
        for bearing in [176.3, 110.0] {
            let result = await MapRenderProbe().run(.airtel(bearing: bearing))
            XCTAssertTrue(result.styleLoaded, "\(result)")
            XCTAssertGreaterThan(result.matchedLandmarkBuildings, 0, "Live map must identify the same site: \(result)")
            XCTAssertGreaterThan(result.glowContribution, 10, "Lit letters must visibly differ from painted letters: \(result)")
            XCTAssertGreaterThan(result.architectureContribution, 500, "Custom mesh must render, not only clip the original: \(result)")
            XCTAssertGreaterThan(result.nativeClipContribution, 100, "The native building must be replaced inside the footprint: \(result)")
            XCTAssertGreaterThan(result.labelInkBefore, 50, "\(result)")
            XCTAssertGreaterThanOrEqual(result.labelInkAfter, Int(Double(result.labelInkBefore) * 0.95), "Labels must survive clipping: \(result)")
            XCTAssertTrue(result.landmarkLifecycleRestored, "\(result)")
            XCTAssertFalse(result.errors.contains { $0.hasPrefix("apply:") }, "\(result)")
        }
    }
}
