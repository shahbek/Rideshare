import XCTest
import SceneKit
import simd
@testable import Twende

@MainActor
final class TanzanitePylonTests: XCTestCase {
    func testPhotoGuidedThicknessAndCurvedShoulders() {
        for central in [true, false] {
            let profile = TanzanitePylonProfile(deckElevation: 20, isCentral: central)
            let foot = profile.section(at: 0)
            let shoulder = profile.section(at: 20)
            let tip = profile.section(at: profile.topElevation)
            XCTAssertEqual(foot.width, central ? 4.8 : 3.8, accuracy: 0.001)
            XCTAssertEqual(shoulder.width, central ? 4.2 : 3.6, accuracy: 0.001)
            XCTAssertEqual(tip.width, central ? 3.3 : 3.2, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(tip.depth, 4.5, "Broad blade faces, not skinny cylindrical poles")
            XCTAssertGreaterThan(shoulder.offset, foot.offset + 3)
            XCTAssertLessThan(tip.offset, shoulder.offset)
            let a = profile.section(at: 19.99).offset, b = profile.section(at: 20).offset, c = profile.section(at: 20.01).offset
            XCTAssertEqual((b - a) / 0.01, (c - b) / 0.01, accuracy: 0.005, "The curve must not kink at deck height")
            for section in profile.sections {
                XCTAssertTrue(section.offset.isFinite && section.width.isFinite && section.depth.isFinite)
                XCTAssertGreaterThan(section.width, 3)
            }
        }
    }

    func testFullRoadwayAndHeadroomRemainOpen() {
        for central in [true, false] {
            let profile = TanzanitePylonProfile(deckElevation: 20, isCentral: central)
            for z in stride(from: 20.0, through: 26.0, by: 0.25) {
                let section = profile.section(at: z)
                XCTAssertGreaterThan(section.offset - section.width / 2, 10.25, "Pillars must remain outside the 20.5m deck for traffic headroom")
            }
        }
    }

    func testCableSocketsMatchTheActualPylonFacesAtEveryStation() throws {
        let alignment = try XCTUnwrap(TanzaniteBridgeAlignment.load())
        for (index, station) in alignment.record.pylonChainages.enumerated() {
            let profile = TanzanitePylonProfile(deckElevation: alignment.deckElevation(at: station), isCentral: index == 2)
            let origin = alignment.point(at: station, elevation: 0)
            let forward = alignment.tangent(at: station)
            let across = simd_cross(SIMD3<Double>(0, 0, 1), forward)
            for side in [-1.0, 1.0] {
                for direction in [-1.0, 1.0] {
                    for cable in 0..<10 {
                        let anchor = TanzaniteProceduralPylons.cableAnchor(alignment: alignment, station: station, isCentral: index == 2, side: side, direction: direction, index: cable)
                        let local = anchor - origin
                        let section = profile.section(at: anchor.z)
                        XCTAssertEqual(simd_dot(local, across), side * section.offset, accuracy: 0.001)
                        XCTAssertEqual(simd_dot(local, forward), direction * (section.depth / 2 + 0.16), accuracy: 0.001)
                        XCTAssertLessThan(anchor.z, profile.topElevation)
                        XCTAssertGreaterThan(anchor.z, profile.deckElevation)
                    }
                }
            }
        }
    }

    func testBakedConcreteRetainsBroadFacesAndSmoothCurves() throws {
        let alignment = try XCTUnwrap(TanzaniteBridgeAlignment.load())
        for central in [true, false] {
            let station = alignment.record.pylonChainages[central ? 2 : 0]
            let root = TanzaniteProceduralPylons.make(alignment: alignment, station: station, isCentral: central)
            let leg = try XCTUnwrap(root.childNode(withName: "pylonLeg.right", recursively: true))
            let scene = SCNScene(); scene.rootNode.addChildNode(leg.clone())
            let vertices = BuildingRenderGeometry.vertices(from: scene)
            XCTAssertGreaterThan(vertices.count, 2_000)
            XCTAssertLessThan(vertices.count, 5_000)
            let profile = TanzanitePylonProfile(deckElevation: alignment.deckElevation(at: station), isCentral: central)
            let section = profile.sections[TanzanitePylonProfile.samplingSteps / 2]
            let ring = vertices.filter { abs(Double($0.position.z) - section.elevation) < 0.0001 }
            XCTAssertFalse(ring.isEmpty)
            let forward = alignment.tangent(at: station), across = simd_cross(SIMD3<Double>(0, 0, 1), forward)
            let origin = alignment.point(at: station, elevation: 0)
            let widths = ring.map { vertex -> Double in
                simd_dot(SIMD3(Double(vertex.position.x), Double(vertex.position.y), Double(vertex.position.z)) - origin, across)
            }
            let depths = ring.map { vertex -> Double in
                simd_dot(SIMD3(Double(vertex.position.x), Double(vertex.position.y), Double(vertex.position.z)) - origin, forward)
            }
            XCTAssertEqual((widths.max() ?? 0) - (widths.min() ?? 0), section.width, accuracy: 0.001)
            XCTAssertEqual((depths.max() ?? 0) - (depths.min() ?? 0), section.depth, accuracy: 0.001)
            XCTAssertTrue(vertices.allSatisfy { v in
                let n = SIMD3(v.normal.x, v.normal.y, v.normal.z)
                return n.x.isFinite && n.y.isFinite && n.z.isFinite && abs(simd_length(n) - 1) < 0.001
            })
            XCTAssertNotNil(root.childNode(withName: "pylonLeg.left", recursively: true))
            XCTAssertEqual(root.childNode(withName: "pylonCrosshead", recursively: true) != nil, central)
        }
    }

    func testGemHasFacetedShoulderFlatTableAndNativeEmission() throws {
        let alignment = try XCTUnwrap(TanzaniteBridgeAlignment.load())
        let scene = TanzaniteBridgeGeometry.make(alignment: alignment)
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        let gem = vertices.filter { $0.appearance.w == 2 }
        XCTAssertGreaterThan(gem.count, 200)
        XCTAssertTrue(gem.allSatisfy { $0.appearance.z > 1 && $0.color.z > $0.color.x + 0.2 })
        XCTAssertEqual(gem.map { $0.position.z }.min() ?? 0, 75, accuracy: 0.001)
        XCTAssertEqual(gem.map { $0.position.z }.max() ?? 0, 83.5, accuracy: 0.001)
        let levels = TanzaniteCrown.gemLevels
        XCTAssertGreaterThan(levels[3].x, levels[0].x * 4)
        XCTAssertGreaterThan(levels[3].x, (levels.last?.x ?? 0) * 1.8)
        for face in 0..<8 {
            XCTAssertNotNil(scene.rootNode.childNode(withName: "tanzaniteGemFacet.\(face)", recursively: true))
        }
        XCTAssertNil(scene.rootNode.childNode(withName: "proceduralTorchFlame", recursively: true))
        let halo = vertices.filter { $0.appearance.w == 3 }
        XCTAssertGreaterThan(halo.count, 1_000)
        XCTAssertTrue(halo.allSatisfy { $0.color.z > $0.color.x && $0.normal.x.isFinite })
        XCTAssertGreaterThan(halo.map { $0.position.z }.max() ?? 0, 83.5)
    }

    func testConcreteTextureIsConfinedToBridgeConcrete() throws {
        let alignment = try XCTUnwrap(TanzaniteBridgeAlignment.load())
        let scene = TanzaniteBridgeGeometry.make(alignment: alignment)
        for name in ["pylonLeg.left", "pylonCrosshead", "crownConcreteSeat", "bridgeConcrete"] {
            let node = try XCTUnwrap(scene.rootNode.childNode(withName: name, recursively: true))
            let isolated = SCNScene(); isolated.rootNode.addChildNode(node.clone())
            let vertices = BuildingRenderGeometry.vertices(from: isolated)
            XCTAssertFalse(vertices.isEmpty)
            XCTAssertTrue(vertices.allSatisfy { $0.appearance.w == -4 && $0.appearance.z == 0 })
        }
        for name in ["bridgeRoad", "bridgeCables", "tanzaniteCrownFins"] {
            let node = try XCTUnwrap(scene.rootNode.childNode(withName: name, recursively: true))
            let isolated = SCNScene(); isolated.rootNode.addChildNode(node.clone())
            XCTAssertTrue(BuildingRenderGeometry.vertices(from: isolated).allSatisfy { $0.appearance.w == 0 })
        }
    }

    func testBridgeHasExactlyOnePortalAndFourSidePylonPairs() throws {
        let alignment = try XCTUnwrap(TanzaniteBridgeAlignment.load())
        let scene = TanzaniteBridgeGeometry.make(alignment: alignment)
        XCTAssertEqual(scene.rootNode.childNodes.filter { $0.name == "centralProceduralPylon" }.count, 1)
        XCTAssertEqual(scene.rootNode.childNodes.filter { $0.name == "sideProceduralPylon" }.count, 4)
        XCTAssertNotNil(scene.rootNode.childNode(withName: "tanzaniteGemFacet.0", recursively: true))
        XCTAssertNotNil(scene.rootNode.childNode(withName: "bridgeCableSockets", recursively: true))
        let a = BuildingRenderGeometry.vertices(from: scene)
        let b = BuildingRenderGeometry.vertices(from: TanzaniteBridgeGeometry.make(alignment: alignment))
        XCTAssertEqual(a.map(\.position), b.map(\.position))
        XCTAssertLessThan(a.count, 150_000)
    }
}
