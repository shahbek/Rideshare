import XCTest
import SceneKit
import simd
import UIKit
@_spi(Experimental) import MapboxMaps
@testable import Twende

@MainActor
final class DarLandmarkTests: XCTestCase {
    func testCatalogContainsVerifiedDistinctFootprintsAndSources() throws {
        XCTAssertEqual(DarLandmarkSite.all.count, 4)
        XCTAssertEqual(Set(DarLandmarkSite.all.map(\.osmWay)), [688369839, 368909370, 688369315, 688369331])
        for site in DarLandmarkSite.all {
            let footprint = try XCTUnwrap(site.footprint)
            let area = abs(BuildingFootprint.area(try XCTUnwrap(footprint.rings.first)))
            XCTAssertGreaterThan(area, 650, site.id)
            XCTAssertLessThan(area, 1200, site.id)
            XCTAssertEqual(site.ring.first, site.ring.last)
            XCTAssertTrue(site.photo.hasPrefix("https://"))
            XCTAssertFalse(site.orientationEvidence.isEmpty)
            XCTAssertFalse(site.heightEvidence.isEmpty)
            XCTAssertTrue(site.matches(site.geometry))
            XCTAssertTrue(DarLandmarkSite.isBespoke(site.geometry))
            for other in DarLandmarkSite.all where site.id != other.id { XCTAssertFalse(site.matches(other.geometry), "\(site.id) must not clip \(other.id)") }
            XCTAssertEqual(site.right.x * site.inward.y - site.right.y * site.inward.x, 1, accuracy: 0.000001)
        }
    }

    func testEachMeshIsFiniteBoundedAndKeepsItsMappedFoundation() throws {
        for site in DarLandmarkSite.all {
            let scene = DarLandmarkGeometry.make(site)
            let vertices = BuildingRenderGeometry.vertices(from: scene)
            XCTAssertGreaterThan(vertices.count, 3000, site.id)
            XCTAssertLessThan(vertices.count, 160000, site.id)
            XCTAssertTrue(vertices.allSatisfy { v in
                v.position.x.isFinite && v.position.y.isFinite && v.position.z.isFinite &&
                v.normal.x.isFinite && v.normal.y.isFinite && v.normal.z.isFinite &&
                abs(simd_length(v.normal) - 1) < 0.001 && v.position.z >= -0.01 && v.position.z < Float(site.height + 0.2)
            }, site.id)
            guard case .polygon(let expanded) = BuildingIllumination.expanded(site.geometry, by: 0.9) else { return XCTFail("Missing polygon") }
            let path = try XCTUnwrap(BuildingFootprint(coordinates: expanded.coordinates, origin: site.anchor.coordinate)).path
            let outside = vertices.filter { !path.contains(CGPoint(x: Double($0.position.x), y: Double($0.position.y))) }
            XCTAssertTrue(outside.isEmpty, "\(site.id) must not extend onto adjoining roads: \(outside.prefix(6).map(\.position))")
            let foundationName = site.kind == "tower" ? "pspfFoundation" : "mappedChurchWalls"
            XCTAssertNotNil(scene.rootNode.childNode(withName: foundationName, recursively: true))
            XCTAssertEqual(vertices.map { $0.position.z }.max() ?? 0, Float(site.height), accuracy: 0.2)
        }
    }

    func testDistinctSilhouettesAndFrontFacingFeatures() throws {
        for site in DarLandmarkSite.all {
            let scene = DarLandmarkGeometry.make(site)
            let root = try XCTUnwrap(scene.rootNode.childNode(withName: site.id, recursively: true))
            XCTAssertGreaterThan(simd_determinant(root.simdTransform), 0.99)
            let feature: String
            switch site.kind {
            case "cathedral":
                feature = "cathedralOctagonalSpire"
                XCTAssertNotNil(root.childNode(withName: "cathedralTriplePortal", recursively: true))
                let tower = try XCTUnwrap(root.childNode(withName: "cathedralNortheastTower", recursively: true))
                let bounds = tower.boundingBox
                let local = SIMD2(Double((bounds.min.x + bounds.max.x) / 2), Double((bounds.min.y + bounds.max.y) / 2))
                let world = site.right * local.x + site.inward * local.y
                XCTAssertGreaterThan(world.x, 0, "Tower belongs on northeast side")
            case "lutheran":
                feature = "azaniaPyramidalBelfryRoof"
                XCTAssertNotNil(root.childNode(withName: "azaniaClockFace", recursively: true))
                XCTAssertNil(root.childNode(withName: "cathedralOctagonalSpire", recursively: true))
            default:
                feature = "pspfSlopingLatticeCrown"
                XCTAssertNotNil(root.childNode(withName: "pspfAsymmetricGoldBands", recursively: true))
                XCTAssertEqual(site.height, 152.7)
            }
            XCTAssertNotNil(root.childNode(withName: feature, recursively: true), site.id)
        }
    }

    func testNewLandmarksRenderWithNativeClippingAndProtectedLabels() async {
        for id in ["st-joseph", "azania", "pspf-se", "pspf-nw"] {
            let result = await MapRenderProbe().run(.cityLandmark(id))
            XCTAssertTrue(result.styleLoaded, "\(id): \(result)")
            XCTAssertGreaterThan(result.architectureContribution, 100, "\(id): actual custom mesh must render: \(result)")
            XCTAssertGreaterThan(result.nativeClipContribution, 20, "\(id): native extrusion must be removed: \(result)")
            XCTAssertGreaterThan(result.labelInkBefore, 50, "\(id): \(result)")
            XCTAssertGreaterThanOrEqual(result.labelInkAfter, Int(Double(result.labelInkBefore) * 0.95), "\(id): \(result)")
            XCTAssertTrue(result.landmarkLifecycleRestored, "\(id): \(result)")
            XCTAssertFalse(result.errors.contains { $0.hasPrefix("apply:") }, "\(id): \(result)")
        }
    }
}
