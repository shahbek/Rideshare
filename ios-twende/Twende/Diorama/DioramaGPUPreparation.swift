import Foundation
import Metal

/// Captures the actual SDK device/formats; future tile uploads can finish before entering its render loop.
nonisolated final class DioramaGPUPreparation: @unchecked Sendable {
    static let shared = DioramaGPUPreparation()
    struct Configuration: @unchecked Sendable {
        let device: MTLDevice
        let color: UInt
        let depth: UInt
    }
    private let lock = NSLock()
    private var configuration: Configuration?
    private var size: (Int, Int) = (0, 0)

    func capture(device: MTLDevice, color: UInt, depth: UInt) {
        lock.lock(); configuration = .init(device: device, color: color, depth: depth); lock.unlock()
    }
    func captureSize(width: Int, height: Int) {
        lock.lock(); size = (width, height); lock.unlock()
    }
    func prepare(_ host: DioramaRenderLayer) {
        lock.lock(); let config = configuration; let size = self.size; lock.unlock()
        guard let config else { return }
        autoreleasepool {
            host.renderingWillStart(config.device, colorPixelFormat: config.color, depthStencilPixelFormat: config.depth)
            if size.0 > 0, size.1 > 0 { host.prepareOutputSize(width: size.0, height: size.1) }
        }
    }
}
