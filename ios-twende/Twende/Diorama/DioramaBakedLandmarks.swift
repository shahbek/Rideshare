import CoreLocation
import Foundation
import SceneKit
import simd

/// One bespoke landmark converted once into the diorama vertex grammar, in metres around `origin`.
nonisolated struct DioramaLandmarkBake: @unchecked Sendable {
    struct Geometry: @unchecked Sendable {
        let vertices: [BuildingRenderVertex]
        let indices: [UInt32]
        let ranges: [DioramaRenderLayer.Range]
        let lights: [DioramaLight]
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
    }
    let id: String
    let origin: CLLocationCoordinate2D
    /// Footprint ring (local metres) whose highest supporting ground becomes the floor datum.
    let floorRing: [DV2]
    let geometry: Geometry
}

/// Landmarks are drawn by the saved tile that contains them, exactly like Slipway and Sea Cliff:
/// one renderer, one lifecycle, and the generic saved shell beneath is owned permanently while the
/// tile is resident. Meshes are built once on the main actor and cached on disk per app build;
/// saved scenery packages are never rewritten or re-downloaded.
nonisolated final class DioramaBakedLandmarks: @unchecked Sendable {
    static let shared = DioramaBakedLandmarks()

    private struct Candidate { let id: String; let tiles: Set<DioramaTileID> }
    private static let candidates: [Candidate] = DioramaLandmarkOwnership.outlines.map { site in
        // Bespoke sites have authored aprons; skyline geometry stays within its mapped envelope.
        let margin = DarSkyline.isSkyline(site.id) ? 0.00001 : 0.0005
        let lons = site.ring.map { $0[0] }, lats = site.ring.map { $0[1] }
        let nw = DioramaTileID(latitude: (lats.max() ?? 0) + margin, longitude: (lons.min() ?? 0) - margin, zoom: 16)
        let se = DioramaTileID(latitude: (lats.min() ?? 0) - margin, longitude: (lons.max() ?? 0) + margin, zoom: 16)
        var tiles: Set<DioramaTileID> = []
        for y in nw.y...max(nw.y, se.y) { for x in nw.x...max(nw.x, se.x) { tiles.insert(.init(z: 16, x: x, y: y)) } }
        return Candidate(id: site.id, tiles: tiles)
    }

    /// Bump whenever any bespoke landmark or skyline recipe/conversion changes. Cached meshes (and the
    /// GPU-ready tile snapshots that contain them) then rebuild once. The stamp is deliberately NOT
    /// tied to the app version/build or executable date: every new build used to rebuild all
    /// ~70 harbour recipes before the first full-detail read, which took minutes on each install.
    static let recipeRevision = 3
    private static let stamp: String = "bake4-compositions-r\(recipeRevision)"

    private let lock = NSLock()
    private var building: [String: Task<DioramaLandmarkBake?, Never>] = [:]
    private var failed: Set<String> = []
    private var floors: [String: Double] = [:]
    private var warming: Set<DioramaTileID> = []
    /// Called (off the main actor) when every missing recipe of a tile has been built or rejected.
    private var tileCompletion: (@Sendable (DioramaTileID) -> Void)?

    static func ids(for tile: DioramaTileID) -> [String] { candidates.filter { $0.tiles.contains(tile) }.map(\.id) }
    static func tiles(for id: String) -> Set<DioramaTileID> { candidates.first { $0.id == id }?.tiles ?? [] }
    static var allIDs: [String] { candidates.map(\.id) }

    /// True once a recipe failed validation; that site then keeps its standalone fallback host.
    func isUnavailable(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed.contains(id)
    }

    /// Meshes of `tile` already on disk, and whether every candidate is cached or known-unavailable.
    /// Never builds: a tile read uses this so it is drawn immediately; see `buildMissing`.
    func cachedMeshes(for tile: DioramaTileID) -> (meshes: [DioramaLandmarkBake], complete: Bool) {
        var result: [DioramaLandmarkBake] = []
        var complete = true
        for id in Self.ids(for: tile) where !isUnavailable(id) {
            if let mesh = readDisk(id) { result.append(mesh) } else { complete = false }
        }
        return (result, complete)
    }

    func isComplete(for tile: DioramaTileID) -> Bool {
        Self.ids(for: tile).allSatisfy { isUnavailable($0) || readHeader($0) != nil }
    }

    func setTileCompletion(_ handler: (@Sendable (DioramaTileID) -> Void)?) {
        lock.lock(); tileCompletion = handler; lock.unlock()
    }

    /// Builds the tile's missing recipes in the background (once per tile at a time) and reports
    /// completion so a tile drawn without them can be reloaded with them.
    func buildMissing(for tile: DioramaTileID) {
        lock.lock()
        guard !warming.contains(tile), !Self.ids(for: tile).isEmpty else { lock.unlock(); return }
        warming.insert(tile)
        lock.unlock()
        Task.detached(priority: .userInitiated) { [self] in
            let started = Date()
            let built = await meshes(for: tile)
            lock.lock(); warming.remove(tile); let handler = tileCompletion; lock.unlock()
            print("[DarLandmarks] \(tile.key) recipes ready: \(built.count) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            handler?(tile)
        }
    }

    /// Meshes that may reach `tile`; builds any missing mesh once and caches it. Skyline recipes
    /// build several at a time on background cores; bespoke SceneKit recipes serialise on the main actor.
    func meshes(for tile: DioramaTileID) async -> [DioramaLandmarkBake] {
        let ids = Self.ids(for: tile)
        var result: [String: DioramaLandmarkBake] = [:]
        var pending: [String] = []
        for id in ids where !isUnavailable(id) {
            if let cached = readDisk(id) { result[id] = cached } else { pending.append(id) }
        }
        if !pending.isEmpty {
            let parallel = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
            await withTaskGroup(of: (String, DioramaLandmarkBake?).self) { group in
                var next = 0
                while next < pending.count, next < parallel {
                    let id = pending[next]; next += 1
                    group.addTask { (id, await self.mesh(id)) }
                }
                while let (id, mesh) = await group.next() {
                    if let mesh { result[id] = mesh }
                    if next < pending.count, !Task.isCancelled {
                        let id = pending[next]; next += 1
                        group.addTask { (id, await self.mesh(id)) }
                    }
                }
            }
        }
        return ids.compactMap { result[$0] }
    }

    func mesh(_ id: String) async -> DioramaLandmarkBake? {
        if isUnavailable(id) { return nil }
        if let cached = readDisk(id) { return cached }
        lock.lock()
        let task: Task<DioramaLandmarkBake?, Never>
        if let pending = building[id] { task = pending } else {
            // Skyline towers use the nonisolated diorama kit; bespoke recipes need SceneKit on the main actor.
            task = DarSkyline.isSkyline(id)
                ? Task.detached(priority: .userInitiated) { DarSkyline.build(id) }
                : Task { @MainActor in DioramaLandmarkBakery.build(id) }
            building[id] = task
        }
        lock.unlock()
        let built = await task.value
        lock.lock()
        if building[id] == task {
            building[id] = nil
            if built == nil { failed.insert(id) }
        }
        lock.unlock()
        if let built { writeDisk(built) }
        return built
    }

    /// Build every missing mesh ahead of the first tile read, one site at a time.
    func prewarm() async {
        // Skyline work follows actual tile demand, not a 70-building startup construction queue.
        for id in Self.allIDs.filter({ !DarSkyline.isSkyline($0) }) {
            if Task.isCancelled { return }
            _ = await mesh(id)
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Additional vertices/indices a tile read will append (header only; 0 before the first build).
    func counts(for tile: DioramaTileID) -> (vertices: Int, indices: Int) {
        Self.ids(for: tile).reduce((0, 0)) { total, id in
            guard let header = readHeader(id) else { return total }
            return (total.0 + header.vertexCount, total.1 + header.indexCount)
        }
    }

    /// Recipe stamp plus the candidate sites of `tile`; part of the GPU-ready snapshot identity.
    func snapshotIdentity(for tile: DioramaTileID) -> String {
        Self.stamp + "|" + Self.ids(for: tile).sorted().joined(separator: ",")
    }

    func markUnavailable(_ id: String) {
        lock.lock(); failed.insert(id); lock.unlock()
    }

    func knownFloor(_ id: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return floors[id]
    }

    /// Adopts a snapshot's floor; false when this session already chose a different datum.
    func adopt(floor value: Double, for id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let known = floors[id] { return abs(known - value) < 0.0001 }
        floors[id] = value
        return true
    }

    /// One floor datum per site and session, so a landmark split across two tiles never steps.
    func floor(for id: String, sample: () -> Double?) -> Double {
        lock.lock()
        if let known = floors[id] { lock.unlock(); return known }
        lock.unlock()
        guard let value = sample() else { return 0 }
        lock.lock(); defer { lock.unlock() }
        if let known = floors[id] { return known }
        floors[id] = value
        return value
    }

    // MARK: - Disk cache

    private struct Header: Codable {
        struct R: Codable {
            let category: DioramaCategory
            let start: Int
            let count: Int
            let minimum: [Float]
            let maximum: [Float]
            let doubleSided: Bool
            let translucent: Bool
        }
        struct L: Codable { let p: [Double]; let c: [Float]; let radius: Double; let intensity: Float }
        let id: String
        let stamp: String
        let latitude: Double
        let longitude: Double
        let vertexCount: Int
        let indexCount: Int
        let ranges: [R]
        let lights: [L]
        let ring: [[Double]]
        let minimum: [Float]
        let maximum: [Float]
    }

    private var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BakedLandmarks", isDirectory: true)
    }

    private func readHeader(_ id: String) -> Header? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("\(id).json")),
              let header = try? JSONDecoder().decode(Header.self, from: data), header.id == id, header.stamp == Self.stamp else { return nil }
        return header
    }

    private func readDisk(_ id: String) -> DioramaLandmarkBake? {
        guard let h = readHeader(id), h.vertexCount > 0, h.indexCount > 0, h.indexCount % 3 == 0,
              let data = try? Data(contentsOf: root.appendingPathComponent("\(id).bin"), options: .mappedIfSafe) else { return nil }
        let vertexBytes = h.vertexCount * MemoryLayout<BuildingRenderVertex>.stride
        guard data.count == vertexBytes + h.indexCount * 4 else { return nil }
        var vertices = [BuildingRenderVertex](repeating: BuildingRenderVertex(position: .zero, normal: .zero, color: .zero, appearance: .zero), count: h.vertexCount)
        var indices = [UInt32](repeating: 0, count: h.indexCount)
        data.withUnsafeBytes { raw in
            vertices.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[0..<vertexBytes])) }
            indices.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[vertexBytes..<data.count])) }
        }
        guard indices.allSatisfy({ Int($0) < h.vertexCount }),
              h.ranges.allSatisfy({ $0.start >= 0 && $0.count >= 0 && $0.start + $0.count <= h.indexCount && $0.minimum.count == 3 && $0.maximum.count == 3 }),
              h.minimum.count == 3, h.maximum.count == 3 else { return nil }
        let ranges = h.ranges.map { r in
            DioramaRenderLayer.Range(category: r.category, start: r.start, count: r.count,
                minimum: SIMD3(r.minimum[0], r.minimum[1], r.minimum[2]), maximum: SIMD3(r.maximum[0], r.maximum[1], r.maximum[2]),
                doubleSided: r.doubleSided, translucent: r.translucent)
        }
        let lights = h.lights.filter { $0.p.count == 3 && $0.c.count == 3 }.map {
            DioramaLight(position: DV3($0.p[0], $0.p[1], $0.p[2]), color: SIMD3($0.c[0], $0.c[1], $0.c[2]), radius: $0.radius, intensity: $0.intensity)
        }
        return DioramaLandmarkBake(id: id, origin: CLLocationCoordinate2D(latitude: h.latitude, longitude: h.longitude),
            floorRing: h.ring.filter { $0.count == 2 }.map { DV2($0[0], $0[1]) },
            geometry: .init(vertices: vertices, indices: indices, ranges: ranges, lights: lights,
                minimum: SIMD3(h.minimum[0], h.minimum[1], h.minimum[2]), maximum: SIMD3(h.maximum[0], h.maximum[1], h.maximum[2])))
    }

    private func writeDisk(_ bake: DioramaLandmarkBake) {
        let g = bake.geometry
        let header = Header(id: bake.id, stamp: Self.stamp, latitude: bake.origin.latitude, longitude: bake.origin.longitude,
            vertexCount: g.vertices.count, indexCount: g.indices.count,
            ranges: g.ranges.map { .init(category: $0.category, start: $0.start, count: $0.count,
                minimum: [$0.minimum.x, $0.minimum.y, $0.minimum.z], maximum: [$0.maximum.x, $0.maximum.y, $0.maximum.z],
                doubleSided: $0.doubleSided, translucent: $0.translucent) },
            lights: g.lights.map { .init(p: [$0.position.x, $0.position.y, $0.position.z], c: [$0.color.x, $0.color.y, $0.color.z], radius: $0.radius, intensity: $0.intensity) },
            ring: bake.floorRing.map { [$0.x, $0.y] },
            minimum: [g.minimum.x, g.minimum.y, g.minimum.z], maximum: [g.maximum.x, g.maximum.y, g.maximum.z])
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var data = Data()
            g.vertices.withUnsafeBytes { data.append(contentsOf: $0) }
            g.indices.withUnsafeBytes { data.append(contentsOf: $0) }
            // Geometry first, header last: a header always describes a complete mesh file.
            try data.write(to: root.appendingPathComponent("\(bake.id).bin"), options: .atomic)
            try JSONEncoder().encode(header).write(to: root.appendingPathComponent("\(bake.id).json"), options: .atomic)
        } catch {
            print("[DarLandmarks] \(bake.id) mesh cache write failed; rebuilt next launch")
        }
    }
}

