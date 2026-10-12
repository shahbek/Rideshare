import Foundation
import CoreGraphics

/// Conservative scenery-only CPU/GPU admission, including one in-flight decode/upload.
/// Mapbox, fleet, older landmarks, the admission-exempt airport and allocator overhead are outside this estimate.
/// New harbour landmarks explicitly reserve their buffers, source/bake scratch and effects here.
@MainActor
final class DioramaResidencyBudget {
    nonisolated struct Cost: Sendable {
        let retained: Int
        let peak: Int
    }
    private struct Entry {
        let context: Bool?
        var bytes: Int
        var loading: Bool
    }
    private var entries: [UUID: Entry] = [:]
    /// Conservative mode follows a memory warning for two minutes and is extended by further
    /// warnings; it no longer pins the whole session to a 1-HD/192 MiB allowance.
    private var constrainedUntil: Date = .distantPast
    var isConstrained: Bool { Date() < constrainedUntil }
    var onAvailable: ((Bool) -> Void)?
    var onLandmarkAvailable: (() -> Void)?
    var contextLimit: Int { isConstrained ? 2 : 4 }
    /// Two HD tiles everywhere (a seam between two tiles, e.g. the harbour, is always fully HD),
    /// three on 6 GiB+ devices. Bytes are still admitted by the ledger below.
    var hdLimit: Int {
        if isConstrained { return 1 }
        return ProcessInfo.processInfo.physicalMemory < 6 * 1_073_741_824 ? 2 : 3
    }
    /// Room for two dense HD tiles (e.g. both harbour halves with their baked skyline) plus coarse.
    var limit: Int {
        let hardware = Int(min(UInt64(896 * 1_048_576), ProcessInfo.processInfo.physicalMemory / 7))
        return isConstrained ? min(hardware, 256 * 1_048_576) : hardware
    }
    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    var availableBytes: Int { max(0, limit - bytes) }
    var isLoading: Bool { entries.values.contains(where: \.loading) }
    /// Coarse and HD each have one decode/upload slot, so a coarse read never starves HD.
    func isLoading(context: Bool) -> Bool { entries.values.contains { $0.loading && $0.context == context } }
    /// Bespoke landmark lifecycle, shown with the allowance so a missing model names its actual stage.
    var landmarkStatus: [String: String] = [:]
    var report: String {
        let landmarks = landmarkStatus.keys.sorted().map { "\n\($0): \(landmarkStatus[$0] ?? "")" }.joined()
        return "Scenery allowance: \(bytes / 1_048_576)/\(limit / 1_048_576) MiB estimated CPU + GPU\(isConstrained ? " · conservative memory mode" : "") (includes tile-baked skyline; excludes independent airport/landmark hosts; not process memory)" + landmarks
    }
    func constrain() { constrainedUntil = Date().addingTimeInterval(120) }
    func canReserve(_ cost: Cost, context: Bool) -> Bool {
        !isLoading(context: context) && entries.values.filter({ $0.context == context }).count < (context ? contextLimit : hdLimit)
            && cost.peak <= limit - min(limit, bytes)
    }
    func canFitAfterReleasing(_ ids: [UUID], cost: Cost) -> Bool {
        guard !isLoading(context: false), entries.values.filter({ $0.context == false }).count < hdLimit else { return false }
        let reclaimed = ids.reduce(0) { $0 + (entries[$1]?.bytes ?? 0) }
        return cost.peak <= limit - min(limit, max(0, bytes - reclaimed))
    }
    func revise(_ id: UUID, cost: Cost) -> Bool {
        guard var entry = entries[id], cost.peak <= limit - min(limit, max(0, bytes - entry.bytes)) else { return false }
        entry.bytes = cost.peak; entries[id] = entry
        return true
    }
    /// Harbour hosts share the hardware allowance without consuming tile-detail slots.
    func reserveLandmark(_ cost: Cost) -> UUID? {
        guard !isLoading, entries.values.filter({ $0.context == nil }).count < 2,
              cost.peak <= availableBytes else { return nil }
        let id = UUID()
        entries[id] = Entry(context: nil, bytes: cost.peak, loading: false)
        return id
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
        onLandmarkAvailable?()
    }
    func release(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        onAvailable?(!entry.loading)
        onLandmarkAvailable?()
    }

