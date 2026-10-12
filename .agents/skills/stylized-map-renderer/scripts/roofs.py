"""Roof solver for any footprint (Z-up, metres).

roof_for_footprint() picks the strategy from footprint.classify():
  rect / ortho   -> rect_cover wings, each an exact hip or gable; wings interpenetrate so equal
                    pitches produce correct valleys (L, T, U, H, cross plans, churches)
  convex/curved  -> exact convex hip (each edge's plane wins where it is lowest)
  mild_concave   -> hip of the convex hull, clipped to the footprint; walls rise to meet the
                    roof along the concave notch (gable infill)
  irregular      -> mansard (ring stack inset + flat top), robust for anything
Also: ring_stack (curved/pagoda/upturned eaves), dome (hemi/ottoman/pointed/onion), cone, spire.
"""
import math

import numpy as np
from shapely.geometry import Polygon, Point, LineString
from shapely.geometry.polygon import orient

from geomlib import (earcut_polygon, flat_poly, lathe, prism, ring_analysis, rings_of, sweep)
from footprint import classify, rect_cover


# ------------------------------------------------------------------ convex helpers
def offset_convex(ring, d):
    """Offsets every edge line of a CCW convex ring outward by d; vertex order preserved."""
    ring = np.asarray(ring, float)
    n = len(ring)
    t = np.roll(ring, -1, axis=0) - ring
    t /= np.linalg.norm(t, axis=1, keepdims=True)
    out_n = np.stack([t[:, 1], -t[:, 0]], 1)
    res = []
    for i in range(n):
        ip = (i - 1) % n
        p1, d1 = ring[ip] + out_n[ip] * d, t[ip]
        p2, d2 = ring[i] + out_n[i] * d, t[i]
        den = d1[0] * d2[1] - d1[1] * d2[0]
        if abs(den) < 1e-9:
            res.append(ring[i] + out_n[i] * d)
        else:
            s = ((p2[0] - p1[0]) * d2[1] - (p2[1] - p1[1]) * d2[0]) / den
            res.append(p1 + d1 * s)
    return np.array(res)


def _clip(poly, a, c):
    """Sutherland-Hodgman: keep a.p <= c."""
    out = []
    n = len(poly)
    for i in range(n):
        P, Q = poly[i], poly[(i + 1) % n]
        fp, fq = a @ P - c, a @ Q - c
        if fp <= 1e-9:
            out.append(P)
        if (fp < -1e-9 and fq > 1e-9) or (fp > 1e-9 and fq < -1e-9):
            s = fp / (fp - fq)
            out.append(P + (Q - P) * s)
    return out


class ConvexRoof:
    """Exact hip/gable surface over a convex host ring (gable edges are excluded from the min)."""

    def __init__(self, host, z_eave, pitch_deg, gable=()):
        self.host = np.asarray(host, float)
        n = len(self.host)
        t = np.roll(self.host, -1, axis=0) - self.host
        t /= np.linalg.norm(t, axis=1, keepdims=True)
        self.m = np.stack([-t[:, 1], t[:, 0]], 1)               # inward normals
        self.active = [i for i in range(n) if i not in set(gable)]
        self.z_eave = z_eave
        self.k = math.tan(math.radians(pitch_deg))
        self.poly = Polygon(self.host)

    def d(self, i, p):
        return self.m[i] @ (np.asarray(p) - self.host[i])

    def z(self, p):
        return self.z_eave + self.k * min(self.d(i, p) for i in self.active)

    def facet(self, i):
        poly = [p for p in self.host]
        for j in self.active:
            if j == i:
                continue
            a = self.m[i] - self.m[j]
            c = self.m[i] @ self.host[i] - self.m[j] @ self.host[j]
            if np.linalg.norm(a) < 1e-9:
                continue
            poly = _clip(poly, a, c)
            if len(poly) < 3:
                return None
        return np.array(poly)

    def breakpoints(self, p, q):
        """Params t in [0,1] along p->q where the governing roof plane changes."""
        p, q = np.asarray(p, float), np.asarray(q, float)
        ts = {0.0, 1.0}
        for a_i, i in enumerate(self.active):
            for j in self.active[a_i + 1:]:
                fp = self.d(i, p) - self.d(j, p)
                fq = self.d(i, q) - self.d(j, q)
                if (fp > 0) != (fq > 0) and abs(fp - fq) > 1e-12:
                    ts.add(float(fp / (fp - fq)))
        return sorted(ts)


