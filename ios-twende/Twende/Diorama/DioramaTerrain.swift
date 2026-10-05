import Foundation

/// One triangulated height field for land, draped finishes, markings and structural foundations.
nonisolated struct DioramaTerrain: Sendable {
    static let lift: Double = 0.6
    static let waterSurface: Double = 0.22
    static let seabed: Double = -1.0
    /// All draped surfaces use the same cell origin, diagonal and interpolation, not separate meshes.
    static let surfaceStep: Double = 4

    let rect: DioramaRect
    let columns: Int
    let rows: Int
    /// Absolute exaggerated DEM values, row-major from south to north.
    let values: [Double]
    /// Visual clearance shared by the whole tile, including sea, boats, lights and reflections.
    /// This is a rendering adjustment, not a surveyed sea-level measurement.
    var clearance: Double = 0
    var gradedNodes: [SIMD2<Int>: Double] = [:]
    var buildingLevels: [UInt64: Double] = [:]

    var waterLevel: Double { Self.waterSurface + clearance }
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
        guard config.usesElevation else { return flat(rect) }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.columns >= 2, file.rows >= 2, file.elevations.count == file.columns * file.rows,
              file.elevations.allSatisfy(\.isFinite) else {
            print("[Diorama] terrain grid missing; using flat ground")
            return flat(rect)
        }
        return DioramaTerrain(rect: rect, columns: file.columns, rows: file.rows, values: file.elevations.map { $0 * 1.6 })
    }

    /// Keep a level ocean above coastal DEM artefacts. Move the ENTIRE scene by the same amount,
    /// rather than raising water into boats/buildings or deforming the ocean into a hillside.
    func resolvingSurfaces(in data: DioramaTileData) -> DioramaTerrain {
        var result = self
        var highest = 0.0
        let water = data.water.compactMap { $0.rings.first }
        for ring in water where ring.count >= 3 {
            for p in DioramaPolygon.densify(ring + [ring[0]], maxStep: Self.surfaceStep) {
                highest = max(highest, rawHeight(p))
            }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let p = DV2(rect.minX + rect.width * Double(column) / Double(columns - 1),
                            rect.minY + rect.height * Double(row) / Double(rows - 1))
                if water.contains(where: { DioramaPolygon.contains($0, p) }) {
                    highest = max(highest, values[row * columns + column])
                }
            }
        }
        result.clearance = highest + Self.lift
        return result
    }

    /// Cut/fill the actual landscape at each mapped building, then blend back into the surrounding
    /// slope. Floors remain horizontal; houses are not perched on highest-point concrete pedestals.
    func gradingBuildingSites(in data: DioramaTileData, roads: DioramaRoadIndex) -> DioramaTerrain {
        var result = self
        var grid = DioramaGrid(cell: 32)
        let buildings = data.buildings.sorted { $0.id < $1.id }
        for (i, building) in buildings.enumerated() {
            guard let first = building.ring.first else { continue }
            let samples = DioramaPolygon.densify(building.ring + [first], maxStep: 1).map { rawHeight($0) }.sorted()
            guard !samples.isEmpty else { continue }
            result.buildingLevels[building.id] = samples[samples.count / 2]
            grid.insert(i, rect: DioramaRect.bounding(building.ring).expanded(by: 12))
        }
        let step = Self.surfaceStep
        var deepestCut = 0.0
        for y in stride(from: floor(rect.minY / step) * step, through: ceil(rect.maxY / step) * step, by: step) {
            for x in stride(from: floor(rect.minX / step) * step, through: ceil(rect.maxX / step) * step, by: step) {
                let p = DV2(x, y), original = rawHeight(p)
                var nearest = Double.infinity
                var target = original
                for i in grid.query(DioramaRect.bounding([p])).sorted() {
                    let building = buildings[i]
                    guard let level = result.buildingLevels[building.id] else { continue }
                    let inside = DioramaPolygon.contains(building.ring, p)
                    let distance = inside ? 0 : DioramaPolygon.distanceToRing(building.ring, p)
                    guard distance < 12, distance < nearest else { continue }
                    // A full terrain cell beyond the walls prevents interpolation cutting through rooms.
                    let t = min(max((distance - 4) / 8, 0), 1)
                    var weight = 1 - t * t * (3 - 2 * t)
                    if distance > 4, let road = roads.nearest(to: p, within: 20) {
                        let roadDistance = p.distance(to: road.point) - roads.corridorHalfWidth(road.road)
                        weight *= min(max(roadDistance / 4, 0), 1)
                    }
                    target = original + (level - original) * weight
                    nearest = distance
                }
                if nearest.isFinite {
                    result.gradedNodes[SIMD2(Int(round(x / step)), Int(round(y / step)))] = target
                    deepestCut = max(deepestCut, original - target)
                }
            }
        }
        // Mapbox's ungraded DEM is still underneath. Keep the cut surface above it, moving all
        // scene categories together instead of lifting individual houses back onto pedestals.
        result.clearance += deepestCut
        return result
    }

    func buildingHeight(_ feature: DioramaBuildingFeature) -> Double {
        guard let level = buildingLevels[feature.id] else { return foundationHeight(feature.ring) }
        return level + Self.lift + clearance + 0.04
    }

    private func surfaceNode(_ p: DV2) -> Double {
        let key = SIMD2(Int(round(p.x / Self.surfaceStep)), Int(round(p.y / Self.surfaceStep)))
        return gradedNodes[key] ?? rawHeight(p)
    }

    /// Level amenity slab above its footprint; buildings use graded site levels instead.
    func foundationHeight(_ ring: [DV2]) -> Double {
        guard let first = ring.first else { return Self.lift + clearance }
        let bounds = DioramaRect.bounding(ring)
        var highest = height(DioramaPolygon.centroid(ring))
        for p in DioramaPolygon.densify(ring + [first], maxStep: 1) { highest = max(highest, height(p)) }
        for y in stride(from: floor(bounds.minY / Self.surfaceStep) * Self.surfaceStep, through: bounds.maxY, by: Self.surfaceStep) {
            for x in stride(from: floor(bounds.minX / Self.surfaceStep) * Self.surfaceStep, through: bounds.maxX, by: Self.surfaceStep) {
                let p = DV2(x, y)
                if DioramaPolygon.contains(ring, p) { highest = max(highest, height(p)) }
            }
        }
        return highest + 0.04
    }

    /// Continuous support reaches below the lowest boundary rather than floating on the high side.
    func footingHeight(_ ring: [DV2]) -> Double {
        guard let first = ring.first else { return Self.lift + clearance - 0.3 }
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
        let h00 = surfaceNode(DV2(x, y)), h11 = surfaceNode(DV2(x + step, y + step))
        let h: Double
        if ty <= tx {
            let h10 = surfaceNode(DV2(x + step, y))
            h = h00 * (1 - tx) + h10 * (tx - ty) + h11 * ty
        } else {
            let h01 = surfaceNode(DV2(x, y + step))
            h = h00 * (1 - ty) + h11 * tx + h01 * (ty - tx)
        }
        return h + Self.lift + clearance
    }

    /// Raw DEM interpolation, with no visual offsets. Used when filling missing live DEM samples.
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
