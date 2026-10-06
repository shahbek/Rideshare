import CryptoKit
import XCTest
@testable import Twende

final class DioramaArchiveTests: XCTestCase {
    @MainActor
    func testInstancedTileCostsLessAndArchivePreservesRendererBuffers() throws {
        var config = DioramaConfig.slipway
        // Geometry is unchanged; smaller albedo is sufficient for a serialization test, not screenshots.
        config.groundImageSize = 256
        config.reducedGroundImageSize = 256
        let data = DioramaMapboxData.resolveOwnership(try XCTUnwrap(DioramaBundledTile.load(config: config)))
        let library = DioramaPropLibrary(config: config)
        var referenceConfig = config
        referenceConfig.instancesArchitecture = false
        let baseline = try DioramaGenerationAudit.$current.withValue(DioramaGenerationAudit(usesCachedCutoutBounds: false)) {
            try DioramaTileGenerator.generate(data, config: referenceConfig, library: library, reduced: false)
        }
        let candidate = try DioramaGenerationAudit.$current.withValue(DioramaGenerationAudit(usesCachedCutoutBounds: true)) {
            try DioramaTileGenerator.generate(data, config: config, library: library, reduced: false)
        }
        XCTAssertLessThan(candidate.totalBytes, baseline.totalBytes)
        XCTAssertLessThan(candidate.totalTriangles, baseline.totalTriangles)
        XCTAssertGreaterThan(candidate.totalInstances, baseline.totalInstances)
        XCTAssertEqual(candidate.drawnTriangles, baseline.drawnTriangles, "Instancing must not remove full-detail faces")
        XCTAssertEqual(candidate.groundImage?.rgba, baseline.groundImage?.rgba)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try DioramaTileArchive.write(candidate, key: "roundtrip", to: directory)
        let restored = try DioramaTileArchive.read(from: directory, key: "roundtrip")
        func digest<T>(_ values: [T]) -> Data {
            values.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) }
        }
        XCTAssertEqual(digest(candidate.vertices), digest(restored.vertices))
        XCTAssertEqual(candidate.indices, restored.indices)
        XCTAssertEqual(digest(candidate.allInstances), digest(restored.allInstances))
        XCTAssertEqual(candidate.groundImage?.rgba, restored.groundImage?.rgba)
        XCTAssertEqual(digest(candidate.groundImage?.paint.triangles ?? []), digest(restored.groundImage?.paint.triangles ?? []))
        XCTAssertEqual(candidate.groundImage?.paint.table, restored.groundImage?.paint.table)
        XCTAssertEqual(candidate.groundImage?.paint.indices, restored.groundImage?.paint.indices)
        XCTAssertEqual(digest(candidate.lightGrid.lights), digest(restored.lightGrid.lights))
        XCTAssertEqual(candidate.lightGrid.table, restored.lightGrid.table)
        XCTAssertEqual(candidate.lightGrid.indices, restored.lightGrid.indices)
        XCTAssertEqual(candidate.drawnTriangles, restored.drawnTriangles)
        XCTAssertEqual(candidate.totalBytes, restored.totalBytes)
        XCTAssertEqual(candidate.buildingLabels.map(\.title), restored.buildingLabels.map(\.title))
        XCTAssertLessThan(bytes, candidate.totalBytes)
        XCTAssertThrowsError(try DioramaTileArchive.read(from: directory, key: "wrong-version"))
        let block = directory.appendingPathComponent("vertices-0.bin")
        try Data([0, 1, 2]).write(to: block)
        XCTAssertThrowsError(try DioramaTileArchive.read(from: directory, key: "roundtrip"))
        let report = "Bundled Slipway; 256px albedo serialization fixture, not live Mapbox coverage\n"
            + "Baked: \(baseline.totalTriangles) unique tris, \(baseline.totalBytes) bytes, \(baseline.generationSeconds)s\n"
            + "Instanced: \(candidate.totalTriangles) unique tris, \(candidate.totalBytes) bytes, \(candidate.generationSeconds)s\n"
            + "Compressed: \(bytes) bytes\n" + candidate.optimizationReport.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "v32-storage-comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[Diorama benchmark] \(report)")
    }
}
