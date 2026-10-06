import Metal
import XCTest
@testable import Twende

final class DioramaInstancingTests: XCTestCase {
    func testRepeatedWindowAndTankBecomeSinglePrototypes() {
        let registry = DioramaPrimitiveRegistry(firstID: 0)
        var mesh = DioramaMesh()
        mesh.primitiveRegistry = registry
        mesh.baseZ = 7
        mesh.recordsHeight = true
        mesh.tint = SIMD3(1.02, 1, 0.98)
        var glow = DioramaMesh()
        let kit = DioramaBuildingKit(config: .slipway)
        for i in 0..<20 {
            kit.window(a: DV2(Double(i) * 3, 0), dir: DV2(1, 0), out: DV2(0, -1), u: 0,
                       z0: 2, z1: 4, width: 1.4, hasGrille: true, lit: false, into: &mesh, glow: &glow)
            kit.waterTank(at: DV2(Double(i) * 3, 0), z0: 8, color: .tankBlue, into: &mesh)
        }
        XCTAssertEqual(registry.entries.count, 2)
        XCTAssertEqual(mesh.instances.count, 40)
        XCTAssertEqual(mesh.triangleCount, 0)
        XCTAssertEqual(mesh.instances[0].transform.translation.z, 9)
        XCTAssertEqual(mesh.instances[0].grading, SIMD4(1, 2, 0, 1))
        XCTAssertEqual(mesh.instances[0].tint, mesh.tint)
        XCTAssertTrue(registry.report.contains { $0.contains("complete tanks") })
        XCTAssertEqual(MemoryLayout<DioramaInstanceData>.stride, 64)
    }

    func testPrimitiveExpansionPreservesShapeNormalsAndCulling() {
        let registry = DioramaPrimitiveRegistry(firstID: 0)
        let angle = 0.72
        let axis = DV2(cos(angle), sin(angle))
        var original = DioramaMesh()
        var instanced = DioramaMesh()
        instanced.primitiveRegistry = registry
        func emit(_ mesh: inout DioramaMesh) {
            mesh.box(centre: DV2(7, -3), z0: 2, axis: axis, halfLength: 1.7, halfWidth: 0.4, height: 1.2, .cream, bevel: 0.04)
            mesh.facadeBox(a: DV2(3, 4), dir: axis, out: axis.right, u: 2, width: 1.4, z0: 3, z1: 5, depth: -0.19, .glass)
            mesh.tube(from: DV3(2, 5, 3), to: DV3(3, 7, 6), r0: 0.2, r1: 0.15, sides: 14, .trimWhite)
            mesh.sphere(centre: DV3(6, 7, 8), radii: DV3(1.1, 0.7, 1.5), .rockWarm)
        }
        emit(&original); emit(&instanced)
        var expanded = DioramaMesh()
        for placement in instanced.instances {
            expanded.append(registry.prototypes[placement.prototype].full, placement.transform)
        }
        XCTAssertEqual(expanded.positions.count, original.positions.count)
        XCTAssertEqual(expanded.indices, original.indices)
        XCTAssertEqual(expanded.doubleSidedTriangles, original.doubleSidedTriangles)
        XCTAssertEqual(expanded.uvs, original.uvs)
        for (a, b) in zip(expanded.positions, original.positions) {
            XCTAssertLessThan((a - b).length, 1e-10)
        }
        for (a, b) in zip(expanded.normals, original.normals) {
            XCTAssertLessThan((a - b).length, 1e-10)
        }
    }

    func testRuntimeMetalIncludesInstancedEffects() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: DioramaShaderSource.fullSource, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "dioramaInstancedVertex"))
        XCTAssertNotNil(library.makeFunction(name: "dioramaInstancedShadowVertex"))
    }
}
