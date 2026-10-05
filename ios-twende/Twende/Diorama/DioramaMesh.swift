import Foundation

/// Rotation about the vertical axis, per-axis scale, then translation.
nonisolated struct DioramaTransform: Sendable {
    var rotation: Double = 0
    var scale: DV3 = DV3(1, 1, 1)
    var translation: DV3 = DV3(0, 0, 0)
}

/// A small model built once at the origin (facing +x, standing on z = 0) and drawn many times as GPU
/// instances. `light` is a cheaper tessellation of the same shape for distant placements.
nonisolated struct DioramaPrototype: Sendable {
    let id: Int
    let full: DioramaMesh
    let light: DioramaMesh
    /// Bounding radius in prototype space, for per-instance frustum culling.
    let radius: Double

    init(id: Int, full: DioramaMesh, light: DioramaMesh? = nil) {
        self.id = id
        self.full = full
        self.light = light ?? full
        radius = full.positions.reduce(0) { max($0, $1.length) }
    }
}

/// One placement of a prototype recorded while generating a category mesh.
nonisolated struct DioramaInstancePlacement: Sendable {
    let prototype: Int
    let transform: DioramaTransform
}

/// Merged triangle mesh in local metres (x east, y north, z up). Every vertex points at a swatch of the
/// palette atlas, so one material colours a whole category. Triangles are auto-wound to face their
/// vertex normals, which keeps every helper free of winding bookkeeping.
nonisolated struct DioramaMesh: Sendable {
    nonisolated struct Chunk: Sendable {
        var vertex: Int
        var index: Int
    }

    /// glTF primitives use 16-bit indices here (Mapbox's model loader stores indices as uint16).
    static let maxChunkVertices = 65_000

    private(set) var positions: [DV3] = []
    private(set) var normals: [DV3] = []
    private(set) var uvs: [SIMD2<Float>] = []
    /// One free float per vertex, forwarded to the shader as `appearance.z` (water uses it for the
    /// distance to the shore; pools mark themselves with -1). Zero for everything else.
    private(set) var attributes: [Float] = []
    private(set) var indices: [UInt32] = []
    private(set) var chunks: [Chunk] = [Chunk(vertex: 0, index: 0)]
    /// Prototype placements drawn as GPU instances rather than baked copies.
    private(set) var instances: [DioramaInstancePlacement] = []
    /// One flag per triangle: true for genuinely thin, open surfaces (fronds, sails, canopies) that
    /// must be visible from both sides. Everything else is a closed shape drawn with back-face culling.
    private(set) var doubleSidedTriangles: [Bool] = []
    /// Set while adding thin surfaces so their triangles are flagged double-sided.
    var doubleSided: Bool = false

    var hasDoubleSidedTriangles: Bool { doubleSidedTriangles.contains(true) }
    /// Added to the z of every vertex appended while set, so generators can build a house at z = 0 and
    /// have it land on the terrain.
    var baseZ: Double = 0
    /// While set, vertices with no explicit attribute record their height above `baseZ` (offset by
    /// `heightAttributeOffset`), so the shader can grade walls lighter towards the top.
    var recordsHeight: Bool = false
    static let heightAttributeOffset: Float = 100
    /// Per-vertex colour multiplier applied at pack time; a slight hue shift per building.
    private(set) var tints: [SIMD3<Float>] = []
    var tint: SIMD3<Float> = SIMD3(1, 1, 1)

    var isEmpty: Bool { indices.isEmpty && instances.isEmpty }
    var triangleCount: Int { indices.count / 3 }

    /// Records one instance of a prototype; `baseZ` applies like it does to baked vertices.
    mutating func instance(_ prototype: DioramaPrototype, _ t: DioramaTransform) {
        var transform = t
        transform.translation.z += baseZ
        instances.append(DioramaInstancePlacement(prototype: prototype.id, transform: transform))
    }

    /// Starts a new 16-bit chunk when the next shape would overflow the current one.
    mutating func reserve(_ count: Int) {
        let base = chunks[chunks.count - 1].vertex
        if positions.count > base, positions.count - base + count > Self.maxChunkVertices {
            chunks.append(Chunk(vertex: positions.count, index: indices.count))
        }
    }

    @discardableResult
    mutating func vertex(_ p: DV3, _ n: DV3, _ uv: SIMD2<Float>, attribute: Float = 0) -> UInt32 {
        positions.append(baseZ == 0 ? p : DV3(p.x, p.y, p.z + baseZ))
        normals.append(n)
        uvs.append(uv)
        attributes.append(recordsHeight && attribute == 0 ? Float(p.z) + Self.heightAttributeOffset : attribute)
        tints.append(tint)
        return UInt32(positions.count - 1)
    }

    /// Appends indices verbatim (no auto-winding); used for shader-built sprites with no geometry normal.
    mutating func rawTriangles(_ list: [UInt32]) {
        indices.append(contentsOf: list)
        for _ in stride(from: 0, to: list.count, by: 3) { doubleSidedTriangles.append(true) }
    }

    /// Triangle whose winding is already geometrically correct (counter-clockwise seen from outside).
    /// Used by every primitive whose orientation is known from its own construction.
    mutating func face(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices.append(contentsOf: [a, b, c])
        doubleSidedTriangles.append(doubleSided)
    }

    /// Triangle wound to face the direction `outward`, derived from the caller's geometry (a wall's
    /// outward side, a cross-section normal), never from averaged vertex normals.
    mutating func face(_ a: UInt32, _ b: UInt32, _ c: UInt32, outward: DV3) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        if (pb - pa).cross(pc - pa).dot(outward) < 0 {
            face(a, c, b)
        } else {
            face(a, b, c)
        }
    }

    /// Legacy helper for strips built from cross-sections: the shared vertex normals there are
    /// computed from the section geometry itself, so they are a reliable outward reference.
    mutating func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let n = normals[Int(a)] + normals[Int(b)] + normals[Int(c)]
        face(a, b, c, outward: n)
    }

    // MARK: Flat primitives

    mutating func triangle(_ a: DV3, _ b: DV3, _ c: DV3, _ s: DioramaSwatch, dark: Bool = false, normal: DV3? = nil) {
        let n = normal ?? (b - a).cross(c - a).normalized
        reserve(3)
        let uv = DioramaAtlas.uv(s, dark: dark)
        let i0 = vertex(a, n, uv), i1 = vertex(b, n, uv), i2 = vertex(c, n, uv)
        face(i0, i1, i2, outward: n)
    }

    mutating func quad(_ a: DV3, _ b: DV3, _ c: DV3, _ d: DV3, _ s: DioramaSwatch, dark: Bool = false, normal: DV3? = nil) {
        var n = normal ?? (b - a).cross(d - a).normalized
        if normal == nil, (b - a).cross(d - a).length < 1e-9 { n = (c - a).cross(d - b).normalized }
        reserve(4)
        let uv = DioramaAtlas.uv(s, dark: dark)
        let i0 = vertex(a, n, uv), i1 = vertex(b, n, uv), i2 = vertex(c, n, uv), i3 = vertex(d, n, uv)
        face(i0, i1, i2, outward: n)
        face(i0, i2, i3, outward: n)
    }

    /// Flat horizontal polygon. Ear clipping of a counter-clockwise ring yields counter-clockwise
    /// triangles, which face up; reversed when facing down.
    mutating func polygon(_ ring: [DV2], z: Double, _ s: DioramaSwatch, dark: Bool = false, facingUp: Bool = true, attribute: Float = 0) {
        let ccw = DioramaPolygon.counterClockwise(ring)
        guard ccw.count >= 3 else { return }
        reserve(ccw.count)
        let n = DV3(0, 0, facingUp ? 1 : -1)
        let uv = DioramaAtlas.uv(s, dark: dark)
        let base = positions.count
        for p in ccw { vertex(DV3(p, z), n, uv, attribute: attribute) }
        for (a, b, c) in DioramaPolygon.triangulate(ccw) {
            if facingUp {
                face(UInt32(base + a), UInt32(base + b), UInt32(base + c))
            } else {
                face(UInt32(base + a), UInt32(base + c), UInt32(base + b))
            }
        }
    }

    /// Vertical wall from `a` to `b`, facing the right of travel. The lowest band uses the darker
    /// "ambient occlusion" copy of the swatch.
    mutating func wall(_ a: DV2, _ b: DV2, z0: Double, z1: Double, _ s: DioramaSwatch, ao: Double = 0) {
        guard z1 > z0 + 1e-4, a.distance(to: b) > 1e-4 else { return }
        let out = DV3((b - a).normalized.right, 0)
        if ao > 0, z0 < 0.01, z1 > ao + 0.05 {
            quad(DV3(a, z0), DV3(b, z0), DV3(b, ao), DV3(a, ao), s, dark: true, normal: out)
            quad(DV3(a, ao), DV3(b, ao), DV3(b, z1), DV3(a, z1), s, normal: out)
        } else {
            quad(DV3(a, z0), DV3(b, z0), DV3(b, z1), DV3(a, z1), s, normal: out)
        }
    }

    /// Smooth vertex normals on radiused ring segments; true angular corners retain hard edges.
    mutating func mouldedWall(_ ring: [DV2], edge i: Int, z0: Double, z1: Double, _ s: DioramaSwatch) {
        guard ring.count >= 3, z1 > z0 else { return }
        let j = (i + 1) % ring.count
        let a = ring[i], b = ring[j]
        let face = (b - a).normalized.right
        func normal(_ index: Int) -> DV3 {
            let before = (ring[index] - ring[(index + ring.count - 1) % ring.count]).normalized.right
            let after = (ring[(index + 1) % ring.count] - ring[index]).normalized.right
            return DV3(before.dot(after) > 0.9 ? (before + after).normalized : face, 0)
        }
        let uv = DioramaAtlas.uv(s, dark: false)
        let na = normal(i), nb = normal(j)
        let v0 = vertex(DV3(a, z0), na, uv), v1 = vertex(DV3(b, z0), nb, uv)
        let v2 = vertex(DV3(b, z1), nb, uv), v3 = vertex(DV3(a, z1), na, uv)
        let out = DV3(face, 0)
        self.face(v0, v1, v2, outward: out); self.face(v0, v2, v3, outward: out)
    }

    /// Walls of a counter-clockwise ring, optionally skipping flagged edges, with an optional lid.
    mutating func extrude(_ ring: [DV2], z0: Double, z1: Double, _ s: DioramaSwatch, ao: Double = 0, skip: [Bool]? = nil, top: DioramaSwatch? = nil) {
        let n = ring.count
        guard n >= 3 else { return }
        for i in 0..<n where !(skip?[i] ?? false) {
            if ao == 0, ring[i].distance(to: ring[(i + 1) % n]) < 2 {
                mouldedWall(ring, edge: i, z0: z0, z1: z1, s)
            } else {
                wall(ring[i], ring[(i + 1) % n], z0: z0, z1: z1, s, ao: ao)
            }
        }
        if let top { polygon(ring, z: z1, top) }
    }

    /// Horizontal band standing proud of a ring (floor lines, cornices, plinths). Follows the ring exactly.
    mutating func band(_ ring: [DV2], flags: [Bool]? = nil, offset d: Double, z0: Double, z1: Double, _ s: DioramaSwatch) {
        let n = ring.count
        guard n >= 3, let outer = DioramaPolygon.offset(ring, by: d), outer.count == n else { return }
        for i in 0..<n where !(flags?[i] ?? false) {
            let j = (i + 1) % n
            mouldedWall(outer, edge: i, z0: z0, z1: z1, s)
            quad(DV3(ring[i], z1), DV3(ring[j], z1), DV3(outer[j], z1), DV3(outer[i], z1), s, normal: .up)
            quad(DV3(ring[i], z0), DV3(ring[j], z0), DV3(outer[j], z0), DV3(outer[i], z0), s, dark: true, normal: DV3(0, 0, -1))
        }
    }

    /// Vertical regular polygon (a sign face) centred at `c`, facing `out`.
    mutating func verticalDisc(centre c: DV3, radius: Double, sides: Int, facing out: DV2, _ s: DioramaSwatch, rotate: Double = 0) {
        let count = max(sides, 3)
        let across = out.left
        reserve(count + 1)
        let uv = DioramaAtlas.uv(s, dark: false)
        let n = DV3(out, 0)
        let centre = vertex(c, n, uv)
        let base = positions.count
        for k in 0..<count {
            let a = Double(k) / Double(count) * 2 * Double.pi + rotate
            vertex(c + DV3(across * (cos(a) * radius), sin(a) * radius), n, uv)
        }
        // A sign face is a single sheet: readable from behind as well.
        let wasDoubleSided = doubleSided
        doubleSided = true
        for k in 0..<count { face(centre, UInt32(base + k), UInt32(base + (k + 1) % count), outward: n) }
        doubleSided = wasDoubleSided
    }

    /// Upright box with optional softly bevelled vertical corners and top edge.
    mutating func box(
        centre: DV2, z0: Double, axis: DV2 = DV2(1, 0), halfLength: Double, halfWidth: Double, height: Double,
        _ s: DioramaSwatch, top: DioramaSwatch? = nil, ao: Double = 0, bevel: Double = 0, bottom: Bool = false
    ) {
        let rect = DioramaOrientedRect(centre: centre, axis: axis.normalized, halfLength: halfLength, halfWidth: halfWidth)
        let z1 = z0 + height
        let lid = top ?? s
        if bevel > 0.005, min(halfLength, halfWidth) > bevel * 1.6, height > bevel * 2 {
            let outer = DioramaPolygon.chamferedCorners(rect.corners, by: bevel)
            let innerRect = rect.expanded(by: -bevel * 0.8)
            let inner = DioramaPolygon.chamferedCorners(innerRect.corners, by: bevel * 0.5)
            extrude(outer, z0: z0, z1: z1 - bevel, s, ao: ao)
            let n = outer.count
            for i in 0..<n {
                let j = (i + 1) % n
                let edgeOut = DV3((outer[j] - outer[i]).normalized.right, 0)
                quad(DV3(outer[i], z1 - bevel), DV3(outer[j], z1 - bevel), DV3(inner[j], z1), DV3(inner[i], z1), lid,
                     normal: (edgeOut + DV3.up).normalized)
            }
            polygon(inner, z: z1, lid)
            if bottom { polygon(outer, z: z0, s, facingUp: false) }
        } else {
            extrude(rect.corners, z0: z0, z1: z1, s, ao: ao)
            polygon(rect.corners, z: z1, lid)
            if bottom { polygon(rect.corners, z: z0, s, facingUp: false) }
        }
    }

    /// Thin box standing proud of a facade. `out` is the facade's outward normal.
    mutating func facadeBox(a: DV2, dir: DV2, out: DV2, u: Double, width: Double, z0: Double, z1: Double, depth: Double,
                            _ s: DioramaSwatch, dark: Bool = false, sides: Bool = true) {
        let l = a + dir * (u - width / 2), r = a + dir * (u + width / 2)
        let lf = l + out * depth, rf = r + out * depth
        quad(DV3(lf, z0), DV3(rf, z0), DV3(rf, z1), DV3(lf, z1), s, dark: dark, normal: DV3(out, 0))
        guard sides else { return }
        quad(DV3(l, z1), DV3(r, z1), DV3(rf, z1), DV3(lf, z1), s, dark: dark, normal: .up)
        quad(DV3(l, z0), DV3(r, z0), DV3(rf, z0), DV3(lf, z0), s, dark: true, normal: DV3(0, 0, -1))
        quad(DV3(l, z0), DV3(lf, z0), DV3(lf, z1), DV3(l, z1), s, dark: dark, normal: DV3(-dir, 0))
        quad(DV3(r, z0), DV3(rf, z0), DV3(rf, z1), DV3(r, z1), s, dark: dark, normal: DV3(dir, 0))
    }

    // MARK: Rounded primitives

    /// Tapered tube between two points with smooth radial normals; optional lid at the far end.
    mutating func tube(from p0: DV3, to p1: DV3, r0: Double, r1: Double, sides: Int, _ s: DioramaSwatch, cap: Bool = true, dark: Bool = false) {
        let axis = (p1 - p0).normalized
        let helper = abs(axis.z) < 0.9 ? DV3.up : DV3(1, 0, 0)
        let u = axis.cross(helper).normalized
        let v = axis.cross(u).normalized
        let count = max(sides, 3)
        reserve(count * 2 + (cap ? count + 1 : 0))
        let uv = DioramaAtlas.uv(s, dark: dark)
        let base = positions.count
        for k in 0..<count {
            let a = Double(k) / Double(count) * 2 * Double.pi
            let radial = u * cos(a) + v * sin(a)
            vertex(p0 + radial * r0, radial, uv)
            vertex(p1 + radial * r1, radial, uv)
        }
        // (u, v, axis) is right-handed, so increasing angle runs counter-clockwise about the axis and
        // (a0, b0, b1) faces outward by construction.
        for k in 0..<count {
            let j = (k + 1) % count
            let a0 = UInt32(base + k * 2), a1 = UInt32(base + k * 2 + 1)
            let b0 = UInt32(base + j * 2), b1 = UInt32(base + j * 2 + 1)
            face(a0, b0, b1)
            face(a0, b1, a1)
        }
        guard cap else { return }
        let centre = vertex(p1, axis, uv)
        let ringBase = positions.count
        for k in 0..<count {
            let a = Double(k) / Double(count) * 2 * Double.pi
            vertex(p1 + (u * cos(a) + v * sin(a)) * r1, axis, uv)
        }
        for k in 0..<count {
            face(centre, UInt32(ringBase + k), UInt32(ringBase + (k + 1) % count))
        }
    }

    /// Upright cylinder or cone.
    mutating func cylinder(centre: DV2, z0: Double, z1: Double, r0: Double, r1: Double, sides: Int, _ s: DioramaSwatch, cap: Bool = true) {
        tube(from: DV3(centre, z0), to: DV3(centre, z1), r0: r0, r1: r1, sides: sides, s, cap: cap)
    }

    /// Smooth ellipsoid: distant stand-ins use 20 faces (detail -1), small details 80, visible
    /// rounded forms 320.
    mutating func sphere(centre: DV3, radii: DV3, _ s: DioramaSwatch, detail: Int = 1) {
        let shape = detail >= 1 ? DioramaIcosphere.level2 : (detail == 0 ? DioramaIcosphere.level1 : DioramaIcosphere.level0)
        reserve(shape.vertices.count)
        let uv = DioramaAtlas.uv(s, dark: false)
        let base = positions.count
        for v in shape.vertices {
            let p = centre + DV3(v.x * radii.x, v.y * radii.y, v.z * radii.z)
            let n = DV3(v.x / max(radii.x, 1e-6), v.y / max(radii.y, 1e-6), v.z / max(radii.z, 1e-6)).normalized
            vertex(p, n, uv)
        }
        // Icosphere faces are counter-clockwise seen from outside; positive radii keep that.
        for f in shape.faces {
            face(UInt32(base) + f.x, UInt32(base) + f.y, UInt32(base) + f.z)
        }
    }

    /// Sculpted foliage mass: an icosphere whose vertices are pushed in and out by smooth seeded noise,
    /// so it reads as one moulded canopy rather than a pile of balls. The underside is flattened and
    /// uses `lower`, the sides `mid`, the sunlit crown `upper`; normals are recomputed from the displaced
    /// surface so the lumps shade softly.
    mutating func blob(centre: DV3, radii: DV3, seed: UInt64, amplitude: Double, frequency: Double,
                       lower: DioramaSwatch, mid: DioramaSwatch, upper: DioramaSwatch, flattenBottom: Double = 0.3, light: Bool = false) {
        // 320 smooth-shaded faces read as one moulded crown from the map camera; the distant
        // version keeps the silhouette with 80. Thousands of canopies are instanced per tile.
        let shape = light ? DioramaIcosphere.level1 : DioramaIcosphere.level2
        var rng = DioramaRandom(seed: seed, salt: 91)
        var waves: [(dir: DV3, freq: Double, phase: Double, amp: Double)] = []
        for k in 0..<5 {
            let dir = DV3(rng.range(-1...1), rng.range(-1...1), rng.range(-1...1)).normalized
            waves.append((dir, frequency * (1 + Double(k) * 0.55), rng.range(0...6.28), amplitude / (1 + Double(k) * 0.7)))
        }
        var points: [DV3] = []
        points.reserveCapacity(shape.vertices.count)
        for v in shape.vertices {
            var d = 0.0
            for w in waves { d += w.amp * sin(v.dot(w.dir) * w.freq + w.phase) }
            var r = 1 + d
            if v.z < 0 { r *= 1 - flattenBottom * (-v.z) }
            points.append(DV3(v.x * radii.x * r, v.y * radii.y * r, v.z * radii.z * r))
        }
        var accumulated = [DV3](repeating: DV3(0, 0, 0), count: points.count)
        for f in shape.faces {
            let a = points[Int(f.x)], b = points[Int(f.y)], c = points[Int(f.z)]
            let n = (b - a).cross(c - a)
            accumulated[Int(f.x)] = accumulated[Int(f.x)] + n
            accumulated[Int(f.y)] = accumulated[Int(f.y)] + n
            accumulated[Int(f.z)] = accumulated[Int(f.z)] + n
        }
        reserve(points.count)
        let base = positions.count
        for i in 0..<points.count {
            let z = shape.vertices[i].z
            let swatch = z > 0.42 ? upper : (z < -0.28 ? lower : mid)
            vertex(centre + points[i], accumulated[i].normalized, DioramaAtlas.uv(swatch, dark: false))
        }
        // Displacement is far below the radius, so the icosphere's outward winding survives.
        for f in shape.faces {
            face(UInt32(base) + f.x, UInt32(base) + f.y, UInt32(base) + f.z)
        }
    }

    /// Bakes a copy of a small prototype mesh (a tree, a bajaji, a lamp) into this mesh.
    mutating func append(_ other: DioramaMesh, _ t: DioramaTransform) {
        guard !other.isEmpty else { return }
        reserve(other.positions.count)
        let base = UInt32(positions.count)
        let c = cos(t.rotation), s = sin(t.rotation)
        for i in 0..<other.positions.count {
            let p = other.positions[i]
            let x = p.x * t.scale.x, y = p.y * t.scale.y
            positions.append(DV3(x * c - y * s + t.translation.x, x * s + y * c + t.translation.y, p.z * t.scale.z + t.translation.z + baseZ))
            let n = other.normals[i]
            let nx = n.x / t.scale.x, ny = n.y / t.scale.y
            normals.append(DV3(nx * c - ny * s, nx * s + ny * c, n.z / t.scale.z).normalized)
            uvs.append(other.uvs[i])
            attributes.append(other.attributes[i])
            tints.append(i < other.tints.count ? other.tints[i] * tint : tint)
        }
        indices.append(contentsOf: other.indices.map { $0 + base })
        doubleSidedTriangles.append(contentsOf: other.doubleSidedTriangles)
        for placement in other.instances {
            // Compose the nested placement with this append's transform.
            let inner = placement.transform
            let x = inner.translation.x * t.scale.x, y = inner.translation.y * t.scale.y
            let composed = DioramaTransform(
                rotation: inner.rotation + t.rotation,
                scale: DV3(inner.scale.x * t.scale.x, inner.scale.y * t.scale.y, inner.scale.z * t.scale.z),
                translation: DV3(x * c - y * s + t.translation.x, x * s + y * c + t.translation.y, inner.translation.z * t.scale.z + t.translation.z + baseZ))
            instances.append(DioramaInstancePlacement(prototype: placement.prototype, transform: composed))
        }
    }
}

