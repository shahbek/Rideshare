import CoreLocation
import Foundation
import simd

/// One researched major building: its verified OSM outline plus the Dar style recipe and a short
/// architectural description (`Resources/dar_skyline.json`).
nonisolated struct DarSkylineSite: Decodable, Sendable {
    let id: String
    let osm: UInt64
    let name: String?
    let levels: Int
    let height: Double
    let district: String
    let style: String
    let wall: String
    let accent: String
    let glass: String
    let roof: String
    let crown: String
    let balconies: String
    let description: String
    let ring: [[Double]]
}

/// Major towers are drawn by the saved tile that contains them (Slipway method), replacing the
/// generic saved shell under their footprint. Meshes are built off the main thread with the
/// diorama kit and cached with the other baked landmarks; saved scenery is never rewritten.
nonisolated enum DarSkyline {
    private struct Catalog: Decodable { let sites: [DarSkylineSite] }

    static let sites: [DarSkylineSite] = {
        guard let url = Bundle.main.url(forResource: "dar_skyline", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.sites.filter { $0.ring.count >= 4 && $0.ring.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } }
    }()

    private static let index: [String: DarSkylineSite] = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func isSkyline(_ id: String) -> Bool { id.hasPrefix("sky-") }
    static func site(_ id: String) -> DarSkylineSite? { index[id] }

    /// Whole-building validation remains mandatory; live all-catalogue counts are not presumed.
    private static let maxTriangles = 40_000

    static func build(_ id: String) -> DioramaLandmarkBake? {
        guard let site = site(id) else { return nil }
        let started = Date()
        let lons = site.ring.map { $0[0] }, lats = site.ring.map { $0[1] }
        let origin = CLLocationCoordinate2D(latitude: lats.reduce(0, +) / Double(lats.count), longitude: lons.reduce(0, +) / Double(lons.count))
        let projection = DioramaProjection(origin: origin)
        let raw = site.ring.map { projection.local(longitude: $0[0], latitude: $0[1]) }
        let clean = DioramaPolygon.clean(raw, flags: Array(repeating: false, count: raw.count)).points
        let ring = DioramaPolygon.counterClockwise(clean)
        guard ring.count >= 3, DioramaPolygon.area(ring) > 60 else { return nil }

        var mesh = DioramaMesh(), glow = DioramaMesh()
        var lights: [DioramaLight] = []
        let built: Bool
        let recipe: String
        if let composition = DarSkylineComposition.design(for: id) {
            built = DarComposedTower(site: site, design: composition).build(ring, into: &mesh, glow: &glow, lights: &lights)
            recipe = "address-specific composition"
        } else {
            var generator = DarTowerGenerator(site: site)
            built = generator.build(ring, into: &mesh, glow: &glow, lights: &lights)
            recipe = "legacy family fallback"
        }
        guard built,
              [mesh, glow].allSatisfy({ model in
                  model.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                      && model.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                      && model.positions.allSatisfy { p in
                          let xy = DV2(p.x, p.y)
                          return DioramaPolygon.contains(ring, xy) || DioramaPolygon.distanceToRing(ring, xy) <= 0.8
                      }
              }) else {
            print("[DarSkyline] \(id) rejected: invalid plan, non-finite geometry or mapped-outline overrun")
            return nil
        }
        let geometry = pack([(.buildings, mesh), (.windowGlow, glow)], lights: lights)

        // Validation: finite, bounded, and standing on its own mapped footprint.
        let low = ring.reduce(DV2(.infinity, .infinity)) { DV2(min($0.x, $1.x), min($0.y, $1.y)) }
        let high = ring.reduce(DV2(-.infinity, -.infinity)) { DV2(max($0.x, $1.x), max($0.y, $1.y)) }
        let margin: Float = 0.8
        guard !geometry.indices.isEmpty, geometry.indices.count / 3 <= maxTriangles,
              geometry.minimum.x.isFinite, geometry.maximum.z.isFinite,
              geometry.minimum.x >= Float(low.x) - margin, geometry.minimum.y >= Float(low.y) - margin,
              geometry.maximum.x <= Float(high.x) + margin, geometry.maximum.y <= Float(high.y) + margin,
              geometry.maximum.z <= Float(site.height) + 6 else {
            print("[DarSkyline] \(id) rejected: \(geometry.indices.count / 3) triangles or out of footprint")
            return nil
        }
        print("[DarSkyline] \(id) \(recipe) baked: \(geometry.indices.count / 3) triangles in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return DioramaLandmarkBake(id: id, origin: origin, floorRing: ring, geometry: geometry)
    }

    /// Diorama meshes into the baked-landmark grammar: shader codes from the shared packing and
    /// deterministic 60 m bins, double-sided triangles apart.
    static func pack(_ meshes: [(DioramaCategory, DioramaMesh)], lights: [DioramaLight]) -> DioramaLandmarkBake.Geometry {
        var vertices: [BuildingRenderVertex] = [], indices: [UInt32] = [], ranges: [DioramaRenderLayer.Range] = []
        struct VertexKey: Hashable {
            let position: SIMD4<Float>
            let normal: SIMD4<Float>
            let color: SIMD4<Float>
            let appearance: SIMD4<Float>
        }
        var shared: [VertexKey: UInt32] = [:]
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for (category, mesh) in meshes where !mesh.indices.isEmpty {
            // Exact welding only: preserve hard normals, material IDs, glow and height grading.
            // Floor/profile seams no longer allocate several identical packed vertices.
            var remap: [UInt32] = []
            remap.reserveCapacity(mesh.positions.count)
            for packedVertex in DioramaMeshPacking.vertices(mesh, category: category, config: .slipway) {
                // Skyline window light blooms on a share of towers (selected in the emissive prepass).
                let a = packedVertex.appearance
                let v = category == .windowGlow
                    ? BuildingRenderVertex(position: packedVertex.position, normal: packedVertex.normal, color: packedVertex.color,
                                           appearance: SIMD4(a.x, 2, a.z, a.w))
                    : packedVertex
                let key = VertexKey(position: v.position, normal: v.normal, color: v.color, appearance: v.appearance)
                if let index = shared[key] { remap.append(index) }
                else {
                    let index = UInt32(vertices.count)
                    shared[key] = index; remap.append(index); vertices.append(v)
                }
            }
            let count = UInt32(mesh.positions.count)
            let flags = mesh.doubleSidedTriangles
            var cells: [Int: [UInt32]] = [:]
            for i in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
                guard a < count, b < count, c < count else { continue }
                let p = (mesh.positions[Int(a)] + mesh.positions[Int(b)] + mesh.positions[Int(c)]) * (1.0 / 3)
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                let twoSided = i / 3 < flags.count && flags[i / 3]
                let key = (Int(floor(p.x / 60)) + 500 + (Int(floor(p.y / 60)) + 500) * 1000) * 2 + (twoSided ? 1 : 0)
                cells[key, default: []].append(contentsOf: [remap[Int(a)], remap[Int(b)], remap[Int(c)]])
            }
            for key in cells.keys.sorted() {
                guard let batch = cells[key] else { continue }
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                for id in batch {
                    let v = vertices[Int(id)].position
                    lo = simd_min(lo, SIMD3(v.x, v.y, v.z)); hi = simd_max(hi, SIMD3(v.x, v.y, v.z))
                }
                ranges.append(.init(category: category, start: indices.count, count: batch.count, minimum: lo, maximum: hi,
                                    doubleSided: key & 1 == 1 || category.isEmissive))
                indices.append(contentsOf: batch)
                if !category.isEmissive { low = simd_min(low, lo); high = simd_max(high, hi) }
            }
        }
        return .init(vertices: vertices, indices: indices, ranges: ranges, lights: lights, minimum: low, maximum: high)
    }
}
