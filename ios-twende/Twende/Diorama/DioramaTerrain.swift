import Foundation

/// One triangulated height field for land, draped finishes, markings and structural foundations.
///
/// The diorama owns its ground: while the tile is shown the basemap's 3D terrain is switched off,
/// and every height here comes from one bundled snapshot, so the tile is identical every session
/// and never competes with a second renderer in the shared depth buffer.
nonisolated struct DioramaTerrain: Sendable {
    /// Small separation above the flat basemap plane so the ground never z-fights Standard's 2D fills.
    static let lift: Double = 0.2
    /// All draped surfaces use the same cell origin, diagonal and interpolation, not separate meshes.
    static let surfaceStep: Double = 4
    /// Band inside soft shores (beach, natural, revetment) over which land eases down to the sea.
    static let coastEase: Double = 6
    /// Illustrative seabed: shore depth for soft and hard shores, open-water depth and the distance
    /// over which about two thirds of that depth is reached.
    static let softShoreDepth: Double = 0.03
    static let hardShoreDepth: Double = 0.6
    static let openWaterDepth: Double = 4.0
    static let openWaterReach: Double = 25

    let rect: DioramaRect
    let columns: Int
    let rows: Int
    /// Bundled snapshot heights in real metres, row-major from south to north.
    let values: [Double]
    var attachedFootprints: [UInt64: [[DV2]]] = [:]
    /// Vertical scale of the snapshot. 1 keeps real metres; the Slipway uses a gentler relief that
    /// stays readable yet short enough to ease into the flat basemap at the tile edge.
    var relief: Double = 1
    /// Width of the band inside the tile edge over which land eases down to the flat basemap.
    var edgeEase: Double = 0
    /// The mapped water edge, the one authoritative coastline. Set by `resolvingSurfaces(in:)`.
    var coast: DioramaCoast? = nil
    /// Immutable shared samples; foundations and props never repeat coastal polygon queries.
    private(set) var surfaceHeights: [Double] = []
    var latticeMinX: Int { Int(floor(rect.minX / Self.surfaceStep)) }
    var latticeMinY: Int { Int(floor(rect.minY / Self.surfaceStep)) }
    var latticeColumns: Int { Int(ceil(rect.maxX / Self.surfaceStep)) - latticeMinX + 1 }
    var latticeRows: Int { Int(ceil(rect.maxY / Self.surfaceStep)) - latticeMinY + 1 }

    func latticePoint(column: Int, row: Int) -> DV2 {
        DV2(min(max(Double(latticeMinX + column) * Self.surfaceStep, rect.minX), rect.maxX),
            min(max(Double(latticeMinY + row) * Self.surfaceStep, rect.minY), rect.maxY))
    }

    var midTideDatum: Double = DioramaConfig.slipway.waterLevel
    var waterLevel: Double { midTideDatum }
    var pierLevel: Double { waterLevel + 0.83 }
    var seabedLevel: Double { waterLevel - 1.22 }

    nonisolated struct File: Decodable, Sendable {
        let columns: Int
        let rows: Int
        let elevations: [Double]
    }

    static let resourceName = "slipway_terrain"

    static func flat(_ rect: DioramaRect) -> DioramaTerrain {
        DioramaTerrain(rect: rect, columns: 2, rows: 2, values: [0, 0, 0, 0])
    }

    /// The one fixed height snapshot of the tile. No live sampling: generation is deterministic
    /// across sessions, and the gentle Msasani landform is kept at `config.terrainRelief`.
    static func load(rect: DioramaRect, config: DioramaConfig) -> DioramaTerrain {
        guard config.usesElevation else {
            var result = flat(rect); result.midTideDatum = config.waterLevel
            return result
        }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.columns >= 2, file.rows >= 2, file.elevations.count == file.columns * file.rows,
              file.elevations.allSatisfy(\.isFinite) else {
            print("[Diorama] terrain grid missing; using flat ground")
            var result = flat(rect); result.midTideDatum = config.waterLevel
            return result
        }
        return DioramaTerrain(rect: rect, columns: file.columns, rows: file.rows, values: file.elevations,
                              relief: config.terrainRelief, edgeEase: config.terrainEdgeEase, midTideDatum: config.waterLevel)
    }

    /// Binds the mapped coastline. The sea datum is the configured one (the flat basemap plane by
    /// default); the seabed is generated from shore distance and soft shores ease down to the sea, so
    /// no DEM percentile is needed and land is never raised.
    func resolvingSurfaces(in data: DioramaTileData) -> DioramaTerrain {
        var result = self
        let coast = DioramaCoast(data: data)
        result.coast = coast.isEmpty ? nil : coast
        var samples: [Double] = []
        samples.reserveCapacity(result.latticeColumns * result.latticeRows)
        for row in 0..<result.latticeRows {
            for column in 0..<result.latticeColumns {
                samples.append(result.rawSurface(result.latticePoint(column: column, row: row)))
            }
        }
        result.surfaceHeights = samples
        for area in data.landuse where area.kind == "terrace" {
            guard let ring = area.rings.first else { continue }
            result.attach(ring, reach: 4, data: data)
        }
        for path in data.paths where path.kind == "pier" {
            let dry = DioramaPolygon.densify(path.line, maxStep: 1).filter { p in
                !data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) }
            }
            result.attach(dry, reach: 30, data: data)
        }
        return result
    }

    private mutating func attach(_ points: [DV2], reach: Double, data: DioramaTileData) {
        guard !points.isEmpty else { return }
        let nearest = data.buildings.map { building in
            (building.id, points.map { DioramaPolygon.contains(building.ring, $0) ? 0 : DioramaPolygon.distanceToRing(building.ring, $0) }.min() ?? .infinity)
        }.min { $0.1 < $1.1 }
        if let nearest, nearest.1 <= reach { attachedFootprints[nearest.0, default: []].append(points) }
    }

    /// Level floors clear the complete footprint and connected decks with a shallow foundation.
    /// Only waterfront buildings with a connected deck are also held above the pier datum.
    func buildingHeight(_ feature: DioramaBuildingFeature) -> Double {
        let attached = attachedFootprints[feature.id, default: []]
        let support = attached.map { foundationHeight($0) }.max() ?? -Double.infinity
        let floor = max(foundationHeight(feature.ring), support)
        return attached.isEmpty ? floor : max(floor, pierLevel)
    }

    /// Level amenity slab above its footprint.
    func foundationHeight(_ ring: [DV2]) -> Double {
        guard let first = ring.first else { return Self.lift }
        let bounds = DioramaRect.bounding(ring)
        var highest = height(DioramaPolygon.centroid(ring))
        for p in DioramaPolygon.densify(ring + [first], maxStep: 1) { highest = max(highest, height(p)) }
        let step = Self.surfaceStep
        for y in stride(from: floor(bounds.minY / step) * step, through: bounds.maxY, by: step) {
            for x in stride(from: floor(bounds.minX / step) * step, through: bounds.maxX, by: step) {
                let clipped = DioramaPolygon.clipPolygon(ring, to: DioramaRect(minX: x, minY: y, maxX: x + step, maxY: y + step))
                for inside in [true, false] {
                    let piece = DioramaGroundCutouts.halfPlane(clipped, a: DV2(x, y), b: DV2(x + step, y + step), inside: inside)
                    // A linear triangle's maximum is at a clipped vertex, including diagonal crossings.
                    for p in piece { highest = max(highest, height(p)) }
                }
            }
        }
        return highest + 0.18
    }

    /// Foundation skirt from the footprint outline, sunk a little into the ground. One quad per edge,
    /// with the shared 4 m lattice only where an edge actually crosses a lattice line, so the skirt
    /// follows the slope without densifying every metre.
    func foundation(_ ring: [DV2], top: Double, swatch: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard let first = ring.first else { return }
        let step = Self.surfaceStep
        for (a, b) in zip(ring + [first], ring.dropFirst() + [first]) where a.distance(to: b) > 0.001 {
            var stations: [DV2] = [a]
            let crossings = Int(abs(floor(b.x / step) - floor(a.x / step)) + abs(floor(b.y / step) - floor(a.y / step)))
            if crossings > 0 {
                let pieces = min(crossings + 1, 6)
                for k in 1..<pieces { stations.append(a + (b - a) * (Double(k) / Double(pieces))) }
            }
            stations.append(b)
            let out = DV3((b - a).normalized.right, 0)
            for (p, q) in zip(stations, stations.dropFirst()) {
                mesh.quad(DV3(p, height(p) - 0.3), DV3(q, height(q) - 0.3), DV3(q, top), DV3(p, top), swatch, normal: out)
            }
        }
    }

    /// Continuous support reaches below the lowest boundary rather than floating on the high side.
    func footingHeight(_ ring: [DV2]) -> Double {
        guard let first = ring.first else { return Self.lift - 0.3 }
        return (DioramaPolygon.densify(ring + [first], maxStep: 1).map { height($0) }.min() ?? height(first)) - 0.3
    }

    func pierHeight(_ line: [DV2]) -> Double {
        max(pierLevel, line.first.map { height($0) + 0.1 } ?? pierLevel)
    }

    /// All support queries interpolate the exact same connected land–sea mesh.
    func height(_ p: DV2) -> Double {
        guard !surfaceHeights.isEmpty else { return planar(p, sample: rawSurface) }
        let c = min(max(Int(floor(p.x / Self.surfaceStep)) - latticeMinX, 0), latticeColumns - 2)
        let r = min(max(Int(floor(p.y / Self.surfaceStep)) - latticeMinY, 0), latticeRows - 2)
        let a = latticePoint(column: c, row: r), b = latticePoint(column: c + 1, row: r + 1)
        let tx = min(max((p.x - a.x) / max(b.x - a.x, 0.0001), 0), 1)
        let ty = min(max((p.y - a.y) / max(b.y - a.y, 0.0001), 0), 1)
        let i = r * latticeColumns + c
        let h00 = surfaceHeights[i], h11 = surfaceHeights[i + latticeColumns + 1]
        if ty <= tx { return h00 * (1 - tx) + surfaceHeights[i + 1] * (tx - ty) + h11 * ty }
        return h00 * (1 - ty) + h11 * tx + surfaceHeights[i + latticeColumns] * (ty - tx)
    }

    func seabed(_ p: DV2) -> Double { height(p) }
    func floorHeight(_ p: DV2) -> Double { height(p) }

    private func rawSurface(_ p: DV2) -> Double {
        if coast?.isWater(p) == true { return rawSeabed(p) }
        return rawHeight(p) + Self.lift
    }

    /// Depth of water over the seabed at `p` (negative on land).
    func depth(_ p: DV2) -> Double {
        waterLevel - floorHeight(p)
    }

    private func planar(_ p: DV2, sample: (DV2) -> Double) -> Double {
        let step = Self.surfaceStep
        let x = floor(p.x / step) * step, y = floor(p.y / step) * step
        let tx = (p.x - x) / step, ty = (p.y - y) / step
        let h00 = sample(DV2(x, y)), h11 = sample(DV2(x + step, y + step))
        if ty <= tx {
            let h10 = sample(DV2(x + step, y))
            return h00 * (1 - tx) + h10 * (tx - ty) + h11 * ty
        } else {
            let h01 = sample(DV2(x, y + step))
            return h00 * (1 - ty) + h11 * tx + h01 * (ty - tx)
        }
    }

    /// Snapshot interpolation scaled by `relief`, eased to the flat basemap inside the tile edge,
    /// and eased down (never up) to the sea within `coastEase` of a soft shore.
    func rawHeight(_ p: DV2) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        var h = interpolated(p) * relief * edgeFactor(p)
        if let coast, let near = coast.nearest(p, within: Self.coastEase), near.kind.easesToWater {
            let t = Self.smooth(near.distance / Self.coastEase)
            let datum = waterLevel + 0.02 - Self.lift
            h = min(h, datum + (h - datum) * t)
        }
        return h
    }

    /// Illustrative seabed (not surveyed): a few centimetres below the sea at a beach, about 60 cm at
    /// a quay wall, then an exponential run-out towards `openWaterDepth` (roughly the beach slope at
    /// the shore), with gentle undulation away from the coast.
    func rawSeabed(_ p: DV2) -> Double {
        guard let coast else { return seabedLevel }
        let reach = Self.openWaterReach * 4
        let near = coast.nearest(p, within: reach)
        let d = near?.distance ?? reach
        let shoreDepth = (near?.kind.easesToWater ?? true) ? Self.softShoreDepth : Self.hardShoreDepth
        var depth = shoreDepth + (Self.openWaterDepth - shoreDepth) * (1 - exp(-d / Self.openWaterReach))
        depth += (Self.noise(p * 0.045) - 0.5) * 0.5 * Self.smooth(min(d / 14, 1))
        return waterLevel - depth
    }

    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Deterministic value noise in [0, 1].
    static func noise(_ p: DV2) -> Double {
        func hash(_ x: Double, _ y: Double) -> Double {
            let s = sin(x * 127.1 + y * 311.7) * 43758.5453
            return s - floor(s)
        }
        let ix = floor(p.x), iy = floor(p.y)
        let fx = smooth(p.x - ix), fy = smooth(p.y - iy)
        let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// 1 in the interior, smoothly 0 at the tile boundary, so there is no step against the basemap.
    func edgeFactor(_ p: DV2) -> Double {
        guard edgeEase > 0 else { return 1 }
        let d = min(min(p.x - rect.minX, rect.maxX - p.x), min(p.y - rect.minY, rect.maxY - p.y))
        let t = min(max(d / edgeEase, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func interpolated(_ p: DV2) -> Double {
        let fx = min(max((p.x - rect.minX) / rect.width, 0), 1) * Double(columns - 1)
        let fy = min(max((p.y - rect.minY) / rect.height, 0), 1) * Double(rows - 1)
        let x0 = min(Int(fx), columns - 2), y0 = min(Int(fy), rows - 2)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let h00 = values[y0 * columns + x0], h10 = values[y0 * columns + x0 + 1]
        let h01 = values[(y0 + 1) * columns + x0], h11 = values[(y0 + 1) * columns + x0 + 1]
        return (h00 * (1 - tx) + h10 * tx) * (1 - ty) + (h01 * (1 - tx) + h11 * tx) * ty
    }

    nonisolated enum Surface: Sendable { case land, sea }

    /// Clip to each shared terrain triangle before triangulating. Independent polygon diagonals
    /// must never bridge a hill and let the ground pierce a finish or cover road markings.
    func drape(_ ring: [DV2], lift: Double, swatch: DioramaSwatch, surface: Surface = .land, into mesh: inout DioramaMesh) {
        guard ring.count >= 3 else { return }
        let onLand = surface == .land
        func elevation(_ p: DV2) -> Double { onLand ? height(p) : seabed(p) }
        let bounds = DioramaRect.bounding(ring), step = Self.surfaceStep
        let uv = DioramaAtlas.uv(swatch, dark: false)
        for y in stride(from: floor(bounds.minY / step) * step, to: bounds.maxY, by: step) {
            for x in stride(from: floor(bounds.minX / step) * step, to: bounds.maxX, by: step) {
                let cell = DioramaRect(minX: x, minY: y, maxX: x + step, maxY: y + step)
                let clipped = DioramaPolygon.clipPolygon(ring, to: cell)
                guard clipped.count >= 3 else { continue }
                // The southwest-to-northeast diagonal matches height(_:).
                for inside in [true, false] {
                    let piece = DioramaGroundCutouts.halfPlane(clipped, a: DV2(x, y), b: DV2(x + step, y + step), inside: inside)
                    guard piece.count >= 3, DioramaPolygon.area(piece) > 0.00001 else { continue }
                    let base = mesh.positions.count
                    for p in piece { mesh.vertex(DV3(p, elevation(p) + lift), .up, uv) }
                    for t in DioramaPolygon.triangulate(piece) {
                        mesh.tri(UInt32(base + t.0), UInt32(base + t.1), UInt32(base + t.2))
                    }
                }
            }
        }
    }
}
