import XCTest
import SceneKit
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class BuildingDetailTests: XCTestCase {
    func testEnvelopeCoversTallestKnownPartWithoutTruncation() {
        XCTAssertGreaterThan(BuildingEnvelope.roof(height: 12, relatedHeights: [34.1, 19]), 34.1)
        XCTAssertGreaterThan(BuildingEnvelope.roof(height: 650), 650)
        XCTAssertGreaterThan(BuildingEnvelope.roof(height: 1100), 1100)
        XCTAssertTrue(BuildingEnvelope.roof(height: .nan, relatedHeights: [.infinity, -2]).isFinite)
    }
    func testDomeTilesAndLightsAreActualBakedGeometry() throws {
        let origin = DarEsSalaam.upanga
        let ring = [origin, origin.offset(eastMetres: 24, northMetres: 0), origin.offset(eastMetres: 24, northMetres: 18), origin.offset(eastMetres: 0, northMetres: 18), origin].map(\.coordinate)
        let geometry = Geometry.polygon(Polygon([ring]))
        let domed = BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: 14, identity: BuildingIdentity(seed: 4))
        XCTAssertNotNil(domed.childNode(withName: "domeRibsAndLantern", recursively: true))
        let greek = BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: 14, identity: BuildingIdentity(seed: 0))
        XCTAssertNotNil(greek.childNode(withName: "spanishBarrelTiles", recursively: true))
        let scene = SCNScene(); scene.rootNode.addChildNode(greek)
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        XCTAssertTrue(vertices.contains { $0.appearance.z > 0.8 }, "Lighting must reach the Metal shader")
        XCTAssertTrue(vertices.allSatisfy { $0.position.x.isFinite && $0.normal.x.isFinite })
        XCTAssertLessThan(vertices.count, 180_000)
    }
    func testMaterialPalettesCannotAssignPurpleWallsOrBlueRoofs() {
        XCTAssertEqual(BuildingIdentity.colors.count, 16)
        for hex in BuildingIdentity.colors {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            BuildingSurfaces.color(hex).getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertFalse(b > r + 0.12 && r > g + 0.08, "No purple painted walls")
            XCTAssertGreaterThan(max(r, g, b), 0.55, "Keep materials legible rather than muddy")
        }
        for hex in BuildingIdentity.pitchedRoofs + BuildingIdentity.metalRoofs {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            BuildingSurfaces.color(hex).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            XCTAssertFalse(h > 0.50 && h < 0.83 && s > 0.10, "Roof palettes cannot contain blue or purple")
        }
    }
}
