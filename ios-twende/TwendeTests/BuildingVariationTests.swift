import XCTest
import SceneKit
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class BuildingVariationTests: XCTestCase {
    func testIdentityIsStableAndProducesBroadVariation() {
        let origin = DarEsSalaam.upanga
        var palettes: Set<Int> = [], orders: Set<Int> = []
        // The palette doubled to sixteen finishes; use enough fixed geographic samples to exercise all.
        for i in 0..<256 {
            let p = origin.offset(eastMetres: Double(i) * 35, northMetres: Double(i % 7) * 40)
            let ring = [p, p.offset(eastMetres: 24, northMetres: 0), p.offset(eastMetres: 24, northMetres: 18), p.offset(eastMetres: 0, northMetres: 18), p].map(\.coordinate)
            let identity = BuildingIdentity(geometry: .polygon(Polygon([ring])))
            let reversed = BuildingIdentity(geometry: .polygon(Polygon([Array(ring.reversed())])))
            XCTAssertEqual(identity.seed, reversed.seed)
            XCTAssertNotEqual(identity.wallHex, identity.roofHex)
            palettes.insert(identity.paletteIndex); orders.insert(identity.order.rawValue)
        }
        XCTAssertEqual(palettes.count, BuildingIdentity.colors.count)
        XCTAssertEqual(orders.count, 8)
    }

    func testAllEightFamiliesHaveDistinctGeometryAndClosedRoofs() throws {
        let origin = DarEsSalaam.upanga
        let ring = [origin, origin.offset(eastMetres: 24, northMetres: 0), origin.offset(eastMetres: 24, northMetres: 18), origin.offset(eastMetres: 0, northMetres: 18), origin].map(\.coordinate)
        var counts: Set<Int> = []
        for order in BuildingIdentity.Order.allCases {
            let node = BuildingArchitecture.make(geometry: .polygon(Polygon([ring])), origin: origin.coordinate, base: 0, roof: 14.5, roofStyle: order == .domed ? .dome : order == .vaulted ? .vault : [.doric, .ionic, .corinthian].contains(order) ? .gable : .terrace, identity: BuildingIdentity(seed: UInt64(order.rawValue)))
            XCTAssertNotNil(node.childNode(withName: "roofDeck", recursively: true))
            switch order {
            case .doric, .ionic, .corinthian, .roman, .gallery:
                XCTAssertNotNil(node.childNode(withName: "order.\(order)", recursively: true))
            case .domed: XCTAssertNotNil(node.childNode(withName: "continuousDome", recursively: true))
            case .vaulted: XCTAssertNotNil(node.childNode(withName: "continuousVault", recursively: true))
            case .terraced: XCTAssertNotNil(node.childNode(withName: "roof.terrace", recursively: true))
            }
            let scene = SCNScene(); scene.rootNode.addChildNode(node)
            let vertices = BuildingRenderGeometry.vertices(from: scene)
            XCTAssertFalse(vertices.isEmpty)
            XCTAssertLessThan(vertices.count, 180_000)
            XCTAssertTrue(vertices.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite && $0.normal.x.isFinite })
            counts.insert(vertices.count)
        }
        XCTAssertGreaterThanOrEqual(counts.count, 7, "The orders must not be the same box with a new label")
    }

    func testSameIdentityProducesSameColoursAndGeometryAcrossSceneOrigins() {
        let origin = DarEsSalaam.upanga
        let ring = [origin, origin.offset(eastMetres: 24, northMetres: 0), origin.offset(eastMetres: 24, northMetres: 18), origin.offset(eastMetres: 0, northMetres: 18), origin].map(\.coordinate)
        let geometry = Geometry.polygon(Polygon([ring]))
        let identity = BuildingIdentity(geometry: geometry)
        let first = BuildingArchitecture.make(geometry: geometry, origin: origin.coordinate, base: 0, roof: 12, identity: identity)
        let second = BuildingArchitecture.make(geometry: geometry, origin: origin.offset(eastMetres: 80, northMetres: 40).coordinate, base: 0, roof: 12, identity: identity)
        let a = first.childNode(withName: "walls", recursively: true)?.geometry?.firstMaterial?.diffuse.contents as? UIColor
        let b = second.childNode(withName: "walls", recursively: true)?.geometry?.firstMaterial?.diffuse.contents as? UIColor
        XCTAssertEqual(a, b)
        XCTAssertEqual(first.childNodes.map(\.name), second.childNodes.map(\.name))
    }
}
