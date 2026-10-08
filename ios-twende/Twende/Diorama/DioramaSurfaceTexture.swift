import Foundation
import Metal

/// One shared CC0 luminance texture per Metal device. It never uses the map download/cache.
nonisolated enum DioramaSurfaceTexture {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var textures: [ObjectIdentifier: MTLTexture] = [:]

    static func texture(device: MTLDevice) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device)
        if let cached = textures[key] { return cached }
        let size = 256
        let url = Bundle.main.url(forResource: "diorama_microdetail_v1", withExtension: "rgba")
        let bytes = url.flatMap { try? Data(contentsOf: $0) }
        let valid = bytes?.count == size * size * 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: valid ? size : 1, height: valid ? size : 1, mipmapped: valid)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pixels = valid ? (bytes ?? Data()) : Data([128, 128, 128, 255])
        pixels.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, descriptor.width, descriptor.height),
                    mipmapLevel: 0, withBytes: base, bytesPerRow: descriptor.width * 4)
            }
        }
        if valid {
            guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
                  let blit = command.makeBlitCommandEncoder() else { return nil }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { return nil }
        }
        textures[key] = texture
        return texture
    }
}
