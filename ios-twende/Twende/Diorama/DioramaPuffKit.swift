import Foundation
import simd

/// Stylised vegetation after the stylized-map-renderer skill (`make_tree.py`, style-spec §3).
///  - A canopy is a cluster of icosphere puffs (320 faces close, 80 far). A face is dropped only
///    when all three corners are buried inside a neighbouring puff, so the seams between puffs
///    always overlap and the crown is a closed, solid shell with no see-through gaps.
///  - Every puff vertex is pushed in or out by a few percent (stable hash), so a crown reads as a
///    lumpy volume of leaf clumps rather than a smooth balloon, at no extra triangle cost.
///  - Canopy normals: each vertex normal is blended 55 % toward the crown centre, so the whole
///    cluster shades as one soft cloud with no facets and no extra triangles.
///  - Colour is a dark-bottom → bright-top gradient in the vertex colour (smoothstep in height);
///    the shader only adds a ±6 % painterly grain (material 10).
///  - Trunks and branches are open 6-sided tapered tubes (4 far): no caps, the ends are hidden in
///    the ground or the canopy.
/// Every model here is a library prototype drawn as GPU instances.
nonisolated enum DioramaPuffKit {
    nonisolated struct Blob: Sendable {
        var centre: DV3
        var radii: DV3
        init(_ centre: DV3, _ r: Double, squash: Double = 1) {
            self.centre = centre
            radii = DV3(r, r, r * squash)
        }
        init(_ centre: DV3, radii: DV3) {
            self.centre = centre
            self.radii = radii
        }
    }

    /// Bottom and top colour of a canopy (sRGB hex), saturated for the Dar es Salaam look.
    nonisolated struct Gradient: Sendable {
        let bottom: UInt32
        let top: UInt32
    }

    static let green = Gradient(bottom: 0x3F8A1C, top: 0xC2E64A)
    static let deep = Gradient(bottom: 0x24661A, top: 0x86C23A)
    static let olive = Gradient(bottom: 0x557A1C, top: 0xB2D047)
    static let lime = Gradient(bottom: 0x4C9A1E, top: 0xD4F052)
    static let blossom = Gradient(bottom: 0xD8468E, top: 0xFFB0D8)
    static let flame = Gradient(bottom: 0xC42A16, top: 0xFF7E2E)
    static let magenta = Gradient(bottom: 0xA0145E, top: 0xF4489E)
    static let tangerine = Gradient(bottom: 0xD24E12, top: 0xFFA43C)
    static let hedge = Gradient(bottom: 0x2F741C, top: 0x96CC38)
    static let cypress = Gradient(bottom: 0x1E5228, top: 0x62A43A)
    static let frond = Gradient(bottom: 0x347A1C, top: 0xA6D63E)
    static let sunflower = Gradient(bottom: 0xE0A414, top: 0xFFDC3C)
    static let poppy = Gradient(bottom: 0xC81E1E, top: 0xFF5A3C)
    static let ivory = Gradient(bottom: 0xE6DCC8, top: 0xFFFDF6)

    static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
    }

    /// Vertex tint that turns a swatch's atlas colour into `target` (the packer multiplies them).
    static func tint(_ target: SIMD3<Float>, over swatch: DioramaSwatch) -> SIMD3<Float> {
        let base = rgb(DioramaSwatch.defaultPalette[swatch] ?? 0xFFFFFF)
        return target / simd_max(base, SIMD3(repeating: 0.02))
    }

    private static func inside(_ p: DV3, _ b: Blob, _ factor: Double) -> Bool {
        let q = DV3((p.x - b.centre.x) / b.radii.x, (p.y - b.centre.y) / b.radii.y, (p.z - b.centre.z) / b.radii.z)
        return q.length < factor
    }

    /// Stable lump in [-1, 1] for a unit-sphere vertex and a puff index.
    static func lump(_ v: DV3, _ salt: Int) -> Double {
        var h = UInt64(bitPattern: Int64((v.x * 977).rounded())) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64((v.y * 613).rounded())) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(bitPattern: Int64((v.z * 431).rounded())) &* 0x1656_67B1_9E37_79F9
        h ^= UInt64(salt) &* 0x27D4_EB2F_1656_67C5
        h ^= h >> 29
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 32
        return Double(h & 0xFFFF) / 32767.5 - 1
    }

    /// One puff cluster with canopy normals and a height gradient. `detail` picks the icosphere
    /// (2 = 320 faces, 1 = 80); by default 320 close and 80 far.
    static func canopy(_ m: inout DioramaMesh, _ blobs: [Blob], _ gradient: Gradient, light: Bool,
                       swatch: DioramaSwatch = .leafMid, blend: Double = 0.55, detail: Int? = nil, lumpiness: Double = 0.06) {
        guard !blobs.isEmpty else { return }
        let level = detail ?? (light ? 1 : 2)
        let shape = level >= 2 ? DioramaIcosphere.level2 : (level == 1 ? DioramaIcosphere.level1 : DioramaIcosphere.level0)
        // Neighbours may dent inward by `lumpiness`; only faces safely below that dent are hidden.
        let buried = 1 - lumpiness - 0.025
        var weight = 0.0
        var centre = DV3(0, 0, 0)
        for b in blobs {
            let w = b.radii.x * b.radii.y * b.radii.z
            centre = centre + b.centre * w
            weight += w
        }
        centre = centre * (1 / max(weight, 1e-9))
        let zLo = blobs.map { $0.centre.z - $0.radii.z }.min() ?? 0
        let zHi = blobs.map { $0.centre.z + $0.radii.z }.max() ?? 1
        let bottom = rgb(gradient.bottom), top = rgb(gradient.top)
        let uv = DioramaAtlas.uv(swatch, dark: false)
        let savedTint = m.tint, savedSurface = m.surface
        m.surface = SIMD2(10, 0)
        defer { m.tint = savedTint; m.surface = savedSurface }
        for (i, b) in blobs.enumerated() {
            func world(_ v: DV3) -> DV3 {
                let s = 1 + lumpiness * lump(v, i)
                return b.centre + DV3(v.x * b.radii.x * s, v.y * b.radii.y * s, v.z * b.radii.z * s)
            }
            var hidden = [Bool](repeating: false, count: shape.vertices.count)
            for (vi, v) in shape.vertices.enumerated() {
                let p = world(v)
                hidden[vi] = blobs.indices.contains { $0 != i && inside(p, blobs[$0], buried) }
            }
            let kept = shape.faces.filter { f in !(hidden[Int(f.x)] && hidden[Int(f.y)] && hidden[Int(f.z)]) }
            guard !kept.isEmpty else { continue }
            m.reserve(shape.vertices.count)
            var remap: [UInt32: UInt32] = [:]
            func index(_ vi: UInt32) -> UInt32 {
                if let found = remap[vi] { return found }
                let v = shape.vertices[Int(vi)]
                let p = world(v)
                let sphereNormal = DV3(v.x / b.radii.x, v.y / b.radii.y, v.z / b.radii.z).normalized
                let n = (sphereNormal * (1 - blend) + (p - centre).normalized * blend).normalized
                var t = min(max((p.z - zLo) / max(zHi - zLo, 1e-6), 0), 1)
                t = t * t * (3 - 2 * t)
                m.tint = savedTint * tint(bottom + (top - bottom) * Float(t), over: swatch)
                let id = m.vertex(p, n, uv)
                remap[vi] = id
                return id
            }
            for f in kept {
                let a = index(f.x), b = index(f.y), c = index(f.z)
                m.face(a, b, c)
            }
        }
    }

    /// Open tapered trunk or branch (6 sides close, 4 far), no caps.
    static func limb(_ m: inout DioramaMesh, from a: DV3, to b: DV3, r0: Double, r1: Double, light: Bool, _ swatch: DioramaSwatch = .trunk) {
        m.tube(from: a, to: b, r0: r0, r1: r1, sides: light ? 4 : 6, swatch, cap: false)
    }

    /// Lathed spindle or tier (`profile` bottom → top, radius, height) with smooth profile normals.
    static func lathe(_ m: inout DioramaMesh, profile: [(r: Double, z: Double)], sides: Int, _ gradient: Gradient,
                      zRange: ClosedRange<Double>, swatch: DioramaSwatch = .cypress) {
        guard profile.count >= 2 else { return }
        let bottom = rgb(gradient.bottom), top = rgb(gradient.top)
        let uv = DioramaAtlas.uv(swatch, dark: false)
        let savedTint = m.tint, savedSurface = m.surface
        m.surface = SIMD2(10, 0)
        defer { m.tint = savedTint; m.surface = savedSurface }
        m.reserve(profile.count * sides)
        let base = UInt32(m.positions.count)
        for (i, ring) in profile.enumerated() {
            let prev = profile[max(i - 1, 0)], next = profile[min(i + 1, profile.count - 1)]
            let dr = next.r - prev.r, dz = next.z - prev.z
            var t = min(max((ring.z - zRange.lowerBound) / max(zRange.upperBound - zRange.lowerBound, 1e-6), 0), 1)
            t = t * t * (3 - 2 * t)
            m.tint = savedTint * tint(bottom + (top - bottom) * Float(t), over: swatch)
            for k in 0..<sides {
                let a = Double(k) / Double(sides) * 2 * Double.pi
                let radial = DV2(cos(a), sin(a))
                m.vertex(DV3(radial * ring.r, ring.z), DV3(radial * dz, -dr).normalized, uv)
            }
        }
        for i in 0..<(profile.count - 1) {
            for k in 0..<sides {
                let j = (k + 1) % sides
                let a0 = base + UInt32(i * sides + k), b0 = base + UInt32(i * sides + j)
                let a1 = a0 + UInt32(sides), b1 = b0 + UInt32(sides)
                m.face(a0, b0, b1)
                m.face(a0, b1, a1)
            }
        }
    }

    /// Spread broadleaf crown: a top puff, a jittered ring and (close up) two lower fill puffs.
    static func crownBlobs(centre c: DV3, radius r: Double, squash: Double, ring: Int, spread: Double = 0.55,
                           fill: Bool, rng: inout DioramaRandom) -> [Blob] {
        var blobs = [Blob(c + DV3(0, 0, r * 0.45 * squash), r * 0.64, squash: squash)]
        for k in 0..<ring {
            let a = Double(k) / Double(ring) * 2 * Double.pi + rng.range(-0.3...0.3)
            let rr = r * rng.range(0.52...0.64)
            blobs.append(Blob(c + DV3(cos(a) * r * spread, sin(a) * r * spread, rng.range(-0.15...0.25) * r * squash), rr, squash: squash))
        }
        if fill {
            for k in 0..<2 {
                let a = rng.range(0...Double.pi * 2) + Double(k) * Double.pi
                blobs.append(Blob(c + DV3(cos(a) * r * 0.3, sin(a) * r * 0.3, -r * 0.35 * squash), r * 0.5, squash: squash))
            }
        }
        return blobs
    }

    /// Puffball broadleaf tree: Y-forked trunk under a puff crown (~6-9 m before instance scale).
    static func puffTree(seed: UInt64, trunkHeight h: Double, radius r: Double, squash: Double = 0.9, ring: Int = 6,
                         spread: Double = 0.55, _ gradient: Gradient, light: Bool, trunkRadius: Double = 0.24) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 0x50_55_46)
        let c = DV3(0, 0, h + r * 0.85 * squash)
        let fork = DV3(0, 0, h * 0.75)
        limb(&m, from: DV3(0, 0, -0.05), to: fork, r0: trunkRadius, r1: trunkRadius * 0.78, light: light)
        let branchAngle = rng.range(0...Double.pi * 2)
        for k in 0..<(light ? 1 : 2) {
            let a = branchAngle + Double(k) * Double.pi
            limb(&m, from: fork, to: c + DV3(cos(a) * r * 0.35, sin(a) * r * 0.35, -r * 0.1), r0: trunkRadius * 0.68, r1: trunkRadius * 0.36, light: light)
        }
        canopy(&m, crownBlobs(centre: c, radius: r, squash: squash, ring: light ? max(3, ring - 2) : ring, spread: spread,
                              fill: !light, rng: &rng), gradient, light: light)
        return m
    }

    /// Stacked puffs on one stem (neem, tall roadside trees, clipped ornamentals).
    static func tieredTree(seed: UInt64, trunkHeight h: Double, tiers: Int, radius r: Double, taper: Double, step: Double,
                           _ gradient: Gradient, light: Bool) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 0x54_49_45)
        limb(&m, from: DV3(0, 0, -0.05), to: DV3(0, 0, h + 0.6), r0: 0.24, r1: 0.18, light: light)
        var blobs: [Blob] = []
        for k in 0..<(light ? max(2, tiers - 1) : tiers) {
            let t = Double(k)
            let rr = r * (1 - taper * t / Double(max(tiers - 1, 1)))
            blobs.append(Blob(DV3(rng.range(-0.25...0.25), rng.range(-0.25...0.25), h + rr * 0.8 + t * step), radii: DV3(rr, rr * 0.94, rr * 0.78)))
        }
        canopy(&m, blobs, gradient, light: light)
        return m
    }

    /// Italian cypress: one lathed spindle (8 sides × 9 rings close, 6 × 6 far).
    static func cypressTree(light: Bool) -> DioramaMesh {
        var m = DioramaMesh()
        let height = 8.0, radius = 0.9, z0 = 0.6
        limb(&m, from: DV3(0, 0, -0.05), to: DV3(0, 0, z0 + 0.3), r0: 0.14, r1: 0.12, light: light)
        let rings = light ? 6 : 9
        var profile: [(r: Double, z: Double)] = []
        for i in 0...rings {
            let s = Double(i) / Double(rings)
            profile.append((radius * pow(s, 0.55) * pow(1 - s, 0.8) * 2.1, z0 + s * (height - z0)))
        }
        lathe(&m, profile: profile, sides: light ? 6 : 8, cypress, zRange: z0...height)
        return m
    }

    /// Coconut palm: curved trunk, ten drooping fronds and a coconut knot. Each frond is a closed
    /// solid with a folded cross-section (raised midrib, leaflets drooping to both edges, a keel
    /// underneath), so it has real thickness from every angle and never shows through.
    static func palm(seed: UInt64, lean: Double, light: Bool) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 0x50_41_4C)
        let height = rng.range(7.6...8.8)
        let heading = rng.range(0...Double.pi * 2)
        let dir = DV2(cos(heading), sin(heading))
        let segments = light ? 3 : 4
        var points: [DV3] = []
        for k in 0...segments {
            let s = Double(k) / Double(segments)
            points.append(DV3(dir * (lean * 1.3 * s * s), height * s))
        }
        for k in 0..<segments {
            let r0 = 0.24 - 0.08 * Double(k) / Double(segments), r1 = 0.24 - 0.08 * Double(k + 1) / Double(segments)
            limb(&m, from: k == 0 ? points[0] - DV3(0, 0, 0.05) : points[k], to: points[k + 1], r0: r0, r1: r1, light: light, .palmTrunk)
        }
        let top = points[segments]
        // Coconut cluster: three nuts tucked under the crown.
        for k in 0..<(light ? 1 : 3) {
            let a = Double(k) / 3 * 2 * Double.pi + heading
            let offset = light ? DV3(0, 0, -0.25) : DV3(cos(a) * 0.2, sin(a) * 0.2, -0.32)
            m.sphere(centre: top + offset, radii: DV3(0.2, 0.2, 0.22), .coconut, detail: light ? -1 : 0)
        }
        let lo = rgb(frond.bottom), hi = rgb(frond.top)
        let uv = DioramaAtlas.uv(.leafMid, dark: false)
        let savedTint = m.tint, savedSurface = m.surface
        m.surface = SIMD2(10, 0)
        defer { m.tint = savedTint; m.surface = savedSurface }
        let count = light ? 7 : 10
        let frondSegments = light ? 3 : 5
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * Double.pi + rng.range(-0.18...0.18)
            let u = DV2(cos(a), sin(a)), side = u.left
            let length = rng.range(3.2...4.0)
            // Upper fronds arch up before drooping; lower ones fall away sooner.
            let rise = i % 2 == 0 ? rng.range(0.55...0.85) : rng.range(0.15...0.4)
            let droop = i % 2 == 0 ? rng.range(1.2...1.6) : rng.range(1.7...2.3)
            for k in 0..<frondSegments {
                // Spine sample s and the next one; each frond segment is four strips with their own normals.
                func section(_ s: Double) -> (p: DV3, w: Double, t: DV3) {
                    let along = u * (length * s)
                    let z = 4 * rise * s * (1 - s) - droop * s * s * s
                    let dz = 4 * rise * (1 - 2 * s) - 3 * droop * s * s
                    let w = 0.06 + 0.62 * sin(min(1, s * 1.15) * Double.pi) * (1 - 0.35 * s)
                    return (top + DV3(along, z), w, DV3(u * length, dz).normalized)
                }
                let s0 = Double(k) / Double(frondSegments), s1 = Double(k + 1) / Double(frondSegments)
                let a0 = section(s0), a1 = section(s1)
                func corners(_ c: (p: DV3, w: Double, t: DV3)) -> [DV3] {
                    let up = DV3.up
                    let rib = c.p + up * (0.05 + c.w * 0.1)
                    let left = c.p - DV3(side * c.w, 0) - up * (c.w * 0.42)
                    let right = c.p + DV3(side * c.w, 0) - up * (c.w * 0.42)
                    let keel = c.p - up * (0.04 + c.w * 0.16)
                    return [rib, right, keel, left]
                }
                let r0 = corners(a0), r1 = corners(a1)
                let t0 = Float(s0), t1 = Float(s1)
                for strip in 0..<4 {
                    let j = (strip + 1) % 4
                    let edge = r0[j] - r0[strip]
                    let outward = a0.t.cross(edge).normalized
                    var n = outward
                    let upper = strip == 0 || strip == 3
                    // Undersides lean up so the shaded leaf stays green, never black.
                    if n.z < 0 { n = (n + DV3.up * 0.9).normalized }
                    m.reserve(4)
                    m.tint = savedTint * tint(hi + (lo - hi) * t0, over: .leafMid) * (upper ? 1 : 0.8)
                    let p0 = m.vertex(r0[strip], n, uv), p1 = m.vertex(r0[j], n, uv)
                    m.tint = savedTint * tint(hi + (lo - hi) * t1, over: .leafMid) * (upper ? 1 : 0.8)
                    let p2 = m.vertex(r1[j], n, uv), p3 = m.vertex(r1[strip], n, uv)
                    m.face(p0, p1, p2, outward: outward)
                    m.face(p0, p2, p3, outward: outward)
                }
            }
        }
        return m
    }

    /// Rounded boulder (style-spec rocks): an 80-face icosphere (20 far) with a stable lumpy
    /// displacement, a flattened, buried base and a dark-bottom → sun-bleached-top gradient.
    /// Five variants: round, slab, tall, split pair and a small cluster.
    static func rock(variant: Int, _ swatch: DioramaSwatch, light: Bool) -> DioramaMesh {
        var m = DioramaMesh()
        let shape = light ? DioramaIcosphere.level0 : DioramaIcosphere.level1
        let uv = DioramaAtlas.uv(swatch, dark: false)
        let savedTint = m.tint
        defer { m.tint = savedTint }
        let blobs: [(DV3, DV3)]
        switch variant % 5 {
        case 0: blobs = [(DV3(0, 0, 0.12), DV3(0.55, 0.48, 0.42))]
        case 1: blobs = [(DV3(0, 0, 0.06), DV3(0.68, 0.46, 0.26))]
        case 2: blobs = [(DV3(0, 0, 0.22), DV3(0.4, 0.36, 0.6))]
        case 3: blobs = [(DV3(-0.22, 0, 0.12), DV3(0.42, 0.36, 0.4)), (DV3(0.34, 0.12, 0.06), DV3(0.3, 0.28, 0.26))]
        default: blobs = [(DV3(0, 0, 0.1), DV3(0.44, 0.4, 0.36)), (DV3(0.42, -0.2, 0.0), DV3(0.24, 0.22, 0.2)),
                          (DV3(-0.3, 0.36, 0.0), DV3(0.2, 0.18, 0.17))]
        }
        for (bi, blob) in blobs.enumerated() {
            let (c, r) = blob
            m.reserve(shape.vertices.count)
            let base = UInt32(m.positions.count)
            for v in shape.vertices {
                // Two octaves of lumps: broad bulges and smaller chips; the base is pressed flat.
                let s = 1 + 0.16 * lump(v, variant * 7 + bi) + 0.06 * lump(v * 2.3, variant * 13 + bi)
                var p = DV3(v.x * r.x * s, v.y * r.y * s, v.z * r.z * s)
                if p.z < -r.z * 0.35 { p.z = -r.z * 0.35 - (p.z + r.z * 0.35) * 0.15 }
                let world = c + p
                let n = (DV3(p.x / (r.x * r.x), p.y / (r.y * r.y), p.z / (r.z * r.z)).normalized * 0.7 + v * 0.3).normalized
                let t = Float(min(max((world.z + 0.1) / 0.9, 0), 1))
                m.tint = savedTint * SIMD3(repeating: 0.66 + 0.46 * t)
                _ = m.vertex(world, n, uv)
            }
            for f in shape.faces { m.face(base + f.x, base + f.y, base + f.z) }
        }
        return m
    }

    /// Low shrub / bush mound: a few flattened puffs.
    static func bush(seed: UInt64, size: Double, puffs: Int, _ gradient: Gradient, light: Bool) -> DioramaMesh {
        var m = DioramaMesh()
        var rng = DioramaRandom(seed: seed, salt: 0x42_55_53)
        var blobs = [Blob(DV3(0, 0, size * 0.62), size * 0.72, squash: 0.78)]
        for k in 0..<(light ? max(1, puffs - 2) : puffs) {
            let a = Double(k) / Double(puffs) * 2 * Double.pi + rng.range(-0.4...0.4)
            let rr = size * rng.range(0.5...0.62)
            blobs.append(Blob(DV3(cos(a) * size * 0.55, sin(a) * size * 0.5, rr * 0.7), rr, squash: 0.8))
        }
        // Knee-high shrubs read as soft mounds with 20-face puffs; canopy normals hide the facets.
        canopy(&m, blobs, gradient, light: light || size < 1.0, swatch: .hedge)
        return m
    }

    /// Flowering bush: a green mound with a few small bloom puffs on its crown.
    static func flowerBush(seed: UInt64, _ bloom: Gradient, light: Bool) -> DioramaMesh {
        var m = bush(seed: seed, size: 0.78, puffs: 3, hedge, light: light)
        var rng = DioramaRandom(seed: seed, salt: 0x46_4C_57)
        var blooms: [Blob] = []
        for _ in 0..<(light ? 2 : 5) {
            let a = rng.range(0...Double.pi * 2), r = rng.range(0.1...0.5)
            blooms.append(Blob(DV3(cos(a) * r, sin(a) * r, 0.95 - r * 0.5), 0.2, squash: 0.85))
        }
        for b in blooms { canopy(&m, [b], bloom, light: true, swatch: .flowerPink, detail: 0, lumpiness: 0) }
        return m
    }

    /// Bougainvillea spilling over a wall: a wide magenta/orange puff cluster with one green puff.
    static func bougainvillea(_ gradient: Gradient, light: Bool) -> DioramaMesh {
        var m = DioramaMesh()
        let blobs = [Blob(DV3(0, 0.1, 1.85), radii: DV3(1.4, 0.8, 0.6)), Blob(DV3(0.75, 0.4, 1.45), radii: DV3(0.7, 0.48, 0.65)),
                     Blob(DV3(0.1, 0.5, 1.15), radii: DV3(0.6, 0.34, 0.8))]
        canopy(&m, light ? Array(blobs.prefix(2)) : blobs, gradient, light: light, swatch: .bougainvilleaMagenta)
        if !light { canopy(&m, [Blob(DV3(-0.8, 0.45, 1.35), radii: DV3(0.65, 0.42, 0.7))], hedge, light: true, swatch: .leafDark) }
        return m
    }
}
