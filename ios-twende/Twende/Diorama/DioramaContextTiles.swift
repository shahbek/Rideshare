import Foundation
@_spi(Experimental) import MapboxMaps

/// Bounded 3×3 context ring. Coarse geometry never replaces the full-detail cache or its effects.
@MainActor
final class DioramaContextTiles {
    private struct Resident {
        let host: DioramaRenderLayer
        let bytes: Int
        let triangles: Int
    }
    private var residents: [DioramaTileID: Resident] = [:]
    private var focus: DioramaTileID?
    private var task: Task<Void, Never>?
    private var revision: UInt = 0
    private weak var map: MapboxMap?
    private var visible: Set<DioramaCategory> = []
    private var time: DioramaTimeOfDay = .dusk
    private var wireframe: Bool = false
    var onReady: ((DioramaTileID) -> Void)?
    var onUnavailable: ((DioramaTileID) -> Void)?

    func groundHeight(at point: GeoPoint) -> Double? {
        let tile = DioramaTileID(latitude: point.latitude, longitude: point.longitude, zoom: 16)
        return residents[tile]?.host.groundHeight(at: point)
    }

    var report: String {
        "Context: \(residents.count) coarse tiles · \(residents.values.reduce(0) { $0 + $1.triangles }) stored tris · \(residents.values.reduce(0) { $0 + $1.bytes } / 1_048_576) MiB packed (not total memory)"
    }

    func update(focus next: DioramaTileID, config: DioramaConfig, map: MapboxMap,
                visible: Set<DioramaCategory>, time: DioramaTimeOfDay, wireframe: Bool) {
        self.map = map; self.visible = visible; self.time = time; self.wireframe = wireframe
        for resident in residents.values {
            resident.host.setVisible(visible, timeOfDay: time)
            resident.host.setWireframe(wireframe)
        }
        guard focus != next else { return }
        cancelPendingInstallations()
        focus = next
        let currentRevision = revision
        let neighbours = (-1...1).flatMap { y in (-1...1).compactMap { x -> DioramaTileID? in
            guard x != 0 || y != 0 else { return nil }
            let tile = DioramaTileID(z: next.z, x: next.x + x, y: next.y + y)
            return DioramaOfflineStore.tiles.contains(tile) ? tile : nil
        }}.sorted {
            let a = abs($0.x - next.x) + abs($0.y - next.y), b = abs($1.x - next.x) + abs($1.y - next.y)
            return a == b ? $0.key < $1.key : a < b
        }
        let wanted = Set(neighbours + [next])
        for tile in Array(residents.keys) where !wanted.contains(tile) { remove(tile) }
        task = Task { [weak self] in
            for tile in neighbours {
                guard let self, !Task.isCancelled, self.revision == currentRevision else { return }
                if self.residents[tile] != nil { self.onReady?(tile); continue }
                let job = Task.detached(priority: .utility) { () -> DioramaTileArtifacts? in
                    guard !Task.isCancelled else { return nil }
                    return await DioramaOfflineStore.shared.read(tile, context: true)
                }
                let artifacts = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, self.revision == currentRevision else { return }
                guard let artifacts else {
                    self.onUnavailable?(tile)
                    DioramaDownloadService.shared.invalidate()
                    return
                }
                // At most eight neighbours and 64 MiB packed data, with one serial temporary build.
                guard self.residents.values.reduce(0, { $0 + $1.bytes }) + artifacts.totalBytes <= 64 * 1_048_576 else { self.onUnavailable?(tile); continue }
                await self.install(artifacts, config: config, revision: currentRevision)
            }
        }
    }

    /// Complement the shared soft field with disjoint screen coverage, not stacked transparent surfaces.
    func setFocusMask(tile: DioramaTileID, reveal: SIMD4<Float>) {
        guard let resident = residents[tile] else { return }
        if reveal.w < 0.5 { remove(tile) }
        else if reveal.w > 1.5 { resident.host.setReveal(SIMD4(reveal.x, reveal.y, reveal.z, 3)) }
        else { remove(tile) }
    }

    func pauseLoading() {
        cancelPendingInstallations()
        focus = nil
    }

    /// Freeze the old ring before handoff; an old installer cannot resurrect the new focus.
    func prepareForFocus() {
        cancelPendingInstallations()
        focus = nil
        for resident in residents.values { resident.host.setReveal(.zero) }
    }

    private func cancelPendingInstallations() {
        task?.cancel(); task = nil; revision &+= 1
        guard let map else { return }
        for tile in Array(residents.keys) where !map.layerExists(withId: id(tile) + "-clip") { remove(tile) }
    }

    func clear() {
        task?.cancel(); task = nil; revision &+= 1
        for tile in Array(residents.keys) { remove(tile) }
        focus = nil
    }

    private func id(_ tile: DioramaTileID) -> String { "zuri-context-\(tile.key)" }

    private func remove(_ tile: DioramaTileID) {
        guard let map else { residents[tile] = nil; return }
        for name in [id(tile) + "-clip", id(tile)] where map.layerExists(withId: name) { try? map.removeLayer(withId: name) }
        if map.sourceExists(withId: id(tile) + "-source") { try? map.removeSource(withId: id(tile) + "-source") }
        residents[tile] = nil
    }

    private func addHost(_ host: DioramaRenderLayer, tile: DioramaTileID, on map: MapboxMap) throws {
        try map.addCustomLayer(withId: id(tile), layerHost: host, layerPosition: nil)
        try map.setLayerProperty(for: id(tile), property: "slot", value: "middle")
    }

    private func install(_ artifacts: DioramaTileArtifacts, config: DioramaConfig, revision expected: UInt) async {
        guard let map else { return }
        let tile = artifacts.tile
        let host = DioramaRenderLayer(origin: tile.centre, vertices: artifacts.vertices, indices: artifacts.indices,
            ranges: artifacts.ranges, groups: artifacts.groups, instances: artifacts.allInstances, lightGrid: artifacts.lightGrid, waterHeight: artifacts.waterHeight,
            groundImage: artifacts.groundImage, groundRect: DioramaProjection(origin: tile.centre).rect(of: tile),
            visible: visible, timeOfDay: time, animates: false, config: config, contextOnly: true)
        host.setReducedEffects(true); host.setWireframe(wireframe)
        do {
            try addHost(host, tile: tile, on: map)
            residents[tile] = Resident(host: host, bytes: artifacts.totalBytes, triangles: artifacts.totalTriangles)
            // Native buildings remain until the replacement actually has a working Metal pipeline.
            for _ in 0..<160 {
                guard !Task.isCancelled, revision == expected, residents[tile]?.host === host else { return }
                if host.hasCompleted(reveal: .zero) { break }
                if host.diagnostic.contains("failed") { remove(tile); onUnavailable?(tile); return }
                map.triggerRepaint()
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, revision == expected, residents[tile]?.host === host else { return }
            guard host.hasCompleted(reveal: .zero) else { remove(tile); onUnavailable?(tile); return }
            var source = GeoJSONSource(id: id(tile) + "-source")
            source.data = .geometry(.polygon(Polygon([tile.outline])))
            try map.addSource(source)
            var clip = ClipLayer(id: id(tile) + "-clip", source: source.id)
            clip.slot = .top; clip.clipLayerScope = .constant(["basemap"]); clip.clipLayerTypes = .constant([.model])
            try map.addLayer(clip)
            onReady?(tile)
            map.triggerRepaint()
        } catch {
            if residents[tile]?.host === host { remove(tile); onUnavailable?(tile) }
        }
    }
}
