import Foundation
import Metal
import simd

/// Tiling building material library: one mipmapped 2D texture array generated once per device
/// (no downloads). Deliberately low resolution: 64 × 64 per layer (16 KiB, ~260 KiB for all twelve
/// with mips). Each layer repeats over `repeatMetres(layer)` with every feature period dividing it.
/// RGB is a tint *ratio* around 0.5 (×2 in the shader, so the building's own source colour is
/// preserved), A is relief height used for groove shading and surface-gradient normals.
///
/// Roofs: 0 corrugated mabati · 1 rusted mabati · 2 clay Roman tile · 3 stepped concrete tile ·
/// 4 box-rib (IBR) sheet · 5 flat concrete slab.
/// Walls: 6 painted plaster · 7 cement block · 8 coral rag stone · 9 rough-cast dash ·
/// 10 fair-face brick · 11 scored render.
nonisolated enum DioramaBuildingMaterials {
    static let layerCount = 12
    static let size = 64
    /// Metres covered by one texture repeat (mirrored in the shader): fine sheet/tile/masonry layers
    /// 1.2 m, the flat slab 4.8 m (big stains, few joints), plaster and dash 2.4 m.
    static func repeatMetres(_ layer: Int) -> Float { layer == 5 ? 4.8 : (layer == 6 || layer == 9 ? 2.4 : 1.2) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var textures: [ObjectIdentifier: MTLTexture] = [:]
    nonisolated(unsafe) private static var cachedPixels: [UInt8]? = nil

    /// Shared texture array for `device`; a 1×1 single-layer neutral array if generation fails, so the
    /// fragment binding always has the declared type.
    static func texture(device: MTLDevice) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device)
        if let cached = textures[key] { return cached }
        let pixels = cachedPixels ?? generate()
        cachedPixels = pixels
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = size; descriptor.height = size
        descriptor.arrayLength = layerCount
        descriptor.mipmapLevelCount = Int(log2(Double(size))) + 1
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return fallback(device: device) }
        let layerBytes = size * size * 4
        pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            for layer in 0..<layerCount {
                texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: layer,
                    withBytes: base + layer * layerBytes, bytesPerRow: size * 4, bytesPerImage: layerBytes)
            }
        }
        guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return fallback(device: device) }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return fallback(device: device) }
        textures[key] = texture
        return texture
    }

    private static func fallback(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 1; descriptor.height = 1; descriptor.arrayLength = 1
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var neutral: [UInt8] = [128, 128, 128, 128]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &neutral, bytesPerRow: 4, bytesPerImage: 4)
        return texture
    }

    // MARK: - Generation

    private static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 2_147_483_647)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }

    /// Tileable value noise with `cells` lattice cells across the texture.
    private static func noise(_ u: Float, _ v: Float, cells: Int, seed: Int) -> Float {
        let x = u * Float(cells), y = v * Float(cells)
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = x - Float(xi), fy = y - Float(yi)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        func h(_ a: Int, _ b: Int) -> Float { hash(((a % cells) + cells) % cells, ((b % cells) + cells) % cells, seed) }
        let a = h(xi, yi) + (h(xi + 1, yi) - h(xi, yi)) * sx
        let b = h(xi, yi + 1) + (h(xi + 1, yi + 1) - h(xi, yi + 1)) * sx
        return a + (b - a) * sy
    }

    /// Tileable anisotropic value noise (different lattice counts across/along), for streaks.
    private static func streaks(_ u: Float, _ v: Float, across: Int, along: Int, seed: Int) -> Float {
        var total: Float = 0, amplitude: Float = 0.5, a = across, b = along
        for octave in 0..<3 {
            let x = u * Float(a), y = v * Float(b)
            let xi = Int(floor(x)), yi = Int(floor(y))
            let fx = x - Float(xi), fy = y - Float(yi)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            func h(_ i: Int, _ j: Int) -> Float { hash(((i % a) + a) % a, ((j % b) + b) % b, seed + octave * 17) }
            let top = h(xi, yi) + (h(xi + 1, yi) - h(xi, yi)) * sx
            let bottom = h(xi, yi + 1) + (h(xi + 1, yi + 1) - h(xi, yi + 1)) * sx
            total += (top + (bottom - top) * sy) * amplitude
            amplitude *= 0.5; a *= 2; b *= 2
        }
        return total / 0.875
    }

    private static func fbm(_ u: Float, _ v: Float, base: Int, seed: Int) -> Float {
        var total: Float = 0, amplitude: Float = 0.5, cells = base
        for octave in 0..<4 {
            total += noise(u, v, cells: cells, seed: seed + octave * 31) * amplitude
            amplitude *= 0.5; cells *= 2
        }
        return total / 0.9375
    }

    /// Running-bond units: returns (edge distance in metres, cell id).
    private static func bond(_ u: Float, _ v: Float, width: Float, height: Float, offset: Float = 0.5, repeat r: Float = 1.2) -> (Float, SIMD2<Int>) {
        let x = u * r, y = v * r
        let row = Int(floor(y / height))
        let shifted = x + (row % 2 == 0 ? 0 : width * offset)
        let column = Int(floor(shifted / width))
        let cx = shifted - Float(column) * width, cy = y - Float(row) * height
        return (min(min(cx, width - cx), min(cy, height - cy)), SIMD2(column, row))
    }

    private static func generate() -> [UInt8] {
        let n = size, layerBytes = n * n * 4
        var out = [UInt8](repeating: 0, count: layerBytes * layerCount)
        for layer in 0..<layerCount {
            for py in 0..<n {
                for px in 0..<n {
                    let u = (Float(px) + 0.5) / Float(n), v = (Float(py) + 0.5) / Float(n)
                    let (tint, height) = texel(layer: layer, u: u, v: v)
                    let i = layer * layerBytes + (py * n + px) * 4
                    out[i] = UInt8(clamping: Int((simd_clamp(tint.x * 0.5, 0, 1) * 255).rounded()))
                    out[i + 1] = UInt8(clamping: Int((simd_clamp(tint.y * 0.5, 0, 1) * 255).rounded()))
                    out[i + 2] = UInt8(clamping: Int((simd_clamp(tint.z * 0.5, 0, 1) * 255).rounded()))
                    out[i + 3] = UInt8(clamping: Int((simd_clamp(height, 0, 1) * 255).rounded()))
                }
            }
        }
        return out
    }

    /// `tint` multiplies the source colour (1 = unchanged); `height` 0…1.
    private static func texel(layer: Int, u: Float, v: Float) -> (SIMD3<Float>, Float) {
        let one = SIMD3<Float>(repeating: 1)
        let grime = fbm(u, v, base: 4, seed: 7 + layer)
        let fine = noise(u, v, cells: 32, seed: 91 + layer)
        // u runs along the eave / along the wall; v runs down the slope / up the wall (metres via repeat).
        let x = u * repeatMetres(layer), y = v * repeatMetres(layer)
        switch layer {
        case 0, 1:
            // Corrugated sheet: 75 mm pitch ridges running down the slope, 0.6 m sheet laps and a
            // horizontal end lap every 1.2 m, fixing screws on every fourth crest.
            let corrugation = 0.5 + 0.5 * cos(x / 0.075 * 2 * .pi)
            let sheet = x.truncatingRemainder(dividingBy: 0.6)
            let lap = sheet < 0.02 ? 0.75 : 1.0
            let endLap = y < 0.025 ? 0.82 : 1.0
            let crest = Int(floor(x / 0.075))
            let screwRow = abs(y - 0.3) < 0.012 || abs(y - 0.9) < 0.012
            let screw: Float = screwRow && crest % 4 == 0 && corrugation > 0.9 ? 0.7 : 1.0
            var tint = one * (0.86 + 0.20 * corrugation) * Float(lap * endLap) * screw
            tint *= 0.93 + 0.12 * grime
            if layer == 1 {
                // Rust blooms along laps and streaks down the slope from fixings.
                let streak = streaks(u, v, across: 16, along: 2, seed: 13)
                let rust = simd_smoothstep(0.48, 0.72, grime * 0.7 + streak * 0.5 + (lap < 1 ? 0.25 : 0))
                tint = simd_mix(tint, SIMD3(1.32, 0.78, 0.52) * (0.85 + 0.25 * fine), SIMD3(repeating: rust * 0.85))
            }
            return (tint, corrugation * 0.85 + 0.1 * fine)
        case 2:
            // Clay Roman tile: 0.24 m wide barrels, 0.30 m courses, staggered with shadowed tails.
            let column = x / 0.24, course = y / 0.30
            let row = Int(floor(course))
            let cx = (column + (row % 2 == 0 ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
            let cy = course - Float(row)
            let barrel = sin(cx * .pi)
            let tail = cy > 0.86 ? 0.62 : 1.0
            let id = hash(Int(floor(column + (row % 2 == 0 ? 0 : 0.5))), row, 5)
            let tone = 0.86 + 0.24 * id
            let tint = SIMD3<Float>(tone * 1.02, tone * 0.98, tone * 0.95) * (0.82 + 0.26 * barrel) * Float(tail) * (0.92 + 0.12 * grime)
            return (tint, barrel * 0.8 + (1 - cy) * 0.2)
        case 3:
            // Stepped concrete/“decra” tile: 0.40 m courses with a deep step shadow and soft waves.
            let course = y / 0.40
            let cy = course - floor(course)
            let wave = 0.5 + 0.5 * cos(x / 0.20 * 2 * .pi)
            let step: Float = cy > 0.86 ? 0.55 : 1.0
            let granule = 0.94 + 0.10 * fine
            let tint = one * (0.88 + 0.14 * wave) * step * granule * (0.93 + 0.12 * grime)
            return (tint, (1 - cy) * 0.6 + wave * 0.3)
        case 4:
            // Box-rib (IBR) painted sheet: trapezoid ribs every 0.229 m, flat pans between.
            let p = x.truncatingRemainder(dividingBy: 0.24)
            let rib = simd_smoothstep(0.0, 0.025, p) * (1 - simd_smoothstep(0.05, 0.075, p))
            let tint = one * (0.95 + 0.12 * rib) * (rib > 0.1 && p > 0.04 ? 0.88 : 1.0) * (0.95 + 0.08 * grime)
            return (tint, rib)
        case 5:
            // Flat cement-screed slab as Dar roofs actually weather: mottled grey screed, black-green
            // algae where water ponds, pale fresh-cement repairs, meandering bitumen-sealed cracks,
            // rust drips from tank stands and sealant strips over the 1.2 m bay joints.
            let mottle = fbm(u, v, base: 4, seed: 41)
            let algae = simd_smoothstep(0.56, 0.74, fbm(u, v, base: 2, seed: 77) * 0.75 + grime * 0.35)
            let repair = simd_smoothstep(0.66, 0.70, fbm(u, v, base: 3, seed: 53))
            let crackField = abs(fbm(u, v, base: 3, seed: 19) - 0.5)
            let crack: Float = crackField < 0.012 && grime > 0.45 ? 1 : 0
            let rust = simd_smoothstep(0.78, 0.9, streaks(u, v, across: 8, along: 2, seed: 61)) * (1 - repair)
            let jx = x.truncatingRemainder(dividingBy: 1.2), jy = y.truncatingRemainder(dividingBy: 1.2)
            let joint: Float = min(jx, jy) < 0.05 ? 1 : 0
            var tint = one * (0.86 + 0.2 * mottle) * (0.95 + 0.08 * fine)
            tint = simd_mix(tint, SIMD3(1.10, 1.09, 1.06), SIMD3(repeating: repair * 0.75))
            tint = simd_mix(tint, SIMD3(0.42, 0.46, 0.40), SIMD3(repeating: algae * 0.7))
            tint = simd_mix(tint, SIMD3(0.98, 0.70, 0.50), SIMD3(repeating: rust * 0.35))
            tint = simd_mix(tint, SIMD3(0.36, 0.35, 0.34), SIMD3(repeating: max(crack, joint * 0.55)))
            return (tint, 0.55 - 0.3 * max(crack, joint) + 0.1 * (fine - 0.5))
        case 6:
            // Painted plaster: trowel mottle and rain streaks under openings.
            let streak = streaks(u, v, across: 16, along: 1, seed: 23)
            let tint = one * (0.95 + 0.07 * grime + 0.03 * fine) * (1 - simd_smoothstep(0.62, 0.85, streak) * 0.09)
            return (tint, 0.5 + 0.25 * (fine - 0.5))
        case 7:
            // Exposed cement block: 0.40 × 0.20 m running bond, recessed mortar.
            let (edge, id) = bond(u, v, width: 0.40, height: 0.20)
            let joint = simd_smoothstep(0.008, 0.02, edge)
            let tone = 0.9 + 0.16 * hash(id.x, id.y, 17) + 0.08 * fine
            let tint = one * tone * (0.72 + 0.28 * joint) * (0.94 + 0.1 * grime)
            return (tint, joint * (0.85 + 0.1 * fine))
        case 8:
            // Coral rag stone: irregular rounded stones in lime mortar (Voronoi on a jittered grid).
            let cells: Float = 6
            let gx = u * cells, gy = v * cells
            var best: Float = 9, second: Float = 9, bestID = 0
            for oy in -1...1 {
                for ox in -1...1 {
                    let cx = Int(floor(gx)) + ox, cy = Int(floor(gy)) + oy
                    let wx = ((cx % Int(cells)) + Int(cells)) % Int(cells), wy = ((cy % Int(cells)) + Int(cells)) % Int(cells)
                    let fx = Float(cx) + 0.15 + 0.7 * hash(wx, wy, 3), fy = Float(cy) + 0.15 + 0.7 * hash(wx, wy, 4)
                    let d = simd_length(SIMD2(gx - fx, gy - fy))
                    if d < best { second = best; best = d; bestID = wy * 97 + wx } else if d < second { second = d }
                }
            }
            let gap = second - best
            let stone = simd_smoothstep(0.04, 0.12, gap)
            let tone = 0.82 + 0.3 * hash(bestID, 1, 9)
            let mortar = SIMD3<Float>(1.08, 1.06, 1.0)
            let tint = simd_mix(mortar, SIMD3(tone * 1.02, tone, tone * 0.93) * (0.9 + 0.15 * fine), SIMD3(repeating: stone))
            return (tint, stone * (0.6 + 0.4 * simd_smoothstep(0.0, 0.4, gap)))
        case 9:
            // Rough-cast dash: dense aggregate speckle.
            let speck = noise(u, v, cells: 64, seed: 61)
            let tint = one * (0.88 + 0.22 * speck) * (0.94 + 0.1 * grime)
            return (tint, speck)
        case 10:
            // Fair-face brick: 0.24 × 0.08 m units, warm unit-to-unit variation.
            let (edge, id) = bond(u, v, width: 0.24, height: 0.08)
            let joint = simd_smoothstep(0.006, 0.014, edge)
            let r = hash(id.x, id.y, 29)
            let brick = SIMD3<Float>(1.0 + 0.12 * r, 0.9 + 0.08 * r, 0.85) * (0.9 + 0.12 * fine)
            let tint = simd_mix(SIMD3(1.1, 1.08, 1.04), brick, SIMD3(repeating: joint)) * (0.94 + 0.1 * grime)
            return (tint, joint)
        default:
            // Scored render: horizontal rustication grooves every 0.30 m on smooth plaster.
            let groove = y.truncatingRemainder(dividingBy: 0.30) < 0.025 ? 0.0 : 1.0
            let tint = one * Float(0.8 + 0.2 * groove) * (0.95 + 0.08 * grime)
            return (tint, Float(groove))
        }
    }
}
