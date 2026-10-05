import Foundation
import Metal
import XCTest
@testable import Twende

/// Production coastline rules and geometry, using the shipped Slipway extract and override file.
final class DioramaShorelineTests: XCTestCase {
    @MainActor
    func testBundledProvenanceAndInspectionSections() throws {
        let data = try XCTUnwrap(DioramaBundledTile.load(config: .slipway))
        XCTAssertEqual(data.water.count, 1)
        XCTAssertEqual(data.landuse.filter { $0.kind == "terrace" }.count, 2)
        XCTAssertEqual(data.paths.filter { $0.kind == "pier" }.count, 1)
        XCTAssertFalse(data.landuse.contains { ["sand", "beach"].contains($0.kind) })
        XCTAssertFalse(data.paths.contains { ["retaining_wall", "breakwater"].contains($0.kind) })
        XCTAssertFalse(data.shorelines.isEmpty)
        XCTAssertTrue(data.shorelines.contains { $0.kind == .deck && $0.source == .data && $0.evidence.contains("180605897") })
        XCTAssertTrue(data.shorelines.contains { $0.kind == .deck && $0.source == .data && $0.evidence.contains("1321652461") })
        XCTAssertTrue(data.shorelines.contains { $0.kind == .deck && $0.source == .data && $0.evidence.contains("1387736908") })
        XCTAssertTrue(data.shorelines.contains { $0.kind == .seawall && $0.source == .override && $0.hasRevetment })
        XCTAssertTrue(data.shorelines.contains { $0.kind == .beach && $0.source == .override })
        XCTAssertTrue(data.shorelines.contains { $0.source == .fallback })
        XCTAssertFalse(data.shorelines.contains { $0.kind == .beach && $0.source == .data })
        print("[Shoreline report]\n" + DioramaShoreline.report(data.shorelines).joined(separator: "\n"))
        let total = data.shorelines.reduce(0) { $0 + $1.length }
        let coast = DioramaShoreline.extract(data.water, rect: data.rect).reduce(0) { $0 + DioramaPolygon.length($1) }
        XCTAssertEqual(total, coast, accuracy: 0.01, "Every real edge is classified exactly once")
    }

