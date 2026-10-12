import CoreLocation
import Foundation
import simd

/// Bundled OpenStreetMap vegetation (ODbL): every mapped tree node in the prepared regions, tree rows,
/// wood/forest, scrub/heath, grassland/meadow, wetland and park/garden polygons.
nonisolated struct DarVegetation: Decodable, Sendable {
    nonisolated struct Area: Decodable, Sendable { let id: Int64; let kind: String; let ring: [[Double]] }
    nonisolated struct Row: Decodable, Sendable { let id: Int64; let line: [[Double]] }
    let areas: [Area]
    let rows: [Row]
    /// [longitude, latitude, species code] (0 unspecified, 1 baobab, 2 palm, 3 flamboyant, 4 mango, 5 terminalia/ficus).
    let trees: [[Double]]

    static let bundled: DarVegetation? = {
        guard let url = Bundle.main.url(forResource: "dar_vegetation", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let data = try? JSONDecoder().decode(DarVegetation.self, from: bytes) else {
            print("[DarVegetation] bundled vegetation unavailable")
            return nil
        }
        return data
    }()
}

/// Mapped planting at saved-tile read. Saved packages carry the generator's own park trees; this adds
/// what OpenStreetMap actually maps: individual trees where they stand (baobabs as baobabs), woodland
/// and the bush that covers the peninsula tip around the old SAM site, scrub, grassland, wetland edges,
/// gardens and tree rows. Eleven shared prototypes (big shade fig, mango, pink tabebuia, flamboyant,
/// umbrella acacia, neem, coconut palm, baobab, scrub bush, thicket, low shrub) are appended to the
/// tile once and drawn as GPU instances. Everything is deterministic per position, so HD and coarse
/// agree, and nothing is placed on roads, paving, sand, golf turf, buildings, walls or water.
nonisolated enum DioramaVegetation {
    nonisolated enum Kind: Int, CaseIterable, Sendable {
        case shadeGiant, mango, pinkTabebuia, flamboyant, umbrellaAcacia, neem, palm, baobab, scrubBush, thicket, lowShrub
        var isTree: Bool { rawValue <= Kind.baobab.rawValue }
    }

    nonisolated struct Prototype: Sendable {
        let vertices: [DioramaPackedVertex]
        let full: [UInt32]
        let light: [UInt32]
        let radius: Float
    }

    nonisolated struct Placement: Sendable {
        let kind: Kind
        let data: DioramaInstanceData
    }

    /// Built once per process; full and light tessellations share one vertex list.
    static let prototypes: [Prototype] = Kind.allCases.map { kind in
        let full = mesh(kind, light: false), light = mesh(kind, light: true)
        var vertices = DioramaMeshPacking.vertices(full, category: .vegetation, config: .slipway).map(DioramaPackedVertex.init)
        let offset = UInt32(vertices.count)
        vertices += DioramaMeshPacking.vertices(light, category: .vegetation, config: .slipway).map(DioramaPackedVertex.init)
        var radius = 0.0
        for p in full.positions { radius = max(radius, (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()) }
        return Prototype(vertices: vertices, full: full.indices, light: light.indices.map { $0 + offset }, radius: Float(radius))
    }
    static var vertexCount: Int { prototypes.reduce(0) { $0 + $1.vertices.count } }

    // MARK: Prototypes

    /// Skill puff kit (`DioramaPuffKit`): puff crowns with canopy normals and a vertex gradient,
    /// open trunks, buried faces dropped; 80-face puffs close, 20 far.
    private static func mesh(_ kind: Kind, light: Bool) -> DioramaMesh {
        let seed = UInt64(kind.rawValue + 1) &* 0x9E37
        var rng = DioramaRandom(seed: seed, salt: 0x56_45_47)
        switch kind {
        case .shadeGiant:
            // Wide fig/rain-tree crown, 11-12 m tall and about 14 m across.
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 3.6, radius: 5.4, squash: 0.62, ring: 7, spread: 0.62,
                                           DioramaPuffKit.green, light: light, trunkRadius: 0.55)
        case .mango:
            // Dense dark evergreen dome on a short trunk.
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 2.2, radius: 3.8, squash: 0.86, ring: 6, spread: 0.5,
                                           DioramaPuffKit.deep, light: light, trunkRadius: 0.4)
        case .pinkTabebuia:
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 2.9, radius: 2.8, squash: 0.8, ring: 6, spread: 0.6,
                                           DioramaPuffKit.blossom, light: light, trunkRadius: 0.28)
        case .flamboyant:
            // Flame tree: a broad, flat scarlet umbrella.
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 3.0, radius: 4.2, squash: 0.48, ring: 7, spread: 0.66,
                                           DioramaPuffKit.flame, light: light, trunkRadius: 0.34)
        case .umbrellaAcacia:
            // Flat-topped savanna acacia: slim stem under a wide thin table.
            return DioramaPuffKit.puffTree(seed: seed, trunkHeight: 3.8, radius: 3.6, squash: 0.36, ring: 6, spread: 0.7,
                                           DioramaPuffKit.olive, light: light, trunkRadius: 0.22)
        case .neem:
            // Tall oval shade tree along roads.
            return DioramaPuffKit.tieredTree(seed: seed, trunkHeight: 3.4, tiers: 4, radius: 2.5, taper: 0.4, step: 1.5,
                                             DioramaPuffKit.green, light: light)
        case .palm:
            return DioramaPuffKit.palm(seed: 41, lean: 0.8, light: light)
        case .baobab:
            // Swollen bottle trunk, short stubby limbs, sparse leaf puffs.
            var m = DioramaMesh()
            DioramaPuffKit.limb(&m, from: DV3(0, 0, -0.05), to: DV3(0, 0, 3.2), r0: 1.45, r1: 1.05, light: light, .palmTrunk)
            DioramaPuffKit.limb(&m, from: DV3(0, 0, 3.2), to: DV3(0, 0, 5.6), r0: 1.05, r1: 0.62, light: light, .palmTrunk)
            var blobs: [DioramaPuffKit.Blob] = []
            let limbs = light ? 3 : 5
            for k in 0..<limbs {
                let a = Double(k) * Double.pi * 2 / Double(limbs) + 0.4
                let tip = DV3(cos(a) * 3.0, sin(a) * 3.0, 7.4 + Double(k % 2) * 0.6)
                DioramaPuffKit.limb(&m, from: DV3(0, 0, 5.2), to: tip, r0: 0.42, r1: 0.16, light: light, .palmTrunk)
                blobs.append(.init(tip + DV3(0, 0, 0.4), 1.25, squash: 0.62))
            }
            DioramaPuffKit.canopy(&m, blobs, DioramaPuffKit.olive, light: light)
            return m
        case .scrubBush:
            return DioramaPuffKit.bush(seed: seed, size: 1.25, puffs: 4, DioramaPuffKit.olive, light: light)
        case .thicket:
            var m = DioramaMesh()
            var blobs: [DioramaPuffKit.Blob] = []
            for (k, offset) in [DV2(0, 0), DV2(1.4, 0.6), DV2(-1.1, 0.9), DV2(0.3, -1.2)].enumerated() where !light || k < 2 {
                let r = rng.range(1.15...1.45)
                blobs.append(.init(DV3(offset, r * 0.75), r, squash: 0.82))
            }
            DioramaPuffKit.canopy(&m, blobs, DioramaPuffKit.hedge, light: light, swatch: .hedge)
            return m
        case .lowShrub:
            return DioramaPuffKit.bush(seed: seed, size: 0.7, puffs: 3, DioramaPuffKit.hedge, light: light)
        }
    }

    // MARK: Placement

    /// - Parameters:
    ///   - allowed: true where a stem may stand (natural ground, clear of buildings/walls) and its height.
    ///   - occupied: true where an existing saved tree already stands within `radius`.
    static func placements(tile rect: DioramaRect, projection: DioramaProjection, bushes: Bool, limit: Int,
                           ground: (DV2, Bool) -> Double?, occupied: (DV2, Double) -> Bool) -> [Placement] {
        guard let data = DarVegetation.bundled else { return [] }
        var out: [Placement] = []
        var taken: [Int64: [DV2]] = [:]
        func cellKey(_ p: DV2) -> Int64 { (Int64(floor(p.x / 4)) << 32) ^ (Int64(floor(p.y / 4)) & 0xFFFF_FFFF) }
        func clear(_ p: DV2, _ spacing: Double) -> Bool {
            let cx = Int64(floor(p.x / 4)), cy = Int64(floor(p.y / 4))
            for dy in -1...1 { for dx in -1...1 {
                for q in taken[((cx + Int64(dx)) << 32) ^ ((cy + Int64(dy)) & 0xFFFF_FFFF)] ?? [] where q.distance(to: p) < spacing { return false }
            } }
            return true
        }
        func hash(_ p: DV2, _ salt: UInt64) -> DioramaRandom {
            DioramaRandom(seed: UInt64(bitPattern: Int64((p.x * 10).rounded()) &* 73_856_093 ^ Int64((p.y * 10).rounded()) &* 19_349_663), salt: salt)
        }
        func add(_ kind: Kind, at p: DV2, spacing: Double, rng: inout DioramaRandom) {
            guard out.count < limit, rect.contains(p), clear(p, spacing) else { return }
            if kind.isTree && occupied(p, 3.5) { return }
            guard let z = ground(p, kind.isTree) else { return }
            let s = Float(kind == .baobab ? rng.range(0.9...1.15) : rng.range(0.82...1.22))
            let tall = Float(rng.range(0.92...1.08))
            let radius = prototypes[kind.rawValue].radius * s * max(1, tall)
            let tone = Float(rng.range(0.9...1.07))
            let data = DioramaInstanceData(placement: SIMD4(Float(p.x), Float(p.y), Float(z) - 0.05, Float(rng.range(0...Double.pi * 2))),
                                           scale: SIMD4(s, s, s * tall, radius),
                                           tint: SIMD4(tone, tone * Float(rng.range(0.97...1.03)), tone, 1), grading: .zero)
            out.append(Placement(kind: kind, data: data))
            taken[cellKey(p), default: []].append(p)
        }
        func pick(_ r: Double, _ table: [(Double, Kind)]) -> Kind {
            table.first { r < $0.0 }?.1 ?? table[table.count - 1].1
        }
        func local(_ lonLat: [Double]) -> DV2? {
            lonLat.count >= 2 ? projection.local(longitude: lonLat[0], latitude: lonLat[1]) : nil
        }
        // Mapped individual trees first: they stand exactly where OSM puts them.
        for tree in data.trees {
            guard let p = local(tree), rect.contains(p) else { continue }
            var rng = hash(p, 0x54_52)
            let roll = rng.unit()
            let kind: Kind
            switch Int(tree.count > 2 ? tree[2] : 0) {
            case 1: kind = .baobab
            case 2: kind = .palm
            case 3: kind = .flamboyant
            case 4: kind = .mango
            default:
                kind = pick(roll, [(0.22, .shadeGiant), (0.38, .mango), (0.5, .pinkTabebuia), (0.56, .flamboyant),
                                   (0.66, .umbrellaAcacia), (0.8, .neem), (1, .palm)])
            }
            add(kind, at: p, spacing: 2.5, rng: &rng)
        }
        for row in data.rows {
            let line = row.line.compactMap(local)
            guard line.count >= 2, DioramaRect.bounding(line).intersects(rect) else { continue }
            let length = DioramaPolygon.length(line)
            var d = 2.0
            while d < length {
                if let s = DioramaPolygon.sample(line, at: d) {
                    var rng = hash(s.point, 0x52_4F)
                    add(rng.chance(0.6) ? .neem : .shadeGiant, at: s.point, spacing: 5, rng: &rng)
                }
                d += 8
            }
        }
        // Areas: jittered grids clipped to the mapped polygon.
        for area in data.areas {
            let ring = area.ring.compactMap(local)
            guard ring.count >= 3 else { continue }
            let box = DioramaRect.bounding(ring)
            guard box.intersects(rect) else { continue }
            let clip = DioramaRect(minX: max(box.minX, rect.minX), minY: max(box.minY, rect.minY),
                                   maxX: min(box.maxX, rect.maxX), maxY: min(box.maxY, rect.maxY))
            typealias Layer = (step: Double, chance: Double, spacing: Double, table: [(Double, Kind)])
            var layers: [Layer] = []
            switch area.kind {
            case "wood":
                layers.append((7.5, 0.7, 5.5, [(0.26, .shadeGiant), (0.46, .mango), (0.66, .umbrellaAcacia), (0.8, .neem),
                                               (0.88, .pinkTabebuia), (0.96, .palm), (1, .baobab)]))
                if bushes { layers.append((3.4, 0.62, 2.4, [(0.4, .thicket), (0.82, .scrubBush), (1, .lowShrub)])) }
            case "scrub":
                layers.append((11, 0.3, 6, [(0.6, .umbrellaAcacia), (1, .neem)]))
                if bushes { layers.append((3.0, 0.72, 2.2, [(0.3, .thicket), (0.78, .scrubBush), (1, .lowShrub)])) }
            case "grassland":
                layers.append((20, 0.22, 8, [(1, .umbrellaAcacia)]))
                if bushes { layers.append((7, 0.3, 3, [(0.7, .scrubBush), (1, .lowShrub)])) }
            case "wetland":
                if bushes { layers.append((4.5, 0.35, 2.5, [(0.75, .lowShrub), (1, .scrubBush)])) }
            case "garden":
                layers.append((12, 0.42, 6, [(0.28, .shadeGiant), (0.5, .pinkTabebuia), (0.72, .palm), (0.86, .mango), (1, .flamboyant)]))
                if bushes { layers.append((6, 0.3, 2.5, [(0.6, .lowShrub), (1, .scrubBush)])) }
            default: break
            }
            for (li, layer) in layers.enumerated() {
                var y = floor(clip.minY / layer.step) * layer.step
                while y < clip.maxY {
                    var x = floor(clip.minX / layer.step) * layer.step
                    while x < clip.maxX {
                        let cellCorner = DV2(x, y)
                        var rng = hash(cellCorner, 0x41_52 &+ UInt64(li))
                        if rng.chance(layer.chance) {
                            let p = cellCorner + DV2(rng.range(0.12...0.88), rng.range(0.12...0.88)) * layer.step
                            if DioramaPolygon.contains(ring, p) { add(pick(rng.unit(), layer.table), at: p, spacing: layer.spacing, rng: &rng) }
                        }
                        x += layer.step
                    }
                    y += layer.step
                }
            }
        }
        return out
    }
}
