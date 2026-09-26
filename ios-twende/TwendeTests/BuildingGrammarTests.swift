import XCTest
import SceneKit
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class BuildingGrammarTests: XCTestCase {
    func testProportionsProduceDifferentCohesiveRoofFamilies() throws {
        let origin = DarEsSalaam.upanga
        let small = [origin, origin.offset(eastMetres: 20, northMetres: 0), origin.offset(eastMetres: 20, northMetres: 14), origin.offset(eastMetres: 0, northMetres: 14), origin].map(\.coordinate)
        let footprint = try XCTUnwrap(BuildingFootprint(coordinates: [small], origin: origin.coordinate))
        let low = BuildingGrammar(footprint: footprint, height: 10, roofOverride: nil)
        let tall = BuildingGrammar(footprint: footprint, height: 40, roofOverride: nil)
        XCTAssertEqual(low.family, .townhouse)
        XCTAssertEqual(low.roofStyle, .hip)
        XCTAssertEqual(tall.family, .tower)
        XCTAssertEqual(tall.roofStyle, .terrace)
        XCTAssertGreaterThan(tall.crownHeight, 0)
        XCTAssertEqual(BuildingGrammar(footprint: footprint, height: 10, roofOverride: .gable).roofStyle, .gable)
        let long = [origin, origin.offset(eastMetres: 60, northMetres: 0), origin.offset(eastMetres: 60, northMetres: 22), origin.offset(eastMetres: 0, northMetres: 22), origin].map(\.coordinate)
        let hall = try XCTUnwrap(BuildingFootprint(coordinates: [long], origin: origin.coordinate))
        XCTAssertEqual(BuildingGrammar(footprint: hall, height: 9, roofOverride: nil).family, .pavilion)
        XCTAssertEqual(BuildingGrammar(footprint: hall, height: 9, roofOverride: nil).roofStyle, .vault)
    }

    func testRecessesRoofAndCrownSurviveGPUBakingDeterministically() throws {
        let origin = DarEsSalaam.upanga
        let ring = [origin, origin.offset(eastMetres: 24, northMetres: 0), origin.offset(eastMetres: 24, northMetres: 18), origin.offset(eastMetres: 0, northMetres: 18), origin].map(\.coordinate)
        let geometry = Geometry.polygon(Polygon([ring]))
        let building = BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: 28, roofStyle: .terrace, identity: BuildingIdentity(seed: 7))
        XCTAssertNotNil(building.childNode(withName: "setbackCrown", recursively: true))
        XCTAssertNotNil(building.childNode(withName: "entranceCanopy", recursively: true))
        let recess = try XCTUnwrap(building.childNode(withName: "windowRecesses", recursively: true))
        let revealScene = SCNScene()
        revealScene.rootNode.addChildNode(recess.clone())
        let revealVertices = BuildingRenderGeometry.vertices(from: revealScene)
        XCTAssertFalse(revealVertices.isEmpty)
        XCTAssertTrue(revealVertices.contains { abs($0.normal.z) > 0.5 }, "Window heads have real depth surfaces, not coloured rectangles")
        let scene = SCNScene()
        scene.rootNode.addChildNode(building)
        let baked = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertTrue(baked.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
        XCTAssertTrue(baked.contains { $0.position.z > 29 }, "Roof crown must actually reach the renderer")
        let otherScene = SCNScene()
        otherScene.rootNode.addChildNode(BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: 28, roofStyle: .terrace, identity: BuildingIdentity(seed: 7)))
        XCTAssertEqual(baked.map(\.position), BuildingRenderGeometry.vertices(from: otherScene).map(\.position))
        XCTAssertLessThan(baked.count, 100_000, "Detail stays bounded for map interaction")
    }

    func testConcaveRoofTrianglesCoverOnlyTheFootprint() throws {
        let origin = DarEsSalaam.upanga
        let ring = [(0.0, 0.0), (30, 0), (30, 10), (10, 10), (10, 30), (0, 30), (0, 0)].map { origin.offset(eastMetres: $0.0, northMetres: $0.1).coordinate }
        let footprint = try XCTUnwrap(BuildingFootprint(coordinates: [ring], origin: origin.coordinate))
        let scene = SCNScene()
        scene.rootNode.addChildNode(footprint.deck(at: 12, thickness: 0.18, material: BuildingSurfaces.membrane))
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertFalse(vertices.isEmpty)
        var area = 0.0
        for i in stride(from: 0, to: vertices.count, by: 3) where vertices[i].normal.z > 0.9 {
            let a = vertices[i].position, b = vertices[i + 1].position, c = vertices[i + 2].position
            area += Double(abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))) / 2
            XCTAssertTrue(footprint.path.contains(CGPoint(x: Double((a.x + b.x + c.x) / 3), y: Double((a.y + b.y + c.y) / 3))), "A roof triangle must not span the missing part of an L-shaped footprint")
        }
        XCTAssertEqual(area, abs(BuildingFootprint.area(footprint.rings[0])), accuracy: 0.1)
    }
}
