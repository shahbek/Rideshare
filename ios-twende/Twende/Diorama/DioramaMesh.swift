import Foundation

/// Rotation about the vertical axis, per-axis scale, then translation.
nonisolated struct DioramaTransform: Sendable {
    var rotation: Double = 0
    var scale: DV3 = DV3(1, 1, 1)
    var translation: DV3 = DV3(0, 0, 0)
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
    private(set) var indices: [UInt32] = []
    private(set) var chunks: [Chunk] = [Chunk(vertex: 0, index: 0)]

    var isEmpty: Bool { indices.isEmpty }
    var triangleCount: Int { indices.count / 3 }

    /// Starts a new 16-bit chunk when the next shape would overflow the current one.
    mutating func reserve(_ count: Int) {
        let base = chunks[chunks.count - 1].vertex
        if positions.count > base, positions.count - base + count > Self.maxChunkVertices {
            chunks.append(Chunk(vertex: positions.count, index: indices.count))
        }
    }

    @discardableResult
    mutating func vertex(_ p: DV3, _ n: DV3, _ uv: SIMD2<Float>) -> UInt32 {
        positions.append(p)
        normals.append(n)
        uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    mutating func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let face = (pb - pa).cross(pc - pa)
        let n = normals[Int(a)] + normals[Int(b)] + normals[Int(c)]
        if face.dot(n) < 0 {
            indices.append(contentsOf: [a, c, b])
        } else {
            indices.append(contentsOf: [a, b, c])
        }
    }

    // MARK: Flat primitives

    mutating func triangle(_ a: DV3, _ b: DV3, _ c: DV3, _ s: DioramaSwatch, dark: Bool = false, normal: DV3? = nil) {
        let n = normal ?? (b - a).cross(c - a).normalized
        reserve(3)
        let uv = DioramaAtlas.uv(s, dark: dark)
        let i0 = vertex(a, n, uv), i1 = vertex(b, n, uv), i2 = vertex(c, n, uv)
        tri(i0, i1, i2)
    }

    mutating func quad(_ a: DV3, _ b: DV3, _ c: DV3, _ d: DV3, _ s: DioramaSwatch, dark: Bool = false, normal: DV3? = nil) {
        var n = normal ?? (b - a).cross(d - a).normalized
        if normal == nil, (b - a).cross(d - a).length < 1e-9 { n = (c - a).cross(d - b).normalized }
        reserve(4)
        let uv = DioramaAtlas.uv(s, dark: dark)
        let i0 = vertex(a, n, uv), i1 = vertex(b, n, uv), i2 = vertex(c, n, uv), i3 = vertex(d, n, uv)
        tri(i0, i1, i2)
        tri(i0, i2, i3)
    }

    /// Flat horizontal polygon.
    mutating func polygon(_ ring: [DV2], z: Double, _ s: DioramaSwatch, dark: Bool = false, facingUp: Bool = true) {
        let ccw = DioramaPolygon.counterClockwise(ring)
        guard ccw.count >= 3 else { return }
        reserve(ccw.count)
        let n = DV3(0, 0, facingUp ? 1 : -1)
        let uv = DioramaAtlas.uv(s, dark: dark)
        let base = positions.count
        for p in ccw { vertex(DV3(p, z), n, uv) }
        for (a, b, c) in DioramaPolygon.triangulate(ccw) {
            tri(UInt32(base + a), UInt32(base + b), UInt32(base + c))
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

    /// Walls of a counter-clockwise ring, optionally skipping flagged edges, with an optional lid.
    mutating func extrude(_ ring: [DV2], z0: Double, z1: Double, _ s: DioramaSwatch, ao: Double = 0, skip: [Bool]? = nil, top: DioramaSwatch? = nil) {
        let n = ring.count
        guard n >= 3 else { return }
        for i in 0..<n where !(skip?[i] ?? false) {
            wall(ring[i], ring[(i + 1) % n], z0: z0, z1: z1, s, ao: ao)
        }
        if let top { polygon(ring, z: z1, top) }
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
        for k in 0..<count {
            let j = (k + 1) % count
            let a0 = UInt32(base + k * 2), a1 = UInt32(base + k * 2 + 1)
            let b0 = UInt32(base + j * 2), b1 = UInt32(base + j * 2 + 1)
            tri(a0, b0, b1)
            tri(a0, b1, a1)
        }
        guard cap else { return }
        let centre = vertex(p1, axis, uv)
        let ringBase = positions.count
        for k in 0..<count {
            let a = Double(k) / Double(count) * 2 * Double.pi
            vertex(p1 + (u * cos(a) + v * sin(a)) * r1, axis, uv)
        }
        for k in 0..<count {
            tri(centre, UInt32(ringBase + k), UInt32(ringBase + (k + 1) % count))
        }
    }

    /// Upright cylinder or cone.
    mutating func cylinder(centre: DV2, z0: Double, z1: Double, r0: Double, r1: Double, sides: Int, _ s: DioramaSwatch, cap: Bool = true) {
        tube(from: DV3(centre, z0), to: DV3(centre, z1), r0: r0, r1: r1, sides: sides, s, cap: cap)
    }

    /// Blobby ellipsoid built from an icosphere (detail 0: 20 triangles, 1: 80 triangles).
    mutating func sphere(centre: DV3, radii: DV3, _ s: DioramaSwatch, detail: Int = 1) {
        let shape = detail >= 1 ? DioramaIcosphere.level1 : DioramaIcosphere.level0
        reserve(shape.vertices.count)
        let uv = DioramaAtlas.uv(s, dark: false)
        let base = positions.count
        for v in shape.vertices {
            let p = centre + DV3(v.x * radii.x, v.y * radii.y, v.z * radii.z)
            let n = DV3(v.x / max(radii.x, 1e-6), v.y / max(radii.y, 1e-6), v.z / max(radii.z, 1e-6)).normalized
            vertex(p, n, uv)
        }
        for f in shape.faces {
            tri(UInt32(base) + f.x, UInt32(base) + f.y, UInt32(base) + f.z)
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
            positions.append(DV3(x * c - y * s + t.translation.x, x * s + y * c + t.translation.y, p.z * t.scale.z + t.translation.z))
            let n = other.normals[i]
            let nx = n.x / t.scale.x, ny = n.y / t.scale.y
            normals.append(DV3(nx * c - ny * s, nx * s + ny * c, n.z / t.scale.z).normalized)
            uvs.append(other.uvs[i])
        }
        indices.append(contentsOf: other.indices.map { $0 + base })
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
