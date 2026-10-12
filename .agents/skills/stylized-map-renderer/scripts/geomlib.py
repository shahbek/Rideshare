"""Shared geometry helpers for the stylized-map-renderer scripts.

Internal convention: Z-up, footprints in the XY plane, rings with material on the LEFT
(exterior CCW, holes CW), outward normal = right side = (dy, -dx).
Export convention: glTF Y-up via (x, y, z) -> (x, z, -y), a proper rotation (winding preserved).
"""
import math
import struct

import numpy as np
import mapbox_earcut as earcut
import trimesh
from shapely.geometry import Polygon, MultiPolygon
from shapely.geometry.polygon import orient


def hex_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


def to_gltf(v):
    v = np.asarray(v, dtype=np.float64)
    return np.stack([v[..., 0], v[..., 2], -v[..., 1]], axis=-1)


# ---------------------------------------------------------------- mesh builder
class MeshBuilder:
    """Accumulates vertices with all attributes needed by the Metal shell format."""

    def __init__(self):
        self.P, self.N, self.C, self.AO = [], [], [], []
        self.FLAGS, self.BEV, self.NL, self.NR, self.PAL = [], [], [], [], []
        self.T = []  # gradient / misc scalar (trees)
        self.tris = []

    def v(self, p, n, color, ao=1.0, flags=0, bevel=(0.0, 0.0, 1000.0, 0.0),
          nl=None, nr=None, pal=0, t=0.0):
        n = np.asarray(n, float)
        n = n / (np.linalg.norm(n) + 1e-12)
        self.P.append(np.asarray(p, float))
        self.N.append(n)
        self.C.append(np.asarray(color, float))
        self.AO.append(float(ao))
        self.FLAGS.append(int(flags))
        self.BEV.append(tuple(float(b) for b in bevel))
        self.NL.append(n if nl is None else np.asarray(nl, float))
        self.NR.append(n if nr is None else np.asarray(nr, float))
        self.PAL.append(int(pal))
        self.T.append(float(t))
        return len(self.P) - 1

    def tri(self, a, b, c):
        self.tris.append((a, b, c))

    def quad(self, a, b, c, d):
        self.tris.append((a, b, c))
        self.tris.append((a, c, d))

    def append(self, other, transform=None, normal_transform=None):
        base = len(self.P)
        for i in range(len(other.P)):
            p, n = other.P[i], other.N[i]
            if transform is not None:
                p = transform(p)
                n = normal_transform(n)
            self.P.append(p)
            self.N.append(n)
            self.C.append(other.C[i])
            self.AO.append(other.AO[i])
            self.FLAGS.append(other.FLAGS[i])
            self.BEV.append(other.BEV[i])
            self.NL.append(other.NL[i] if transform is None else normal_transform(other.NL[i]))
            self.NR.append(other.NR[i] if transform is None else normal_transform(other.NR[i]))
            self.PAL.append(other.PAL[i])
            self.T.append(other.T[i])
        self.tris.extend((a + base, b + base, c + base) for a, b, c in other.tris)

    @property
    def tri_count(self):
        return len(self.tris)

    def to_trimesh(self, zup_input=True, bake_ao=True):
        P = np.array(self.P) if self.P else np.zeros((0, 3))
        N = np.array(self.N) if self.N else np.zeros((0, 3))
        if zup_input:
            P, N = to_gltf(P), to_gltf(N)
        col = np.array(self.C) if self.C else np.zeros((0, 3))
        if bake_ao:
            col = col * np.array(self.AO)[:, None]
        rgba = np.concatenate([np.clip(col, 0, 1), np.ones((len(col), 1))], axis=1)
        m = trimesh.Trimesh(vertices=P, faces=np.array(self.tris, dtype=np.int64),
                            vertex_normals=N, vertex_colors=(rgba * 255).astype(np.uint8),
                            process=False)
        return m


def export_glb(builder_or_meshes, path, zup_input=True):
    meshes = builder_or_meshes if isinstance(builder_or_meshes, list) else [builder_or_meshes]
    scene = trimesh.Scene()
    for i, b in enumerate(meshes):
        m = b.to_trimesh(zup_input=zup_input) if isinstance(b, MeshBuilder) else b
        scene.add_geometry(m, geom_name=f"mesh_{i}")
    data = trimesh.exchange.gltf.export_glb(scene, include_normals=True)
    with open(path, "wb") as f:
        f.write(data)


