import Foundation

/// Smoothed ground elevation for the tile, sampled from a small bundled SRTM grid
/// (`slipway_terrain.json`). Every generator drapes its geometry over this so streets climb the
/// Msasani rise and the shore drops to the bay, the way the real peninsula does.
nonisolated struct DioramaTerrain: Sendable {
    /// Height added to all land so the diorama's floor always sits above the basemap's ground plane.
    static let lift: Double = 0.3
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

    static func load(rect: DioramaRect) -> DioramaTerrain {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.columns >= 2, file.rows >= 2, file.elevations.count == file.columns * file.rows,
              file.elevations.allSatisfy(\.isFinite) else {
            print("[Diorama] terrain grid missing; using flat ground")
            return flat(rect)
        }
        let floor = file.elevations.min() ?? 0
        return DioramaTerrain(rect: rect, columns: file.columns, rows: file.rows, values: file.elevations.map { $0 - floor })
    }

    /// Ground height (including `lift`) at a local point. Clamped at the tile edges.
    func height(_ p: DV2) -> Double {
        guard rect.width > 0, rect.height > 0 else { return Self.lift }
        let fx = min(max((p.x - rect.minX) / rect.width, 0), 1) * Double(columns - 1)
        let fy = min(max((p.y - rect.minY) / rect.height, 0), 1) * Double(rows - 1)
        let x0 = min(Int(fx), columns - 2), y0 = min(Int(fy), rows - 2)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        // Smoothstep across each cell hides the creases a plain bilinear patch would show.
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let h00 = values[y0 * columns + x0], h10 = values[y0 * columns + x0 + 1]
        let h01 = values[(y0 + 1) * columns + x0], h11 = values[(y0 + 1) * columns + x0 + 1]
        let h = (h00 * (1 - sx) + h10 * sx) * (1 - sy) + (h01 * (1 - sx) + h11 * sx) * sy
        return h + Self.lift
    }
}