def build_convex_roof(b, R, color, clip=None, underside=0.12, pal=0):
    """Emits facets (flat normals) + a darker underside offset below for visible thickness."""
    under = color * 0.72
    for i in R.active:
        f = R.facet(i)
        if f is None or len(f) < 3:
            continue
        parts = [Polygon(f)]
        if clip is not None:
            g = Polygon(f).intersection(clip)
            parts = [x for x in getattr(g, "geoms", [g]) if x.geom_type == "Polygon" and x.area > 1e-4]
        nrm = np.array([-R.m[i][0] * R.k, -R.m[i][1] * R.k, 1.0])
        for part in parts:
            if part.area < 1e-4:
                continue
            verts, tris = earcut_polygon(orient(part, 1.0))
            zs = [R.z_eave + R.k * R.d(i, v) for v in verts]
            top = [b.v((x, y, z), nrm, color, ao=0.92 if z < R.z_eave + 0.4 else 1.0, pal=pal)
                   for (x, y), z in zip(verts, zs)]
            for a, c, d in tris:
                b.tri(top[a], top[c], top[d])
            if underside:
                bot = [b.v((x, y, z - underside), -nrm, under, pal=pal) for (x, y), z in zip(verts, zs)]
                for a, c, d in tris:
                    b.tri(bot[a], bot[d], bot[c])


def roof_boards(b, R, outline, color, depth=0.22):
    """Fascia along eaves and barge boards along rakes: one rule for both - a vertical board
    that follows the roof height along every outline edge."""
    ring = np.asarray(outline, float)
    n = len(ring)
    for i in range(n):
        p, q = ring[i], ring[(i + 1) % n]
        d = q - p
        L = np.linalg.norm(d)
        if L < 1e-6:
            continue
        on = np.array([d[1], -d[0]]) / L
        ts = R.breakpoints(p, q)
        pts = [p + d * t for t in ts]
        zs = [R.z(x) for x in pts]
        for k in range(len(pts) - 1):
            a, c = pts[k] + on * 0.015, pts[k + 1] + on * 0.015
            n3 = (on[0], on[1], 0.0)
            ids = [b.v((*a, zs[k] - depth), n3, color), b.v((*c, zs[k + 1] - depth), n3, color),
                   b.v((*c, zs[k + 1] + 0.03), n3, color), b.v((*a, zs[k] + 0.03), n3, color)]
            b.quad(*ids)


def infill_walls(b, segments, zfun_R, z_base, color, min_rise=0.05):
    """Raises walls from z_base up to the roof along footprint segments (gable ends, notches)."""
    for p, q in segments:
        p, q = np.asarray(p, float), np.asarray(q, float)
        d = q - p
        L = np.linalg.norm(d)
        if L < 1e-6:
            continue
        on = np.array([d[1], -d[0]]) / L
        n3 = (on[0], on[1], 0.0)
        ts = zfun_R.breakpoints(p, q)
        pts = [p + d * t for t in ts]
        zs = [zfun_R.z(x) for x in pts]
        if max(zs) < z_base + min_rise:
            continue
        for k in range(len(pts) - 1):
            z0, z1 = max(zs[k], z_base), max(zs[k + 1], z_base)
            if z0 <= z_base + 1e-3 and z1 <= z_base + 1e-3:
                continue
            ids = [b.v((*pts[k], z_base), n3, color), b.v((*pts[k + 1], z_base), n3, color),
                   b.v((*pts[k + 1], z1), n3, color), b.v((*pts[k], z0), n3, color)]
            b.quad(*ids)


# ------------------------------------------------------------------ main dispatcher
class RoofResult:
    def __init__(self):
        self.roofs = []          # ConvexRoof list
        self.top_z = 0.0
        self.kind = None

    def z(self, p):
        """Roof height at a point (max over wings containing it), or None."""
        best = None
        for R in self.roofs:
            if R.poly.buffer(1e-6).contains(Point(p)):
                z = R.z(p)
                best = z if best is None else max(best, z)
        return best