# ---------------------------------------------------------------- runtime format
def oct_encode(n):
    n = np.asarray(n, float)
    n = n / (np.abs(n).sum(axis=1, keepdims=True) + 1e-12)
    e = n[:, :2].copy()
    neg = n[:, 2] < 0
    if neg.any():
        xy = n[neg][:, :2]
        sgn = np.where(xy >= 0, 1.0, -1.0)
        e[neg] = (1.0 - np.abs(xy[:, ::-1])) * sgn
    return e


def write_runtime_bin(builder, path, zup_input=True):
    """Writes the 28-byte shell vertex layout from references/metal-renderer.md §2.

    File: 'SMB1' | u32 vcount | u32 icount | float3 origin | float halfExtent | vertices | u32 indices
    """
    P = np.array(builder.P)
    N = np.array(builder.N)
    NL = np.array(builder.NL)
    NR = np.array(builder.NR)
    if zup_input:
        P, N, NL, NR = to_gltf(P), to_gltf(N), to_gltf(NL), to_gltf(NR)
    origin = (P.min(0) + P.max(0)) / 2
    half = float(np.abs(P - origin).max()) or 1.0
    dt = np.dtype([("pos", "<i2", 4), ("nrm", "i1", 4), ("info", "u1", 4),
                   ("bev", "<f2", 4), ("nbr", "i1", 4)])
    assert dt.itemsize == 28
    arr = np.zeros(len(P), dtype=dt)
    arr["pos"][:, :3] = np.round((P - origin) / half * 32767).astype(np.int16)
    arr["nrm"][:, :2] = np.round(oct_encode(N) * 127).astype(np.int8)
    arr["info"][:, 0] = np.array(builder.PAL, dtype=np.uint8)
    arr["info"][:, 1] = np.round(np.clip(builder.AO, 0, 1) * 255).astype(np.uint8)
    arr["info"][:, 2] = np.array(builder.FLAGS, dtype=np.uint8)
    arr["bev"] = np.array(builder.BEV, dtype=np.float16)
    arr["nbr"][:, :2] = np.round(oct_encode(NL) * 127).astype(np.int8)
    arr["nbr"][:, 2:] = np.round(oct_encode(NR) * 127).astype(np.int8)
    idx = np.array(builder.tris, dtype=np.uint32).ravel()
    with open(path, "wb") as f:
        f.write(b"SMB1")
        f.write(struct.pack("<II", len(P), len(idx)))
        f.write(struct.pack("<3ff", *origin.tolist(), half))
        f.write(arr.tobytes())
        f.write(idx.tobytes())
    return len(P) * 28 + len(idx) * 4 + 28


# ---------------------------------------------------------------- polygons
def clean_polygon(poly, simplify=0.05):
    poly = poly.buffer(0)
    if isinstance(poly, MultiPolygon):
        poly = max(poly.geoms, key=lambda g: g.area)
    poly = poly.simplify(simplify, preserve_topology=True)
    return orient(poly, sign=1.0)


def round_corners(poly, radius, quad_segs=2):
    """Rounds convex corners (radius r, quad_segs segments per 90 deg); concave stay sharp."""
    if radius <= 0:
        return poly
    shrunk = poly.buffer(-radius, join_style="mitre")
    if shrunk.is_empty or shrunk.area < 0.2 * poly.area:
        return poly
    out = shrunk.buffer(radius, join_style="round", quad_segs=quad_segs)
    if isinstance(out, MultiPolygon):
        out = max(out.geoms, key=lambda g: g.area)
    return orient(out, sign=1.0)


def rings_of(poly):
    """Returns list of (Nx2 array, is_hole), exterior CCW, holes CW, closing point removed."""
    poly = orient(poly, sign=1.0)
    out = [(np.array(poly.exterior.coords)[:-1], False)]
    for r in poly.interiors:
        out.append((np.array(r.coords)[:-1], True))
    return out


def edge_normals(ring):
    d = np.roll(ring, -1, axis=0) - ring
    L = np.linalg.norm(d, axis=1, keepdims=True) + 1e-12
    t = d / L
    return np.stack([t[:, 1], -t[:, 0]], axis=1), t, L[:, 0]


def ring_vertex_info(ring, smooth_angle_deg=50.0):
    """Per vertex: smooth flag (soft turn, e.g. rounded arc) and concave flag."""
    en, t, L = edge_normals(ring)
    t_in = np.roll(t, 1, axis=0)
    cos = np.clip((t_in * t).sum(1), -1, 1)
    ang = np.degrees(np.arccos(cos))
    cross = t_in[:, 0] * t[:, 1] - t_in[:, 1] * t[:, 0]
    smooth = ang < smooth_angle_deg
    concave = cross < -1e-9   # material on the left: right turn = reflex corner
    return smooth, concave, en, t, L