/// Builds landmark recipes with their established SceneKit generators (main actor only).
@MainActor
enum DioramaLandmarkBakery {
    static func build(_ id: String) -> DioramaLandmarkBake? {
        let started = Date()
        let scene: SCNScene, ring: [SIMD2<Double>], origin: CLLocationCoordinate2D
        if id == "airtel" {
            guard let geometry = AirtelBuildingSite.geometry else { return nil }
            scene = AirtelBuildingGeometry.make(geometry: geometry)
            ring = AirtelBuildingSite.footprint(geometry)?.rings.first ?? []
            origin = AirtelBuildingSite.anchor.coordinate
        } else {
            guard let site = DarLandmarkSite.all.first(where: { $0.id == id }) else { return nil }
            scene = DarLandmarkGeometry.make(site)
            if site.isBudgetedArchitecture, HarbourArchitectureParts.validate(scene, site: site) == nil {
                print("[DarLandmarks] \(id) bake rejected: \(HarbourArchitectureParts.lastRejection)")
                return nil
            }
            ring = site.footprint?.rings.first ?? []
            origin = site.anchor.coordinate
        }
        let geometry = DioramaLandmarkMesh.standard(scene)
        guard !geometry.indices.isEmpty, geometry.minimum.x.isFinite, geometry.maximum.x.isFinite else {
            print("[DarLandmarks] \(id) bake produced no geometry")
            return nil
        }
        print("[DarLandmarks] \(id) baked for saved tiles: \(geometry.indices.count / 3) triangles in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return DioramaLandmarkBake(id: id, origin: origin, floorRing: ring.map { DV2($0.x, $0.y) }, geometry: geometry)
    }

    /// Main-actor gate for the standalone hosts: a landmark whose tile is saved and shown by the
    /// diorama is drawn by that tile, never by a second custom layer.
    static func isDrawnBySavedTile(_ id: String) -> Bool {
        let state = DioramaState.shared
        guard state.isEnabled, !state.isBasemapOnly, !DioramaBakedLandmarks.shared.isUnavailable(id) else { return false }
        let tiles = DioramaBakedLandmarks.tiles(for: id)
        return !tiles.isEmpty && tiles.contains { DioramaOfflineStore.hasSavedPackage($0) }
    }
}

nonisolated extension DioramaLightGrid {
    /// The same grid with extra lights appended to every cell they reach.
    func merging(_ extra: [DioramaShaderLight], perCell: Int = 16) -> DioramaLightGrid {
        guard !extra.isEmpty, cells > 0, cellSize > 0 else { return self }
        var buckets: [[UInt32]] = table.map { entry in Array(indices[Int(entry.x)..<Int(entry.x + entry.y)]) }
        let base = UInt32(lights.count)
        for (i, light) in extra.enumerated() {
            let r = light.position.w
            let x0 = max(Int((light.position.x - r - minX) / cellSize), 0), x1 = min(Int((light.position.x + r - minX) / cellSize), cells - 1)
            let y0 = max(Int((light.position.y - r - minY) / cellSize), 0), y1 = min(Int((light.position.y + r - minY) / cellSize), cells - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 where buckets[y * cells + x].count < perCell { buckets[y * cells + x].append(base + UInt32(i)) } }
        }
        var newTable: [SIMD2<UInt32>] = [], newIndices: [UInt32] = []
        newTable.reserveCapacity(buckets.count)
        for bucket in buckets {
            newTable.append(SIMD2(UInt32(newIndices.count), UInt32(bucket.count)))
            newIndices.append(contentsOf: bucket)
        }
        return DioramaLightGrid(cells: cells, minX: minX, minY: minY, cellSize: cellSize, lights: lights + extra, table: newTable, indices: newIndices)
    }
}
