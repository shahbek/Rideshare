"""Core building pieces shared by styles.py and landmarks.py (Z-up, metres)."""
import hashlib
import math

import numpy as np
from shapely.geometry import Polygon, Point
from shapely.geometry.polygon import orient

from geomlib import (MeshBuilder, hex_rgb, rings_of, ring_analysis, earcut_polygon, sweep, to_gltf,
                     prism)

FLAT_ROOF = hex_rgb("#CFC8CC")

PROFILES = {
    # (offset outward from wall face, height). Visible side on the right of the traversal.
    "cornice": [(0.00, 0.00), (0.18, 0.02), (0.30, 0.12), (0.34, 0.30), (0.30, 0.48), (0.18, 0.58), (0.00, 0.60)],
    "cornice_small": [(0.00, 0.00), (0.10, 0.03), (0.16, 0.14), (0.12, 0.26), (0.00, 0.30)],
    "cornice_heavy": [(0.00, 0.00), (0.10, 0.00), (0.12, 0.25), (0.45, 0.45), (0.62, 0.62), (0.66, 0.85),
                      (0.55, 0.95), (0.00, 1.00)],
    "parapet": [(0.00, 0.00), (0.00, 0.55), (-0.10, 0.65), (-0.25, 0.62), (-0.30, 0.45), (-0.30, 0.00)],
    "parapet_soft": [(0.00, 0.00), (0.02, 0.45), (-0.06, 0.70), (-0.25, 0.80), (-0.45, 0.70), (-0.52, 0.45),
                     (-0.52, 0.00)],
    "parapet_thin": [(0.00, 0.00), (0.00, 0.35), (-0.15, 0.40), (-0.15, 0.00)],
    "parapet_lod1": [(0.00, 0.00), (0.00, 0.60), (-0.30, 0.60), (-0.30, 0.00)],
    "band": [(0.00, 0.00), (0.08, 0.04), (0.08, 0.14), (0.00, 0.18)],
    "slab": [(0.00, 0.00), (0.12, 0.02), (0.12, 0.40), (0.00, 0.42)],
    "plinth": [(0.12, 0.00), (0.12, 0.55), (0.04, 0.65), (0.00, 0.68)],
    "lip": [(0.00, 0.00), (0.25, 0.05), (0.28, 0.20), (0.00, 0.26)],
    "balcony_ring": [(0.00, -0.30), (0.75, -0.05), (0.80, 0.05), (0.80, 0.85), (0.72, 0.90), (0.00, 0.40)],
}


def hsh(s, mod):
    return int(hashlib.md5(str(s).encode()).hexdigest(), 16) % mod


def pick(lst, key):
    return hex_rgb(lst[hsh(key, len(lst))]) if isinstance(lst, (list, tuple)) else hex_rgb(lst)


# ------------------------------------------------------------------ walls
def build_walls(b, poly, height, color, pal=0, ao_mid=2.5, z0=0.0):
    """Walls with exact arc normals, hard corners + shader-bevel attributes. Returns straight
    edges usable for façades: dicts(p0, t, n, L, ring, idx)."""
    edges = []
    for ri, (ring, is_hole) in enumerate(rings_of(poly)):
        A = ring_analysis(ring)
        smooth, concave, en, t, L, straight, vn = (A[k] for k in
                                                    ("smooth", "concave", "en", "t", "L", "straight", "vn"))
        n = len(ring)
        hgt = height - z0
        zs = [z0, z0 + ao_mid, height] if hgt > ao_mid * 1.6 else [z0, height]
        ao_rows = [0.65, 1.0, 1.0] if len(zs) == 3 else [0.65, 1.0]
        for i in range(n):
            j = (i + 1) % n
            prev_n, next_n = en[(i - 1) % n], en[j]
            na = vn[i] if smooth[i] else en[i]
            nb = vn[j] if smooth[j] else en[i]
            na3, nb3 = np.array([na[0], na[1], 0.0]), np.array([nb[0], nb[1], 0.0])
            nl = np.array([*(en[i] if smooth[i] else prev_n), 0.0])
            nr = np.array([*(en[i] if smooth[j] else next_n), 0.0])
            flags = 1 if straight[i] else 0
            cols = []
            for zi, z in enumerate(zs):
                aoa = ao_rows[zi] * (0.85 if concave[i] else 1.0)
                aob = ao_rows[zi] * (0.85 if concave[j] else 1.0)
                va = b.v((*ring[i], z), na3, color, ao=aoa, flags=flags,
                         bevel=(0.0, L[i], height - z, z), nl=nl, nr=nr, pal=pal)
                vb = b.v((*ring[j], z), nb3, color, ao=aob, flags=flags,
                         bevel=(L[i], L[i], height - z, z), nl=nl, nr=nr, pal=pal)
                cols.append((va, vb))
            for r in range(len(zs) - 1):
                (a0, b0), (a1, b1) = cols[r], cols[r + 1]
                b.quad(a0, b0, b1, a1)
            if straight[i] and L[i] >= 1.5:
                edges.append(dict(p0=ring[i].copy(), t=t[i].copy(), n=en[i].copy(), L=float(L[i]),
                                  ring=ri, idx=i, hole=is_hole))
    return edges


