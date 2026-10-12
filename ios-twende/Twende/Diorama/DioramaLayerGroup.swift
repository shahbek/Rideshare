import Foundation
import MapboxMaps
import Metal

/// One Mapbox custom layer that draws every resident scenery tile (coarse first, then full detail),
/// instead of one style layer per tile. Mapbox evaluates, orders and sets up a single layer per frame;
/// each member still encodes exactly the same passes it did as its own layer, in the same order.
///
/// Members are started lazily inside the SDK's render callback with the SDK's device and formats,
/// and ended when detached or when the group layer itself is removed (style reload, teardown).
nonisolated final class DioramaLayerGroup: NSObject, CustomLayerHost, @unchecked Sendable {
    static let layerID = "zuri-diorama-group"

    private struct Member {
        let id: String
        let order: Int
        let sequence: Int
        let host: CustomLayerHost
        var started: Bool
    }

    private let lock = NSLock()
    private var members: [Member] = []
    private var sequence = 0
    private var device: MTLDevice?
    private var formats: (color: UInt, depth: UInt)?

    @MainActor private static var groups: [ObjectIdentifier: DioramaLayerGroup] = [:]

    /// The map's group, re-adding its style layer if a style reload removed it.
    @MainActor static func group(for map: MapboxMap) throws -> DioramaLayerGroup {
        let key = ObjectIdentifier(map)
        let group = groups[key] ?? DioramaLayerGroup()
        groups[key] = group
        if !map.layerExists(withId: layerID) {
            group.endAll()
            try map.addCustomLayer(withId: layerID, layerHost: group, layerPosition: nil)
            try map.setLayerProperty(for: layerID, property: "slot", value: "middle")
        }
        return group
    }

    /// The map's group without creating or re-adding its layer.
    @MainActor static func existing(for map: MapboxMap) -> DioramaLayerGroup? { groups[ObjectIdentifier(map)] }

    /// Adds a member drawn after all members of a lower `order` (0 coarse, 1 full detail).
    @MainActor func attach(_ host: CustomLayerHost, id: String, order: Int, map: MapboxMap) {
        lock.lock()
        members.removeAll { $0.id == id }
        sequence += 1
        members.append(Member(id: id, order: order, sequence: sequence, host: host, started: false))
        members.sort { ($0.order, $0.sequence) < ($1.order, $1.sequence) }
        lock.unlock()
        map.triggerRepaint()
    }

    @MainActor func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return members.contains { $0.id == id }
    }

    /// Removes a member and releases its GPU resources, as removing its own layer did.
    @MainActor func detach(_ id: String) {
        lock.lock()
        let removed = members.filter { $0.id == id }
        members.removeAll { $0.id == id }
        lock.unlock()
        for member in removed where member.started { member.host.renderingWillEnd() }
    }

    private func endAll() {
        lock.lock()
        let started = members.filter(\.started)
        for i in members.indices { members[i].started = false }
        lock.unlock()
        for member in started { member.host.renderingWillEnd() }
    }

    func renderingWillStart(_ metalDevice: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        lock.lock()
        device = metalDevice; formats = (colorPixelFormat, depthStencilPixelFormat)
        for i in members.indices { members[i].started = false }
        lock.unlock()
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        lock.lock()
        guard let device, let formats else { lock.unlock(); return }
        var pending: [CustomLayerHost] = []
        for i in members.indices where !members[i].started {
            members[i].started = true; pending.append(members[i].host)
        }
        let snapshot = members.map(\.host)
        lock.unlock()
        for host in pending {
            host.renderingWillStart(device, colorPixelFormat: formats.color, depthStencilPixelFormat: formats.depth)
        }
        for host in snapshot {
            host.render(parameters, mtlCommandBuffer: mtlCommandBuffer, mtlRenderPassDescriptor: mtlRenderPassDescriptor)
        }
    }

    func renderingWillEnd() {
        endAll()
        lock.lock(); device = nil; formats = nil; lock.unlock()
    }
}