def _rect_gables(ring, mode, street_dir=None):
    L = [np.linalg.norm(ring[(i + 1) % 4] - ring[i]) for i in range(4)]
    if mode == "street" and street_dir is not None:
        sd = np.asarray(street_dir) / np.linalg.norm(street_dir)
        par = [abs(((ring[(i + 1) % 4] - ring[i]) / L[i]) @ sd) for i in range(4)]
        return {i for i in range(4) if par[i] > 0.7}
    if max(L) / max(min(L), 1e-6) < 1.12:
        return set()                       # square: hip
    short = sorted(range(4), key=lambda i: L[i])[:2]
    return set(short)


def roof_for_footprint(b, poly, H, kind="hip", pitch=30.0, color=None, wall_color=None,
                       trim_color=None, overhang=0.4, gable_mode="short", street_dir=None,
                       boards=True, pal=0, thick=0.12):
    """thick: visible roof thickness (0.12 sheet roofs, 0.3-0.4 makuti thatch)."""
    """Builds a pitched roof over walls of height H. kind: hip | gable | mansard | shed."""
    res = RoofResult()
    cls = classify(poly)
    k = math.tan(math.radians(pitch))
    z_eave = H - overhang * k
    trim_color = trim_color if trim_color is not None else color
    if kind == "mansard" or cls == "irregular" or poly.interiors:
        res.kind = "mansard"
        mansard(b, poly, H, color, top_color=color * 1.05)
        res.top_z = H + 2.4
        return res

    if cls in ("rect", "ortho"):
        wings = rect_cover(poly) if cls == "ortho" else [poly]
        for w in wings:
            ring = np.array(orient(w, 1.0).exterior.coords)[:-1]
            if len(ring) != 4:
                ring = np.array(orient(w.minimum_rotated_rectangle, 1.0).exterior.coords)[:-1]
            gables = _rect_gables(ring, gable_mode, street_dir) if kind == "gable" else set()
            if kind == "shed":
                gables = {0, 1, 2, 3} - {_rect_gables(ring, "street", street_dir).pop()
                                        if street_dir is not None else 0}
            host = offset_convex(ring, overhang)
            R = ConvexRoof(host, z_eave, pitch, gables)
            build_convex_roof(b, R, color, pal=pal, underside=thick)
            if boards:
                roof_boards(b, R, host, trim_color, depth=max(0.22, thick + 0.1))
            if gables and wall_color is not None:
                segs = [(ring[i], ring[(i + 1) % 4]) for i in sorted(gables)]
                infill_walls(b, segs, R, H, wall_color)
            res.roofs.append(R)
        res.kind = f"{kind}:{len(wings)} wings"
    else:
        hull = orient(poly.convex_hull, 1.0)
        ring = np.array(hull.exterior.coords)[:-1]
        host = offset_convex(ring, overhang)
        R = ConvexRoof(host, z_eave, pitch, ())
        clip = None
        if cls == "mild_concave":
            clip = poly.buffer(overhang, join_style="mitre")
        build_convex_roof(b, R, color, clip=clip, pal=pal, underside=thick)
        if boards:
            outline = np.array(orient(clip, 1.0).exterior.coords)[:-1] if clip is not None else host
            roof_boards(b, R, outline, trim_color, depth=max(0.22, thick + 0.1))
        if clip is not None and wall_color is not None:
            fr = np.array(poly.exterior.coords)[:-1]
            segs = [(fr[i], fr[(i + 1) % len(fr)]) for i in range(len(fr))]
            infill_walls(b, segs, R, H, wall_color)
        res.roofs.append(R)
        res.kind = f"hip:{cls}"
    res.top_z = max(max(R.z(p) for p in [R.host.mean(0)] + list(R.host)) for R in res.roofs)
    return res


