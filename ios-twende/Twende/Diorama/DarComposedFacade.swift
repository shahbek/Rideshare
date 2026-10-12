import Foundation
import simd

/// Construction vocabulary for individually composed skyline parts. Wall openings, glass planes,
/// deep galleries and two-storey frames have different sections, not just different paint.
nonisolated struct DarComposedFacade {
    typealias Elevation = DarSkylineComposition.Elevation
    let wall: SIMD3<Float>
    let accent: SIMD3<Float>
    let glass: SIMD3<Float>
    let sourceID: UInt64
    /// Shader-facade datums (snapped by the tower); zero storey keeps the modelled facades.
    var ground: Double = 0
    var storey: Double = 0
    private let cream = DarTowerGenerator.rgb("#F4EFE7")
    private let silver = DarTowerGenerator.rgb("#BFCBCB")

    func pigment(_ color: SIMD3<Float>, as swatch: DioramaSwatch, into mesh: inout DioramaMesh) {
        let value = DioramaSwatch.defaultPalette[swatch] ?? 0xFFFFFF
        let base = SIMD3<Float>(Float((value >> 16) & 255), Float((value >> 8) & 255), Float(value & 255)) / 255
        mesh.tint = color / simd_max(base, SIMD3(repeating: 0.05))
    }

    /// Conservative discrete facade bound, including glow, reveals, rails and per-edge minimum bays.
    /// Roof/deck geometry is reserved separately and the finished building still has an exact cap.
    func triangleAllowance(_ ring: [DV2], from: Int, to: Int, front: DV2,
                           elevation: Elevation, sides: Elevation, bayWidth: Double) -> Int {
        let lengths = zip(ring, ring.dropFirst() + [ring[0]]).map { $0.distance(to: $1) }
        let longest = lengths.max() ?? 1
        let floors = to - from
        return ring.indices.reduce(0) { total, i in
            let length = lengths[i]
            if length < max(1.1, longest * 0.025) { return total + 2 }
            let out = (ring[(i + 1) % ring.count] - ring[i]).normalized.right
            let style = out.dot(front) > 0.6 ? elevation : sides
            if style == .nikko { return total + floors * 80 }
            let share = style == .rainbow ? 0.8 : 1.0
            let bays = max(1, Int(ceil(length * share / bayWidth)))
            if style == .curtain { return total + floors * (bays * 4 + 4) + (bays + 1) * 2 }
            let rows = style == .frame ? (floors + 1) / 2 : floors
            let cell = style == .gallery ? 34 : 24
            let eyebrows = style == .hotel || style == .horizontal ? rows * 12 : 0
            let corner = style == .rainbow ? floors * 12 + 6 : 0
            return total + rows * bays * cell + eyebrows + corner
        }
    }

    func build(_ ring: [DV2], from: Int, to: Int, floor: (Int) -> Double,
               front: DV2, elevation: Elevation, sides: Elevation, bayWidth: Double,
               into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let longest = zip(ring, ring.dropFirst() + [ring[0]]).map { $0.distance(to: $1) }.max() ?? 1
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let dir = (b - a).normalized, out = dir.right, length = a.distance(to: b)
            let main = out.dot(front) > 0.6
            let style = main ? elevation : sides
            if DioramaConfig.shaderFacades, storey > 0, style != .nikko {
                let drawn: DioramaFacade.Style
                if length < max(1.1, longest * 0.025) {
                    drawn = .plain
                } else {
                    switch style {
                    case .curtain: drawn = .curtain
                    case .horizontal: drawn = .ribbon
                    case .gallery: drawn = .gallery
                    default: drawn = .masonry
                    }
                }
                pigment(drawn == .curtain ? glass : wall, as: .whitewash, into: &mesh)
                let foot = floor(from)
                mesh.facadeWall(ring, edge: i, bottom: { _ in foot }, top: floor(to) - 0.24, .whitewash,
                    facade: DioramaFacade(style: drawn, storey: storey, groundFloor: ground), front: main && from == 0)
                continue
            }
            if length < max(1.1, longest * 0.025) {
                pigment(wall, as: .whitewash, into: &mesh)
                mesh.mouldedWall(ring, edge: i, z0: floor(from), z1: floor(to) - 0.24, .whitewash)
                continue
            }
            if style == .nikko {
                nikko(a, b, ring: ring, from: from, to: to, floor: floor, into: &mesh, glow: &glow)
                continue
            }
            var start = a
            if style == .rainbow {
                let end = a + (b - a) * 0.20
                curtain(a, end, from: from, to: to, floor: floor, bays: 2, into: &mesh, glow: &glow)
                start = end
            }
            let count = max(1, Int(ceil(start.distance(to: b) / bayWidth)))
            if style == .curtain {
                curtain(start, b, from: from, to: to, floor: floor, bays: count, into: &mesh, glow: &glow)
                continue
            }
            let group = style == .frame ? 2 : 1
            for f in stride(from: from, to: to, by: group) {
                let low = floor(f), high = floor(min(to, f + group)) - (f + group >= to ? 0.24 : 0)
                for k in 0..<count {
                    let pa = start + (b - start) * (Double(k) / Double(count))
                    let pb = start + (b - start) * (Double(k + 1) / Double(count))
                    let lit = (f * 7 + k * 3 + i + Int(sourceID % 31)) % 17 == 3
                    let share: Double
                    let sill: Double
                    let lintel: Double
                    let recess: Double
                    switch style {
                    case .horizontal: share = 0.94; sill = 0.85; lintel = 0.3; recess = 0.3
                    case .vertical: share = 0.69; sill = 0.20; lintel = 0.18; recess = 0.62
                    case .frame: share = 0.80; sill = 0.28; lintel = 0.42; recess = 0.85
                    case .gallery: share = 0.86; sill = 0.14; lintel = 0.28; recess = 1.45
                    case .hotel: share = k % 3 == 2 ? 0.41 : 0.82; sill = 0.85; lintel = 0.5; recess = 0.23
                    case .paired: share = 0.76; sill = 0.68; lintel = 0.52; recess = 0.35
                    case .rainbow: share = 0.65; sill = 0.6; lintel = 0.48; recess = 0.48
                    default: share = 0.52; sill = 0.9; lintel = 0.55; recess = 0.25
                    }
                    let pigment = style == .vertical && (k == 0 || k == count - 1) ? accent : wall
                    opening(pa, pb, ring: ring, low: low, high: high, share: share, sill: sill,
                        lintel: lintel, depth: recess, color: pigment, paired: style == .paired || style == .hotel,
                        gallery: style == .gallery, lit: lit,
                        transom: style == .frame && f + 1 < to ? floor(f + 1) : nil, into: &mesh, glow: &glow)
                }
                if style == .hotel || style == .horizontal {
                    pigment(style == .hotel ? accent : cream, as: .trimWhite, into: &mesh)
                    // Front-only eyebrow with a shallow closed section. No wraparound floor-ring generator.
                    strip(start + out * 0.06, b + out * 0.06, out: out,
                        low: high - 0.14, high: high, depth: 0.20, into: &mesh)
                }
            }
        }
    }

    private func curtain(_ a: DV2, _ b: DV2, from: Int, to: Int, floor: (Int) -> Double,
                         bays: Int, into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let out = (b - a).normalized.right
        for f in from..<to {
            let low = floor(f), high = floor(f + 1) - (f == to - 1 ? 0.24 : 0)
            pigment(glass * 0.70, as: .glassPale, into: &mesh)
            mesh.wall(a, b, z0: low, z1: low + 0.45, .glassPale)
            for k in 0..<bays {
                let left = a + (b - a) * (Double(k) / Double(bays))
                let right = a + (b - a) * (Double(k + 1) / Double(bays))
                pigment(glass * (k % 4 == 1 ? 0.89 : 1), as: .glassPale, into: &mesh)
                mesh.wall(left, right, z0: low + 0.45, z1: high, .glassPale)
                if (f * 3 + k * 7 + Int(sourceID % 23)) % 19 == 2 {
                    glow.wall(left + out * 0.01, right + out * 0.01, z0: low + 0.55, z1: high - 0.12, .windowGlow)
                }
            }
            pigment(silver * 0.7, as: .mastGrey, into: &mesh)
            mesh.wall(a + out * 0.018, b + out * 0.018, z0: high - 0.055, z1: high, .mastGrey)
        }
        pigment(silver * 0.82, as: .mastGrey, into: &mesh)
        let dir = (b - a).normalized
        for k in 0...bays {
            // Keep edge seams inside the face rather than protruding beyond a narrow source corner.
            let t = min(0.996, max(0.004, Double(k) / Double(bays)))
            let p = a + (b - a) * t + out * 0.02
            mesh.wall(p - dir * 0.035, p + dir * 0.035,
                z0: floor(from), z1: floor(to) - 0.24, .mastGrey)
        }
    }

    /// A complete opaque wall face with a recessed, backed opening. The four reveals terminate on
    /// real glazing; a gallery gets a floor and a solid thin balustrade inside that opening.
    private func opening(_ a: DV2, _ b: DV2, ring: [DV2], low: Double, high: Double,
                         share: Double, sill: Double, lintel: Double, depth: Double,
                         color: SIMD3<Float>, paired: Bool, gallery: Bool, lit: Bool, transom: Double? = nil,
                         into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let dir = (b - a).normalized, out = dir.right
        let left = a + (b - a) * ((1 - share) * 0.5), right = b - (b - a) * ((1 - share) * 0.5)
        let bottom = low + min(sill, (high - low) * 0.3), top = high - min(lintel, (high - low) * 0.25)
        pigment(color, as: .whitewash, into: &mesh)
        mesh.wall(a, left, z0: low, z1: high, .whitewash)
        mesh.wall(right, b, z0: low, z1: high, .whitewash)
        mesh.wall(left, right, z0: low, z1: bottom, .whitewash)
        mesh.wall(left, right, z0: top, z1: high, .whitewash)
        // Concave corners and shallow wings cannot accept arbitrary rectangular balcony cavities.
        let resolved = [depth, min(0.25, depth), 0.04].first { d in
            DarArchitecturePlan.fits([left, right, right - out * d, left - out * d], inside: ring, clearance: -0.025)
        } ?? 0
        let backL = left - out * resolved, backR = right - out * resolved
        if resolved > 0 {
            mesh.quad(DV3(left, bottom), DV3(right, bottom), DV3(backR, bottom), DV3(backL, bottom), .whitewash, normal: .up)
            mesh.quad(DV3(left, top), DV3(backL, top), DV3(backR, top), DV3(right, top), .whitewash, normal: DV3(0, 0, -1))
            mesh.quad(DV3(left, bottom), DV3(backL, bottom), DV3(backL, top), DV3(left, top), .whitewash, normal: DV3(dir, 0))
            mesh.quad(DV3(right, bottom), DV3(right, top), DV3(backR, top), DV3(backR, bottom), .whitewash, normal: DV3(-dir, 0))
        }
        pigment(glass, as: .glassPale, into: &mesh)
        mesh.wall(backL, backR, z0: bottom, z1: top, .glassPale)
        if lit { glow.wall(backL + out * 0.008, backR + out * 0.008, z0: bottom + 0.06, z1: top - 0.06, .windowGlow) }
        pigment(paired ? cream : silver, as: .mastGrey, into: &mesh)
        let width = paired ? 0.11 : 0.035
        let mid = (backL + backR) * 0.5 + out * 0.018
        mesh.wall(mid - dir * width, mid + dir * width, z0: bottom, z1: top, .mastGrey)
        if let transom, transom > bottom + 0.08, transom < top - 0.08 {
            pigment(silver, as: .mastGrey, into: &mesh)
            mesh.wall(backL + out * 0.024, backR + out * 0.024, z0: transom - 0.08, z1: transom + 0.08, .mastGrey)
        }
        if gallery && resolved > 0.7 {
            pigment(cream, as: .trimWhite, into: &mesh)
            strip(left - out * 0.09, right - out * 0.09, out: out,
                low: bottom, high: min(bottom + 0.92, top - 0.2), depth: 0.11, into: &mesh)
        }
    }

    /// Nikko's identifiable tapered glass panel. Its sides meet real flanking loggias rather than
    /// placing a triangle on top of an unrelated all-glass rectangular tower.
    private func nikko(_ a: DV2, _ b: DV2, ring: [DV2], from: Int, to: Int, floor: (Int) -> Double,
                       into mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let out = (b - a).normalized.right
        for f in from..<to {
            let low = floor(f), high = floor(f + 1) - (f == to - 1 ? 0.24 : 0)
            let t0 = Double(f - from) / Double(max(1, to - from))
            let t1 = Double(f + 1 - from) / Double(max(1, to - from))
            let w0 = 0.62 - 0.44 * t0, w1 = 0.62 - 0.44 * t1
            let l0 = a + (b - a) * ((1 - w0) * 0.5), r0 = b - (b - a) * ((1 - w0) * 0.5)
            let l1 = a + (b - a) * ((1 - w1) * 0.5), r1 = b - (b - a) * ((1 - w1) * 0.5)
            opening(a, l0, ring: ring, low: low, high: high, share: 0.82, sill: 0.14, lintel: 0.24,
                depth: 1.15, color: accent, paired: false, gallery: true, lit: f % 4 == 1, into: &mesh, glow: &glow)
            opening(r0, b, ring: ring, low: low, high: high, share: 0.82, sill: 0.14, lintel: 0.24,
                depth: 1.15, color: accent, paired: false, gallery: true, lit: f % 5 == 2, into: &mesh, glow: &glow)
            pigment(wall, as: .whitewash, into: &mesh)
            mesh.triangle(DV3(l0, low), DV3(l1, high), DV3(l0, high), .whitewash, normal: DV3(out, 0))
            mesh.triangle(DV3(r0, low), DV3(r0, high), DV3(r1, high), .whitewash, normal: DV3(out, 0))
            pigment(glass * 1.10, as: .glassPale, into: &mesh)
            mesh.quad(DV3(l0, low), DV3(r0, low), DV3(r1, high), DV3(l1, high), .glassPale, normal: DV3(out, 0))
            pigment(silver, as: .mastGrey, into: &mesh)
            mesh.wall(l1 + out * 0.018, r1 + out * 0.018, z0: high - 0.07, z1: high, .mastGrey)
            let mid = (a + b) * 0.5 + out * 0.02, dir = (b - a).normalized
            mesh.wall(mid - dir * 0.04, mid + dir * 0.04, z0: low, z1: high, .mastGrey)
        }
    }

    private func strip(_ a: DV2, _ b: DV2, out: DV2, low: Double, high: Double, depth: Double,
                       into mesh: inout DioramaMesh) {
        guard a.distance(to: b) > 0.05, high > low else { return }
        let ring = DioramaPolygon.counterClockwise([a, b, b - out * depth, a - out * depth])
        mesh.extrude(ring, z0: low, z1: high, .trimWhite, top: .trimWhite)
        mesh.polygon(ring, z: low, .trimWhite, facingUp: false)
    }
}
