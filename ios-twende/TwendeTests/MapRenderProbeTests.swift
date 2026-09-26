import Foundation
@_spi(Experimental) import MapboxMaps
import Testing
@testable import Twende

/// Empirical render checks: each candidate 3D vehicle pipeline is drawn on a live Mapbox map on the
/// simulator and passes only if pixels around the anchor actually changed.
@Suite(.serialized)
@MainActor
struct MapRenderProbeTests {
    private static let duck = URL(string: "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/Duck/glTF-Binary/Duck.glb")!
    private static let bundled = Bundle.main.url(forResource: "vehicle_economy", withExtension: "glb")
    private static let flattened = Bundle.main.url(forResource: "vehicle_economy_flat", withExtension: "glb")

    @Test func noiseFloor() async {
        let result = await MapRenderProbe().run(.none)
        print("[probe] none: \(result)")
        #expect(result.styleLoaded, "\(result)")
        #expect(result.mapChanged >= 0 && result.mapChanged < 300, "noise too high: \(result)")
    }

    @Test func modelLayerRemoteDuck() async {
        let result = await MapRenderProbe().run(.modelLayer(url: Self.duck, scale: 30, slot: nil, type: .common3d))
        print("[probe] duck common3d: \(result)")
        #expect(result.mapChanged > 300, "\(result)")
    }

    @Test func modelLayerBundledCommon3D() async throws {
        let url = try #require(Self.bundled)
        let result = await MapRenderProbe().run(.modelLayer(url: url, scale: 10, slot: nil, type: .common3d))
        print("[probe] bundled common3d: \(result)")
        #expect(result.mapChanged > 300, "\(result)")
    }

    @Test func modelLayerBundledLocationIndicator() async throws {
        let url = try #require(Self.bundled)
        let result = await MapRenderProbe().run(.modelLayer(url: url, scale: 10, slot: nil, type: .locationIndicator))
        print("[probe] bundled locationIndicator: \(result)")
        #expect(result.mapChanged > 300, "\(result)")
    }

    @Test func modelLayerFlattenedCommon3D() async throws {
        let url = try #require(Self.flattened)
        let result = await MapRenderProbe().run(.modelLayer(url: url, scale: 10, slot: nil, type: .common3d))
        print("[probe] flattened common3d: \(result)")
        #expect(result.mapChanged > 300, "\(result)")
    }

    @Test func puck3DBundled() async throws {
        let url = try #require(Self.bundled)
        let result = await MapRenderProbe().run(.puck3D(url: url, scale: 20))
        print("[probe] puck3D bundled: \(result)")
        #expect(result.mapChanged > 300, "\(result)")
    }

    @Test func puck3DDuck() async {
        let result = await MapRenderProbe().run(.puck3D(url: Self.duck, scale: 40))
        print("[probe] puck3D duck: \(result)")
        #expect(result.mapChanged > 300, "\(result)")
    }

    @Test func proceduralAnnotation() async {
        let result = await MapRenderProbe().run(.procedural)
        print("[probe] procedural: \(result)")
        #expect(result.hierarchyChanged > 300, "\(result)")
    }
}
