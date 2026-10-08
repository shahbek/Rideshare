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

    /// Per-host screen targets: half-resolution G-buffer/depth/AO, two bloom levels, capped reflection,
    /// 2048² shadow depth and label textures. Coarse hosts allocate none of these.
    nonisolated static func effectBytes(context: Bool, labelTitles: [String], size: CGSize, scale: Float) -> Int {
        guard !context else { return 0 }
        let w = Int(max(1, size.width)), h = Int(max(1, size.height))
        let hw = max(1, w / 2), hh = max(1, h / 2)
        let screen = hw * hh * 30 + max(1, hw / 2) * max(1, hh / 2) * 16 + max(1, hw / 4) * max(1, hh / 4) * 16
        let reflection = max(1, min(768, w / 4)) * max(1, min(768, h / 4)) * 8
        return 16 * 1_048_576 + screen + reflection + DioramaLabelRenderer.estimatedTextureBytes(titles: labelTitles, scale: scale)
    }

    /// Saved tiles decode straight into shared Metal storage (unified memory): one copy, packed
    /// 32-byte vertices, ground streamed into its mipmapped texture. Peak adds only the 4 MiB
    /// scratch block, per-vertex tag flags, the CPU instance list being split, an r3 sidecar
    /// (≤16 MiB) and, for the Airtel tile, the old index buffer while it is regrown.
    nonisolated static func residentCost(_ plan: DioramaTileArchive.ResidentPlan, labelTitles: [String], context: Bool,
                                         size: CGSize, scale: Float) -> Cost {
        let vertices = plan.vertexCount * MemoryLayout<DioramaPackedVertex>.stride
        let indices = plan.indexCapacity * 4
        let instances = plan.instanceCount * MemoryLayout<DioramaInstanceData>.stride
        let groupCPU = plan.groupInstances * MemoryLayout<DioramaInstanceData>.stride
        let ground = plan.imageSize * plan.imageSize * 4 * 4 / 3
        let gpu = vertices + indices + instances + ground + plan.paintBytes + plan.lightBytes + plan.lodBytes
        let retained = gpu + groupCPU + plan.lightBytes + (plan.ownershipCopy ? indices : 0)
            + effectBytes(context: context, labelTitles: labelTitles, size: size, scale: scale) + 2 * 1_048_576
        let transient = 4 * 1_048_576 + plan.vertexCount + groupCPU + instances
            + (plan.ownershipCopy ? indices : 0) + 6 * 1_048_576
        return Cost(retained: retained, peak: retained + transient)
    }

    /// Reconciled after decoding, from the allocations actually made.
    nonisolated static func residentCost(_ tile: DioramaResidentTile, context: Bool, size: CGSize, scale: Float) -> Int {
        tile.gpuBytes + tile.cpuBytes + effectBytes(context: context, labelTitles: tile.labels.map(\.title), size: size, scale: scale) + 2 * 1_048_576
    }
}