    /// Per-host screen targets: half-resolution G-buffer/depth/AO, two bloom levels, capped reflection,
    /// 2048² shadow depth and label textures, plus each host's bounded geometry chunk cache.
    /// Coarse hosts allocate only the chunk cache allowance, not the screen/shadow effects.
    nonisolated static func effectBytes(context: Bool, labelTitles: [String], size: CGSize, scale: Float) -> Int {
        let grade = DioramaRenderLayer.gradeFieldSize(context: context)
        let chunks = DioramaGeometryChunks.reservationBytes(context: context) + grade * grade * 8
        guard !context else { return chunks }
        let w = Int(max(1, size.width)), h = Int(max(1, size.height))
        let hw = max(1, w / 2), hh = max(1, h / 2)
        let screen = hw * hh * 30 + max(1, hw / 2) * max(1, hh / 2) * 16 + max(1, hw / 4) * max(1, hh / 4) * 16
        let reflection = max(1, min(768, w / 4)) * max(1, min(768, h / 4)) * 8
        return chunks + 16 * 1_048_576 + screen + reflection + DioramaLabelRenderer.estimatedTextureBytes(titles: labelTitles, scale: scale)
    }

    /// Saved tiles decode straight into shared Metal storage (unified memory): one copy, packed
    /// 32-byte vertices, ground streamed into its mipmapped texture. Peak adds only the 4 MiB
    /// scratch block, per-vertex tag flags, the CPU instance list being split, an r3 sidecar
    /// (≤16 MiB) and, for the Airtel tile, the old index buffer while it is regrown.
    nonisolated static func residentCost(_ plan: DioramaTileArchive.ResidentPlan, labelTitles: [String], context: Bool,
                                         size: CGSize, scale: Float) -> Cost {
        // Includes the spare capacity reserved for read-time pitched roofs (DioramaRoofRetrofit).
        let roofVertices = DioramaTileArchive.roofReserveVertices(plan.vertexCount) + DioramaVegetation.vertexCount
        // Mapped planting: up to 14k placements plus their index spans.
        let planting = 14_000 * MemoryLayout<DioramaInstanceData>.stride * 2 + 400_000
        let vertices = (plan.vertexCount + roofVertices) * MemoryLayout<DioramaPackedVertex>.stride + planting
        let indices = plan.indexCapacity * 4
        let instances = plan.instanceCount * MemoryLayout<DioramaInstanceData>.stride
        let groupCPU = plan.groupInstances * MemoryLayout<DioramaInstanceData>.stride
        let ground = plan.imageSize * plan.imageSize * 4 * 4 / 3
        let gpu = vertices + indices + instances + ground + plan.paintBytes + plan.lightBytes + plan.lodBytes
        // Painted-ground lookup grid: offsets plus at most a few cell references per triangle.
        let groundGrid = min(plan.indexCapacity / 3 * 8, 4 * 1_048_576)
        let retained = gpu + groupCPU + plan.lightBytes + groundGrid + (plan.ownershipCopy ? indices : 0)
            + effectBytes(context: context, labelTitles: labelTitles, size: size, scale: scale) + 2 * 1_048_576
        // The index buffer is regrown once when roofs are appended (old copy held briefly).
        let transient = 4 * 1_048_576 + plan.vertexCount + groupCPU + instances
            + (plan.ownershipCopy ? indices : 0) + indices + 6 * 1_048_576
        return Cost(retained: retained, peak: retained + transient)
    }

    /// Reconciled after decoding, from the allocations actually made.
    nonisolated static func residentCost(_ tile: DioramaResidentTile, context: Bool, size: CGSize, scale: Float) -> Int {
        // HD tiles draw their 3D rooftop markers (label textures); coarse tiles carry none.
        tile.gpuBytes + tile.cpuBytes + effectBytes(context: context, labelTitles: context ? [] : tile.labels.map(\.title), size: size, scale: scale) + 2 * 1_048_576
    }
}
