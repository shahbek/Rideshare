import Foundation

/// One triangulated height field for land, draped finishes, markings and structural foundations.
nonisolated struct DioramaTerrain: Sendable {
    /// Shared render separation from Standard; preserves the DEM shape and all land attachments.
    static let lift: Double = 0.2
    /// All draped surfaces use the same cell origin, diagonal and interpolation, not separate meshes.
    static let surfaceStep: Double = 4

    let rect: DioramaRect
    let columns: Int
    let rows: Int
    /// Absolute exaggerated DEM values, row-major from south to north.
    let values: [Double]
    var attachedFootprints: [UInt64: [[DV2]]] = [:]

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

    /// Offline estimate until the already loaded Mapbox DEM is available.
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
        return DioramaTerrain(rect: rect, columns: file.columns, rows: file.rows,
                              values: file.elevations.map { $0 * 1.6 }, midTideDatum: config.waterLevel)
    }

    /// The sea datum is read from the open-water DEM itself, so the flat sea sits just above the
    /// draped seabed. Land is never raised to meet it: where the landform rises through the datum,
    /// that is simply the shore. A robust percentile ignores land values bleeding into coastal cells.
    func resolvingSurfaces(in data: DioramaTileData) -> DioramaTerrain {
        var result = self
        var interior: [Double] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let p = DV2(rect.minX + Double(column) * rect.width / Double(columns - 1),
                            rect.minY + Double(row) * rect.height / Double(rows - 1))
                guard data.water.contains(where: { DioramaPolygon.contains(polygon: $0.rings, p) }),
                      !data.shorelines.contains(where: { DioramaShoreline.distance(p, line: $0.points) < 12 }) else { continue }
                interior.append(rawHeight(p))
            }
        }
        if interior.count >= 4 {
            let sorted = interior.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            result.midTideDatum = max(midTideDatum, p95 + Self.lift + 0.3)
        }
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

    /// Footprint-contained foundation skirt follows the slope without modifying continuous land.
    func foundation(_ ring: [DV2], top: Double, swatch: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard let first = ring.first else { return }
        let boundary = DioramaPolygon.densify(ring + [first], maxStep: 1)
        for (a, b) in zip(boundary, boundary.dropFirst()) {
            mesh.quad(DV3(a, height(a) - 0.08), DV3(b, height(b) - 0.08),
                      DV3(b, top), DV3(a, top), swatch, normal: DV3((b - a).normalized.right, 0))
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

    /// Shared piecewise-planar surface. Every clipped polygon and painted stripe lies on this mesh.
    func height(_ p: DV2) -> Double {
        let step = Self.surfaceStep
        let x = floor(p.x / step) * step, y = floor(p.y / step) * step
        let tx = (p.x - x) / step, ty = (p.y - y) / step
        let h00 = rawHeight(DV2(x, y)), h11 = rawHeight(DV2(x + step, y + step))
        let h: Double
        if ty <= tx {
            let h10 = rawHeight(DV2(x + step, y))
            h = h00 * (1 - tx) + h10 * (tx - ty) + h11 * ty
        } else {
            let h01 = rawHeight(DV2(x, y + step))
            h = h00 * (1 - ty) + h11 * tx + h01 * (ty - tx)
        }
        return h + Self.lift
    }

    /// DEM interpolation with no visual offsets or additional exaggeration.
    func rawHeight(_ p: DV2) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        let fx = min(max((p.x - rect.minX) / rect.width, 0), 1) * Double(columns - 1)
        let fy = min(max((p.y - rect.minY) / rect.height, 0), 1) * Double(rows - 1)
        let x0 = min(Int(fx), columns - 2), y0 = min(Int(fy), rows - 2)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let h00 = values[y0 * columns + x0], h10 = values[y0 * columns + x0 + 1]
        let h01 = values[(y0 + 1) * columns + x0], h11 = values[(y0 + 1) * columns + x0 + 1]
        return (h00 * (1 - tx) + h10 * tx) * (1 - ty) + (h01 * (1 - tx) + h11 * tx) * ty
    }

    /// Clip to each shared terrain triangle before triangulating. Independent polygon diagonals
    /// must never bridge a hill and let the ground pierce a finish or cover road markings.
    func drape(_ ring: [DV2], lift: Double, swatch: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard ring.count >= 3 else { return }
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
                    for p in piece { mesh.vertex(DV3(p, height(p) + lift), .up, uv) }
                    for t in DioramaPolygon.triangulate(piece) {
                        mesh.tri(UInt32(base + t.0), UInt32(base + t.1), UInt32(base + t.2))
                    }
                }
            }
        }
    }
}