def build_flat_roof(b, poly, z, parapet_t=0.30, ao_ring=0.8, color=None):
    color = FLAT_ROOF if color is None else color
    inner = poly.buffer(-parapet_t, join_style="mitre") if parapet_t > 0 else poly
    if inner.is_empty:
        return None
    if inner.geom_type == "MultiPolygon":
        inner = max(inner.geoms, key=lambda g: g.area)
    inner = orient(inner, 1.0)
    core = inner.buffer(-ao_ring, join_style="mitre") if ao_ring > 0 else inner
    up = (0, 0, 1)
    if ao_ring <= 0 or core.is_empty or core.geom_type != "Polygon" or core.area < 4.0:
        verts, tris = earcut_polygon(inner)
        ids = [b.v((x, y, z), up, color, ao=0.85 if ao_ring > 0 else 1.0) for x, y in verts]
        for a, c, d in tris:
            b.tri(ids[a], ids[c], ids[d])
        return inner
    core = orient(core, 1.0)
    core_pts = {(round(x, 6), round(y, 6)) for r in [core.exterior, *core.interiors] for x, y in r.coords}
    ann = inner.difference(core)
    for part in (ann.geoms if ann.geom_type == "MultiPolygon" else [ann]):
        if part.is_empty or part.geom_type != "Polygon":
            continue
        verts, tris = earcut_polygon(part)
        ids = [b.v((x, y, z), up, color,
                   ao=1.0 if (round(x, 6), round(y, 6)) in core_pts else 0.72) for x, y in verts]
        for a, c, d in tris:
            b.tri(ids[a], ids[c], ids[d])
    verts, tris = earcut_polygon(core)
    ids = [b.v((x, y, z), up, color, ao=1.0) for x, y in verts]
    for a, c, d in tris:
        b.tri(ids[a], ids[c], ids[d])
    return core


def parapet_and_roof(b, poly, H, trim, profile="parapet", cornice=None, roof_color=None, cornice_drop=0.62):
    """Flat roof with parapet sweep (+ optional cornice under it)."""
    prof = PROFILES[profile]
    t = -min(o for o, _ in prof)
    for ring, _ in rings_of(poly):
        sweep(b, ring, prof, H, trim, ao_fn=lambda k, p, n: 0.72 if (p[0] < -0.1 and p[1] < 0.05) else 1.0)
        if cornice:
            sweep(b, ring, PROFILES[cornice], H - cornice_drop, trim,
                  ao_fn=lambda k, p, n: 0.78 if n[1] < -0.3 else 1.0)
    return build_flat_roof(b, poly, H, parapet_t=t, color=roof_color)


# ------------------------------------------------------------------ instances
def inst(module, xy, z, n2, scale=1.0, **extra):
    """Instance record in glTF space: module faces outward along the 2D normal n2."""
    n_gl = to_gltf(np.array([n2[0], n2[1], 0.0]))
    d = {"module": module, "pos": to_gltf(np.array([xy[0], xy[1], z])).round(3).tolist(),
         "yaw": round(math.atan2(n_gl[0], n_gl[2]), 5)}
    if abs(scale - 1.0) > 1e-6:
        d["scale"] = round(float(scale), 4)
    d.update(extra)
    return d


