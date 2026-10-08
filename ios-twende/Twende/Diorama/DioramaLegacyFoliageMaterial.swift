import Foundation
import simd

/// Transient, category-safe legacy finish tagging; source geometry and archive bytes stay unchanged.
nonisolated enum DioramaLegacyFoliageMaterial {
    static func tagged(_ source: [BuildingRenderVertex], indices: [UInt32],
                       ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup]) -> (vertices: [BuildingRenderVertex], count: Int, architectureCount: Int) {
        var vertices = source
        var count = 0
        func visit(start: Int, count indexCount: Int, hedgeOnly: Bool) {
            guard start >= 0, start <= indices.count, indexCount >= 0, indexCount <= indices.count - start else { return }
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
            guard start >= 0, indexCount >= 0, start <= indices.count, indexCount <= indices.count - start else { return }
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
