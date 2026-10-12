import Foundation
import QuartzCore

/// Render-time diagnostic switches read by every diorama host on the render thread, plus the
/// triangles each host submitted per category in its latest plan. Settings-only; never persisted.
nonisolated final class DioramaDebugSwitches: @unchecked Sendable {
    static let shared = DioramaDebugSwitches()

    struct Flags: Equatable, Sendable {
        var labels: Bool = true
        /// Per-pixel street lamps / doorway lights.
        var pointLights: Bool = true
        /// Vector road paint, pavements and lane markings evaluated per pixel on the ground.
        var groundPaint: Bool = true
        /// Shader-drawn windows, doors and corners on facade walls.
        var facadeShader: Bool = true
        /// Sun shadow map (re-draws every caster from the sun).
        var shadows: Bool = true
        /// Screen-space bloom on lit windows and lamps.
        var bloom: Bool = true
    }

    /// What one host drew in its current plan.
    struct HostStats: Sendable {
        var triangles: [DioramaCategory: Int] = [:]
        var drawCalls: Int = 0
        var shadowTriangles: Int = 0
        var labels: Int = 0
        var lights: Int = 0
        var gpuMS: Double?
        var updated: CFTimeInterval = 0
    }

    private let lock = NSLock()
    private var storedFlags = Flags()
    private var hosts: [ObjectIdentifier: HostStats] = [:]

    var flags: Flags {
        get { lock.lock(); defer { lock.unlock() }; return storedFlags }
        set { lock.lock(); storedFlags = newValue; lock.unlock() }
    }

    func record(_ host: ObjectIdentifier, _ update: (inout HostStats) -> Void) {
        lock.lock()
        var stats = hosts[host] ?? HostStats()
        update(&stats)
        stats.updated = CACurrentMediaTime()
        hosts[host] = stats
        lock.unlock()
    }

    func remove(_ host: ObjectIdentifier) {
        lock.lock(); hosts[host] = nil; lock.unlock()
    }

    /// Hosts that drew within the last two seconds (anything older is off screen).
    func liveHosts() -> [HostStats] {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        return hosts.values.filter { now - $0.updated < 2 }
    }
}
