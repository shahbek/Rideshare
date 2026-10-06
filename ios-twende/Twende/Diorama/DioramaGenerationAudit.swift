import Foundation

/// Opt-in, task-scoped CPU measurements. Normal app generation does not allocate an audit.
/// Nested operation timings are inclusive and must not be added to generator-stage timings.
nonisolated final class DioramaGenerationAudit: @unchecked Sendable {
    @TaskLocal static var current: DioramaGenerationAudit?

    nonisolated struct Timing: Codable, Sendable {
        var calls: Int = 0
        var seconds: Double = 0
    }

    nonisolated struct Geometry: Codable, Sendable {
        let category: String
        let bakedTriangles: Int
        let bakedVertexBytes: Int
        let bakedIndexBytes: Int
        let instances: Int
    }

    nonisolated struct Snapshot: Codable, Sendable {
        let stages: [String: Timing]
        let operations: [String: Timing]
        let geometry: [Geometry]
    }

    /// Candidate CPU optimization stays audit-only until visual and timing gates pass.
    let usesCachedCutoutBounds: Bool

    init(usesCachedCutoutBounds: Bool = false) {
        self.usesCachedCutoutBounds = usesCachedCutoutBounds
    }

    private let lock = NSLock()
    private var stages: [String: Timing] = [:]
    private var operations: [String: Timing] = [:]
    private var geometry: [Geometry] = []

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    func stage(_ name: String, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        stages[name, default: Timing()].calls += 1
        stages[name, default: Timing()].seconds += seconds
    }

    func operation(_ name: String, since start: Double) {
        let seconds = Self.now - start
        lock.lock(); defer { lock.unlock() }
        operations[name, default: Timing()].calls += 1
        operations[name, default: Timing()].seconds += seconds
    }

    func record(_ mesh: DioramaMesh, category: DioramaCategory) {
        let entry = Geometry(category: category.rawValue, bakedTriangles: mesh.triangleCount,
                             bakedVertexBytes: mesh.positions.count * MemoryLayout<BuildingRenderVertex>.stride,
                             bakedIndexBytes: mesh.indices.count * MemoryLayout<UInt32>.stride,
                             instances: mesh.instances.count)
        lock.lock(); defer { lock.unlock() }
        geometry.append(entry)
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(stages: stages, operations: operations, geometry: geometry)
    }
}
