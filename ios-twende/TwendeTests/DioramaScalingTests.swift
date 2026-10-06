import CryptoKit
import Foundation
import XCTest
@testable import Twende

/// Cold CPU benchmarks are deliberately separate from the existing visual/performance acceptance tests.
/// These fixtures use shipped source data, never changing network responses or the app's tile cache.
final class DioramaScalingTests: XCTestCase {
    @MainActor
    func testV31ColdGenerationBaseline() throws {
        try compareColdGeneration(candidate: false)
    }

    @MainActor
    func testCachedCutoutBoundsPreserveFullTilePayload() throws {
        try compareColdGeneration(candidate: true)
    }

    @MainActor
    private func compareColdGeneration(candidate: Bool) throws {
        var config = DioramaConfig.slipway
        config.instancesArchitecture = false
        let bundled = try XCTUnwrap(DioramaBundledTile.load(config: config))
        let data = DioramaMapboxData.resolveOwnership(bundled)
        var reference: [String: String]?
        for iteration in 0..<2 {
            try autoreleasepool {
                let audit = DioramaGenerationAudit(usesCachedCutoutBounds: candidate && iteration == 1)
                let wallStart = DioramaGenerationAudit.now
                let artifacts = try DioramaGenerationAudit.$current.withValue(audit) {
                    let start = DioramaGenerationAudit.now
                    let library = DioramaPropLibrary(config: config)
                    audit.stage("prototype library", seconds: DioramaGenerationAudit.now - start)
                    return try DioramaTileGenerator.generate(data, config: config, library: library, reduced: false)
                }
                let wallSeconds = DioramaGenerationAudit.now - wallStart
                let fingerprints = Self.fingerprints(artifacts)
                XCTAssertFalse(artifacts.hasMapboxCoverage, "This is the frozen bundled-only fixture, not a live-source benchmark")
                XCTAssertGreaterThan(artifacts.totalTriangles, 1000)
                XCTAssertEqual(audit.snapshot().geometry.count, 10)
                XCTAssertGreaterThan(audit.snapshot().operations["cutout.subtract"]?.calls ?? 0, 0)
                if let reference {
                    XCTAssertEqual(fingerprints, reference, "Repeated cold generation must preserve every fingerprinted renderer input bit")
                } else {
                    reference = fingerprints
                }
                let report = Report(fixture: "bundled Slipway + v31 ownership; no Mapbox supplement", iteration: iteration,
                                    cachedCutoutBounds: audit.usesCachedCutoutBounds,
                                    generatorVersion: config.generatorVersion,
                                    os: ProcessInfo.processInfo.operatingSystemVersionString,
                                    processorCount: ProcessInfo.processInfo.processorCount,
                                    wallSecondsIncludingLibrary: wallSeconds,
                                    generatorSeconds: artifacts.generationSeconds,
                                    uniqueTriangles: artifacts.totalTriangles,
                                    fullDrawnTriangles: artifacts.drawnTriangles,
                                    lightDrawnTriangles: artifacts.lightDrawnTriangles,
                                    legacyTotalBytes: artifacts.totalBytes,
                                    paintBytes: Self.paintBytes(artifacts),
                                    lightBytes: Self.lightBytes(artifacts),
                                    fingerprints: fingerprints, audit: audit.snapshot())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = try encoder.encode(report)
                let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
                attachment.name = "slipway-v31-cold-\(iteration)"
                attachment.lifetime = .keepAlways
                add(attachment)
                print("[Diorama benchmark] " + String(decoding: json, as: UTF8.self))
            }
        }
    }

    @MainActor
    func testCachedBoundsPreserveClippingOrderAndDoubleBits() throws {
        let bundled = try XCTUnwrap(DioramaBundledTile.load(config: .slipway))
        let masks = bundled.buildings.flatMap(\.footprints)
        let cutouts = DioramaGroundCutouts(polygons: masks)
        let subjects = Array(masks.prefix(20)) + [
            [DV2(-20, -20), DV2(30, -20), DV2(30, 0), DV2(0, 0), DV2(0, 30), DV2(-20, 30)],
            [DV2(0, 0), DV2(1, 0), DV2(1, 0), DV2(1, 1), DV2(0, 1)],
            [DV2(0, 0), DV2(0.000001, 0), DV2(0, 0.000001)], []
        ]
        func bits(_ pieces: [[DV2]]) -> [[UInt64]] {
            pieces.map { $0.flatMap { [$0.x.bitPattern, $0.y.bitPattern] } }
        }
        for ring in subjects {
            let reference = DioramaGenerationAudit.$current.withValue(DioramaGenerationAudit(usesCachedCutoutBounds: false)) {
                cutouts.subtract(from: ring)
            }
            let candidate = DioramaGenerationAudit.$current.withValue(DioramaGenerationAudit(usesCachedCutoutBounds: true)) {
                cutouts.subtract(from: ring)
            }
            XCTAssertEqual(bits(candidate), bits(reference))
        }
    }

