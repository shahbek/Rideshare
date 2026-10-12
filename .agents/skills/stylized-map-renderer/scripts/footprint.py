"""Footprint repair and analysis for awkward real-world data (OSM / Overture / traced meshes).

repair(poly)        -> list of clean polygons (multipolygons split, spikes, slivers, acute corners fixed)
classify(poly)      -> 'rect' | 'ortho' | 'convex' | 'curved' | 'mild_concave' | 'irregular'
orthogonalize(poly) -> snaps near-90deg footprints to exact right angles
rect_cover(poly)    -> overlapping rectangles covering an orthogonal polygon (for cross-hip roofs)
street_edge(poly, spec) -> index of the façade edge that faces the street
"""
import math

import numpy as np
from shapely import affinity
from shapely.geometry import Polygon, MultiPolygon, GeometryCollection, Point
from shapely.geometry.polygon import orient
from shapely.validation import make_valid


# ------------------------------------------------------------------ ring helpers
def _turns(ring):
    """Signed turn angle (deg, + = left/convex for CCW) and interior angle per vertex."""
    t_in = ring - np.roll(ring, 1, axis=0)
    t_out = np.roll(ring, -1, axis=0) - ring
    cross = t_in[:, 0] * t_out[:, 1] - t_in[:, 1] * t_out[:, 0]
    dot = (t_in * t_out).sum(1)
    turn = np.degrees(np.arctan2(cross, dot))
    return turn, 180.0 - turn


def _clean_ring(ring, min_edge=0.3, spike_deg=12.0, collinear_deg=4.0):
    pts = [np.asarray(p, float) for p in ring]
    changed = True
    guard = 0
    while changed and len(pts) > 3 and guard < 500:
        changed = False
        guard += 1
        arr = np.array(pts)
        # duplicate / very short edges -> merge to midpoint
        L = np.linalg.norm(np.roll(arr, -1, axis=0) - arr, axis=1)
        k = int(np.argmin(L))
        if L[k] < min_edge and len(pts) > 3:
            j = (k + 1) % len(pts)
            pts[k] = (pts[k] + pts[j]) / 2
            del pts[j]
            changed = True
            continue
        turn, interior = _turns(arr)
        # spikes (needle-like convex tips or reflex slits) and collinear points
        bad = np.where((interior < spike_deg) | (interior > 360 - spike_deg) |
                       (np.abs(turn) < collinear_deg))[0]
        if len(bad):
            del pts[int(bad[0])]
            changed = True
    return np.array(pts)


def _chamfer_acute(ring, acute_deg=40.0, cut=0.6):
    """Replaces very sharp convex corners with a short cut so offsets/sweeps can't spike."""
    out = []
    n = len(ring)
    _, interior = _turns(ring)
    for i in range(n):
        if interior[i] < acute_deg:
            p, a, b = ring[i], ring[i - 1], ring[(i + 1) % n]
            da, db = a - p, b - p
            la, lb = np.linalg.norm(da), np.linalg.norm(db)
            c = min(cut, 0.3 * la, 0.3 * lb)
            out.append(p + da / la * c)
            out.append(p + db / lb * c)
        else:
            out.append(ring[i])
    return np.array(out)


def dominant_angle(poly):
    """Length-weighted dominant edge direction modulo 90 deg (radians)."""
    ring = np.array(poly.exterior.coords)
    d = np.diff(ring, axis=0)
    L = np.linalg.norm(d, axis=1)
    ang = np.mod(np.arctan2(d[:, 1], d[:, 0]), math.pi / 2)
    # circular mean on the 4-fold symmetric angle
    c = (L * np.cos(4 * ang)).sum()
    s = (L * np.sin(4 * ang)).sum()
    return math.atan2(s, c) / 4.0