# ------------------------------------------------------------------ ring stacks
def ring_stack(b, ring, z0, steps, color, cap=True, cap_color=None, pal=0):
    """Stacks inset copies of a ring: steps = [(inset, dz), ...] measured from the eave ring.
    Hip roofs with curved profiles (Japanese, pagoda), mansards, stepped crowns.
    Edges keep hard creases; the profile is smooth along each slope."""
    ring = np.asarray(ring, float)
    A = ring_analysis(ring)
    en, smooth = A["en"], A["smooth"]
    n = len(ring)
    miter = en + np.roll(en, 1, axis=0)
    miter /= np.linalg.norm(miter, axis=1, keepdims=True)
    scale = 1.0 / np.maximum((miter * en).sum(1), 0.35)
    levels = [(0.0, 0.0)] + list(steps)
    P = [[ring[i] - miter[i] * scale[i] * ins for i in range(n)] for ins, _ in levels]
    Z = [z0 + dz for _, dz in levels]
    t3 = [np.array([*(ring[(i + 1) % n] - ring[i]), 0.0]) for i in range(n)]
    for i in range(n):
        t3[i] /= np.linalg.norm(t3[i]) + 1e-12
    nrm = np.zeros((len(levels), n, 3))
    for i in range(n):
        m3 = np.array([-en[i][0], -en[i][1], 0.0])       # inward
        segn = []
        for k in range(len(levels) - 1):
            di = levels[k + 1][0] - levels[k][0]
            dz = levels[k + 1][1] - levels[k][1]
            nn = np.cross(t3[i], m3 * di + np.array([0, 0, dz]))
            if nn[2] < 0 or (abs(nn[2]) < 1e-6 and nn @ m3 > 0):
                nn = -nn
            segn.append(nn / (np.linalg.norm(nn) + 1e-12))
        for k in range(len(levels)):
            a = segn[max(k - 1, 0)] + segn[min(k, len(segn) - 1)]
            nrm[k, i] = a / np.linalg.norm(a)
    for i in range(n):
        j = (i + 1) % n
        for k in range(len(levels) - 1):
            na_k, na_k1 = nrm[k, i], nrm[k + 1, i]
            # smooth footprints (round towers): average with neighbour edge normals
            if smooth[i]:
                na_k = (nrm[k, i] + nrm[k, (i - 1) % n]); na_k1 = (nrm[k + 1, i] + nrm[k + 1, (i - 1) % n])
            nb_k, nb_k1 = nrm[k, i], nrm[k + 1, i]
            if smooth[j]:
                nb_k = (nrm[k, i] + nrm[k, j]); nb_k1 = (nrm[k + 1, i] + nrm[k + 1, j])
            ao_lo = 0.9 if k == 0 else 1.0
            ids = [b.v((*P[k][i], Z[k]), na_k, color, ao=ao_lo, pal=pal),
                   b.v((*P[k][j], Z[k]), nb_k, color, ao=ao_lo, pal=pal),
                   b.v((*P[k + 1][j], Z[k + 1]), nb_k1, color, pal=pal),
                   b.v((*P[k + 1][i], Z[k + 1]), na_k1, color, pal=pal)]
            b.quad(*ids)
    if cap:
        last = Polygon(P[-1])
        if last.is_valid and last.area > 0.05:
            flat_poly(b, orient(last, 1.0), Z[-1], True, cap_color if cap_color is not None else color)
    return P[-1], Z[-1]


def mansard(b, poly, H, color, top_color=None, height=2.4, inset=0.9):
    """Universal fallback for awkward footprints: steep inset slope + flat top (any polygon)."""
    for ring, is_hole in rings_of(poly):
        if is_hole:
            continue
        top_ring, _ = ring_stack(b, ring, H, [(inset * 0.15, height * 0.55), (inset, height)],
                                 color, cap=False)
    core = poly.buffer(-inset, join_style="mitre")
    if not core.is_empty:
        for part in getattr(core, "geoms", [core]):
            flat_poly(b, orient(part, 1.0), H + height, True, top_color if top_color is not None else color)


def curved_hip(b, ring, H, color, rise_ratio=0.32, overhang=0.9, upturn=0.25, segments=4):
    """East-Asian hip: upturned eave and concave slope (rectangles / squares)."""
    ring = np.asarray(ring, float)
    host = offset_convex(ring, overhang)
    L = [np.linalg.norm(host[(i + 1) % len(host)] - host[i]) for i in range(len(host))]
    half = min(L) / 2 * 0.999
    rise = half * 2 * rise_ratio
    steps = []
    for s in range(1, segments + 1):
        u = s / segments
        steps.append((half * u, rise * (u ** 1.8)))
    z_eave = H - 0.15 + upturn * 0.3
    # upturn: lift the eave ring slightly relative to the first inset ring
    steps = [(half * 0.06, -upturn * 0.25 + 0.02)] + [(i, dz) for i, dz in steps]
    return ring_stack(b, host, z_eave, steps, color, cap=True)


