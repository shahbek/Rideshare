import Foundation

/// Shared absolute, exaggerated metre datum for geometry, foundations, lights and shadows.
/// Loaded Mapbox DEM samples replace the bundled SRTM fallback without shifting the sea plane.
nonisolated struct DioramaTerrain: Sendable {
    /// Height added to all land so the diorama's floor always sits above the basemap's ground plane.
    static let lift: Double = 0.6
    /// Absolute height of the water surface and the seabed under it.
    static let waterSurface: Double = 0.22
    static let seabed: Double = -1.0

    let rect: DioramaRect
    let columns: Int
    let rows: Int
    /// Row-major, rows south to north, columns west to east.
    let values: [Double]

    nonisolated struct File: Decodable, Sendable {
        let columns: Int
        let rows: Int
        let elevations: [Double]
    }

    static let resourceName = "slipway_terrain"

    /// Flat terrain, used when the bundled grid is missing.
    static func flat(_ rect: DioramaRect) -> DioramaTerrain {
        DioramaTerrain(rect: rect, columns: 2, rows: 2, values: [0, 0, 0, 0])
    }

    /// Offline absolute SRTM estimate, replaced with available Mapbox DEM samples by the manager.
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

    /// Level foundation above the highest sampled ground along the footprint, not just its centroid.
    func foundationHeight(_ ring: [DV2]) -> Double {
        guard let first = ring.first else { return Self.lift }
        let perimeter = DioramaPolygon.densify(ring + [first], maxStep: 2)
        return max(perimeter.map { height($0) }.max() ?? Self.lift,
                   height(DioramaPolygon.centroid(ring))) + 0.04
    }

    /// Ground height (including `lift`) at a local point. Clamped at the tile edges.
    func height(_ p: DV2) -> Double {
        guard rect.width > 0, rect.height > 0 else { return Self.lift }
        let fx = min(max((p.x - rect.minX) / rect.width, 0), 1) * Double(columns - 1)
        let fy = min(max((p.y - rect.minY) / rect.height, 0), 1) * Double(rows - 1)
        let x0 = min(Int(fx), columns - 2), y0 = min(Int(fy), rows - 2)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        // Linear sampling retains the DEM slope instead of flattening it at every cell boundary.
        let sx = tx, sy = ty
        let h00 = values[y0 * columns + x0], h10 = values[y0 * columns + x0 + 1]
        let h01 = values[(y0 + 1) * columns + x0], h11 = values[(y0 + 1) * columns + x0 + 1]
        let h = (h00 * (1 - sx) + h10 * sx) * (1 - sy) + (h01 * (1 - sx) + h11 * sx) * sy
        return h + Self.lift
    }
}
