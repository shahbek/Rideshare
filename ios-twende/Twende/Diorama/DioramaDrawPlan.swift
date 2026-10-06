import simd

/// Coalesces only consecutive, contiguous submissions. Selection/culling and each bin's LOD
/// happen first, so merging never fills a culled gap or changes a primitive's detail level.
nonisolated enum DioramaDrawPlan {
    struct Instance: Sendable {
        let category: DioramaCategory
        let start: Int
        let count: Int
        let firstInstance: Int
        var instanceCount: Int
        let doubleSided: Bool
    }

    static func ranges(_ input: [DioramaRenderLayer.Range]) -> [DioramaRenderLayer.Range] {
        var output: [DioramaRenderLayer.Range] = []
        output.reserveCapacity(input.count)
        for range in input where range.count > 0 {
            if let last = output.last, last.category == range.category,
               last.doubleSided == range.doubleSided, last.start + last.count == range.start {
                output[output.count - 1] = .init(category: last.category, start: last.start,
                    count: last.count + range.count, minimum: simd_min(last.minimum, range.minimum),
                    maximum: simd_max(last.maximum, range.maximum), doubleSided: last.doubleSided)
            } else { output.append(range) }
        }
        return output
    }

    static func instances(_ input: [DioramaInstanceGroup], eye: SIMD3<Float>? = nil,
                          lodDistance: Float = 140) -> [Instance] {
        var output: [Instance] = []
        output.reserveCapacity(input.count)
        for group in input where !group.instances.isEmpty {
            let light = group.lightCount > 0 && (eye.map {
                simd_distance((group.minimum + group.maximum) * 0.5, $0) > lodDistance
            } ?? true)
            let start = light ? group.lightStart : group.fullStart
            let count = light ? group.lightCount : group.fullCount
            guard count > 0 else { continue }
            if let last = output.last, last.category == group.category,
               last.doubleSided == group.doubleSided, last.start == start, last.count == count,
               last.firstInstance + last.instanceCount == group.firstInstance {
                output[output.count - 1].instanceCount += group.instances.count
            } else {
                output.append(.init(category: group.category, start: start, count: count,
                    firstInstance: group.firstInstance, instanceCount: group.instances.count,
                    doubleSided: group.doubleSided))
            }
        }
        return output
    }
}
