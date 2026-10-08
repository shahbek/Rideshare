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

    nonisolated static func cost(_ artifact: DioramaTileArtifacts, context: Bool, size: CGSize) -> Cost {
        cost(payload: artifact.decodedBytes, ground: artifact.groundImage?.rgba.count ?? 0,
            vertices: artifact.vertices.count * MemoryLayout<BuildingRenderVertex>.stride, instances: 0,
            labels: artifact.buildingLabels.count, context: context, size: size)
    }
    nonisolated static func cost(payload: Int, ground: Int, vertices: Int, instances: Int,
                                 labels: Int, context: Bool, size: CGSize) -> Cost {
        let pixels = Int(min(4096, max(1, size.width))) * Int(min(4096, max(1, size.height)))
        // Retained CPU arrays + uploaded buffers/mip chain, static shadow, screen targets,
        // reflection, labels and conservative spatial/light/shadow metadata slack.
        let effects = context ? 0 : 16 * 1_048_576 + pixels * 10 + 8 * 1_048_576
        let retained = payload * 2 + ground / 3 + instances + effects
            + labels * 256 * 1024 + vertices / 4 + 4 * 1_048_576
        // Local visual upgrades/material tagging may copy the vertex array; checked compressed
        // blocks and r3 patch scratch remain reserved until preparation finishes.
        return Cost(retained: retained, peak: retained + vertices + 32 * 1_048_576)
    }
}
