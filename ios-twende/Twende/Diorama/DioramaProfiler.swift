import Foundation
import QuartzCore
import Darwin

/// Thread-safe store of per-frame samples written from the render completion handlers.
/// Costs one lock check per frame while not recording.
nonisolated final class DioramaProfiler: @unchecked Sendable {
    static let shared = DioramaProfiler()

    struct Frame: Sendable {
        var t: CFTimeInterval
        var host: Int
        var zoom: Double
        var pitch: Double
        var bearing: Double
        var latitude: Double
        var longitude: Double
        var cpuMS: Double
        var gpuMS: Double?
    }

    private let lock = NSLock()
    private var recording: Bool = false
    private var stored: [Frame] = []
    private var repaintHooks: [ObjectIdentifier: () -> Void] = [:]
    private static let cap = 60_000

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recording }

    func begin() { lock.lock(); stored.removeAll(keepingCapacity: true); recording = true; lock.unlock() }
    func end() -> [Frame] { lock.lock(); defer { lock.unlock() }; recording = false; return stored }

    func record(_ frame: Frame) {
        lock.lock()
        if recording, stored.count < Self.cap { stored.append(frame) }
        lock.unlock()
    }

    func frames(from: CFTimeInterval, to: CFTimeInterval = .greatestFiniteMagnitude) -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        return stored.filter { $0.t >= from && $0.t <= to }
    }

    var lastFrame: Frame? { lock.lock(); defer { lock.unlock() }; return stored.last }

    /// The map registers itself so the scripted test can force steady redraws on a still camera.
    func registerRepaint(owner: AnyObject, _ hook: @escaping () -> Void) {
        lock.lock(); repaintHooks[ObjectIdentifier(owner)] = hook; lock.unlock()
    }
    func requestRepaint() {
        lock.lock(); let hooks = Array(repaintHooks.values); lock.unlock()
        for hook in hooks { hook() }
    }

    // MARK: System readings

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    /// Resident footprint in MB, the number iOS uses for jetsam.
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Sum of all thread CPU usage, in percent of one core.
    static func processCPUPercent() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return total
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "FAIR"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "unknown"
        }
    }
}