def window_slots(L, spacing, wmin=1.5):
    """Same rule as the façade shader: centred slots with a clamped margin."""
    if L < wmin:
        return []
    margin = min(0.6, max(0.1, (L - 1.3) / 2))
    usable = L - 2 * margin
    count = max(int(usable // spacing), 1)
    start = margin + (usable - (count - 1) * spacing) / 2
    return [start + k * spacing for k in range(count)]


def facade_windows(edges, levels, floor_h, H, module, spacing, first=0, top_margin=0.9, sill=0.9,
                   street=None, door=None, door_pos="center", ground_module=None, street_module=None,
                   z_base=0.0, skip_holes=False, door_z=0.0):
    """Window/door instances on every straight edge. `street` = dict(mid, n) selects the façade
    that gets the door and street-only modules."""
    from modules import module_size
    out = []
    win_h = module_size(module)[1] + 0.1
    st_idx = street_edge_of(edges, street) if street else None
    for k, e in enumerate(edges):
        if skip_holes and e["hole"]:
            continue
        slots = window_slots(e["L"], spacing)
        is_street = (k == st_idx)
        door_u = None
        if is_street and door:
            door_u = e["L"] / 2 if door_pos == "center" else min(e["L"] * 0.2 + 0.8, e["L"] - 1.0)
            out.append(inst(door, e["p0"] + e["t"] * door_u, z_base + door_z, e["n"]))
        for f in range(first, levels):
            y = z_base + f * floor_h + sill
            if y + win_h > H - top_margin + 0.01:
                continue
            mod = module
            if f == 0 and ground_module:
                mod = ground_module
            if is_street and street_module and f > 0:
                mod = street_module
            for u in slots:
                if f == 0 and door_u is not None and abs(u - door_u) < 1.4:
                    continue
                out.append(inst(mod, e["p0"] + e["t"] * u, y, e["n"]))
    return out


def street_edge_of(edges, street):
    best, bd = None, 1e18
    for k, e in enumerate(edges):
        if e["hole"] or e["n"] @ street["n"] < 0.9:
            continue
        mid = e["p0"] + e["t"] * e["L"] / 2
        d = abs((mid - street["mid"]) @ street["n"]) + 0.2 * np.linalg.norm(mid - street["mid"])
        if d < bd:
            best, bd = k, d
    return best


def street_info(poly, idx):
    ring = np.array(orient(poly, 1.0).exterior.coords)[:-1]
    p0, p1 = ring[idx], ring[(idx + 1) % len(ring)]
    t = (p1 - p0) / np.linalg.norm(p1 - p0)
    return dict(p0=p0, p1=p1, t=t, n=np.array([t[1], -t[0]]), L=float(np.linalg.norm(p1 - p0)), mid=(p0 + p1) / 2)


def edge_box(b, p, t, n, u0, u1, d0, d1, z0, z1, color, top=True):
    """Box in an edge's local frame (u along t, d along outward n)."""
    p, t, n = (np.asarray(x, float) for x in (p, t, n))
    q = [p + t * u0 + n * d0, p + t * u1 + n * d0, p + t * u1 + n * d1, p + t * u0 + n * d1]
    P = orient(Polygon(q), 1.0)
    prism(b, P, z0, z1, color, top=top)


def place_instances(target, instances, get_module):
    """Bakes instances into a preview builder (glTF space)."""
    for ins in instances:
        mod = get_module(ins["module"])
        yaw, pos, sc = ins["yaw"], np.array(ins["pos"]), ins.get("scale", 1.0)
        s, c = math.sin(yaw), math.cos(yaw)

        def rot(v):
            v = np.asarray(v, float)
            return np.array([c * v[0] + s * v[2], v[1], -s * v[0] + c * v[2]])
        target.append(mod, transform=lambda p: rot(p) * sc + pos, normal_transform=rot)
