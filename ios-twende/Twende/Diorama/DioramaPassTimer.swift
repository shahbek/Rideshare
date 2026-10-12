import Foundation
import Metal
import QuartzCore

/// Per-pass GPU timing from Metal stage-boundary timestamp counters (vertex start → fragment end)
/// for the diorama's own passes, including its encoder inside Mapbox's main pass. Only measured
/// frames are reported; devices without stage-boundary counters say so instead of estimating.
nonisolated final class DioramaPassTimer: @unchecked Sendable {
    /// One frame's sample buffer. Each attached pass uses two samples.
    final class Frame: @unchecked Sendable {
        fileprivate let buffer: MTLCounterSampleBuffer
        fileprivate var labels: [String] = []
        fileprivate var triangles: [String: Int] = [:]
        fileprivate var draws: [String: SIMD2<Int>] = [:]
        private let capacity: Int
        fileprivate init(buffer: MTLCounterSampleBuffer, capacity: Int) { self.buffer = buffer; self.capacity = capacity }

        /// Adds timestamps to a pass descriptor the diorama owns (or borrows for one encoder).
        func attach(_ descriptor: MTLRenderPassDescriptor, _ label: String) {
            guard labels.count * 2 + 2 <= capacity else { return }
            let slot = labels.count * 2
            let attachment = descriptor.sampleBufferAttachments[0]
            attachment?.sampleBuffer = buffer
            attachment?.startOfVertexSampleIndex = slot
            attachment?.endOfVertexSampleIndex = MTLCounterDontSample
            attachment?.startOfFragmentSampleIndex = MTLCounterDontSample
            attachment?.endOfFragmentSampleIndex = slot + 1
            labels.append(label)
        }
        static func detach(_ descriptor: MTLRenderPassDescriptor) {
            descriptor.sampleBufferAttachments[0]?.sampleBuffer = nil
        }
        func count(_ label: String, triangles: Int, draws: Int = 0, inputDraws: Int = 0) {
            self.triangles[label, default: 0] += triangles
            let previous = self.draws[label] ?? .zero
            self.draws[label] = SIMD2(previous.x + draws, previous.y + inputDraws)
        }
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var pool: [MTLCounterSampleBuffer] = []
    private var busy: Set<ObjectIdentifier> = []
    private var samples: [String: [Double]] = [:]
    private var triangleSamples: [String: Int] = [:]
    private var drawSamples: [String: SIMD2<Int>] = [:]
    private var lastPublished: CFTimeInterval = 0
    private var clock: (cpu: MTLTimestamp, gpu: MTLTimestamp) = (0, 0)
    private var nanosecondsPerTick: Double = 1
    let isSupported: Bool
    private static let capacity = 32

    init(device: MTLDevice) {
        self.device = device
        let timestamps = device.counterSets?.first { $0.name == MTLCommonCounterSet.timestamp.rawValue }
        isSupported = timestamps != nil && device.supportsCounterSampling(.atStageBoundary)
        guard isSupported, let timestamps else { return }
        for _ in 0..<3 {
            let d = MTLCounterSampleBufferDescriptor()
            d.counterSet = timestamps; d.sampleCount = Self.capacity; d.storageMode = .shared
            d.label = "Diorama pass timestamps"
            if let buffer = try? device.makeCounterSampleBuffer(descriptor: d) { pool.append(buffer) }
        }
        let sample = device.sampleTimestamps()
        clock = (sample.cpu, sample.gpu)
    }

    /// Nil when unsupported or all buffers are still in flight (that frame is simply not timed).
    func begin() -> Frame? {
        guard isSupported else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let buffer = pool.first(where: { !busy.contains(ObjectIdentifier($0)) }) else { return nil }
        busy.insert(ObjectIdentifier(buffer))
        return Frame(buffer: buffer, capacity: Self.capacity)
    }

    /// Resolves after the command buffer completes; returns a report about once per second.
    func finish(_ frame: Frame, command: MTLCommandBuffer, report: @escaping @Sendable (String) -> Void) {
        let buffer = frame.buffer
        // Passes attach after this call; read labels when the GPU has finished.
        command.addCompletedHandler { [weak self] finished in
            guard let self else { return }
            let labels = frame.labels, triangles = frame.triangles, draws = frame.draws
            defer { self.lock.lock(); self.busy.remove(ObjectIdentifier(buffer)); self.lock.unlock() }
            guard finished.status == .completed, !labels.isEmpty,
                  let data = try? buffer.resolveCounterRange(0..<(labels.count * 2)) else { return }
            let (cpu, gpu) = self.device.sampleTimestamps()
            let values: [MTLTimestamp] = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self).map(\.timestamp)) }
            if let text = self.record(labels: labels, values: values, triangles: triangles, draws: draws, cpu: cpu, gpu: gpu) { report(text) }
        }
    }

    private func record(labels: [String], values: [MTLTimestamp], triangles: [String: Int], draws: [String: SIMD2<Int>], cpu: MTLTimestamp, gpu: MTLTimestamp) -> String? {
        lock.lock(); defer { lock.unlock() }
        if gpu > clock.gpu, cpu > clock.cpu { nanosecondsPerTick = Double(cpu - clock.cpu) / Double(gpu - clock.gpu) }
        clock = (cpu, gpu)
        for (i, label) in labels.enumerated() where i * 2 + 1 < values.count {
            let start = values[i * 2], end = values[i * 2 + 1]
            guard start != 0, end > start, start != MTLCounterErrorValue, end != MTLCounterErrorValue else { continue }
            samples[label, default: []].append(Double(end - start) * nanosecondsPerTick / 1_000_000)
            if samples[label]!.count > 90 { samples[label]!.removeFirst() }
        }
        for (label, count) in triangles { triangleSamples[label] = count }
        for (label, counts) in draws { drawSamples[label] = counts }
        let now = CACurrentMediaTime()
        guard now - lastPublished >= 1 else { return nil }
        lastPublished = now
        let order = ["Shadow", "Reflection", "AO/glow prepass", "AO filter", "Main"]
        let keys = samples.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        let lines = keys.map { key -> String in
            let sorted = samples[key]!.sorted()
            let p50 = sorted[sorted.count / 2], p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
            let tris = triangleSamples[key].map { " · \($0.formatted()) tris" } ?? ""
            let draws = drawSamples[key].map { " · \($0.x)/\($0.y) geometry draws after/before chunks" } ?? ""
            return String(format: "  %@: p50 %.2f ms / p95 %.2f ms", key, p50, p95) + tris + draws + " (\(sorted.count) timed)"
        }
        return (["GPU time per diorama pass (measured, vertex start → fragment end):"] + lines
            + ["Passes run only when their inputs change; cached passes cost nothing that frame."]).joined(separator: "\n")
    }
}
