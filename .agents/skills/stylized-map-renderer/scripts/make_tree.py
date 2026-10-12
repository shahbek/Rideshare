#!/usr/bin/env python3
"""Generates stylized library trees for instancing (puffball broadleaf, layered conifer, cypress).

Usage:
  python make_tree.py --kind puff --lod 0 --out puff_lod0.glb [--seed 3] [--palette blossom]
  python make_tree.py --all --outdir trees/           # every kind x LOD0/LOD1 + a contact sheet list

Techniques (see references/style-spec.md §3):
  - canopy = cluster of icospheres; faces buried inside neighbouring blobs are removed
  - CANOPY NORMALS: normals blended toward (p - canopy_centre) -> soft cloud shading, no facets
  - height gradient (dark bottom -> bright top) in vertex colour; t stored for the shader
  - trunk = tapered 6-sided tubes, Y-forked, no caps (hidden in canopy / ground)
Output is glTF Y-up, origin at the trunk base, unit = metres, ~6-9 m tall before instance scale.
"""
import argparse
import math
import os
import sys

import numpy as np
import trimesh

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geomlib import MeshBuilder, export_glb, hex_rgb, lathe

PALETTES = {
    "green":   ("#5F8A2A", "#B9D64A"),
    "olive":   ("#4F6B2E", "#9DB45A"),
    "blossom": ("#D98AAE", "#FFD0E2"),
    "conifer": ("#244A33", "#4E7A4A"),
    "cypress": ("#2B4A2A", "#6B8A3E"),
    "palm":    ("#4F7A2A", "#93B83E"),
}
TRUNK = hex_rgb("#8A5A3C")


def ramp(bottom, top, t):
    t = np.clip(t, 0, 1)
    t = t * t * (3 - 2 * t)
    return bottom + (top - bottom) * t


