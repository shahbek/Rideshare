import CoreGraphics
import CoreText
import Foundation

/// Top-down painted ground for one tile. RGB is albedo; alpha carries the material code (×32) the
/// shader uses to pick its faint grain (grass mottle, sand, asphalt, paving).
nonisolated struct DioramaGroundImage: Sendable {
    let size: Int
    let rgba: [UInt8]
    var paint: DioramaVectorPaint = .init()
}

/// Paints every flat finish of the tile (roads, pavements, lane paint, crossings, lawns, paving, sand,
/// car parks, forecourts) once into a single image that the ground mesh samples. Nothing flat is
/// draped as geometry any more, so there is no millimetre layer ladder, no boolean cutouts and no
/// slivers; later fills simply cover earlier ones with anti-aliased edges.
nonisolated final class DioramaGroundPainter {
    nonisolated enum Material: UInt8, Sendable {
        /// `mown` is grass that the shader also draws with alternating mower stripes (golf turf).
        case plain = 0, grass = 1, sand = 2, asphalt = 3, paving = 4, mown = 5, dirt = 6, clay = 7
        var shade: CGFloat { CGFloat(rawValue) * 32 / 255 }
    }

    /// Hybrid finish pigments store -(hybridBase + material) in alpha; anything below the threshold is one.
    static let hybridBase: Float = 100
    static let hybridThreshold: Float = -99.5
    /// Raster ops record which finish epoch they painted over in the low 5 bits of the material alpha.
    static let maximumEpoch: UInt8 = 31

    let rect: DioramaRect
    let size: Int
    private let color: CGContext
    private let material: CGContext
    private let config: DioramaConfig
    private var paintRings: [(ring: [DV2], color: SIMD4<Float>)] = []
    private var paintLayers: [UInt32] = []
    private var paintEpochs: [UInt32] = []
    private let analyticFinishes: Bool
    /// Compact tiles: hard finishes (asphalt, paving, clay) are exact vector layers; the raster only
    /// carries natural ground (grass, lawn, sand, soil, coast) at low resolution. Painter's order is
    /// kept with epochs: a raster op painted after a finish layer stores a newer epoch in its pixels,
    /// and finish layers from older epochs are hidden there (shader and CPU lookups agree).
    let hybridFinishes: Bool
    private var nextFinishLayer: UInt32 = 1
    private var epoch: UInt8 = 0
    private var finishSinceEpoch = false
    private(set) var epochOverflow = false
    /// Temporarily paints a different grain code than the swatch's default (e.g. mown golf turf).
    var materialOverride: Material?
    /// Stylised bakes: lane paint and crossings are rasterised like everything else, so the image is
    /// the whole ground and the shader never walks a vector paint list.
    let rasterOnly: Bool

    private func isVectorPaint(_ swatch: DioramaSwatch) -> Bool {
        !rasterOnly && (swatch == .marking || swatch == .crossing || swatch == .signYellow)
    }

    private func record(_ ring: [DV2], _ swatch: DioramaSwatch) {
        guard ring.count >= 3 else { return }
        paintRings.append((ring, DioramaAtlas.color(swatch, dark: false, config: config)))
        paintLayers.append(0); paintEpochs.append(0)
    }

    private func recordFinish(_ rings: [[DV2]], _ swatch: DioramaSwatch) {
        guard analyticFinishes, !isVectorPaint(swatch), swatch != .grass else { return }
        var pigment = DioramaAtlas.color(swatch, dark: false, config: config)
        // Negative alpha is metadata, never output opacity: -(material + 1).
        pigment.w = -Float(Self.material(for: swatch).rawValue) - 1
        for ring in rings where ring.count >= 3 {
            paintRings.append((ring, pigment)); paintLayers.append(nextFinishLayer); paintEpochs.append(0)
        }
        nextFinishLayer += 1
    }

    /// Hard surfaces become vector layers in compact tiles; natural ground stays in the raster.
    private func isHybridFinish(_ swatch: DioramaSwatch) -> Bool {
        guard hybridFinishes, !isVectorPaint(swatch) else { return false }
        switch materialOverride ?? Self.material(for: swatch) {
        case .asphalt, .paving, .clay: return true
        default: return false
        }
    }

    private func recordHybrid(_ rings: [[DV2]], _ swatch: DioramaSwatch) {
        var pigment = DioramaAtlas.color(swatch, dark: false, config: config)
        pigment.w = -(Self.hybridBase + Float((materialOverride ?? Self.material(for: swatch)).rawValue))
        var any = false
        for ring in rings where ring.count >= 3 {
            paintRings.append((ring, pigment)); paintLayers.append(nextFinishLayer); paintEpochs.append(UInt32(epoch))
            any = true
        }
        guard any else { return }
        nextFinishLayer += 1
        finishSinceEpoch = true
    }

    /// True when `rings` are an outer ring plus holes (any later ring starts inside the first).
    private static func hasHoles(_ rings: [[DV2]]) -> Bool {
        guard let outer = rings.first, rings.count > 1 else { return false }
        return rings.dropFirst().contains { $0.first.map { DioramaPolygon.contains(outer, $0) } ?? false }
    }

    init?(rect: DioramaRect, size requested: Int, config: DioramaConfig, analyticFinishes: Bool = false, hybridFinishes: Bool = false, rasterOnly: Bool = false) {
        // The renderer never samples a ground raster any more (procedural turf + exact vector
        // finishes, lane paint and kerbs). Only a 64 px placeholder is kept so archive formats and
        // readers stay unchanged; nothing large is painted, stored or uploaded.
        let size = min(requested, 64)
        guard rect.width > 0, rect.height > 0, requested >= 64,
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
        self.analyticFinishes = analyticFinishes && !rasterOnly
        self.hybridFinishes = hybridFinishes && !analyticFinishes && !rasterOnly
        self.rasterOnly = rasterOnly
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
        case .naturalEarth: .dirt
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
        var shade = (materialOverride ?? Self.material(for: swatch)).shade
        if hybridFinishes {
            // A raster op after finish layers starts a new epoch; its pixels hide those layers.
            if finishSinceEpoch {
                if epoch < Self.maximumEpoch { epoch += 1 } else { epochOverflow = true }
                finishSinceEpoch = false
            }
            shade = CGFloat(Int((materialOverride ?? Self.material(for: swatch)).rawValue) * 32 + Int(epoch)) / 255
        }
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
        if isVectorPaint(swatch) { for ring in rings { record(ring, swatch) }; return }
        // Holed hard surfaces stay raster (vector layers are hole-free triangles).
        if isHybridFinish(swatch), !Self.hasHoles(rings) { recordHybrid(rings, swatch); return }
        guard let path = Self.path(rings) else { return }
        if rings.count == 1 { recordFinish(rings, swatch) }
        set(swatch, stroke: false)
        for context in [color, material] {
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
    }

    /// Independent filled pieces are a union, not an even-odd polygon with holes. Nonzero winding
    /// avoids cancellation and antialiased cracks along shared boolean-piece edges.
    func fillPieces(_ pieces: [[DV2]], _ swatch: DioramaSwatch) {
        if isHybridFinish(swatch) { recordHybrid(pieces, swatch); return }
        guard let path = Self.path(pieces.map { DioramaPolygon.counterClockwise($0) }) else { return }
        recordFinish(pieces, swatch)
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
        if isVectorPaint(swatch) {
            let clean = DioramaLinearGeometry.simplified(line)
            let dash = dashes?.filter { $0 > 0 } ?? []
            let period = dash.reduce(0, +)
            let total = DioramaPolygon.length(clean)
            // Visible station intervals along the whole line (dashes run across vertices).
            var intervals: [(Double, Double)] = []
            if period > 0 {
                var s = 0.0
                while s < total - 0.00001 {
                    var t = (s + phase).truncatingRemainder(dividingBy: period)
                    if t < 0 { t += period }
                    var index = 0
                    while index < dash.count - 1 && t >= dash[index] { t -= dash[index]; index += 1 }
                    let run = min(total - s, max(0.00001, dash[index] - t))
                    if index % 2 == 0 { intervals.append((s, s + run)) }
                    s += run
                }
            } else {
                intervals = [(0, total)]
            }
            for (s0, s1) in intervals {
                for quad in Self.mitredStrip(Self.subline(clean, from: s0, to: s1), halfWidth: width / 2) { record(quad, swatch) }
            }
            return
        }
        if analyticFinishes || (isHybridFinish(swatch) && (dashes ?? []).isEmpty) {
            let clean = DioramaLinearGeometry.simplified(line)
            let road = DioramaRoadFeature(id: 0, line: clean, roadClass: "service", isPaved: true, width: width)
            let pieces = DioramaStreetSurface.corridor(road, extra: 0, caps: cap != .butt)
            if hybridFinishes { recordHybrid(pieces, swatch); return }
            recordFinish(pieces, swatch)
        }
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

    /// The part of `line` between two stations (metres from its start).
    static func subline(_ line: [DV2], from s0: Double, to s1: Double) -> [DV2] {
        var result: [DV2] = []
        var station = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let length = a.distance(to: b)
            defer { station += length }
            guard length > 1e-6, station + length >= s0, station <= s1 else { continue }
            let t0 = max(0, (s0 - station) / length), t1 = min(1, (s1 - station) / length)
            let p = a + (b - a) * t0, q = a + (b - a) * t1
            if result.last.map({ $0.distance(to: p) > 1e-4 }) ?? true { result.append(p) }
            if q.distance(to: p) > 1e-4 { result.append(q) }
        }
        return result
    }

    /// A polyline offset sideways with mitred corners (clipped to 3× the offset on hairpins).
    static func mitredOffset(_ line: [DV2], by offset: Double) -> [DV2] {
        guard line.count >= 2 else { return line }
        return line.indices.map { i in
            let before = i > 0 ? (line[i] - line[i - 1]).normalized : nil
            let after = i < line.count - 1 ? (line[i + 1] - line[i]).normalized : nil
            let n0 = before?.right ?? after?.right ?? DV2(0, 0), n1 = after?.right ?? n0
            let sum = n0 + n1
            guard sum.length > 1e-6 else { return line[i] + n0 * offset }
            let bisector = sum.normalized
            let scale = min(3, 1 / max(bisector.dot(n0), 1e-3))
            return line[i] + bisector * (offset * scale)
        }
    }

    /// Quads of a mitred stroke. Consecutive quads share their joint edge exactly, so the
    /// shader's summed coverage is seamless across bends (no wedge gaps, no doubled overlaps).
    static func mitredStrip(_ line: [DV2], halfWidth: Double) -> [[DV2]] {
        guard line.count >= 2 else { return [] }
        let left = mitredOffset(line, by: -halfWidth), right = mitredOffset(line, by: halfWidth)
        var quads: [[DV2]] = []
        for i in 0..<(line.count - 1) {
            let quad = [left[i], right[i], right[i + 1], left[i + 1]]
            // A hairpin can fold a joint; fall back to a plain rectangle for that segment only.
            if (quad[1] - quad[0]).cross(quad[2] - quad[1]) * (quad[3] - quad[2]).cross(quad[0] - quad[3]) > 0 {
                quads.append(quad)
            } else {
                let n = (line[i + 1] - line[i]).normalized.right * halfWidth
                quads.append([line[i] - n, line[i] + n, line[i + 1] + n, line[i + 1] - n])
            }
        }
        return quads
    }

    /// Axis-aligned-to-direction rectangle stroke: a short bar centred on `p` of `length` along `along`.
    func bar(at p: DV2, along: DV2, length: Double, width: Double, _ swatch: DioramaSwatch) {
        let d = along.normalized * (length / 2)
        stroke([p - d, p + d], width: width, swatch, cap: .butt)
    }

    /// Muted earth tint with a feathered boundary, using the existing terrain surface only.
    func earthPatch(_ pieces: [[DV2]], outline: [DV2], centre: DV2) {
        guard let path = Self.path(pieces.map { DioramaPolygon.counterClockwise($0) }) else { return }
        set(.naturalEarth, stroke: false)
        color.saveGState()
        color.addPath(path); color.clip()
        color.setAlpha(0.28)
        for factor in stride(from: 1.0, through: 0.75, by: -0.05) {
            let inset = outline.map { centre + ($0 - centre) * factor }
            if let feather = Self.path([inset]) { color.addPath(feather); color.fillPath() }
        }
        color.restoreGState()
        material.addPath(path); material.fillPath(using: .winding)
    }

    /// Baked lighting: darkens the colour under `pieces` (a union, filled once so overlaps never
    /// double-darken) by `darkness`. Material codes are untouched.
    func shade(_ pieces: [[DV2]], darkness: Double) {
        guard let path = Self.path(pieces.map { DioramaPolygon.counterClockwise($0) }) else { return }
        color.saveGState()
        color.setBlendMode(.multiply)
        let grey = CGFloat(max(0, min(1, 1 - darkness)))
        color.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
        color.addPath(path)
        color.fillPath(using: .winding)
        color.restoreGState()
    }

    /// Baked lighting: a soft round shadow (tree crowns) centred on `centre`.
    func shadeDisc(at centre: DV2, radius: Double, darkness: Double) {
        guard radius > 0.05 else { return }
        color.saveGState()
        color.setBlendMode(.multiply)
        let grey = CGFloat(max(0, min(1, 1 - darkness)))
        color.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
        color.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius * 0.7, width: radius * 2, height: radius * 1.4))
        color.restoreGState()
    }

    /// Road names are painted into albedo, not floating signs or extra 3D surfaces.
    func roadName(_ title: String, centre: DV2, direction: DV2, maximumWidth: Double) {
        // Compact rasters are too coarse for 1 m lettering; the map's own street labels name roads.
        guard !hybridFinishes, !rasterOnly else { return }
        let font = CTFontCreateWithName("Figtree-SemiBold" as CFString, 1.15, nil)
        let text = NSAttributedString(string: title, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.98, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0, width <= maximumWidth else { return }
        let axis = direction.x < 0 ? -direction : direction
        color.saveGState()
        color.translateBy(x: centre.x, y: centre.y)
        color.rotate(by: axis.angle)
        color.textMatrix = .identity
        color.setTextDrawingMode(.fill)
        color.textPosition = CGPoint(x: -width / 2, y: -0.42)
        CTLineDraw(line, color)
        color.restoreGState()
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
        return DioramaGroundImage(size: size, rgba: rgba, paint: DioramaVectorPaint(rings: paintRings, rect: rect, layers: paintLayers,
                                                                                    epochs: hybridFinishes ? paintEpochs : [], kerbs: kerbRecords))
    }

    // MARK: Shader kerbs

    /// Kerbs are paint, not geometry (skill: "a shader bevel on the sidewalk polygon border"). Each
    /// exposed carriageway span becomes a 0.7 m band inside the asphalt; the fragment shader turns
    /// the distance from the road edge into a pale kerb top, a sun-lit kerb face and a soft gutter
    /// shadow. Two records per span (color.w 3: distance from edge0; 4: band width minus it).
    static let kerbBand: Double = 0.7
    private var kerbRecords: [(DioramaPaintTriangle, DioramaRect)] = []
    /// True when kerbs can be drawn by the shader (compact vector tiles).
    var paintsKerbs: Bool { hybridFinishes && !rasterOnly }

    func kerb(_ a: DV2, _ b: DV2, inward: DV2, startExtra: Double = 0.12, endExtra: Double = 0.12) {
        guard paintsKerbs, a.distance(to: b) > 0.05 else { return }
        var dir = (b - a).normalized
        // Overlap neighbouring spans so bends never open a wedge; the shader averages overlaps.
        var p0 = a - dir * startExtra, p1 = b + dir * endExtra
        if dir.left.dot(inward) < 0 { swap(&p0, &p1); dir = -dir }
        let band = dir.left * Self.kerbBand
        let p1w = p1 + band, p0w = p0 + band
        var colour = DioramaAtlas.color(.kerb, dark: false, config: config)
        func edge(_ u: DV2, _ v: DV2) -> SIMD4<Float> {
            let n = (v - u).normalized.left
            return SIMD4(Float(n.x), Float(n.y), Float(-n.dot(u)), 0)
        }
        let bounds = DioramaRect.bounding([p0, p1, p1w, p0w])
        colour.w = 3
        kerbRecords.append((DioramaPaintTriangle(edge0: edge(p0, p1), edge1: edge(p1, p1w), edge2: edge(p1w, p0), color: colour), bounds))
        colour.w = 4
        kerbRecords.append((DioramaPaintTriangle(edge0: edge(p1w, p0w), edge1: edge(p0w, p0), edge2: edge(p0, p1w), color: colour), bounds))
    }
}