    @MainActor
    func testTileClipClosuresAreExcludedAndSharedEndpointsWeld() {
        let rect = DioramaRect(minX: -20, minY: -20, maxX: 20, maxY: 20)
        let water = DioramaAreaFeature(id: 1, rings: [[DV2(-20, -20), DV2(0, -20), DV2(0, 20), DV2(-20, 20)]],
                                      clipped: [true, false, true, true], kind: "water")
        let chains = DioramaShoreline.extract([water], rect: rect)
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains[0], [DV2(0, -20), DV2(0, 20)])
        let joined = DioramaShoreline.merge([(DV2(0, 0), DV2(0, 10)), (DV2(0.001, 10), DV2(0, 20))])
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].count, 3)
        XCTAssertTrue(DioramaShoreline.frames(joined[0]).allSatisfy { $0.x < -0.99 && abs($0.y) < 0.01 })
    }

    @MainActor
    func testNaturalBeachAndRetainingWallTagRules() throws {
        var data = try XCTUnwrap(DioramaBundledTile.load(config: .slipway))
        data.buildings = []; data.paths = []; data.roads = []; data.landuse = []
        XCTAssertEqual(DioramaShoreline.choose(at: .zero, data: data, config: .slipway, overrides: []).kind, .natural)
        data.landuse = [DioramaAreaFeature(id: 72, rings: [[DV2(-10, -10), DV2(10, -10), DV2(10, 10), DV2(-10, 10)]],
                            clipped: [false, false, false, false], kind: "sand", tags: ["natural": "beach"])]
        let beach = DioramaShoreline.choose(at: .zero, data: data, config: .slipway, overrides: [])
        XCTAssertEqual(beach.kind, .beach); XCTAssertEqual(beach.source, .data)
        data.landuse = []
        data.paths = [DioramaPathFeature(id: 99, line: [DV2(-5, 0), DV2(5, 0)], kind: "wall", isLit: false,
                                         tags: ["barrier": "retaining_wall"])]
        let wall = DioramaShoreline.choose(at: .zero, data: data, config: .slipway, overrides: [])
        XCTAssertEqual(wall.kind, .seawall); XCTAssertEqual(wall.source, .data); XCTAssertTrue(wall.rocks)
        data.paths = [DioramaPathFeature(id: 80, line: [DV2(-5, 0), DV2(5, 0)], kind: "footway", isLit: false)]
        let fallback = DioramaShoreline.choose(at: .zero, data: data, config: .slipway, overrides: [])
        XCTAssertEqual(fallback.source, .fallback); XCTAssertEqual(fallback.kind, .seawall)
    }

    @MainActor
    func testAllProfilesAreFiniteAndBeachContinuesUnderwaterWithoutChangingDEM() throws {
        let config = DioramaConfig.slipway
        let original = try XCTUnwrap(DioramaBundledTile.load(config: config))
        let library = DioramaPropLibrary(config: config)
        let terrain = DioramaTerrain.load(rect: original.rect, config: config).resolvingSurfaces(in: original)
        let originalValues = terrain.values
        for kind in [DioramaShoreline.Kind.beach, .seawall, .deck, .natural] {
            var data = original
            data.shorelines = original.shorelines.filter { $0.kind == kind }
            XCTAssertFalse(data.shorelines.isEmpty, "Missing \(kind) inspection fixture")
            var ground = DioramaMesh(), props = DioramaMesh(), vegetation = DioramaMesh(), debug = DioramaMesh()
            DioramaShorelineGenerator(config: config, data: data, terrain: terrain, library: library)
                .generate(ground: &ground, props: &props, vegetation: &vegetation, debug: &debug)
            XCTAssertGreaterThan(ground.triangleCount, 0)
            XCTAssertGreaterThan(debug.triangleCount, 0)
            for mesh in [ground, props, vegetation, debug] {
                XCTAssertEqual(mesh.positions.count, mesh.normals.count)
                XCTAssertTrue(mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
                XCTAssertTrue(mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs($0.length - 1) < 0.001 })
                XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.positions.count })
            }
            if kind == .beach {
                XCTAssertTrue(ground.positions.contains { $0.z < terrain.waterLevel - 0.4 })
                XCTAssertTrue(ground.uvs.contains { DioramaAtlas.lookup($0)?.swatch == .wetSand })
                XCTAssertTrue(ground.uvs.contains { DioramaAtlas.lookup($0)?.swatch == .earth })
            }
            if kind == .seawall {
                XCTAssertTrue(ground.uvs.contains { DioramaAtlas.lookup($0)?.swatch == .algaeStone })
                XCTAssertTrue(props.positions.contains { $0.z < terrain.waterLevel })
            }
            XCTAssertEqual(terrain.values, originalValues)
        }
    }

    @MainActor
    func testDeckHasThinFasciaAndPostsBelowWater() throws {
        let data = try XCTUnwrap(DioramaBundledTile.load(config: .slipway))
        let ring = try XCTUnwrap(data.landuse.first(where: { $0.id == 180605897 })?.rings.first)
        let terrain = DioramaTerrain.load(rect: data.rect, config: .slipway).resolvingSurfaces(in: data)
        let top = terrain.foundationHeight(ring) + 0.35
        var mesh = DioramaMesh()
        DioramaDeckGenerator(config: .slipway, data: data, terrain: terrain).build(pieces: [ring], top: top, axis: DV2(0, 1), props: &mesh)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        let timber = mesh.positions.indices.filter { DioramaAtlas.lookup(mesh.uvs[$0])?.swatch == .deckWood }
        XCTAssertFalse(timber.isEmpty)
        XCTAssertTrue(timber.allSatisfy { abs(mesh.positions[$0].z - top) < 0.001 })
        XCTAssertTrue(mesh.uvs.contains { DioramaAtlas.lookup($0)?.swatch == .palmTrunk })
        XCTAssertTrue(mesh.positions.contains { $0.z < top - 0.5 })
    }

    @MainActor
    func testConcavePromenadeCoversOnlyItsPlanAndHasNoInternalSideFaces() {
        let ring = [DV2(0, 0), DV2(12, 0), DV2(12, 4), DV2(4, 4), DV2(4, 12), DV2(0, 12)]
        let pieces = DioramaGroundCutouts(polygons: []).subtract(from: ring)
        let terrain = DioramaTerrain.flat(DioramaRect(minX: -1, minY: -1, maxX: 15, maxY: 15))
        var mesh = DioramaMesh()
        for piece in pieces { terrain.drape(piece, lift: 0.11, swatch: .paving, into: &mesh) }
        var area = 0.0
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[i])].xy
            let b = mesh.positions[Int(mesh.indices[i + 1])].xy
            let c = mesh.positions[Int(mesh.indices[i + 2])].xy
            area += abs((b - a).cross(c - a)) / 2
            XCTAssertTrue(DioramaPolygon.contains(ring, (a + b + c) * (1 / 3.0)))
        }
        XCTAssertEqual(area, DioramaPolygon.area(ring), accuracy: 0.0001)
        XCTAssertTrue(mesh.normals.allSatisfy { $0.z == 1 })
        XCTAssertTrue(mesh.positions.allSatisfy { abs($0.z - 0.71) < 0.0001 })
    }

    @MainActor
    func testFullSlipwayPipelineHasOneWaterPlaneAndClassifiedDebugBatches() throws {
        let config = DioramaConfig.slipway
        let data = try XCTUnwrap(DioramaBundledTile.load(config: config))
        let artifacts = try DioramaTileGenerator.generate(data, config: config, library: DioramaPropLibrary(config: config), reduced: false)
        XCTAssertGreaterThan(artifacts.totalTriangles, 1000)
        XCTAssertTrue(artifacts.parts.contains { $0.category == .shorelineDebug && $0.triangles > 0 })
        XCTAssertTrue(artifacts.shorelineReport.contains { $0.contains("override") && $0.contains("beach") })
        var waterVertices: Set<UInt32> = []
        for range in artifacts.ranges where range.category == .water {
            waterVertices.formUnion(artifacts.indices[range.start..<(range.start + range.count)])
        }
        XCTAssertFalse(waterVertices.isEmpty)
        for index in waterVertices {
            let vertex = artifacts.vertices[Int(index)]
            XCTAssertEqual(Double(vertex.position.z), artifacts.waterHeight, accuracy: 0.0001)
            XCTAssertEqual(vertex.appearance.w, 1)
            XCTAssertGreaterThanOrEqual(vertex.appearance.z, 0)
        }
        print("[Shoreline integration] \(artifacts.totalTriangles) triangles, \(artifacts.totalBytes / 1024) KB, \(artifacts.generationSeconds) seconds")
    }

    @MainActor
    func testDebugSettingsNotifyTheRendererWithoutMovingTheCamera() {
        let state = DioramaState()
        let changed = expectation(description: "Renderer receives settings changes")
        changed.expectedFulfillmentCount = 3
        let observer = NotificationCenter.default.addObserver(forName: DioramaState.renderSettingsChanged, object: state, queue: .main) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        state.showsWireframe = true
        state.toggle(.shorelineDebug)
        state.isBasemapOnly = true
        wait(for: [changed], timeout: 1)
        XCTAssertTrue(state.visibleCategories.contains(.shorelineDebug))
        XCTAssertFalse(DioramaState().visibleCategories.contains(.shorelineDebug))
    }

    @MainActor
    func testConfiguredWaterDatumFlowsIntoEverySurfaceAndMetalCompiles() throws {
        var config = DioramaConfig.slipway
        config.waterLevel = 1.4
        let data = try XCTUnwrap(DioramaBundledTile.load(config: config))
        let terrain = DioramaTerrain.load(rect: data.rect, config: config).resolvingSurfaces(in: data)
        XCTAssertEqual(terrain.waterLevel, config.waterLevel + terrain.clearance, accuracy: 0.0001)
        XCTAssertEqual(terrain.pierLevel, terrain.waterLevel + 0.83, accuracy: 0.0001)
        XCTAssertEqual(terrain.seabedLevel, terrain.waterLevel - 1.22, accuracy: 0.0001)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: DioramaShaderSource.source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "dioramaFragment"))
        XCTAssertNotNil(library.makeFunction(name: "dioramaVertex"))
    }
}