def earcut_polygon(poly):
    """Triangulates a shapely polygon (with holes). Returns (Nx2 verts, Mx3 tris) facing +Z."""
    poly = orient(poly, sign=1.0)
    rings = [np.array(poly.exterior.coords)[:-1]] + [np.array(r.coords)[:-1] for r in poly.interiors
                                                     if len(r.coords) >= 4]
    verts = np.concatenate(rings, axis=0).astype(np.float64)
    ends = np.cumsum([len(r) for r in rings]).astype(np.uint32)
    idx = earcut.triangulate_float64(verts, ends).reshape(-1, 3)
    fixed = []
    for a, b, c in idx:
        ab, ac = verts[b] - verts[a], verts[c] - verts[a]
        fixed.append((a, b, c) if ab[0] * ac[1] - ab[1] * ac[0] >= 0 else (a, c, b))
    return verts, np.array(fixed, dtype=np.int64)


# ---------------------------------------------------------------- profiles & sweeps
def profile_normals(profile):
    """2D normals (nx, ny) for profile points, right side of traversal, smooth-averaged."""
    p = np.asarray(profile, float)
    seg = np.diff(p, axis=0)
    sn = np.stack([seg[:, 1], -seg[:, 0]], axis=1)
    sn /= np.linalg.norm(sn, axis=1, keepdims=True) + 1e-12
    n = np.zeros_like(p)
    n[0], n[-1] = sn[0], sn[-1]
    for k in range(1, len(p) - 1):
        m = sn[k - 1] + sn[k]
        n[k] = m / (np.linalg.norm(m) + 1e-12)
    return n


def ring_analysis(ring, smooth_angle_deg=50.0):
    """Classifies a ring for shading.

    smooth[v]   : soft turn at vertex v (rounded arc or gentle bend)
    concave[v]  : reflex corner w.r.t. the material
    straight[e] : edge e is a real wall segment (not an arc chord)
    vn[v]       : shading normal at a smooth vertex. At an arc/straight junction this is the
                  straight edge's normal (= the exact circle normal at the tangent point), so long
                  walls never get a normal gradient smeared across them.
    """
    smooth, concave, en, t, L = ring_vertex_info(ring, smooth_angle_deg)
    n = len(ring)
    nxt_smooth = np.roll(smooth, -1)
    straight = ~(smooth & nxt_smooth) | (L > 1.8 * np.roll(L, 1)) | (L > 1.8 * np.roll(L, -1))
    vn = np.zeros((n, 2))
    for i in range(n):
        ep, ec = (i - 1) % n, i
        if straight[ep] and not straight[ec]:
            vn[i] = en[ep]
        elif straight[ec] and not straight[ep]:
            vn[i] = en[ec]
        else:
            m = en[ep] + en[ec]
            vn[i] = m / (np.linalg.norm(m) + 1e-12)
    return dict(smooth=smooth, concave=concave, en=en, t=t, L=L, straight=straight, vn=vn)


def sweep(builder, ring, profile, z0, color, ao_fn=None, pal=0, support=0.3):
    """Sweeps a 2D profile [(offset_out, height), ...] along a closed ring at base height z0.

    Profiles are traversed so the visible surface is on the right (outer face going up).
    - Smooth vertices (arcs): shared vertices, exact arc normals -> perfectly round.
    - Hard corners: the corner gets the bisector normal and two 'support' points are inserted
      `support` metres away carrying the plain edge normals. The rounded shading is confined to
      a 2*support strip at the corner (cost: +2 ring points per hard corner).
    """
    ring = np.asarray(ring, float)
    prof = np.asarray(profile, float)
    pn = profile_normals(prof)
    A = ring_analysis(ring)
    en, t, L, smooth = A["en"], A["t"], A["L"], A["smooth"]
    n = len(ring)
    pts = []   # (xy, displacement_dir, shading_normal_2d)
    for i in range(n):
        ep = (i - 1) % n
        miter = en[ep] + en[i]
        miter /= np.linalg.norm(miter) + 1e-12
        sc = 1.0 / max(float(miter @ en[i]), 0.35)
        if smooth[i]:
            pts.append((ring[i], miter * sc, A["vn"][i]))
        else:
            d_in = min(support, L[ep] / 3.0)
            d_out = min(support, L[i] / 3.0)
            if support > 0:
                pts.append((ring[i] - t[ep] * d_in, en[ep], en[ep]))
            pts.append((ring[i], miter * sc, miter))
            if support > 0:
                pts.append((ring[i] + t[i] * d_out, en[i], en[i]))
    m = len(pts)
    ids = np.zeros((m, len(prof)), dtype=np.int64)
    for i, (xy, disp, sn) in enumerate(pts):
        for k in range(len(prof)):
            o, y = prof[k]
            p = xy + disp * o
            nrm = np.array([sn[0] * pn[k, 0], sn[1] * pn[k, 0], pn[k, 1]])
            ao = ao_fn(k, prof[k], pn[k]) if ao_fn else 1.0
            ids[i, k] = builder.v((p[0], p[1], z0 + y), nrm, color, ao=ao, pal=pal)
    for i in range(m):
        j = (i + 1) % m
        for k in range(len(prof) - 1):
            builder.quad(ids[i, k], ids[j, k], ids[j, k + 1], ids[i, k + 1])
    return ids


