import Foundation

/// Tags green surfaces only within vegetation/hedge categories; never guesses from building color.
nonisolated enum DioramaLegacyFoliageMaterial {
    static func tagged(_ source: [BuildingRenderVertex], indices: [UInt32],
                       ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup]) -> (vertices: [BuildingRenderVertex], count: Int) {
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
        return (vertices, count)
    }
}
