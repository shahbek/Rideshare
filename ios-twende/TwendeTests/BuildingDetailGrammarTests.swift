import XCTest
import SceneKit
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class BuildingDetailGrammarTests: XCTestCase {
    func testRulesOfferSevenTreatmentsWithoutConflictingPlacement() {
        var treatments: Set<BuildingDetailGrammar.Treatment> = []
        for order in BuildingIdentity.Order.allCases {
            for variant in 0..<4 {
                let identity = BuildingIdentity(seed: UInt64(order.rawValue) | (UInt64(variant) << 36))
                let grammar = BuildingDetailGrammar(identity: identity)
                for floor in 0..<5 {
                    for bay in 0..<4 {
                        let choice = grammar.treatment(floor: floor, bay: bay, width: 4.5, storey: 3.6, isEntry: false, isCourtyard: false)
                        treatments.insert(choice)
                        if floor == 0 { XCTAssertNotEqual(choice, .balcony) }
                        XCTAssertEqual(choice, grammar.treatment(floor: floor, bay: bay, width: 4.5, storey: 3.6, isEntry: false, isCourtyard: false))
                        XCTAssertEqual(grammar.treatment(floor: floor, bay: bay, width: 2, storey: 3.6, isEntry: false, isCourtyard: false), .none)
                        XCTAssertEqual(grammar.treatment(floor: floor, bay: bay, width: 4.5, storey: 3.6, isEntry: true, isCourtyard: false), .none)
                        XCTAssertEqual(grammar.treatment(floor: floor, bay: bay, width: 4.5, storey: 3.6, isEntry: false, isCourtyard: true), .none)
                    }
                }
            }
        }
        XCTAssertEqual(treatments, Set(BuildingDetailGrammar.Treatment.allCases))
    }

    func testEveryTreatmentCreatesFiniteGeometryWithinBudget() {
        for treatment in BuildingDetailGrammar.Treatment.allCases where treatment != .none {
            var details = BuildingFacadeDetails(limit: 1)
            for _ in 0..<5 {
                details.bay(treatment, start: .zero, tangent: SIMD2(1, 0), outward: SIMD2(0, -1), left: 1.2, right: 3.2, sill: 4.5, lintel: 6.6, floorTop: 7.2, bayLeft: 0, bayRight: 4.5)
            }
            XCTAssertEqual(details.treatmentCount, 1, "Bounded embellishment budget must be enforced")
            let scene = SCNScene()
            details.addNodes(to: scene.rootNode, identity: BuildingIdentity(seed: 1))
            let vertices = BuildingRenderGeometry.vertices(from: scene)
            XCTAssertFalse(vertices.isEmpty, "\(treatment) cannot be just a named empty node")
            XCTAssertLessThan(vertices.count, 4_000)
            XCTAssertTrue(vertices.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.normal.z.isFinite })
            XCTAssertTrue(vertices.allSatisfy { $0.position.z > 3.5 && $0.position.z < 7.2 })
        }
    }

    func testFamiliesIntegrateDetailsAndRoleCorrectRoofMaterials() throws {
        let origin = DarEsSalaam.upanga
        let ring = [origin, origin.offset(eastMetres: 24, northMetres: 0), origin.offset(eastMetres: 24, northMetres: 18), origin.offset(eastMetres: 0, northMetres: 18), origin].map(\.coordinate)
        let geometry = Geometry.polygon(Polygon([ring]))
        for order in BuildingIdentity.Order.allCases {
            let identity = BuildingIdentity(seed: UInt64(order.rawValue))
            let building = BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: 14.4, roofStyle: order == .domed ? .dome : order == .vaulted ? .vault : [.doric, .ionic, .corinthian].contains(order) ? .gable : .terrace, identity: identity)
            switch order {
            case .doric, .ionic, .corinthian:
                XCTAssertNotNil(building.childNode(withName: "roofDentils", recursively: true))
                XCTAssertNotNil(building.childNode(withName: "facadeStoneDetails", recursively: true))
                let tiles = try XCTUnwrap(building.childNode(withName: "spanishBarrelTiles", recursively: true)?.geometry?.firstMaterial?.diffuse.contents as? UIColor)
                XCTAssertEqual(tiles, BuildingSurfaces.color(identity.tileHex))
            case .gallery:
                XCTAssertNotNil(building.childNode(withName: "facadeShuttersAndScreens", recursively: true))
                XCTAssertNotNil(building.childNode(withName: "roofBalusters", recursively: true))
            case .roman, .terraced:
                XCTAssertNotNil(building.childNode(withName: "roofBalusters", recursively: true))
            case .domed:
                let roof = try XCTUnwrap(building.childNode(withName: "continuousDome", recursively: true)?.geometry?.firstMaterial?.diffuse.contents as? UIColor)
                XCTAssertEqual(roof, BuildingSurfaces.color(identity.metalHex))
            case .vaulted:
                XCTAssertNotNil(building.childNode(withName: "facadeShuttersAndScreens", recursively: true))
            }
            let scene = SCNScene(); scene.rootNode.addChildNode(building)
            XCTAssertLessThan(BuildingRenderGeometry.vertices(from: scene).count, 180_000)
        }
    }
}