def orthogonalize(poly, tol_deg=7.0):
    """Snaps edges within tol of the dominant axes to exact H/V. Returns (poly, fully_orthogonal)."""
    th = dominant_angle(poly)
    P = affinity.rotate(poly, -th, origin=(0, 0), use_radians=True)

    def snap_ring(ring):
        r = np.array(ring)[:-1].copy()
        n = len(r)
        kinds = []
        for i in range(n):
            d = r[(i + 1) % n] - r[i]
            a = math.degrees(math.atan2(abs(d[1]), abs(d[0])))
            kinds.append("H" if a < tol_deg else ("V" if a > 90 - tol_deg else None))
        for i in range(n):
            j = (i + 1) % n
            if kinds[i] == "H":
                y = (r[i, 1] + r[j, 1]) / 2
                r[i, 1] = r[j, 1] = y
        for i in range(n):
            j = (i + 1) % n
            if kinds[i] == "V":
                x = (r[i, 0] + r[j, 0]) / 2
                r[i, 0] = r[j, 0] = x
        return r, all(k is not None for k in kinds)

    ext, ok = snap_ring(P.exterior.coords)
    holes = []
    for h in P.interiors:
        hr, hok = snap_ring(h.coords)
        holes.append(hr)
        ok = ok and hok
    # cluster nearly-equal x / y values so collinear walls share one exact line
    allr = [ext] + holes
    for axis in (0, 1):
        vals = np.sort(np.concatenate([r[:, axis] for r in allr]))
        groups, cur = [], [vals[0]]
        for v in vals[1:]:
            if v - cur[-1] < 0.3:
                cur.append(v)
            else:
                groups.append(cur); cur = [v]
        groups.append(cur)
        for g in groups:
            m = float(np.mean(g))
            for r in allr:
                sel = (r[:, axis] >= g[0] - 1e-9) & (r[:, axis] <= g[-1] + 1e-9)
                r[sel, axis] = m
    Q = Polygon(ext, holes).buffer(0)
    if Q.is_empty or Q.geom_type != "Polygon" or abs(Q.area - P.area) > 0.08 * P.area:
        return poly, False
    Q = affinity.rotate(Q, th, origin=(0, 0), use_radians=True)
    return orient(Q, 1.0), ok


def repair(poly, min_area=2.0, min_hole=20.0, min_edge=0.3, acute_deg=40.0, ortho_tol=7.0):
    """Returns a list of clean, valid, CCW polygons. Multipolygons are split into parts."""
    g = make_valid(poly)
    parts = []
    stack = [g]
    while stack:
        x = stack.pop()
        if isinstance(x, Polygon):
            parts.append(x)
        elif isinstance(x, (MultiPolygon, GeometryCollection)):
            stack.extend(x.geoms)
    out = []
    for p in parts:
        if p.area < min_area:
            continue
        ext = _clean_ring(np.array(orient(p, 1.0).exterior.coords)[:-1], min_edge)
        holes = []
        for h in orient(p, 1.0).interiors:
            hp = Polygon(h)
            if hp.area >= min_hole:
                hr = _clean_ring(np.array(h.coords)[:-1], min_edge)
                if len(hr) >= 3:
                    holes.append(hr)
        if len(ext) < 3:
            continue
        ext = _chamfer_acute(ext, acute_deg)
        q = Polygon(ext, holes).buffer(0)
        if q.is_empty:
            continue
        if q.geom_type == "MultiPolygon":
            q = max(q.geoms, key=lambda z: z.area)
        q = orient(q, 1.0)
        q2, _ = orthogonalize(q, ortho_tol)
        out.append(orient(q2, 1.0))
    return out


def is_orthogonal(poly, tol_deg=2.0):
    th = dominant_angle(poly)
    rings = [np.array(poly.exterior.coords)] + [np.array(r.coords) for r in poly.interiors]
    for r in rings:
        d = np.diff(r, axis=0)
        a = np.degrees(np.mod(np.arctan2(d[:, 1], d[:, 0]) - th, math.pi / 2))
        if np.any((a > tol_deg) & (a < 90 - tol_deg)):
            return False
    return True


def classify(poly):
    hull = poly.convex_hull
    n = len(poly.exterior.coords) - 1
    rr = poly.minimum_rotated_rectangle
    if n <= 5 and not poly.interiors and poly.area / rr.area > 0.98:
        return "rect"
    if is_orthogonal(poly):
        return "ortho"
    fill = poly.area / hull.area
    if fill > 0.995 and not poly.interiors:
        turn, _ = _turns(np.array(poly.exterior.coords)[:-1])
        if np.mean(np.abs(turn) < 20) > 0.4 and n >= 8:
            return "curved"
        return "convex"
    if fill > 0.85 and not poly.interiors:
        return "mild_concave"
    return "irregular"


