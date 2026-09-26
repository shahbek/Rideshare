import XCTest
import SceneKit
import simd
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class BuildingRefinementTests: XCTestCase {
    func testBuildingMaterialsAreNaturalAndTextureFree() throws {
        let materials = BuildingMaterialStyle.allCases.map { BuildingSurfaces.wall($0) } + [BuildingSurfaces.slate, BuildingSurfaces.terracotta, BuildingSurfaces.zinc, BuildingSurfaces.membrane, BuildingSurfaces.glass]
        for material in materials {
            let color = try XCTUnwrap(material.diffuse.contents as? UIColor)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
            XCTAssertGreaterThan(a, 0.99)
            XCTAssertLessThanOrEqual(max(r, g, b) - min(r, g, b), 0.6, "Keep materials in the natural masonry, clay and metal range")
            XCTAssertFalse(material.normal.contents is UIImage)
        }
    }

    func testConvexFilletsPreserveConcavitiesAndCourtyardGeometry() {
        let outer: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 10), SIMD2(10, 10), SIMD2(10, 30), SIMD2(0, 30)]
        let hole: [SIMD2<Double>] = [SIMD2(3, 3), SIMD2(3, 7), SIMD2(7, 7), SIMD2(7, 3)]
        let footprint = BuildingFootprint(rings: [outer, hole])
        let rounded = BuildingContour.softened(footprint)
        XCTAssertGreaterThan(rounded.rings[0].count, outer.count)
        XCTAssertTrue(rounded.rings[0].contains(SIMD2(10, 10)), "The inner elbow of an L must not be bridged")
        XCTAssertEqual(rounded.rings[1], hole, "Courtyard openings retain exact geometry")
        XCTAssertFalse(rounded.path.contains(CGPoint(x: 5, y: 5)))
        XCTAssertFalse(rounded.path.contains(CGPoint(x: 20, y: 20)))
        XCTAssertLessThan(abs(BuildingFootprint.area(rounded.rings[0])), abs(BuildingFootprint.area(outer)))
        XCTAssertEqual(BuildingContour.softened(footprint).rings, rounded.rings)
        XCTAssertTrue(BuildingContour.outwardNormals(rounded.rings[0]).allSatisfy { $0.x.isFinite && $0.y.isFinite && abs(simd_length($0) - 1) < 0.0001 })
    }

    func testWallCornersAndCornicesHaveActualSmoothGeometry() throws {
        let origin = DarEsSalaam.upanga
        let ring = [(0.0, 0.0), (24, 0), (24, 18), (0, 18), (0, 0)].map { origin.offset(eastMetres: $0.0, northMetres: $0.1).coordinate }
        let building = BuildingArchitecture.make(geometry: .polygon(Polygon([ring])), origin: origin.coordinate, base: 0, roof: 40, identity: BuildingIdentity(seed: 7))
        let wallScene = SCNScene()
        wallScene.rootNode.addChildNode(try XCTUnwrap(building.childNode(withName: "curtainGlass", recursively: true)).clone())
        let corners = BuildingRenderGeometry.vertices(from: wallScene).filter { abs($0.normal.x) > 0.2 && abs($0.normal.y) > 0.2 }
        XCTAssertGreaterThan(corners.count, 20, "Rounded vertical corners need intermediate surface normals")
        let corniceScene = SCNScene()
        corniceScene.rootNode.addChildNode(try XCTUnwrap(building.childNode(withName: "towerFloorRibbons", recursively: true)).clone())
        XCTAssertTrue(BuildingRenderGeometry.vertices(from: corniceScene).contains { abs($0.normal.z) > 0.2 && abs($0.normal.z) < 0.9 }, "Mouldings have real rounded profiles, not sharp boxes")
        XCTAssertNotNil(building.childNode(withName: "sculptedTowerCrown", recursively: true))
        XCTAssertNotNil(building.childNode(withName: "towerCrownFins", recursively: true))
        let fullScene = SCNScene()
        fullScene.rootNode.addChildNode(building)
        let all = BuildingRenderGeometry.vertices(from: fullScene)
        XCTAssertLessThan(all.count, 100_000)
        XCTAssertTrue(all.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
    }

    func testLongPavilionHasContinuousCurvedVaultAndClosedDeck() throws {
        let origin = DarEsSalaam.upanga
        let ring = [(0.0, 0.0), (60, 0), (60, 22), (0, 22), (0, 0)].map { origin.offset(eastMetres: $0.0, northMetres: $0.1).coordinate }
        let building = BuildingArchitecture.make(geometry: .polygon(Polygon([ring])), origin: origin.coordinate, base: 0, roof: 9, identity: BuildingIdentity(seed: 6))
        let vault = try XCTUnwrap(building.childNode(withName: "continuousVault", recursively: true))
        XCTAssertNotNil(building.childNode(withName: "roofDeck", recursively: true))
        XCTAssertNotNil(building.childNode(withName: "vaultEnds", recursively: true))
        let scene = SCNScene()
        scene.rootNode.addChildNode(vault.clone())
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertGreaterThan(vertices.count, 100)
        XCTAssertTrue(vertices.contains { $0.position.z > 12 })
        XCTAssertTrue(vertices.contains { $0.normal.z > 0.8 && $0.normal.z < 0.99 })
    }

    func testAtriumFitsBesideCourtyardRatherThanAcrossIt() throws {
        let outer: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(40, 0), SIMD2(40, 40), SIMD2(0, 40)]
        let hole: [SIMD2<Double>] = [SIMD2(16, 16), SIMD2(16, 24), SIMD2(24, 24), SIMD2(24, 16)]
        let footprint = BuildingFootprint(rings: [outer, hole])
        let atrium = try XCTUnwrap(BuildingCrown.atrium(footprint: footprint, eave: 15, trim: BuildingSurfaces.wall(.royalStone)))
        let scene = SCNScene()
        scene.rootNode.addChildNode(atrium)
        for vertex in BuildingRenderGeometry.vertices(from: scene) {
            XCTAssertTrue(footprint.path.contains(CGPoint(x: Double(vertex.position.x), y: Double(vertex.position.y))))
            XCTAssertGreaterThanOrEqual(vertex.position.z, 15)
        }
    }
}