    private struct Report: Encodable {
        let fixture: String
        let iteration: Int
        let cachedCutoutBounds: Bool
        let generatorVersion: Int
        let os: String
        let processorCount: Int
        let wallSecondsIncludingLibrary: Double
        let generatorSeconds: Double
        let uniqueTriangles: Int
        let fullDrawnTriangles: Int
        let lightDrawnTriangles: Int
        let legacyTotalBytes: Int
        let paintBytes: Int
        let lightBytes: Int
        let fingerprints: [String: String]
        let audit: DioramaGenerationAudit.Snapshot
    }

    /// Hash only explicitly packed GPU structs: none contain Bool, reference storage, or padding.
    /// Metadata is encoded separately, component by component (SIMD3 has an unused padding lane).
    private static func hash<T>(_ values: [T]) -> String {
        var digest = SHA256()
        values.withUnsafeBytes { digest.update(bufferPointer: $0) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprints(_ a: DioramaTileArtifacts) -> [String: String] {
        var metadata: [String] = [a.tile.key, String(a.waterHeight.bitPattern), String(a.hasMapboxCoverage)]
        func vector(_ v: SIMD3<Float>) { metadata += [v.x, v.y, v.z].map { String($0.bitPattern) } }
        for range in a.ranges {
            metadata += [range.category.rawValue, String(range.start), String(range.count), String(range.doubleSided)]
            vector(range.minimum); vector(range.maximum)
        }
        for group in a.groups {
            metadata += [group.category.rawValue, String(group.fullStart), String(group.fullCount), String(group.lightStart),
                         String(group.lightCount), String(group.firstInstance), String(group.instances.count), String(group.doubleSided)]
            vector(group.minimum); vector(group.maximum)
        }
        for label in a.buildingLabels {
            metadata += [String(label.id), label.title, String(label.isNamed)]
            vector(label.anchor)
            for p in label.footprint { metadata += [String(p.x.bitPattern), String(p.y.bitPattern)] }
        }
        metadata += [String(a.lightGrid.cells), String(a.lightGrid.minX.bitPattern), String(a.lightGrid.minY.bitPattern),
                     String(a.lightGrid.cellSize.bitPattern), String(a.groundImage?.size ?? 0)]
        return [
            "vertices": hash(a.vertices), "indices": hash(a.indices), "instances": hash(a.allInstances),
            "groundRGBA": hash(a.groundImage?.rgba ?? []),
            "paintTriangles": hash(a.groundImage?.paint.triangles ?? []),
            "paintTable": hash(a.groundImage?.paint.table ?? []),
            "paintIndices": hash(a.groundImage?.paint.indices ?? []),
            "lights": hash(a.lightGrid.lights), "lightTable": hash(a.lightGrid.table), "lightIndices": hash(a.lightGrid.indices),
            "metadata": hash(Array(metadata.joined(separator: "\u{0}").utf8)),
            "shaderSource": hash(Array(DioramaShaderSource.fullSource.utf8))
        ]
    }

    private static func paintBytes(_ a: DioramaTileArtifacts) -> Int {
        guard let paint = a.groundImage?.paint else { return 0 }
        return paint.triangles.count * MemoryLayout<DioramaPaintTriangle>.stride
            + paint.table.count * MemoryLayout<SIMD2<UInt32>>.stride + paint.indices.count * 4
    }

    private static func lightBytes(_ a: DioramaTileArtifacts) -> Int {
        a.lightGrid.lights.count * MemoryLayout<DioramaShaderLight>.stride
            + a.lightGrid.table.count * MemoryLayout<SIMD2<UInt32>>.stride + a.lightGrid.indices.count * 4
    }
}
