import Foundation
import QuartzCore

/// Rolling measurements, with scopes spelled out: main-pass submissions, diorama CPU encoding,
/// and the shared Mapbox command buffer's GPU time (not isolated diorama GPU time or display FPS).
nonisolated final class DioramaFrameMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var cpu: [Double] = []
    private var gpu: [Double] = []
    private var triangles: [Int] = []
    private var lastPublished: Double = 0

    func record(triangles count: Int, cpuMS: Double, gpuMS: Double?) -> String? {
        lock.lock(); defer { lock.unlock() }
        cpu.append(cpuMS)
        triangles.append(count)
        if let gpuMS, gpuMS.isFinite, gpuMS > 0 { gpu.append(gpuMS) }
        if cpu.count > 120 { cpu.removeFirst(cpu.count - 120) }
        if gpu.count > 120 { gpu.removeFirst(gpu.count - 120) }
        if triangles.count > 120 { triangles.removeFirst(triangles.count - 120) }
        let now = CACurrentMediaTime()
        guard now - lastPublished >= 1 else { return nil }
        lastPublished = now
        func percentile(_ data: [Double], _ p: Double) -> String {
            guard !data.isEmpty else { return "unavailable" }
            let ordered = data.sorted()
            return String(format: "%.2f", ordered[min(ordered.count - 1, Int(Double(ordered.count - 1) * p))]) + " ms"
        }
        return "Main-pass triangles: \(count) (rolling max \(triangles.max() ?? count))\n"
            + "Diorama CPU encode p50/p95: \(percentile(cpu, 0.5)) / \(percentile(cpu, 0.95))\n"
            + "Shared map command GPU p50/p95: \(percentile(gpu, 0.5)) / \(percentile(gpu, 0.95))\n"
            + "\(cpu.count) recent samples; excludes triangle counts for shadow/AO/reflection passes."
    }
}
