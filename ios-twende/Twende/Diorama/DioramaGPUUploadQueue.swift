import Foundation

/// Serial pre-registration uploads avoid bursts of allocations competing with the map render thread.
actor DioramaGPUUploadQueue {
    static let shared = DioramaGPUUploadQueue()
    func prepare(_ host: DioramaRenderLayer) {
        guard !Task.isCancelled else { return }
        DioramaGPUPreparation.shared.prepare(host)
    }
}
