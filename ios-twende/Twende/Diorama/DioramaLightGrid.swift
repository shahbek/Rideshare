import Foundation
import simd

/// One point light as the GPU sees it: xyz position in local metres + radius, rgb colour + intensity.
nonisolated struct DioramaShaderLight: Codable, Sendable {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Uniform 2D grid over the tile that lists, per cell, which lights can reach it. The fragment shader
/// looks up its cell and visits only those lights, so hundreds of lamps and lit facades stay cheap.
nonisolated struct DioramaLightGrid: Codable, Sendable {
    let cells: Int
    let minX: Float
    let minY: Float
    let cellSize: Float
    let lights: [DioramaShaderLight]
    /// `cells * cells` entries of (first index, count) into `indices`.
    let table: [SIMD2<UInt32>]
    let indices: [UInt32]

    static func build(_ sources: [DioramaLight], rect: DioramaRect, cells: Int, perCell: Int) -> DioramaLightGrid {
        let n = max(cells, 1)
        let size = Float(max(rect.width, rect.height) / Double(n))
        let minX = Float(rect.minX), minY = Float(rect.minY)
        let lights = sources.map {
            DioramaShaderLight(
                position: SIMD4<Float>(Float($0.position.x), Float($0.position.y), Float($0.position.z), Float($0.radius)),
                color: SIMD4<Float>($0.color, $0.intensity)
            )
        }
        var buckets = [[UInt32]](repeating: [], count: n * n)
        for (i, light) in lights.enumerated() {
            let r = light.position.w
            let x0 = max(Int((light.position.x - r - minX) / size), 0), x1 = min(Int((light.position.x + r - minX) / size), n - 1)
            let y0 = max(Int((light.position.y - r - minY) / size), 0), y1 = min(Int((light.position.y + r - minY) / size), n - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 where buckets[y * n + x].count < perCell {
                    buckets[y * n + x].append(UInt32(i))
                }
            }
        }
        var table: [SIMD2<UInt32>] = []
        table.reserveCapacity(n * n)
        var indices: [UInt32] = []
        for bucket in buckets {
            table.append(SIMD2<UInt32>(UInt32(indices.count), UInt32(bucket.count)))
            indices.append(contentsOf: bucket)
        }
        return DioramaLightGrid(cells: n, minX: minX, minY: minY, cellSize: size, lights: lights, table: table, indices: indices)
    }
}