def lathe(builder, profile, sections, color_fn, center=(0, 0, 0), pal=0, t_fn=None,
          a0=0.0, a1=2 * math.pi, ao_fn=None):
    """Revolves [(r, z), ...] (bottom to top) around Z with smooth normals.
    a0..a1 restricts the sweep angle (half domes, apses); a full turn is closed."""
    prof = np.asarray(profile, float)
    pn = profile_normals(prof)
    cx, cy, cz = center
    closed = abs((a1 - a0) - 2 * math.pi) < 1e-6
    cols = sections if closed else sections + 1
    ids = np.zeros((cols, len(prof)), dtype=np.int64)
    for s in range(cols):
        a = a0 + (a1 - a0) * s / sections
        ca, sa = math.cos(a), math.sin(a)
        for k, (r, z) in enumerate(prof):
            p = (cx + ca * r, cy + sa * r, cz + z)
            n = (ca * pn[k, 0], sa * pn[k, 0], pn[k, 1])
            t = t_fn(z) if t_fn else 0.0
            ao = ao_fn(z) if ao_fn else 1.0
            ids[s, k] = builder.v(p, n, color_fn(z), pal=pal, t=t, ao=ao)
    for s in range(sections):
        s2 = (s + 1) % cols
        for k in range(len(prof) - 1):
            builder.quad(ids[s, k], ids[s2, k], ids[s2, k + 1], ids[s, k + 1])
    return ids


def flat_poly(builder, poly, z, normal_up=True, color=(0.8, 0.8, 0.8), ao=1.0, pal=0, ao_fn=None):
    """Earcut a shapely polygon into a horizontal face at height z (up or down facing)."""
    verts, tris = earcut_polygon(poly)
    n = (0, 0, 1) if normal_up else (0, 0, -1)
    ids = [builder.v((x, y, z), n, color, ao=(ao_fn(x, y) if ao_fn else ao), pal=pal) for x, y in verts]
    for a, b, c in tris:
        if normal_up:
            builder.tri(ids[a], ids[b], ids[c])
        else:
            builder.tri(ids[a], ids[c], ids[b])


def prism(builder, poly, z0, z1, color, top=True, bottom=False, ao_bottom=1.0, top_color=None, pal=0):
    """Extruded shapely polygon (holes ok): walls with exact arc normals + optional caps."""
    for ring, _ in rings_of(poly):
        A = ring_analysis(ring)
        en, vn, smooth = A["en"], A["vn"], A["smooth"]
        n = len(ring)
        for i in range(n):
            j = (i + 1) % n
            na = vn[i] if smooth[i] else en[i]
            nb = vn[j] if smooth[j] else en[i]
            a0 = builder.v((*ring[i], z0), (*na, 0), color, ao=ao_bottom, pal=pal)
            b0 = builder.v((*ring[j], z0), (*nb, 0), color, ao=ao_bottom, pal=pal)
            b1 = builder.v((*ring[j], z1), (*nb, 0), color, pal=pal)
            a1 = builder.v((*ring[i], z1), (*na, 0), color, pal=pal)
            builder.quad(a0, b0, b1, a1)
    if top:
        flat_poly(builder, poly, z1, True, top_color if top_color is not None else color, pal=pal)
    if bottom:
        flat_poly(builder, poly, z0, False, color, pal=pal)


