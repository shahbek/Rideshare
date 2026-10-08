import Foundation

/// Original seamless crown leaves and larger curved grass blades in the shared texture's B/A channels.
nonisolated enum DioramaLeafRelief {
    static func pack(into pixels: inout Data, size: Int) {
        guard size == 256, pixels.count == size * size * 4 else { return }
        let leaves = plane(size: size, grass: false)
        let blades = plane(size: size, grass: true)
        pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in leaves.indices {
                buffer[index * 4 + 2] = UInt8((min(1, leaves[index]) * 255).rounded())
                buffer[index * 4 + 3] = UInt8((min(1, blades[index]) * 255).rounded())
            }
        }
    }

    private static func plane(size: Int, grass: Bool) -> [Float] {
        var heights: [Float] = Array(repeating: 0, count: size * size)
        var rng = DioramaRandom(seed: 108, salt: grass ? 1711 : 711)
        let grid = grass ? 8 : 16
        let cell = Double(size) / Double(grid)
        for row in 0..<grid {
            for column in 0..<grid {
                let x = (Double(column) + rng.range(0.15...0.85)) * cell
                let y = (Double(row) + rng.range(0.15...0.85)) * cell
                let angle = rng.range(0...Double.pi * 2)
                let c = cos(angle), s = sin(angle)
                let length = grass ? rng.range(11.0...20.0) : rng.range(5.5...10.0)
                let width = grass ? rng.range(1.0...2.0) : rng.range(1.6...2.8)
                let bend = length * (grass ? rng.range(0.12...0.24) : 0.07)
                let lift = Float(rng.range(0.62...1.0))
                let reach = Int(ceil(length + width + bend + 2))
                for iy in (Int(y) - reach)...(Int(y) + reach) {
                    for ix in (Int(x) - reach)...(Int(x) + reach) {
                        let dx = Double(ix) + 0.5 - x, dy = Double(iy) + 0.5 - y
                        let u = (dx * c + dy * s) / length
                        guard abs(u) < 1 else { continue }
                        let taper = 1 - u * u
                        let v = (dy * c - dx * s - bend * taper) / width
                        let section = max(0, 1 - abs(v) / max(taper, 0.001))
                        guard section > 0 else { continue }
                        // Smooth flanks avoid the needle-like derivative spikes of sqrt(section).
                        let relief = Float(taper * pow(section, 1.35)) * lift
                        let wrappedY = (iy % size + size) % size
                        let wrappedX = (ix % size + size) % size
                        let index = wrappedY * size + wrappedX
                        heights[index] = max(heights[index], relief)
                    }
                }
            }
        }
        return heights
    }
}
