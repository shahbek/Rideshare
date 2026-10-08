import Foundation
import CoreGraphics

/// Conservative scenery-only CPU/GPU admission, including one in-flight decode/upload.
/// Mapbox, fleet, landmarks and allocator overhead are outside this estimate.
@MainActor
final class DioramaResidencyBudget {
    nonisolated struct Cost: Sendable {
        let retained: Int
        let peak: Int
    }
    private struct Entry {
        let context: Bool
        var bytes: Int
        var loading: Bool
    }
    private var entries: [UUID: Entry] = [:]
    private(set) var isConstrained: Bool = false
    var onAvailable: ((Bool) -> Void)?
    var contextLimit: Int { isConstrained ? 2 : 4 }
    var hdLimit: Int { isConstrained || ProcessInfo.processInfo.physicalMemory < 6 * 1_073_741_824 ? 1 : 2 }
    var limit: Int {
        let hardware = Int(min(UInt64(384 * 1_048_576), ProcessInfo.processInfo.physicalMemory / 16))
        return isConstrained ? min(hardware, 192 * 1_048_576) : hardware
    }
    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    var availableBytes: Int { max(0, limit - bytes) }
    var isLoading: Bool { entries.values.contains(where: \.loading) }
    var report: String {
        "Scenery allowance: \(bytes / 1_048_576)/\(limit / 1_048_576) MiB estimated CPU + GPU\(isConstrained ? " · conservative memory mode" : "") (not process memory)"
    }
    func constrain() { isConstrained = true }
    func canReserve(_ cost: Cost, context: Bool) -> Bool {
        !isLoading && entries.values.filter({ $0.context == context }).count < (context ? contextLimit : hdLimit)
            && cost.peak <= limit - min(limit, bytes)
    }
    func canFitAfterReleasing(_ ids: [UUID], cost: Cost) -> Bool {
        guard !isLoading, entries.values.filter({ !$0.context }).count < hdLimit else { return false }
        let reclaimed = ids.reduce(0) { $0 + (entries[$1]?.bytes ?? 0) }
        return cost.peak <= limit - min(limit, max(0, bytes - reclaimed))
    }
    func revise(_ id: UUID, cost: Cost) -> Bool {
        guard var entry = entries[id], cost.peak <= limit - min(limit, max(0, bytes - entry.bytes)) else { return false }
        entry.bytes = cost.peak; entries[id] = entry
        return true
    }
    func reserve(_ cost: Cost, context: Bool) -> UUID? {
        guard canReserve(cost, context: context) else { return nil }
        let id = UUID()
        entries[id] = Entry(context: context, bytes: cost.peak, loading: true)
        return id
    }
    func commit(_ id: UUID, cost: Cost) {
        guard var entry = entries[id] else { return }
        entry.bytes = cost.retained; entry.loading = false; entries[id] = entry
        onAvailable?(false)
    }
    func release(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        onAvailable?(!entry.loading)
    }

    nonisolated static func cost(_ artifact: DioramaTileArtifacts, context: Bool, size: CGSize, scale: Float) -> Cost {
        let groupBytes = artifact.groups.reduce(0) { $0 + $1.instances.count * MemoryLayout<DioramaInstanceData>.stride }
        return cost(payload: artifact.decodedBytes - groupBytes, groupBytes: groupBytes,
            ground: artifact.groundImage?.rgba.count ?? 0,
            vertices: artifact.vertices.count * MemoryLayout<BuildingRenderVertex>.stride,
            indices: artifact.indices.count * MemoryLayout<UInt32>.stride,
            labelTitles: artifact.buildingLabels.map(\.title), context: context, size: size, scale: scale)
    }
    nonisolated static func cost(payload: Int, groupBytes: Int, ground: Int, vertices: Int, indices: Int,
                                 labelTitles: [String], context: Bool, size: CGSize, scale: Float) -> Cost {
        let w = Int(max(1, size.width)), h = Int(max(1, size.height))
        let hw = max(1, w / 2), hh = max(1, h / 2)
        // Match half-resolution G-buffer/depth/AO, two bloom levels and capped reflection targets.
        let screen = hw * hh * 30 + max(1, hw / 2) * max(1, hh / 2) * 16
            + max(1, hw / 4) * max(1, hh / 4) * 16
        let reflection = max(1, min(768, w / 4)) * max(1, min(768, h / 4)) * 8
        let labels = context ? 0 : DioramaLabelRenderer.estimatedTextureBytes(titles: labelTitles, scale: scale)
        let effects = context ? 0 : 16 * 1_048_576 + screen + reflection + labels
        // Group placement arrays are CPU-only copies of the uploaded contiguous instances.
        // Ownership partition can retain an additional index array on CPU and GPU.
        let cpu = payload + groupBytes
        let retained = cpu + payload + ground / 3 + indices * 2 + effects + 4 * 1_048_576
        // Patch/tag copies exist BEFORE GPU setup. Reserve the larger phase, not their sum.
        let decodePeak = cpu + vertices + 32 * 1_048_576
        let uploadPeak = retained + indices + 8 * 1_048_576
        return Cost(retained: retained, peak: max(decodePeak, uploadPeak))
    }
}