# ------------------------------------------------------------------ domes, cones, spires
DOME_PROFILES = {
    "hemi":     [(math.cos(t), math.sin(t)) for t in np.linspace(0, math.pi / 2, 9)],
    "ottoman":  [(math.cos(t), 0.72 * math.sin(t)) for t in np.linspace(0, math.pi / 2, 8)],
    "pointed":  [(1.0, 0.0), (0.98, 0.28), (0.9, 0.58), (0.74, 0.88), (0.52, 1.12), (0.28, 1.3), (0.0, 1.48)],
    "onion":    [(1.0, 0.0), (1.13, 0.18), (1.16, 0.36), (1.06, 0.6), (0.82, 0.86), (0.5, 1.1),
                 (0.24, 1.32), (0.08, 1.52), (0.0, 1.7)],
    "bulb":     [(1.0, 0.0), (1.06, 0.2), (1.02, 0.45), (0.85, 0.72), (0.55, 0.95), (0.25, 1.1), (0.0, 1.2)],
}


def dome(b, center, R, z0, kind="hemi", color=None, sections=16, a0=0.0, a1=2 * math.pi,
         finial=0.0, finial_color=None, lip_color=None):
    prof = [(R * r, z) for r, z in [(r, z * R) for r, z in DOME_PROFILES[kind]]]
    prof = [(max(r, 0.0), z) for r, z in prof]
    top = prof[-1][1]
    lathe(b, prof, sections, lambda z: color, center=(center[0], center[1], z0), a0=a0, a1=a1,
          ao_fn=lambda z: 0.85 if z < 0.08 * R else 1.0)
    if lip_color is not None and abs(a1 - a0 - 2 * math.pi) < 1e-6:
        lathe(b, [(R * 1.06, -0.05), (R * 1.08, 0.12), (R * 1.0, 0.2)], sections,
              lambda z: lip_color, center=(center[0], center[1], z0))
    if finial > 0:
        fc = finial_color if finial_color is not None else color
        lathe(b, [(finial * 0.12, 0), (finial * 0.1, finial * 0.4), (finial * 0.22, finial * 0.5),
                  (finial * 0.1, finial * 0.62), (0.0, finial)], 6, lambda z: fc,
              center=(center[0], center[1], z0 + top - 0.05))
    return z0 + top + finial


def cone(b, center, r, h, z0, color, sections=12, flare=0.0, finial=0.0, finial_color=None):
    prof = []
    if flare > 0:
        prof += [(r * (1 + flare), 0.0), (r * 1.02, h * 0.12)]
    else:
        prof += [(r, 0.0)]
    prof += [(r * 0.55, h * 0.5), (0.0, h)]
    lathe(b, prof, sections, lambda z: color, center=(center[0], center[1], z0))
    if finial > 0:
        fc = finial_color if finial_color is not None else color
        lathe(b, [(0.08, 0), (0.06, finial * 0.7), (0.16, finial * 0.75), (0.0, finial)], 6,
              lambda z: fc, center=(center[0], center[1], z0 + h - 0.05))
    return z0 + h + finial


def drum(b, center, r, z0, h, color, sides=16, cornice_color=None):
    pts = [(center[0] + r * math.cos(2 * math.pi * i / sides), center[1] + r * math.sin(2 * math.pi * i / sides))
           for i in range(sides)]
    P = orient(Polygon(pts), 1.0)
    prism(b, P, z0, z0 + h, color, top=False)
    if cornice_color is not None:
        ring = np.array(P.exterior.coords)[:-1]
        sweep(b, ring, [(0.0, -0.05), (0.18, 0.0), (0.18, 0.18), (0.0, 0.25)], z0 + h - 0.25,
              cornice_color, support=0.0)
    return z0 + h
