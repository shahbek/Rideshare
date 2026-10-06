import Foundation
import Metal

/// Immutable pipeline states are shared across tile hosts; buffers and render targets stay per tile.
/// Only for the diorama's fixed library and vertex layouts (no function constants/descriptors).
nonisolated final class DioramaPipelineCache: @unchecked Sendable {
    static let shared = DioramaPipelineCache()
    private let lock = NSLock()
    private var states: [String: MTLRenderPipelineState] = [:]

    func state(device: MTLDevice, descriptor d: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState {
        var parts = [String(device.registryID), d.vertexFunction?.name ?? "", d.fragmentFunction?.name ?? "",
                     String(d.depthAttachmentPixelFormat.rawValue), String(d.stencilAttachmentPixelFormat.rawValue),
                     String(d.rasterSampleCount), String(d.isAlphaToCoverageEnabled), String(d.isRasterizationEnabled)]
        for i in 0..<8 {
            guard let a = d.colorAttachments[i] else { continue }
            parts.append("\(a.pixelFormat.rawValue):\(a.writeMask.rawValue):\(a.isBlendingEnabled):\(a.sourceRGBBlendFactor.rawValue):\(a.destinationRGBBlendFactor.rawValue):\(a.rgbBlendOperation.rawValue):\(a.sourceAlphaBlendFactor.rawValue):\(a.destinationAlphaBlendFactor.rawValue):\(a.alphaBlendOperation.rawValue)")
        }
        let key = parts.joined(separator: "|")
        lock.lock(); defer { lock.unlock() }
        if let existing = states[key] { return existing }
        let state = try device.makeRenderPipelineState(descriptor: d)
        states[key] = state
        return state
    }
}
