import Foundation
import CoreLocation
import Metal

/// Resident lighting resources are reused by the live fleet without invalidating static effect caches.
nonisolated final class DioramaFleetLighting: @unchecked Sendable {
    static let shared = DioramaFleetLighting()
    struct Snapshot {
        let origin: CLLocationCoordinate2D
        let uniforms: DioramaShaderUniforms
        let buffers: [MTLBuffer]
        let textures: [MTLTexture?]
        let fullDetail: Bool
    }
    private final class Entry {
        weak var host: DioramaRenderLayer?
        let snapshot: Snapshot
        init(host: DioramaRenderLayer, snapshot: Snapshot) { self.host = host; self.snapshot = snapshot }
    }
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func publish(host: DioramaRenderLayer, snapshot: Snapshot) {
        lock.lock()
        entries = entries.filter { $0.value.host != nil }
        entries[ObjectIdentifier(host)] = Entry(host: host, snapshot: snapshot)
        lock.unlock()
    }
    func remove(host: DioramaRenderLayer) {
        lock.lock(); entries[ObjectIdentifier(host)] = nil; lock.unlock()
    }
    func environment(at point: GeoPoint) -> (DioramaRenderLayer, Snapshot)? {
        let tile = DioramaTileID(latitude: point.latitude, longitude: point.longitude, zoom: 16)
        lock.lock(); defer { lock.unlock() }
        let candidates = entries.values.filter { entry in
            let c = entry.snapshot.origin
            return entry.host != nil && DioramaTileID(latitude: c.latitude, longitude: c.longitude, zoom: 16) == tile
        }.sorted { $0.snapshot.fullDetail && !$1.snapshot.fullDetail }
        guard let entry = candidates.first, let host = entry.host else { return nil }
        return (host, entry.snapshot)
    }
}