/// Unit icospheres, built once.
nonisolated enum DioramaIcosphere {
    nonisolated struct Shape: Sendable {
        let vertices: [DV3]
        let faces: [SIMD3<UInt32>]
    }

    static let level0: Shape = make(subdivisions: 0)
    static let level1: Shape = make(subdivisions: 1)
    static let level2: Shape = make(subdivisions: 2)
    /// 642-vertex surface for close-up hero shapes; canopies use level 2 since they are instanced by the thousand.
    static let level3: Shape = make(subdivisions: 3)

    private static func make(subdivisions: Int) -> Shape {
        let t = (1 + 5.0.squareRoot()) / 2
        var vertices: [DV3] = [
            DV3(-1, t, 0), DV3(1, t, 0), DV3(-1, -t, 0), DV3(1, -t, 0),
            DV3(0, -1, t), DV3(0, 1, t), DV3(0, -1, -t), DV3(0, 1, -t),
            DV3(t, 0, -1), DV3(t, 0, 1), DV3(-t, 0, -1), DV3(-t, 0, 1),
        ].map(\.normalized)
        var faces: [SIMD3<UInt32>] = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
            [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
            [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
            [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
        ]
        for _ in 0..<subdivisions {
            var cache: [UInt64: UInt32] = [:]
            func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let found = cache[key] { return found }
                let m = ((vertices[Int(a)] + vertices[Int(b)]) * 0.5).normalized
                vertices.append(m)
                let index = UInt32(vertices.count - 1)
                cache[key] = index
                return index
            }
            var next: [SIMD3<UInt32>] = []
            for f in faces {
                let ab = midpoint(f.x, f.y), bc = midpoint(f.y, f.z), ca = midpoint(f.z, f.x)
                next.append([f.x, ab, ca])
                next.append([f.y, bc, ab])
                next.append([f.z, ca, bc])
                next.append([ab, bc, ca])
            }
            faces = next
        }
        return Shape(vertices: vertices, faces: faces)
    }
}

extension DioramaPolygon {
    /// Cuts every corner of a convex ring (used for bevelled boxes). Keeps counter-clockwise order.
    nonisolated static func chamferedCorners(_ corners: [DV2], by b: Double) -> [DV2] {
        var out: [DV2] = []
        let n = corners.count
        for i in 0..<n {
            let c = corners[i], prev = corners[(i + n - 1) % n], next = corners[(i + 1) % n]
            out.append(c + (prev - c).normalized * b)
            out.append(c + (next - c).normalized * b)
        }
        return out
    }

    /// Rounds convex corners of a footprint with a short arc (the "Apple Maps toy" silhouette). Corners
    /// next to clipped tile-edge edges are left alone. Edge flags follow the same convention as `chamfer`.
    nonisolated static func rounded(_ ring: [DV2], flags: [Bool], radius r: Double, segments: Int = 4) -> (points: [DV2], flags: [Bool]) {
        let n = ring.count
        guard n >= 3, r > 0, flags.count == n else { return (ring, flags) }
        var points: [DV2] = []
        var outFlags: [Bool] = []
        points.reserveCapacity(n * (segments + 1))
        for i in 0..<n {
            let c = ring[i], prev = ring[(i + n - 1) % n], next = ring[(i + 1) % n]
            let inEdge = c - prev, outEdge = next - c
            let convex = inEdge.cross(outEdge) > 0
            let fp = flags[(i + n - 1) % n], fn = flags[i]
            let reach = min(r, inEdge.length * 0.3, outEdge.length * 0.3)
            if convex, !fp, !fn, reach > 0.05 {
                let a = c - inEdge.normalized * reach
                let b = c + outEdge.normalized * reach
                let steps = max(segments, 1)
                for k in 0...steps {
                    let t = Double(k) / Double(steps)
                    // Quadratic Bézier through the corner reads as a fillet at this scale.
                    let p = a * ((1 - t) * (1 - t)) + c * (2 * (1 - t) * t) + b * (t * t)
                    points.append(p)
                    outFlags.append(k == steps ? fn : false)
                }
            } else {
                points.append(c)
                outFlags.append(fn)
            }
        }
        return (points, outFlags)
    }

    /// Inserts points so no segment of the polyline is longer than `maxStep`; lets ribbons follow terrain.
    nonisolated static func densify(_ line: [DV2], maxStep: Double) -> [DV2] {
        guard line.count >= 2, maxStep > 0.1 else { return line }
        var out: [DV2] = [line[0]]
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let steps = max(Int((a.distance(to: b) / maxStep).rounded(.up)), 1)
            for s in 1...steps { out.append(a + (b - a) * (Double(s) / Double(steps))) }
        }
        return out
    }

    /// Softens convex corners of a footprint. Corners next to clipped tile-edge edges are left alone.
    nonisolated static func chamfer(_ ring: [DV2], flags: [Bool], by b: Double) -> (points: [DV2], flags: [Bool]) {
        let n = ring.count
        guard n >= 3, b > 0 else { return (ring, flags) }
        var points: [DV2] = []
        var outFlags: [Bool] = []
        for i in 0..<n {
            let c = ring[i], prev = ring[(i + n - 1) % n], next = ring[(i + 1) % n]
            let inEdge = c - prev, outEdge = next - c
            let convex = inEdge.cross(outEdge) > 0
            let fp = flags[(i + n - 1) % n], fn = flags[i]
            if convex, !fp, !fn, inEdge.length > b * 3, outEdge.length > b * 3 {
                points.append(c - inEdge.normalized * b)
                outFlags.append(false)
                points.append(c + outEdge.normalized * b)
                outFlags.append(fn)
            } else {
                points.append(c)
                outFlags.append(fn)
            }
        }
        return (points, outFlags)
    }
}
