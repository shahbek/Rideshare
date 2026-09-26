import Foundation
import Metal

/// Compiles `BuildingMapShaderSource` once per device and hands the same library to every map layer.
nonisolated enum BuildingShaderLibrary {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (device: ObjectIdentifier, library: MTLLibrary)?

    static func library(for device: MTLDevice) -> MTLLibrary? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device)
        if let cached, cached.device == key { return cached.library }
        do {
            let library = try device.makeLibrary(source: BuildingMapShaderSource.source, options: nil)
            cached = (key, library)
            return library
        } catch {
            print("[BuildingShaderLibrary] Shader compile failed")
            return nil
        }
    }
}
