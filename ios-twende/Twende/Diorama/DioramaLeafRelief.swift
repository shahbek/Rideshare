import Foundation

/// Original seamless miniature-leaf relief, packed into the shared texture's unused B/A channels.
nonisolated enum DioramaLeafRelief {
    static func pack(into pixels: inout Data, size: Int) {
        guard size == 256, pixels.count == size * size * 4 else { return }
        var heights: [Float] = Array(repeating: 0, count: size * size)
        var pigment: [Float] = Array(repeating: 0.5, count: size * size)
        var rng = DioramaRandom(seed: 108, salt: 711)
        // Jittered, rotating lanceolate leaves avoid photographic clumps and a regular dotted grid.
        for row in 0..<16 {
            for column in 0..<16 {
                let x = (Double(column) + rng.range(0.15...0.85)) * 16
                let y = (Double(row) + rng.range(0.15...0.85)) * 16
                let angle = rng.range(0...Double.pi * 2)
                let c = cos(angle), s = sin(angle)
                let length = rng.range(4.0...7.4), width = rng.range(1.2...2.3)
                let lift = Float(rng.range(0.62...1.0))
                let reach = Int(ceil(length + width + 2))
                for iy in (Int(y) - reach)...(Int(y) + reach) {
                    for ix in (Int(x) - reach)...(Int(x) + reach) {
                        let dx = Double(ix) + 0.5 - x, dy = Double(iy) + 0.5 - y
                        let u = (dx * c + dy * s) / length
                        guard abs(u) < 1 else { continue }
                        let curve = 0.45 * (1 - u * u)
                        let v = (dy * c - dx * s - curve) / width
                        let taper = 1 - u * u
                        let section = max(0, 1 - abs(v) / max(taper, 0.001))
                        guard section > 0 else { continue }
                        let relief = Float(taper * sqrt(section)) * lift
                        let index = ((iy + size) % size) * size + (ix + size) % size
                        heights[index] = max(heights[index], relief)
                        pigment[index] = max(pigment[index], 0.5 + relief * 0.13)
                    }
                }
            }
        }
        pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in heights.indices {
                buffer[index * 4 + 2] = UInt8((min(1, heights[index]) * 255).rounded())
                buffer[index * 4 + 3] = UInt8((min(1, pigment[index]) * 255).rounded())
            }
        }
    }
}
