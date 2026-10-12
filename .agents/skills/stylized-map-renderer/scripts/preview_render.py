#!/usr/bin/env python3
"""CPU preview of a GLB with the stylized lighting model (wrap diffuse, purple shadow tint,
hemisphere ambient, rim, fog), so geometry and normals can be judged without Xcode.

Usage:
  python preview_render.py model.glb --out preview.png [--az 35] [--el 35] [--dist 1.0]
                           [--size 900x700] [--ssaa 2]

Vertex colours are used as albedo (the generator bakes AO into them). Normals are interpolated
per pixel, so smooth-normal tricks look the same as on the GPU. Pure numpy; ~10-60 s for
tens of thousands of triangles.
"""
import argparse
import math

import numpy as np
import trimesh

SUN = np.array([-0.5, 0.75, 0.45]); SUN /= np.linalg.norm(SUN)
SUN_COL = np.array([1.0, 0.97, 0.92])
SHADOW = np.array([0.55, 0.53, 0.75])
SKY = np.array([0.72, 0.82, 0.95])
BOUNCE = np.array([0.80, 0.78, 0.62])
FOG = np.array([0.66, 0.80, 0.92])
BG_TOP, BG_BOT = np.array([0.66, 0.80, 0.92]), np.array([0.85, 0.90, 0.95])


def stylize(albedo, N, V, wrap=0.45, rim_k=0.08):
    ndl = (N * SUN).sum(-1)
    diff = np.clip((ndl + wrap) / (1 + wrap), 0, 1)
    diff = diff * diff * (3 - 2 * diff)
    direct = SHADOW + (SUN_COL - SHADOW) * diff[..., None]
    amb = BOUNCE + (SKY - BOUNCE) * (N[..., 1:2] * 0.5 + 0.5)
    rim = (1 - np.clip((N * V).sum(-1), 0, 1)) ** 3 * rim_k
    return albedo * (direct * 0.78 + amb * 0.30) + rim[..., None] * SKY


def load(path):
    scene = trimesh.load(path, force="scene", process=False)
    V, N, C, F = [], [], [], []
    off = 0
    for name in scene.graph.nodes_geometry:
        T, gname = scene.graph[name]
        g = scene.geometry[gname]
        v = trimesh.transform_points(g.vertices, T)
        n = g.vertex_normals @ T[:3, :3].T
        try:
            c = g.visual.vertex_colors[:, :3] / 255.0
        except Exception:
            c = np.full((len(v), 3), 0.8)
        V.append(v); N.append(n); C.append(c); F.append(g.faces + off)
        off += len(v)
    return np.concatenate(V), np.concatenate(N), np.concatenate(C), np.concatenate(F)


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def render(V, N, C, F, W, H, az, el, dist_k, fov=35.0, fog_density=0.0):
    lo, hi = V.min(0), V.max(0)
    center = (lo + hi) / 2
    radius = np.linalg.norm(hi - lo) / 2
    d = radius / math.tan(math.radians(fov / 2)) * dist_k
    a, e = math.radians(az), math.radians(el)
    eye = center + d * np.array([math.cos(e) * math.sin(a), math.sin(e), math.cos(e) * math.cos(a)])
    fwd = center - eye; fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0, 1, 0]); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    rel = V - eye
    x, y, z = rel @ right, rel @ up, rel @ fwd
    f = 1 / math.tan(math.radians(fov / 2))
    sx = (x / z * f * (H / W) * 0.5 + 0.5) * W
    sy = (0.5 - y / z * f * 0.5) * H

    yy = np.linspace(0, 1, H)[:, None]
    img = (BG_TOP[None, None, :] * (1 - yy[:, :, None]) + BG_BOT[None, None, :] * yy[:, :, None]) * np.ones((1, W, 1))
    img = srgb_to_lin(img)
    zbuf = np.full((H, W), np.inf)
    alb = srgb_to_lin(C)

    for tri in F:
        if (z[tri] <= 0.01).any():
            continue
        px, py = sx[tri], sy[tri]
        x0, x1 = int(max(math.floor(px.min()), 0)), int(min(math.ceil(px.max()), W - 1))
        y0, y1 = int(max(math.floor(py.min()), 0)), int(min(math.ceil(py.max()), H - 1))
        if x0 > x1 or y0 > y1:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        (ax, bx, cx), (ay, by, cy) = px, py
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-12:
            continue
        w0 = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
        w1 = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
        w2 = 1 - w0 - w1
        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not inside.any():
            continue
        iz = 1 / z[tri]
        izp = w0 * iz[0] + w1 * iz[1] + w2 * iz[2]
        depth = 1 / np.where(izp > 0, izp, 1e-9)
        sub = zbuf[y0:y1 + 1, x0:x1 + 1]
        m = inside & (depth < sub)
        if not m.any():
            continue
        # perspective-correct weights
        pw = np.stack([w0 * iz[0], w1 * iz[1], w2 * iz[2]], -1) / izp[..., None]
        pw = pw[m]
        n = pw @ N[tri]
        n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
        p = pw @ V[tri]
        vdir = eye - p; vdir /= np.linalg.norm(vdir, axis=1, keepdims=True)
        # back faces (open meshes): flip toward viewer
        flip = (n * vdir).sum(1) < 0
        n[flip] *= -1
        col = stylize(pw @ alb[tri], n, vdir)
        if fog_density > 0:
            fd = 1 - np.exp(-np.linalg.norm(p - eye, axis=1) * fog_density)
            col = col + (srgb_to_lin(FOG) - col) * fd[:, None]
        sub[m] = depth[m]
        blk = img[y0:y1 + 1, x0:x1 + 1]
        blk[m] = col
    return lin_to_srgb(img)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("glb")
    ap.add_argument("--out", required=True)
    ap.add_argument("--az", type=float, default=35)
    ap.add_argument("--el", type=float, default=35)
    ap.add_argument("--dist", type=float, default=1.0)
    ap.add_argument("--size", default="900x700")
    ap.add_argument("--ssaa", type=int, default=2)
    ap.add_argument("--fog", type=float, default=0.0)
    a = ap.parse_args()
    W, H = (int(s) for s in a.size.lower().split("x"))
    V, N, C, F = load(a.glb)
    img = render(V, N, C, F, W * a.ssaa, H * a.ssaa, a.az, a.el, a.dist, fog_density=a.fog)
    if a.ssaa > 1:
        img = img.reshape(H, a.ssaa, W, a.ssaa, 3).mean((1, 3))
    from PIL import Image
    Image.fromarray((img * 255).astype(np.uint8)).save(a.out)
    print(f"rendered {len(F)} triangles -> {a.out}")


if __name__ == "__main__":
    main()