def rect_cover(poly, min_side=1.2):
    """Greedy cover of an orthogonal polygon by maximal, possibly overlapping rectangles.
    Overlap is intentional: each wing spans its full length so roofs interpenetrate into
    correct valleys (L, T, U, H, plus shapes)."""
    th = dominant_angle(poly)
    P = affinity.rotate(poly, -th, origin=(0, 0), use_radians=True)
    coords = [np.array(P.exterior.coords)] + [np.array(r.coords) for r in P.interiors]
    xs = np.unique(np.round(np.concatenate([c[:, 0] for c in coords]), 2))
    ys = np.unique(np.round(np.concatenate([c[:, 1] for c in coords]), 2))
    nx, ny = len(xs) - 1, len(ys) - 1
    if nx < 1 or ny < 1 or nx * ny > 1600:
        return [poly]
    inside = np.zeros((nx, ny), bool)
    area = np.zeros((nx, ny))
    for i in range(nx):
        for j in range(ny):
            cx, cy = (xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2
            inside[i, j] = P.contains(Point(cx, cy))
            area[i, j] = (xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j])
    covered = np.zeros_like(inside)

    def psum(a):
        s = np.zeros((nx + 1, ny + 1))
        s[1:, 1:] = a.cumsum(0).cumsum(1)
        return s

    I0, I1 = np.triu_indices(nx + 1, 1)   # x spans [I0, I1)
    J0, J1 = np.triu_indices(ny + 1, 1)
    w = (xs[I1] - xs[I0])[:, None]
    h = (ys[J1] - ys[J0])[None, :]
    S_in = psum(inside.astype(float))
    full = (S_in[I1][:, J1] - S_in[I0][:, J1] - S_in[I1][:, J0] + S_in[I0][:, J0])
    cells = (I1 - I0)[:, None] * (J1 - J0)[None, :]
    valid = (np.abs(full - cells) < 0.5) & (w >= min_side) & (h >= min_side)
    rects = []
    for _ in range(24):
        if covered[inside].all():
            break
        S_unc = psum(area * (inside & ~covered))
        gain = (S_unc[I1][:, J1] - S_unc[I0][:, J1] - S_unc[I1][:, J0] + S_unc[I0][:, J0])
        score = np.where(valid, gain + 1e-3 * (w * h), -1)
        k = np.unravel_index(int(np.argmax(score)), score.shape)
        if score[k] <= 1e-6:
            break
        a, b = I0[k[0]], I1[k[0]]
        c, d = J0[k[1]], J1[k[1]]
        covered[a:b, c:d] = True
        r = Polygon([(xs[a], ys[c]), (xs[b], ys[c]), (xs[b], ys[d]), (xs[a], ys[d])])
        rects.append(orient(affinity.rotate(r, th, origin=(0, 0), use_radians=True), 1.0))
    return rects or [poly]


def street_edge(poly, spec):
    """Façade edge index: spec 'street' point -> facing edge; 'street_edge' index (mapped by
    midpoint onto the repaired ring); default the longest exterior edge."""
    ring = np.array(poly.exterior.coords)[:-1]
    n = len(ring)
    mids = (ring + np.roll(ring, -1, axis=0)) / 2
    d = np.roll(ring, -1, axis=0) - ring
    L = np.linalg.norm(d, axis=1)
    if "street" in spec:
        sp = np.asarray(spec["street"], float)
        nrm = np.stack([d[:, 1], -d[:, 0]], 1) / (L[:, None] + 1e-9)
        score = ((sp - mids) * nrm).sum(1) / (np.linalg.norm(sp - mids, axis=1) + 1e-9) * np.sqrt(L)
        return int(np.argmax(score))
    if "street_edge" in spec and spec.get("_orig_ring") is not None:
        o = np.asarray(spec["_orig_ring"], float)
        k = spec["street_edge"] % len(o)
        m = (o[k] + o[(k + 1) % len(o)]) / 2
        return int(np.argmin(np.linalg.norm(mids - m, axis=1) - 0.01 * L))
    return int(np.argmax(L))
