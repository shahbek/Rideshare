import CoreGraphics
import Foundation

/// Top-down painted ground for one tile. RGB is albedo; alpha carries the material code (×32) the
/// shader uses to pick its faint grain (grass mottle, sand, asphalt, paving).
nonisolated struct DioramaGroundImage: Sendable {
    let size: Int
    let rgba: [UInt8]
}

/// Paints every flat finish of the tile (roads, pavements, lane paint, crossings, lawns, paving, sand,
/// car parks, forecourts) once into a single image that the ground mesh samples. Nothing flat is
/// draped as geometry any more, so there is no millimetre layer ladder, no boolean cutouts and no
/// slivers; later fills simply cover earlier ones with anti-aliased edges.
nonisolated final class DioramaGroundPainter {
    nonisolated enum Material: UInt8, Sendable {
        case plain = 0, grass = 1, sand = 2, asphalt = 3, paving = 4, clay = 7
        var shade: CGFloat { CGFloat(rawValue) * 32 / 255 }
    }

    let rect: DioramaRect
    let size: Int
    private let color: CGContext
    private let material: CGContext
    private let config: DioramaConfig

    init?(rect: DioramaRect, size: Int, config: DioramaConfig) {
        guard rect.width > 0, rect.height > 0, size >= 64,
              let color = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let material = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        self.rect = rect
        self.size = size
        self.color = color
        self.material = material
        self.config = config
        // Draw in local metres: x east, y north. Row 0 of the bitmap is the north edge.
        for context in [color, material] {
            context.scaleBy(x: CGFloat(Double(size) / rect.width), y: CGFloat(Double(size) / rect.height))
            context.translateBy(x: CGFloat(-rect.minX), y: CGFloat(-rect.minY))
            context.setLineJoin(.round)
            context.setLineCap(.round)
        }
        color.setShouldAntialias(true)
        color.setAllowsAntialiasing(true)
        // Material codes must never blend across an edge into a different code.
        material.setShouldAntialias(false)
        material.setAllowsAntialiasing(false)
    }

    /// Which grain a painted swatch gets in the shader.
    static func material(for swatch: DioramaSwatch) -> Material {
        switch swatch {
        case .grass, .lawn, .pitchGreen, .hedge: .grass
        case .earth, .wetSand, .seabed, .soil: .sand
        case .asphalt, .roadEarth: .asphalt
        case .paving, .pavement, .concrete, .courtyard, .kerb, .parkEdge: .paving
        case .tileClay: .clay
        default: .plain
        }
    }

    private func set(_ swatch: DioramaSwatch, stroke: Bool) {
        let rgb = config.palette[swatch] ?? 0xFF00FF
        let r = CGFloat((rgb >> 16) & 0xFF) / 255, g = CGFloat((rgb >> 8) & 0xFF) / 255, b = CGFloat(rgb & 0xFF) / 255
        let shade = Self.material(for: swatch).shade
        if stroke {
            color.setStrokeColor(red: r, green: g, blue: b, alpha: 1)
            material.setStrokeColor(gray: shade, alpha: 1)
        } else {
            color.setFillColor(red: r, green: g, blue: b, alpha: 1)
            material.setFillColor(gray: shade, alpha: 1)
        }
    }

    private static func path(_ rings: [[DV2]]) -> CGPath? {
        let path = CGMutablePath()
        var any = false
        for ring in rings where ring.count >= 3 {
            path.move(to: CGPoint(x: ring[0].x, y: ring[0].y))
            for p in ring.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            path.closeSubpath()
            any = true
        }
        return any ? path : nil
    }

    /// Fills one ring.
    func fill(_ ring: [DV2], _ swatch: DioramaSwatch) {
        fill([ring], swatch)
    }

    /// Fills an outer ring with holes (even-odd), or several disjoint rings at once.
    func fill(_ rings: [[DV2]], _ swatch: DioramaSwatch) {
        guard let path = Self.path(rings) else { return }
        set(swatch, stroke: false)
        for context in [color, material] {
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
    }

    /// Independent filled pieces are a union, not an even-odd polygon with holes. Nonzero winding
    /// avoids cancellation and antialiased cracks along shared boolean-piece edges.
    func fillPieces(_ pieces: [[DV2]], _ swatch: DioramaSwatch) {
        guard let path = Self.path(pieces.map { DioramaPolygon.counterClockwise($0) }) else { return }
        set(swatch, stroke: false)
        for context in [color, material] {
            context.addPath(path)
            context.fillPath(using: .winding)
        }
    }

    /// Fills the whole tile.
    func fillAll(_ swatch: DioramaSwatch) {
        fill([DV2(rect.minX, rect.minY), DV2(rect.maxX, rect.minY), DV2(rect.maxX, rect.maxY), DV2(rect.minX, rect.maxY)], swatch)
    }

    /// Strokes a polyline with a width in metres; optional dash pattern (also metres).
    func stroke(_ line: [DV2], width: Double, _ swatch: DioramaSwatch, dashes: [Double]? = nil, phase: Double = 0, cap: CGLineCap = .round) {
        guard line.count >= 2, width > 0 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: line[0].x, y: line[0].y))
        for p in line.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
        set(swatch, stroke: true)
        for context in [color, material] {
            context.setLineWidth(CGFloat(width))
            context.setLineCap(cap)
            if let dashes, !dashes.isEmpty {
                context.setLineDash(phase: CGFloat(phase), lengths: dashes.map { CGFloat($0) })
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }
            context.addPath(path)
            context.strokePath()
        }
    }

    /// Axis-aligned-to-direction rectangle stroke: a short bar centred on `p` of `length` along `along`.
    func bar(at p: DV2, along: DV2, length: Double, width: Double, _ swatch: DioramaSwatch) {
        let d = along.normalized * (length / 2)
        stroke([p - d, p + d], width: width, swatch, cap: .butt)
    }

    /// Final image: colour from the RGB context, material code from the grey context.
    func image() -> DioramaGroundImage {
        let count = size * size
        var rgba = [UInt8](repeating: 0, count: count * 4)
        if let colorData = color.data?.assumingMemoryBound(to: UInt8.self) {
            rgba.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                base.update(from: colorData, count: count * 4)
            }
        }
        if let materialData = material.data?.assumingMemoryBound(to: UInt8.self) {
            for i in 0..<count { rgba[i * 4 + 3] = materialData[i] }
        }
        return DioramaGroundImage(size: size, rgba: rgba)
    }
}