def tube(b, p0, p1, r0, r1, sections=6):
    """Tapered open tube with smooth radial normals (Z-up)."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    axis = p1 - p0
    L = np.linalg.norm(axis)
    w = axis / L
    a = np.array([1.0, 0, 0]) if abs(w[0]) < 0.9 else np.array([0, 1.0, 0])
    u = np.cross(w, a); u /= np.linalg.norm(u)
    v = np.cross(w, u)
    slope = (r0 - r1) / L
    ids = []
    for s in range(sections):
        ang = 2 * math.pi * s / sections
        d = math.cos(ang) * u + math.sin(ang) * v
        n = d + w * slope
        ids.append((b.v(p0 + d * r0, n, TRUNK * 0.8, ao=0.8), b.v(p1 + d * r1, n, TRUNK)))
    for s in range(sections):
        (a0, a1), (b0, b1) = ids[s], ids[(s + 1) % sections]
        b.quad(a0, b0, b1, a1)


def puff_tree(seed=0, lod=0, palette="green"):
    rng = np.random.default_rng(seed)
    b = MeshBuilder()
    bottom, top = (hex_rgb(c) for c in PALETTES[palette])
    trunk_h, R = 2.4, 2.6                       # canopy radius ~2.6 m
    C = np.array([0, 0, trunk_h + R * 0.85])     # canopy centre

    # blob layout: crown + ring + lower fill (fewer at LOD1)
    blobs = [(C + [0, 0, R * 0.45], R * 0.62)]
    ring_n = 6 if lod == 0 else 4
    for k in range(ring_n):
        a = 2 * math.pi * k / ring_n + rng.uniform(-0.3, 0.3)
        rr = R * rng.uniform(0.52, 0.62)
        blobs.append((C + [math.cos(a) * R * 0.55, math.sin(a) * R * 0.55, rng.uniform(-0.15, 0.25) * R], rr))
    if lod == 0:
        for k in range(2):
            a = rng.uniform(0, 2 * math.pi)
            blobs.append((C + [math.cos(a) * R * 0.3, math.sin(a) * R * 0.3, -R * 0.35], R * 0.5))

    z_lo = min(c[2] - r for c, r in blobs)
    z_hi = max(c[2] + r for c, r in blobs)
    sphere = trimesh.creation.icosphere(subdivisions=2 if lod == 0 else 1)
    blend = 0.55
    for bi, (c, r) in enumerate(blobs):
        V = sphere.vertices * r + c
        keep = []
        for f in sphere.faces:
            centroid = V[f].mean(0)
            buried = any(np.linalg.norm(centroid - c2) < r2 * 0.97
                         for bj, (c2, r2) in enumerate(blobs) if bj != bi)
            if not buried:
                keep.append(f)
        remap = {}
        for f in keep:
            for vi in f:
                if vi not in remap:
                    p = V[vi]
                    ns = sphere.vertices[vi]
                    nc = (p - C) / (np.linalg.norm(p - C) + 1e-9)
                    n = (1 - blend) * ns + blend * nc
                    t = (p[2] - z_lo) / (z_hi - z_lo)
                    remap[vi] = b.v(p, n, ramp(bottom, top, t), ao=0.7 + 0.3 * t, t=t)
            b.tri(remap[f[0]], remap[f[1]], remap[f[2]])

    # Y-forked trunk
    sec = 6 if lod == 0 else 4
    fork = np.array([0, 0, trunk_h * 0.75])
    tube(b, [0, 0, 0], fork, 0.22, 0.17, sec)
    for k in range(2 if lod == 0 else 1):
        a = rng.uniform(0, 2 * math.pi) + k * math.pi
        end = C + [math.cos(a) * R * 0.35, math.sin(a) * R * 0.35, -R * 0.1]
        tube(b, fork, end, 0.15, 0.08, sec)
    return b


def conifer(seed=0, lod=0, palette="conifer"):
    b = MeshBuilder()
    bottom, top = (hex_rgb(c) for c in PALETTES[palette])
    tiers = 4 if lod == 0 else 3
    sections = 10 if lod == 0 else 7
    z, H = 1.2, 7.5
    trunk_top = z + 0.5
    tube(b, [0, 0, 0], [0, 0, trunk_top], 0.2, 0.16, 6 if lod == 0 else 4)
    total = H - z
    for k in range(tiers):
        f = k / tiers
        r = 2.2 * (1 - f * 0.7)
        h = total / tiers * 1.6
        z0 = z + total * f * 0.85
        # underside centre -> drooping rim -> soft shoulder -> apex
        prof = [(0.0, z0 + 0.25 * h), (r * 0.6, z0 + 0.05 * h), (r, z0), (r * 0.92, z0 + 0.1 * h), (0.0, z0 + h)]
        lathe(b, prof, sections, lambda zz: ramp(bottom, top, (zz - z) / (H - z)),
              t_fn=lambda zz: (zz - z) / (H - z))
    return b


def cypress(seed=0, lod=0, palette="cypress"):
    b = MeshBuilder()
    bottom, top = (hex_rgb(c) for c in PALETTES[palette])
    H, R, z0 = 8.0, 0.9, 0.6
    rings = 9 if lod == 0 else 6
    tube(b, [0, 0, 0], [0, 0, z0 + 0.3], 0.14, 0.12, 6 if lod == 0 else 4)
    prof = []
    for i in range(rings + 1):
        s = i / rings
        r = R * (s ** 0.55) * ((1 - s) ** 0.8) * 2.1
        prof.append((r, z0 + s * (H - z0)))
    lathe(b, prof, 8 if lod == 0 else 6, lambda zz: ramp(bottom, top, (zz - z0) / (H - z0)),
          t_fn=lambda zz: (zz - z0) / (H - z0))
    return b


def palm(seed=0, lod=0, palette="palm"):
    """Coconut palm: curved tapering trunk + drooping fronds (each a thin, softly-shaded blade),
    a small crown blob. ~100 tris at LOD0."""
    rng = np.random.default_rng(seed)
    b = MeshBuilder()
    trunk_c, frond_lo, frond_hi = hex_rgb("#9C8466"), hex_rgb("#4F7A2A"), hex_rgb("#93B83E")
    H = 8.5
    lean = rng.uniform(0.6, 1.4)
    a = rng.uniform(0, 2 * math.pi)
    d = np.array([math.cos(a), math.sin(a), 0.0])
    segs = 4 if lod == 0 else 3
    pts = [np.array([0, 0, 0.0]) + d * lean * (k / segs) ** 2 + np.array([0, 0, H * k / segs]) for k in range(segs + 1)]
    for k in range(segs):
        r0 = 0.22 - 0.07 * k / segs
        r1 = 0.22 - 0.07 * (k + 1) / segs
        tube(b, pts[k], pts[k + 1], r0, r1, 6 if lod == 0 else 4)
    top = pts[-1]
    for i in range(8 if lod == 0 else 6):
        ang = 2 * math.pi * i / (8 if lod == 0 else 6) + rng.uniform(-0.2, 0.2)
        u = np.array([math.cos(ang), math.sin(ang), 0.0])
        side = np.array([-u[1], u[0], 0.0])
        L = rng.uniform(3.0, 3.8)
        mids = [top, top + u * L * 0.45 + np.array([0, 0, 0.55]), top + u * L * 0.85 + np.array([0, 0, -0.35]),
                top + u * L + np.array([0, 0, -1.3])]
        widths = [0.05, 0.55, 0.4, 0.02]
        rows = []
        for k, (m, w) in enumerate(zip(mids, widths)):
            nrm = np.array([0, 0, 1.0]) - u * (0.2 + 0.25 * k)
            t = k / 3
            col = frond_hi + (frond_lo - frond_hi) * t
            rows.append((b.v(m - side * w, nrm, col, t=1 - t), b.v(m + side * w, nrm, col, t=1 - t),
                         b.v(m - side * w, -nrm, col * 0.8), b.v(m + side * w, -nrm, col * 0.8)))
        for k in range(3):
            (l0, r0, bl0, br0), (l1, r1, bl1, br1) = rows[k], rows[k + 1]
            b.quad(l0, r0, r1, l1)
            b.quad(bl0, bl1, br1, br0)
    for (x, y, z) in [(0.0, 0.0, -0.3)]:
        sph = trimesh.creation.icosphere(subdivisions=0, radius=0.22)
        base = len(b.P)
        for v, n in zip(sph.vertices, sph.vertex_normals):
            b.v(top + np.array([x, y, z]) + v, n, hex_rgb("#7A6A2E"))
        for f in sph.faces:
            b.tri(base + f[0], base + f[1], base + f[2])
    return b


KINDS = {"puff": puff_tree, "cone": conifer, "cypress": cypress, "palm": palm}
DEFAULT_PAL = {"puff": "green", "cone": "conifer", "cypress": "cypress", "palm": "palm"}


def build(kind, lod, seed, palette):
    return KINDS[kind](seed=seed, lod=lod, palette=palette or DEFAULT_PAL[kind])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kind", choices=list(KINDS), default="puff")
    ap.add_argument("--lod", type=int, choices=[0, 1], default=0)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--palette", choices=list(PALETTES))
    ap.add_argument("--out")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--outdir", default=".")
    a = ap.parse_args()

    jobs = []
    if a.all:
        os.makedirs(a.outdir, exist_ok=True)
        for kind in KINDS:
            for lod in (0, 1):
                jobs.append((kind, lod, a.seed, None, os.path.join(a.outdir, f"{kind}_lod{lod}.glb")))
        for lod in (0, 1):
            jobs.append(("puff", lod, a.seed + 1, "blossom", os.path.join(a.outdir, f"blossom_lod{lod}.glb")))
    else:
        if not a.out:
            ap.error("--out required unless --all")
        jobs.append((a.kind, a.lod, a.seed, a.palette, a.out))

    for kind, lod, seed, pal, out in jobs:
        b = build(kind, lod, seed, pal)
        export_glb(b, out)
        print(f"{os.path.basename(out):<22} {b.tri_count:>6} tris  {len(b.P):>6} verts")


if __name__ == "__main__":
    main()
