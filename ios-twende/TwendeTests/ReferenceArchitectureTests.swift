import XCTest
import SceneKit
import simd
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class ReferenceArchitectureTests: XCTestCase {
    func testTowerHasBroadGlassRibbonsAndProtectedCrown() throws {
        let footprint = BuildingFootprint(rings: [[SIMD2(0, 0), SIMD2(24, 0), SIMD2(24, 18), SIMD2(0, 18)]])
        let tower = BuildingGlassTower.make(footprint: footprint, base: 0, roof: 100, identity: BuildingIdentity(seed: 7))
        for name in ["curtainGlass", "towerFloorRibbons", "sculptedTowerCrown", "towerCrownFins", "roofDeck"] { XCTAssertNotNil(tower.childNode(withName: name, recursively: true)) }
        let scene = SCNScene(); scene.rootNode.addChildNode(tower)
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertTrue(vertices.contains { $0.appearance.w == 1 && $0.color.z > $0.color.x + 0.1 })
        XCTAssertLessThan(vertices.count, 80_000)
        let crown = try XCTUnwrap(tower.childNode(withName: "sculptedTowerCrown", recursively: true))
        XCTAssertGreaterThanOrEqual(crown.boundingBox.min.z, 100, "Taper must not cut into the basic native model")
    }

    func testGreenRoofPlotsPreserveCourtyard() throws {
        let outer = [SIMD2<Double>(0, 0), SIMD2(40, 0), SIMD2(40, 40), SIMD2(0, 40)]
        let hole = [SIMD2<Double>(14, 14), SIMD2(14, 26), SIMD2(26, 26), SIMD2(26, 14)]
        let footprint = BuildingFootprint(rings: [outer, hole])
        let roof = try XCTUnwrap(BuildingLifestyle.plantedRoof(footprint: footprint, eave: 20, identity: BuildingIdentity(seed: 7)))
        let scene = SCNScene(); scene.rootNode.addChildNode(roof)
        for v in BuildingRenderGeometry.vertices(from: scene) {
            XCTAssertTrue(footprint.path.contains(CGPoint(x: Double(v.position.x), y: Double(v.position.y))))
            XCTAssertGreaterThan(v.position.z, 20)
        }
        XCTAssertNotNil(roof.childNode(withName: "roofGrass", recursively: true))
    }

    func testTropicalAndSanFranciscoFormsHaveDifferentGeometry() throws {
        let footprint = BuildingFootprint(rings: [[SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 8), SIMD2(0, 8)]])
        let identity = BuildingIdentity(seed: 5)
        let tropical = try XCTUnwrap(BuildingLifestyle.tropical(footprint: footprint, eave: 8, base: 0, identity: identity))
        XCTAssertNotNil(tropical.childNode(withName: "tropicalTimberScreen", recursively: true))
        XCTAssertNotNil(tropical.childNode(withName: "roof.hip", recursively: true))
        let sf = try XCTUnwrap(BuildingLifestyle.sanFranciscoBays(footprint: footprint, base: 0, eave: 12, identity: identity))
        XCTAssertNotNil(sf.childNode(withName: "bayWindowGlass", recursively: true))
        XCTAssertNotNil(sf.childNode(withName: "projectingBayWalls", recursively: true))
        let scene = SCNScene(); scene.rootNode.addChildNode(sf)
        XCTAssertTrue(BuildingRenderGeometry.vertices(from: scene).allSatisfy { $0.position.x.isFinite && $0.normal.z.isFinite })
    }

    func testWallMaterialPatternsReachGPUWithoutTextureImages() throws {
        for (seed, expected) in [(UInt64(3) << 8, Float(-1)), (UInt64(1) << 8, Float(-3))] {
            var mesh = BuildingMesh()
            mesh.quad(SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 0, 10), SIMD3(0, 0, 10))
            let scene = SCNScene(); scene.rootNode.addChildNode(mesh.node(name: "walls", material: BuildingIdentity(seed: seed).material("wall")))
            let vertices = BuildingRenderGeometry.vertices(from: scene)
            XCTAssertEqual(vertices.first?.appearance.w, expected)
        }
    }

    func testProceduralTorchPylonFitsBridgeStationWithoutBundledModel() throws {
        let alignment = try XCTUnwrap(TanzaniteBridgeAlignment.load())
        let station = alignment.record.pylonChainages[2]
        let pylon = TanzaniteProceduralPylons.make(alignment: alignment, station: station, isCentral: true)
        let scene = SCNScene(); scene.rootNode.addChildNode(pylon)
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertGreaterThan(vertices.count, 5_000)
        XCTAssertLessThan(vertices.count, 20_000)
        XCTAssertEqual(vertices.filter { $0.appearance.w != 3 }.map { $0.position.z }.max() ?? 0, 83.5, accuracy: 0.1)
        XCTAssertEqual(vertices.map { $0.position.z }.min() ?? 0, 0, accuracy: 0.1)
        XCTAssertNotNil(pylon.childNode(withName: "proceduralTanzaniteCrown", recursively: true))
        XCTAssertNotNil(pylon.childNode(withName: "pylonCrosshead", recursively: true))
        let origin = alignment.point(at: station, elevation: 0)
        let forward = alignment.tangent(at: station)
        let across = simd_cross(SIMD3<Double>(0, 0, 1), forward)
        for v in vertices where v.appearance.w != 3 {
            let p = SIMD3<Double>(Double(v.position.x), Double(v.position.y), Double(v.position.z)) - origin
            XCTAssertLessThanOrEqual(abs(simd_dot(p, across)), 15.6)
            XCTAssertLessThanOrEqual(abs(simd_dot(p, forward)), 3.01)
        }
        XCTAssertNil(Bundle.main.url(forResource: "tanzanite_torch_pylon", withExtension: "usdz"), "The obsolete imported asset must not ship")
    }

    func testBridgeSpansMappedEndpointsAndBendsSouth() throws {
        let alignment = try XCTUnwrap(TanzaniteBridgeAlignment.load())
        XCTAssertEqual(alignment.length, 1_030, accuracy: 8)
        XCTAssertEqual(alignment.record.widthMetres, 20.5)
        XCTAssertEqual(alignment.record.pylonChainages.count, 5)
        XCTAssertEqual(alignment.record.coordinates.first?.latitude ?? 0, -6.7882415, accuracy: 0.000001)
        XCTAssertEqual(alignment.record.coordinates.last?.longitude ?? 0, 39.2867562, accuracy: 0.000001)
        let first = alignment.point(at: 0, elevation: 0), last = alignment.point(at: alignment.length, elevation: 0)
        XCTAssertEqual(first.x, alignment.points[0].x, accuracy: 0.001)
        XCTAssertEqual(last.y, alignment.points.last?.y ?? 0, accuracy: 0.001)
        XCTAssertGreaterThan(simd_distance(alignment.tangent(at: 0), alignment.tangent(at: alignment.length)), 0.1)
        let scene = TanzaniteBridgeGeometry.make(alignment: alignment)
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertGreaterThan(vertices.count, 5_000)
        XCTAssertLessThan(vertices.count, 150_000)
        XCTAssertTrue(vertices.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite && $0.normal.x.isFinite && $0.normal.y.isFinite && $0.normal.z.isFinite })
        XCTAssertGreaterThanOrEqual(vertices.map { $0.position.z }.min() ?? 0, -2, "Sloping pylon feet can extend slightly below water level; the roadway cannot")
        let roadScene = SCNScene()
        roadScene.rootNode.addChildNode(try XCTUnwrap(scene.rootNode.childNode(withName: "bridgeRoad", recursively: true)).clone())
        XCTAssertTrue(BuildingRenderGeometry.vertices(from: roadScene).allSatisfy { $0.position.z >= 4 })
        XCTAssertNotNil(scene.rootNode.childNode(withName: "bridgeCables", recursively: true))
        XCTAssertNotNil(scene.rootNode.childNode(withName: "bridgeRoad", recursively: true))
    }
}
