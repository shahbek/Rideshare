import Foundation
import simd

/// Additive geometry only. Original archive sections are never changed or duplicated on disk.
nonisolated struct DioramaVisualPatch: Sendable {
    nonisolated struct Tree: Codable, Sendable {
        let originalStart: Int
        let fullStart: Int
        let fullCount: Int
        let lightStart: Int
        let lightCount: Int
        let radius: Float
    }
    nonisolated struct Metadata: Codable, Sendable {
        let revision: Int
        let baseDigest: String
        let trees: [Tree]
        let removedTriangles: [Int]
        let roofCount: Int
        let skippedRoofs: Int
    }
    let additions: DioramaTileArtifacts
    let metadata: Metadata

    func applying(to base: DioramaTileArtifacts) -> DioramaTileArtifacts {
        var vertices = base.vertices
        var indices = base.indices
        let vertexOffset = UInt32(vertices.count), indexOffset = indices.count
        vertices.append(contentsOf: additions.vertices)
        indices.append(contentsOf: additions.indices.map { $0 + vertexOffset })
        let removed = Set(metadata.removedTriangles)
        var ranges: [DioramaRenderLayer.Range] = []
        for range in base.ranges {
            let affected = range.category == .buildings && stride(from: range.start, to: range.start + range.count, by: 3).contains { removed.contains($0) }
            if !affected { ranges.append(range); continue }
            let start = indices.count
            for index in stride(from: range.start, to: range.start + range.count, by: 3) where !removed.contains(index) {
                indices.append(contentsOf: base.indices[index..<(index + 3)])
            }
            if indices.count > start {
                ranges.append(.init(category: range.category, start: start, count: indices.count - start,
                    minimum: range.minimum, maximum: range.maximum, doubleSided: range.doubleSided))
            }
        }
        ranges.append(contentsOf: additions.ranges.map {
            .init(category: $0.category, start: $0.start + indexOffset, count: $0.count,
                  minimum: $0.minimum, maximum: $0.maximum, doubleSided: $0.doubleSided)
        })
        let (groups, instances) = patchedGroups(base.groups, indexOffset: indexOffset)
        var result = DioramaTileArtifacts(tile: base.tile, vertices: vertices, indices: indices, ranges: ranges,
            groups: groups, allInstances: instances, parts: DioramaCategory.allCases.map { category in
                .init(category: category, triangles: ranges.filter { $0.category == category }.reduce(0) { $0 + $1.count / 3 },
                      instances: groups.filter { $0.category == category }.reduce(0) { $0 + $1.instances.count })
            }, lights: base.lights, lightGrid: base.lightGrid,
            waterHeight: base.waterHeight, shorelineReport: base.shorelineReport, generationSeconds: base.generationSeconds,
            groundImage: base.groundImage, buildingLabels: base.buildingLabels, hasMapboxCoverage: base.hasMapboxCoverage,
            optimizationReport: base.optimizationReport, stageTimings: base.stageTimings)
        result.optimizationReport.append(report)
        return result
    }

    var report: String {
        "Local visual r\(metadata.revision): \(metadata.trees.count) tree prototypes, \(metadata.roofCount) verified roofs; \(metadata.skippedRoofs) roof candidates retained. Original map/archive bytes unchanged."
    }

    /// Tree prototype replacement; `indexOffset` is where the additions' indices begin.
    func patchedGroups(_ baseGroups: [DioramaInstanceGroup], indexOffset: Int) -> ([DioramaInstanceGroup], [DioramaInstanceData]) {
        let replacements = Dictionary(uniqueKeysWithValues: metadata.trees.map { ($0.originalStart, $0) })
        var instances: [DioramaInstanceData] = []
        var groups: [DioramaInstanceGroup] = []
        for group in baseGroups {
            var list = group.instances
            let replacement = group.category == .vegetation ? replacements[group.fullStart] : nil
            var minimum = group.minimum, maximum = group.maximum
            if let replacement {
                minimum = SIMD3(repeating: .greatestFiniteMagnitude)
                maximum = SIMD3(repeating: -.greatestFiniteMagnitude)
                for i in list.indices {
                    list[i].scale.w = replacement.radius * max(list[i].scale.x, max(list[i].scale.y, list[i].scale.z))
                    let radius = SIMD3<Float>(repeating: list[i].radius)
                    minimum = simd_min(minimum, list[i].centre - radius)
                    maximum = simd_max(maximum, list[i].centre + radius)
                }
            }
            groups.append(DioramaInstanceGroup(category: group.category,
                fullStart: replacement.map { $0.fullStart + indexOffset } ?? group.fullStart,
                fullCount: replacement?.fullCount ?? group.fullCount,
                lightStart: replacement.map { $0.lightStart + indexOffset } ?? group.lightStart,
                lightCount: replacement?.lightCount ?? group.lightCount,
                doubleSided: replacement == nil ? group.doubleSided : false, instances: list,
                firstInstance: instances.count, minimum: minimum, maximum: maximum))
            instances.append(contentsOf: list)
        }
        return (groups, instances)
    }
}
