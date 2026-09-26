import XCTest
import SceneKit
import simd
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class BuildingMorphologyTests: XCTestCase {
    func testSameFootprintChangesFromVillaToVerticalTowerWithHeight() {
        let footprint = BuildingFootprint(rings: [[SIMD2(0, 0), SIMD2(24, 0), SIMD2(24, 18), SIMD2(0, 18)]])
        let identity = BuildingIdentity(seed: 0)
        let low = BuildingMorphology(footprint: footprint, height: 12, identity: identity)
        let high = BuildingMorphology(footprint: footprint, height: 90, identity: identity)
        XCTAssertEqual(low.family, .villa)
        XCTAssertEqual(low.roofStyle, .gable)
        XCTAssertEqual(high.family, .slenderTower)
        XCTAssertEqual(high.roofStyle, .terrace, "Random Greek orders must not put cottage roofs on high-rises")
        XCTAssertTrue(high.usesVerticalRibs)
        XCTAssertFalse(high.hasClassicalOrnaments)
        XCTAssertEqual(high.crownLevels, 3)
        XCTAssertGreaterThan(high.windowRatio, low.windowRatio)
        XCTAssertEqual(low.identity.wallHex, high.identity.wallHex, "A morphology change must not reshuffle the material identity")
    }

    func testMetricsAndDecisionsAreInvariantUnderRotationAndTranslation() {
        let shape: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(58, 0), SIMD2(58, 20), SIMD2(0, 20)]
        let original = BuildingFootprint(rings: [shape])
        let baseline = BuildingMorphology(footprint: original, height: 11, identity: BuildingIdentity(seed: 6))
        XCTAssertEqual(baseline.family, .marketHall)
        for angle in [0.25, 0.83, 1.7, 2.43] {
            let transformed = shape.map { p in SIMD2(p.x * cos(angle) - p.y * sin(angle) + 430, p.x * sin(angle) + p.y * cos(angle) - 170) }
            let form = BuildingMorphology(footprint: BuildingFootprint(rings: [transformed]), height: 11, identity: BuildingIdentity(seed: 6))
            XCTAssertEqual(form.metrics.width, 20, accuracy: 0.01)
            XCTAssertEqual(form.metrics.length, 58, accuracy: 0.01)
            XCTAssertEqual(form.metrics.area, baseline.metrics.area, accuracy: 0.001)
            XCTAssertEqual(form.family, baseline.family)
            XCTAssertEqual(form.roofStyle, baseline.roofStyle)
        }
    }

    func testCourtyardsConcaveAndRoundFootprintsUseCompatibleForms() {
        let outer = [SIMD2<Double>(0, 0), SIMD2(40, 0), SIMD2(40, 40), SIMD2(0, 40)]
        let inner = [SIMD2<Double>(14, 14), SIMD2(14, 26), SIMD2(26, 26), SIMD2(26, 14)]
        let courtyard = BuildingMorphology(footprint: BuildingFootprint(rings: [outer, inner]), height: 20, identity: BuildingIdentity(seed: 0))
        XCTAssertEqual(courtyard.family, .courtyard)
        XCTAssertEqual(courtyard.roofStyle, .terrace)
        let lShape = [SIMD2<Double>(0, 0), SIMD2(30, 0), SIMD2(30, 9), SIMD2(9, 9), SIMD2(9, 30), SIMD2(0, 30)]
        let corner = BuildingMorphology(footprint: BuildingFootprint(rings: [lShape]), height: 20, identity: BuildingIdentity(seed: 2))
        XCTAssertEqual(corner.family, .cornerBlock)
        XCTAssertEqual(corner.roofStyle, .terrace)
        let circle: [SIMD2<Double>] = (0..<16).map { i -> SIMD2<Double> in
            let angle: Double = Double(i) * Double.pi / 8.0
            return SIMD2<Double>(cos(angle) * 18.0, sin(angle) * 18.0)
        }
        let rotunda = BuildingMorphology(footprint: BuildingFootprint(rings: [circle]), height: 16, identity: BuildingIdentity(seed: 7))
        XCTAssertEqual(rotunda.family, .rotunda)
        XCTAssertEqual(rotunda.roofStyle, .dome)
    }

    func testAllFourteenMorphologyRulesAreReachable() {
        var families: Set<BuildingMorphology.Family> = []
        for (width, length, height) in [(8.0, 12.0, 7.0), (7, 24, 20), (18, 24, 12), (20, 60, 10), (32, 40, 18), (18, 24, 23), (18, 24, 30), (16, 24, 90), (14, 50, 50), (30, 35, 40)] {
            let footprint = BuildingFootprint(rings: [[SIMD2(0, 0), SIMD2(length, 0), SIMD2(length, width), SIMD2(0, width)]])
            for seed in stride(from: UInt64(0), to: 256, by: 8) {
                families.insert(BuildingMorphology(footprint: footprint, height: height, identity: BuildingIdentity(seed: seed)).family)
            }
        }
        let outer = [SIMD2<Double>(0, 0), SIMD2(40, 0), SIMD2(40, 40), SIMD2(0, 40)]
        let inner = [SIMD2<Double>(14, 14), SIMD2(14, 26), SIMD2(26, 26), SIMD2(26, 14)]
        let lShape = [SIMD2<Double>(0, 0), SIMD2(30, 0), SIMD2(30, 9), SIMD2(9, 9), SIMD2(9, 30), SIMD2(0, 30)]
        let circle: [SIMD2<Double>] = (0..<16).map { i -> SIMD2<Double> in
            let angle: Double = Double(i) * Double.pi / 8.0
            return SIMD2<Double>(cos(angle) * 18.0, sin(angle) * 18.0)
        }
        for rings in [[outer, inner], [lShape], [circle]] {
            families.insert(BuildingMorphology(footprint: BuildingFootprint(rings: rings), height: 20, identity: BuildingIdentity(seed: 0)).family)
        }
        XCTAssertEqual(families, Set(BuildingMorphology.Family.allCases))
    }

    func testNewRoofSurfacesAndGlazingBakeWithinOriginalFootprint() throws {
        let corners = [SIMD2<Double>(0, 0), SIMD2(40, 0), SIMD2(40, 18), SIMD2(0, 18)]
        let footprint = BuildingFootprint(rings: [corners])
        for style in [BuildingRoof.Style.mansard, .sawtooth] {
            let roof = BuildingRoof.make(footprint: footprint, eave: 22, style: style, trim: BuildingSurfaces.wall(.royalStone), variant: 2)
            XCTAssertNotNil(roof.childNode(withName: "roofDeck", recursively: true))
            XCTAssertNotNil(roof.childNode(withName: style == .mansard ? "dormerGlass" : "clerestoryGlass", recursively: true))
            let scene = SCNScene(); scene.rootNode.addChildNode(roof)
            let vertices = BuildingRenderGeometry.vertices(from: scene)
            XCTAssertTrue(vertices.contains { $0.appearance.w == 1 }, "Roof glazing needs the same environment sheen as windows")
            XCTAssertLessThan(vertices.count, 10_000)
            for v in vertices {
                XCTAssertTrue(v.position.x.isFinite && v.normal.x.isFinite)
                XCTAssertGreaterThanOrEqual(v.position.x, -0.01)
                XCTAssertLessThanOrEqual(v.position.x, 40.01)
                XCTAssertGreaterThanOrEqual(v.position.y, -0.01)
                XCTAssertLessThanOrEqual(v.position.y, 18.01)
                XCTAssertGreaterThanOrEqual(v.position.z, 22)
            }
        }
        let hollow = BuildingFootprint(rings: [corners, [SIMD2(8, 6), SIMD2(8, 12), SIMD2(30, 12), SIMD2(30, 6)]])
        XCTAssertEqual(BuildingRoof.make(footprint: hollow, eave: 22, style: .mansard, trim: BuildingSurfaces.wall(.royalStone)).name, "roof.terrace")
        XCTAssertEqual(BuildingRoof.make(footprint: hollow, eave: 22, style: .sawtooth, trim: BuildingSurfaces.wall(.royalStone)).name, "roof.terrace")
    }

    func testTallGeneratedBuildingPreservesEnvelopeAndAddsVerticalRibs() throws {
        let origin = DarEsSalaam.upanga
        let ring = [origin, origin.offset(eastMetres: 24, northMetres: 0), origin.offset(eastMetres: 24, northMetres: 18), origin.offset(eastMetres: 0, northMetres: 18), origin].map(\.coordinate)
        for height in [90.0, 600.0] {
            let eave = BuildingEnvelope.roof(height: height)
            let building = BuildingArchitecture.make(geometry: .polygon(Polygon([ring])), origin: origin.coordinate, base: 0, roof: eave, identity: BuildingIdentity(seed: 0))
            XCTAssertNotNil(building.childNode(withName: "towerCrownFins", recursively: true))
            XCTAssertNil(building.childNode(withName: "continuousDome", recursively: true))
            XCTAssertNil(building.childNode(withName: "spanishBarrelTiles", recursively: true))
            let deck = try XCTUnwrap(building.childNode(withName: "roofDeck", recursively: true))
            let scene = SCNScene(); scene.rootNode.addChildNode(deck.clone())
            XCTAssertTrue(BuildingRenderGeometry.vertices(from: scene).allSatisfy { $0.position.z > Float(height) })
            let fullScene = SCNScene(); fullScene.rootNode.addChildNode(building)
            XCTAssertLessThan(BuildingRenderGeometry.vertices(from: fullScene).count, 100_000)
        }
    }

    func testNewFacadeColoursStayNaturalAndOrderIndependent() {
        XCTAssertEqual(BuildingIdentity.colors.count, 16)
        for seed in stride(from: UInt64(0), to: 4096, by: 256) {
            let identity = BuildingIdentity(seed: seed)
            for order in BuildingIdentity.Order.allCases {
                let adjusted = identity.withOrder(order)
                XCTAssertEqual(adjusted.paletteIndex, identity.paletteIndex)
                XCTAssertEqual(adjusted.variant(channel: 3, count: 8), identity.variant(channel: 3, count: 8))
                XCTAssertEqual(adjusted.wallHex, identity.wallHex)
            }
            let color = BuildingSurfaces.color(identity.wallHex)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertFalse(b > r + 0.12 && r > g + 0.08, "No purple painted walls")
            XCTAssertGreaterThan(max(r, g, b), 0.55)
        }
    }
}
