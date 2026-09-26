import XCTest
@testable import Twende

@MainActor
final class BuildingRenderingTests: XCTestCase {
    func testArchitectureRendersWithoutNativeBuildingOcclusion() async {
        let result = await MapRenderProbe().run(.architecture(.royalStone), isolatesGeometry: true)
        XCTAssertTrue(result.styleLoaded, "\(result)")
        XCTAssertGreaterThan(result.mapChanged, 300, "\(result)")
    }

    func testMansardAndSawtoothRenderInTheNativeMapPass() async {
        for roof in [BuildingRoof.Style.mansard, .sawtooth] {
            let result = await MapRenderProbe().run(.architecturalRoof(roof), isolatesGeometry: true)
            XCTAssertTrue(result.styleLoaded, "\(result)")
            XCTAssertGreaterThan(result.mapChanged, 300, "\(roof): \(result)")
            XCTAssertFalse(result.errors.contains { $0.hasPrefix("apply:") }, "\(result)")
        }
    }

    func testGlassTowerDrawsBelowProtectedLabels() async {
        let result = await MapRenderProbe().run(.glassTower, isolatesGeometry: true)
        XCTAssertTrue(result.styleLoaded, "\(result)")
        XCTAssertGreaterThan(result.mapChanged, 300, "\(result)")
        XCTAssertGreaterThan(result.labelInkBefore, 50)
        XCTAssertGreaterThanOrEqual(result.labelInkAfter, Int(Double(result.labelInkBefore) * 0.95), "Labels drawn after geometry must remain unobscured")
    }

    func testTanzaniteLanternGlowContributesNativeMapPixels() async {
        let result = await MapRenderProbe().run(.bridgeCrown, isolatesGeometry: true)
        XCTAssertTrue(result.styleLoaded, "\(result)")
        XCTAssertGreaterThan(result.mapChanged, 100, "\(result)")
        XCTAssertGreaterThan(result.glowContribution, 20, "Removing only the halo must change visible pixels: \(result)")
        XCTAssertFalse(result.errors.contains { $0.hasPrefix("apply:") }, "\(result)")
    }

    func testTanzaniteBridgeRendersAtItsGeographicLocation() async {
        let result = await MapRenderProbe().run(.bridge)
        XCTAssertTrue(result.styleLoaded, "\(result)")
        XCTAssertGreaterThan(result.mapChanged, 100, "\(result)")
        XCTAssertFalse(result.errors.contains { $0.hasPrefix("apply:") }, "\(result)")
    }

    func testRestrainedArchitectureDrawsInsideTheNativeMapPass() async {
        let result = await MapRenderProbe().run(.selectedArchitecture)
        XCTAssertTrue(result.styleLoaded, "\(result)")
        XCTAssertGreaterThan(result.mapChanged, 300, "Native map snapshot must contain the actual building, not just a UIKit overlay: \(result)")
        XCTAssertGreaterThan(result.architectureContribution, 100, "PCG must contribute visible geometry beyond the coloured fallback: \(result)")
        XCTAssertGreaterThan(result.neighbourCount, 0)
        XCTAssertLessThanOrEqual(result.neighbourCount, 8)
        XCTAssertGreaterThan(result.neighbourContribution, 100, "Nearby geometry must render, not merely be registered")
        XCTAssertGreaterThan(result.nativeLabelPixelsBefore, 20, "Fixture must include visible native labels")
        XCTAssertGreaterThan(result.nativeLabelPixelsAfter, 20, "Native labels must still contribute pixels with PCG present")
        XCTAssertFalse(result.errors.contains { $0.hasPrefix("apply:") }, "\(result)")
    }
}