def box(builder, x0, x1, y0, y1, z0, z1, color, faces="all", ao_bottom=1.0):
    """Axis-aligned box in the builder's own frame. faces: 'all' or a string of +x-x+y-y+z-z keys."""
    from shapely.geometry import box as sbox
    want = faces
    P = sbox(x0, y0, x1, y1)
    if want == "all":
        prism(builder, P, z0, z1, color, top=True, bottom=False, ao_bottom=ao_bottom)
        return
    quads = {
        "+x": ([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], (1, 0, 0)),
        "-x": ([(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], (-1, 0, 0)),
        "+y": ([(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)], (0, 1, 0)),
        "-y": ([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], (0, -1, 0)),
        "+z": ([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (0, 0, 1)),
        "-z": ([(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)], (0, 0, -1)),
    }
    for key in ("+x", "-x", "+y", "-y", "+z", "-z"):
        if key in want:
            pts, n = quads[key]
            ids = [builder.v(p, n, color, ao=(ao_bottom if p[2] == z0 else 1.0)) for p in pts]
            builder.quad(*ids)


def panel(builder, origin, u_dir, n_dir, shape_uv, thickness, color, z_base=0.0, holes=(), back=True):
    """Extrudes a 2D shape drawn in a wall plane.

    origin: 2D point on the wall line, u_dir: 2D unit vector along the wall, n_dir: 2D outward
    normal. shape_uv: [(u, v)] with v = height above z_base. The panel spans 0..thickness
    outward (front face at +thickness). Used for pediments, mission/Dutch gables, stepped parapets.
    """
    from shapely.geometry import Polygon as SPoly
    o = np.asarray(origin, float); u = np.asarray(u_dir, float); nn = np.asarray(n_dir, float)

    def W(uv, off):
        xy = o + u * uv[0] + nn * off
        return (xy[0], xy[1], z_base + uv[1])
    poly = orient(SPoly(shape_uv, [list(h) for h in holes]), 1.0)
    verts, tris = earcut_polygon(poly)
    nf = (nn[0], nn[1], 0.0)
    front = [builder.v(W(p, thickness), nf, color) for p in verts]
    # in (u, v) space CCW faces the viewer looking from +n when u x v points along +n
    flip = (u[0] * nn[1] - u[1] * nn[0]) > 0
    for a, b, c in tris:
        builder.tri(front[a], front[c], front[b]) if flip else builder.tri(front[a], front[b], front[c])
    if back:
        nb = (-nn[0], -nn[1], 0.0)
        bk = [builder.v(W(p, 0.0), nb, color) for p in verts]
        for a, b, c in tris:
            builder.tri(bk[a], bk[b], bk[c]) if flip else builder.tri(bk[a], bk[c], bk[b])
    # sides
    for ring, _ in rings_of(poly):
        m = len(ring)
        for i in range(m):
            p, q = ring[i], ring[(i + 1) % m]
            d = q - p
            L = np.linalg.norm(d)
            if L < 1e-6:
                continue
            side2 = np.array([d[1], -d[0]]) / L          # outward in (u, v)
            sn = u * side2[0]
            sn3 = (sn[0], sn[1], side2[1])
            ids = [builder.v(W(p, 0.0), sn3, color), builder.v(W(q, 0.0), sn3, color),
                   builder.v(W(q, thickness), sn3, color), builder.v(W(p, thickness), sn3, color)]
            if flip:
                builder.quad(ids[0], ids[3], ids[2], ids[1])
            else:
                builder.quad(ids[0], ids[1], ids[2], ids[3])
    return poly


def wall_strip(builder, p0, p1, n2, z0, z1, color, offset=0.03):
    """A flat quad floating `offset` in front of a wall (half-timbering, glass bands, decals)."""
    p0 = np.asarray(p0, float) + np.asarray(n2) * offset
    p1 = np.asarray(p1, float) + np.asarray(n2) * offset
    n3 = (n2[0], n2[1], 0.0)
    ids = [builder.v((*p0, z0), n3, color), builder.v((*p1, z0), n3, color),
           builder.v((*p1, z1), n3, color), builder.v((*p0, z1), n3, color)]
    builder.quad(*ids)


def wall_quad(builder, a, b, c, d, color, offset_n=None):
    """Arbitrary planar quad (3D points, CCW seen from the visible side)."""
    a, b, c, d = (np.asarray(x, float) for x in (a, b, c, d))
    n = np.cross(b - a, d - a)
    ids = [builder.v(x, n, color) for x in (a, b, c, d)]
    builder.quad(*ids)
