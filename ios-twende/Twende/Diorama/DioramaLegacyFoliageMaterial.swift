import Foundation
import simd

/// Transient, category-safe legacy finish tagging; source geometry and archive bytes stay unchanged.
nonisolated enum DioramaLegacyFoliageMaterial {
    /// Streaming equivalent of `tagged`: bit0 foliage, bit1 hedge-only foliage, bit2 architecture.
    static func flags(indices: UnsafeBufferPointer<UInt32>, vertexCount: Int,
                      ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup]) -> [UInt8] {
        var flags = [UInt8](repeating: 0, count: vertexCount)
        var visited: Set<SIMD3<Int>> = []
        func mark(_ start: Int, _ count: Int, _ bit: UInt8) {
            guard start >= 0, count >= 0, start <= indices.count, count <= indices.count - start,
                  visited.insert(SIMD3(start, count, Int(bit))).inserted else { return }
            for offset in start..<(start + count) {
                let index = Int(indices[offset])
                if index < vertexCount { flags[index] |= bit }
            }
        }
        for range in ranges where range.category == .vegetation || range.category == .walls {
            mark(range.start, range.count, range.category == .walls ? 2 : 1)
        }
        for group in groups where group.category == .vegetation || group.category == .walls {
            mark(group.fullStart, group.fullCount, group.category == .walls ? 2 : 1)
            mark(group.lightStart, group.lightCount, group.category == .walls ? 2 : 1)
        }
        for range in ranges where range.category == .buildings { mark(range.start, range.count, 4) }
        for group in groups where group.category == .buildings {
            mark(group.fullStart, group.fullCount, 4); mark(group.lightStart, group.lightCount, 4)
        }
        return flags
    }

    private static let roofColors: [SIMD3<Float>] = {
        let swatches: [DioramaSwatch] = [.roofTeal, .roofRust, .roofSlate, .roofGreen, .roofTerracotta, .roofConcrete, .seaCliffRoof]
        return swatches.compactMap { swatch in
            guard let hex = DioramaSwatch.defaultPalette[swatch] else { return nil }
            return SIMD3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255)) / 255
        }
    }()

    /// Same per-vertex decisions as `tagged`; returns the material written (0 none, 10 foliage, 11/12 architecture).
    static func tag(_ v: inout BuildingRenderVertex, flags: UInt8) -> Float {
        guard flags != 0, v.appearance.w < 0.5, v.appearance.y < 0.5 else { return 0 }
        let c = v.color
        if flags & 3 != 0, c.x.isFinite, c.y.isFinite, c.z.isFinite, c.x > 0.10, c.y > c.x * 1.08, c.y > c.z * 1.25,
           flags & 1 != 0 || c.z < c.y * 0.55 {
            var appearance = v.appearance; appearance.y = 10
            v = BuildingRenderVertex(position: v.position, normal: v.normal, color: c, appearance: appearance)
            return 10
        }
        guard flags & 4 != 0 else { return 0 }
        var material: Float = 0
        if v.appearance.z > 50, abs(v.normal.z) < 0.95 { material = 12 }
        else if v.normal.z > 0.15 {
            let rgb = SIMD3(c.x, c.y, c.z)
            for roof in roofColors {
                let scale = simd_dot(rgb, roof) / simd_dot(roof, roof)
                if scale >= 0.45, scale <= 1.2, simd_length(rgb - roof * scale) < 0.0003 { material = 11; break }
            }
        }
        guard material > 0 else { return 0 }
        var appearance = v.appearance; appearance.y = material
        v = BuildingRenderVertex(position: v.position, normal: v.normal, color: c, appearance: appearance)
        return material
    }

    static func tagged(_ source: [BuildingRenderVertex], indices: [UInt32],
                       ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup]) -> (vertices: [BuildingRenderVertex], count: Int, architectureCount: Int) {
        var vertices = source
        var count = 0
        var visitedFoliage: Set<SIMD3<Int>> = []
        var visitedArchitecture: Set<SIMD2<Int>> = []
        func visit(start: Int, count indexCount: Int, hedgeOnly: Bool) {
            guard start >= 0, start <= indices.count, indexCount >= 0, indexCount <= indices.count - start,
                  visitedFoliage.insert(SIMD3(start, indexCount, hedgeOnly ? 1 : 0)).inserted else { return }
            for offset in start..<(start + indexCount) {
                let index = Int(indices[offset])
                guard index < vertices.count else { continue }
                let v = vertices[index], c = v.color
                guard v.appearance.w < 0.5, v.appearance.y < 0.5,
                      c.x.isFinite, c.y.isFinite, c.z.isFinite,
                      c.x > 0.10, c.y > c.x * 1.08, c.y > c.z * 1.25,
                      !hedgeOnly || c.z < c.y * 0.55 else { continue }
                var appearance = v.appearance
                appearance.y = 10
                vertices[index] = BuildingRenderVertex(position: v.position, normal: v.normal, color: c, appearance: appearance)
                count += 1
            }
        }
        for range in ranges where range.category == .vegetation || range.category == .walls {
            visit(start: range.start, count: range.count, hedgeOnly: range.category == .walls)
        }
        for group in groups where group.category == .vegetation || group.category == .walls {
            visit(start: group.fullStart, count: group.fullCount, hedgeOnly: group.category == .walls)
            visit(start: group.lightStart, count: group.lightCount, hedgeOnly: group.category == .walls)
        }
        var architectureCount: Int = 0
        let roofSwatches: [DioramaSwatch] = [.roofTeal, .roofRust, .roofSlate, .roofGreen, .roofTerracotta, .roofConcrete, .seaCliffRoof]
        let roofColors: [SIMD3<Float>] = roofSwatches.compactMap { swatch in
            guard let hex = DioramaSwatch.defaultPalette[swatch] else { return nil }
            return SIMD3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255)) / 255
        }
        func architecture(start: Int, count indexCount: Int) {
            guard start >= 0, indexCount >= 0, start <= indices.count, indexCount <= indices.count - start,
                  visitedArchitecture.insert(SIMD2(start, indexCount)).inserted else { return }
            for offset in start..<(start + indexCount) {
                let index = Int(indices[offset])
                guard index < vertices.count else { continue }
                let v = vertices[index]
                guard v.appearance.w < 0.5, v.appearance.y < 0.5 else { continue }
                var material: Float = 0
                if v.appearance.z > 50, abs(v.normal.z) < 0.95 { material = 12 }
                else if v.normal.z > 0.15 {
                    let c = SIMD3(v.color.x, v.color.y, v.color.z)
                    // Legacy archives lack semantic IDs. Admit only an unchanged palette ray,
                    // including scalar source shading; uncertain/tinted roof faces stay untouched.
                    for roof in roofColors {
                        let scale = simd_dot(c, roof) / simd_dot(roof, roof)
                        let error = simd_length(c - roof * scale)
                        if scale >= 0.45, scale <= 1.2, error < 0.0003 { material = 11; break }
                    }
                }
                guard material > 0 else { continue }
                var appearance = v.appearance; appearance.y = material
                vertices[index] = BuildingRenderVertex(position: v.position, normal: v.normal, color: v.color, appearance: appearance)
                architectureCount += 1
            }
        }
        for range in ranges where range.category == .buildings { architecture(start: range.start, count: range.count) }
        for group in groups where group.category == .buildings {
            architecture(start: group.fullStart, count: group.fullCount)
            architecture(start: group.lightStart, count: group.lightCount)
        }
        return (vertices, count, architectureCount)
    }
}
