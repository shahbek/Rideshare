"""Landmark generators (Z-up, metres). Each returns (MeshBuilder shell, instances).

build_tower(spec)   skyscrapers: setback tiers, façade systems (grid / curtain / punched), crowns
build_church(spec)  gothic | romanesque | orthodox (onion) | byzantine
build_mosque(spec)  ottoman | persian | mughal
build_pagoda(spec)  japanese | chinese

All take a footprint (any polygon; landmarks use its oriented bounding rectangle for the
composition) or explicit dimensions, plus an optional 'street' point/edge for orientation.
"""
import math

import numpy as np
from shapely.geometry import Polygon, Point
from shapely.geometry.polygon import orient
from shapely.ops import unary_union

import roofs
from core import (PROFILES, build_walls, build_flat_roof, parapet_and_roof, facade_windows, inst,
                  window_slots, edge_box, hsh, street_info)
from footprint import repair, street_edge
from geomlib import (MeshBuilder, hex_rgb, rings_of, sweep, round_corners, prism, flat_poly, lathe,
                     wall_strip, panel)

H_ = hex_rgb


# ------------------------------------------------------------------ local frame
class Frame:
    """u along the main axis (entrance -> back), v to the left. Right-handed, so CCW stays CCW."""

    def __init__(self, origin, axis):
        self.o = np.asarray(origin, float)
        a = np.asarray(axis, float)
        self.a = a / np.linalg.norm(a)
        self.l = np.array([-self.a[1], self.a[0]])

    def p(self, u, v):
        return self.o + self.a * u + self.l * v

    def d(self, du, dv):
        x = self.a * du + self.l * dv
        return x / np.linalg.norm(x)

    def rect(self, u0, u1, v0, v1):
        return orient(Polygon([self.p(u0, v0), self.p(u1, v0), self.p(u1, v1), self.p(u0, v1)]), 1.0)

    def circle(self, u, v, r, segs=4):
        return orient(Point(self.p(u, v)).buffer(r, quad_segs=segs), 1.0)

    def angle(self):
        return math.atan2(self.a[1], self.a[0])


def frame_from_spec(spec, default_len=40.0, default_w=20.0):
    """Oriented rectangle of the footprint -> Frame at the entrance-end midpoint + (L, W)."""
    if "footprint" not in spec:
        L, W = spec.get("length", default_len), spec.get("width", default_w)
        o = np.array(spec.get("origin", (0.0, 0.0)), float)
        ang = math.radians(spec.get("axis_deg", 0.0))
        return Frame(o, (math.cos(ang), math.sin(ang))), L, W
    poly = repair(Polygon(spec["footprint"]))[0]
    rr = np.array(orient(poly.minimum_rotated_rectangle, 1.0).exterior.coords)[:-1]
    e = [np.linalg.norm(rr[(i + 1) % 4] - rr[i]) for i in range(4)]
    i_long = int(np.argmax(e))
    L, W = e[i_long], e[(i_long + 1) % 4]
    axis = (rr[(i_long + 1) % 4] - rr[i_long]) / L
    c = rr.mean(0)
    s = dict(spec)
    s["_orig_ring"] = spec["footprint"]
    k = street_edge(poly, s)
    si = street_info(poly, k)
    # entrance at the short end nearest the street façade midpoint (or the street end itself)
    end_a, end_b = c - axis * L / 2, c + axis * L / 2
    if np.linalg.norm(si["mid"] - end_b) < np.linalg.norm(si["mid"] - end_a):
        axis = -axis
        end_a = end_b
    return Frame(end_a, axis), L, W


# ================================================================== SKYSCRAPERS
TOWER_PRESETS = {
    "art_deco": dict(setbacks=[(0.22, 3.0), (0.55, 3.0), (0.74, 2.6), (0.86, 2.2)], facade="grid",
                     wall="#55667A", stone="#E7DFD0", crown="spire", radius=0.0, floor_h=3.8, podium=True),
    "modern_glass": dict(setbacks=[], facade="curtain", wall="#7E9DBC", stone="#E9EEF2", crown="flat",
                         radius=3.5, floor_h=4.0, podium=False),
    "classic": dict(setbacks=[(0.25, 2.5)], facade="punched", wall="#E3D3BC", stone="#F2EAE0",
                    crown="pyramid", roof="#6FA58F", radius=0.0, floor_h=3.6, podium=True),
    "dar_glass": dict(setbacks=[], facade="curtain", wall="#4E8C96", stone="#E3E8EA", crown="flat",
                      radius=1.0, floor_h=4.2, podium=True),
    "supertall": dict(setbacks=[(0.3, 1.6), (0.5, 1.6), (0.65, 1.6), (0.78, 1.6), (0.88, 1.4)],
                      facade="curtain", wall="#6E8CA8", stone="#E4EAF0", crown="antenna", radius=2.0,
                      floor_h=4.2, podium=False),
}


def _tower_facade(b, ins, poly, z0, z1, P, floor_h, edges):
    stone, wall = H_(P["stone"]), H_(P["wall"])
    floors = max(int(round((z1 - z0) / floor_h)), 1)
    fh = (z1 - z0) / floors
    if P["facade"] == "grid":
        for e in edges:
            if e["hole"]:
                continue
            for f in range(floors):
                z = z0 + f * fh
                wall_strip(b, e["p0"], e["p0"] + e["t"] * e["L"], e["n"], z, z + 0.9, stone * 0.92, offset=0.012)
            k = max(int(e["L"] // 2.6), 1)
            for i in range(k + 1):
                u = 0.3 + (e["L"] - 0.6) * i / k
                edge_box(b, e["p0"], e["t"], e["n"], u - 0.3, u + 0.3, -0.05, 0.22, z0, z1 + 0.5, stone, top=True)
    elif P["facade"] == "curtain":
        prof = [(0.0, 0.0), (0.07, 0.02), (0.07, 0.16), (0.0, 0.18)]
        step = 1 if floors <= 40 else 2      # very tall: every other floor (the shader can draw the rest)
        for ring, hole in rings_of(poly):
            for f in range(step, floors, step):
                sweep(b, ring, prof, z0 + f * fh - 0.09, stone, support=0.0)
    else:  # punched
        ins += facade_windows(edges, floors, fh, z1, "window", 2.2, z_base=z0, sill=0.8, top_margin=0.7)


def build_tower(spec):
    P = dict(TOWER_PRESETS[spec.get("style", "art_deco")])
    P.update({k: spec[k] for k in ("setbacks", "facade", "crown", "radius", "floor_h", "podium", "wall", "stone")
              if k in spec})
    bid = str(spec.get("id", "tower"))
    H = float(spec.get("height", 160.0))
    b, ins = MeshBuilder(), []
    base = repair(Polygon(spec["footprint"]))[0]
    if P["radius"] > 0:
        base = round_corners(base, P["radius"], 3)
    stone, wall = H_(P["stone"]), H_(P["wall"])
    tiers, cur, z0 = [], base, 0.0
    for frac, inset in P["setbacks"]:
        z1 = H * frac
        nxt = cur.buffer(-inset, join_style="mitre")
        if nxt.is_empty or nxt.geom_type != "Polygon" or nxt.area < 40:
            break
        if P["radius"] > 0:
            nxt = round_corners(orient(nxt, 1.0), max(P["radius"] - inset * 0.3, 0.5), 3)
        tiers.append((cur, z0, z1, orient(nxt, 1.0)))
        cur, z0 = orient(nxt, 1.0), z1
    tiers.append((cur, z0, H, None))
    s = dict(spec); s["_orig_ring"] = spec["footprint"]
    st = street_info(base, street_edge(base, s)) if not P["radius"] else None

    for ti, (poly, za, zb, nxt) in enumerate(tiers):
        if ti == 0 and P.get("podium"):
            zp = min(3 * P["floor_h"] + 1.0, zb * 0.5)
            edges = build_walls(b, poly, zp, stone)
            for ring, _ in rings_of(poly):
                sweep(b, ring, PROFILES["cornice"], zp - 0.3, stone)
            ins += facade_windows(edges, 3, (zp - 0.4) / 3, zp, "window_tall", 2.4, sill=0.6, top_margin=0.6,
                                  street=dict(mid=st["mid"], n=st["n"]) if st else None, door="door_arched")
            za = zp
        edges = build_walls(b, poly, zb, wall if P["facade"] != "punched" else stone, z0=za)
        _tower_facade(b, ins, poly, za, zb, P, P["floor_h"], edges)
        if nxt is not None:
            for ring, _ in rings_of(poly):
                sweep(b, ring, PROFILES["parapet"], zb, stone)
                if P["facade"] != "curtain":
                    sweep(b, ring, PROFILES["cornice_small"], zb - 0.35, stone)
            terrace = poly.buffer(-0.3, join_style="mitre").difference(nxt)
            for part in getattr(terrace, "geoms", [terrace]):
                if part.geom_type == "Polygon" and part.area > 0.5:
                    flat_poly(b, orient(part, 1.0), zb, True, H_("#CFC8CC"),
                              ao_fn=lambda x, y, nx=nxt: 0.75 if nx.exterior.distance(Point(x, y)) < 0.05 else 1.0)

    top_poly = tiers[-1][0]
    crown = P["crown"]
    c = np.array(top_poly.centroid.coords[0])
    minx, miny, maxx, maxy = top_poly.bounds
    small = min(maxx - minx, maxy - miny)
    if crown == "pyramid":
        rr = np.array(orient(top_poly.minimum_rotated_rectangle, 1.0).exterior.coords)[:-1]
        for ring, _ in rings_of(top_poly):
            sweep(b, ring, PROFILES["cornice"], H - 0.62, stone)
        R = roofs.ConvexRoof(roofs.offset_convex(rr, 0.5), H - 0.1, 56.0)
        roofs.build_convex_roof(b, R, H_(P.get("roof", "#6FA58F")))
        roofs.roof_boards(b, R, R.host, stone)
        top = max(R.z(p) for p in [R.host.mean(0)])
        roofs.drum(b, c, small * 0.09, top - 1.0, 3.0, H_(P.get("roof", "#6FA58F")), sides=8)
        roofs.cone(b, c, small * 0.1, 4.0, top + 2.0, H_(P.get("roof", "#6FA58F")), sections=8, finial=3.0,
                   finial_color=H_("#D8B45A"))
    else:
        core = parapet_and_roof(b, top_poly, H, stone, profile="parapet")
        if crown in ("flat", "antenna"):
            pent = top_poly.buffer(-small * 0.22, join_style="mitre")
            if not pent.is_empty and pent.geom_type == "Polygon":
                pent = orient(pent, 1.0)
                build_walls(b, pent, H + 5.0, stone * 0.95, z0=H)
                parapet_and_roof(b, pent, H + 5.0, stone, profile="parapet_thin")
            if crown == "antenna":
                lathe(b, [(0.9, 0), (0.7, 6), (0.35, 20), (0.15, H * 0.22), (0.0, H * 0.22 + 1)], 8,
                      lambda z: H_("#B9BEC6"), center=(c[0], c[1], H + 5.0))
        elif crown == "spire":
            z, cur = H, top_poly
            for k in range(3):
                nx = cur.buffer(-small * 0.09, join_style="mitre")
                if nx.is_empty or nx.geom_type != "Polygon":
                    break
                nx = orient(nx, 1.0)
                build_walls(b, nx, z + 5.0, stone, z0=z)
                for ring, _ in rings_of(nx):
                    sweep(b, ring, PROFILES["parapet"], z + 5.0, stone)
                build_flat_roof(b, nx, z + 5.0)
                cur, z = nx, z + 5.0
            r0 = small * 0.13
            lathe(b, [(r0, 0), (r0 * 0.95, 8), (r0 * 0.75, 9), (r0 * 0.7, 16), (r0 * 0.45, 18),
                      (r0 * 0.3, 26), (0.25, 40), (0.0, 46)], 8, lambda zz: stone * 0.97, center=(c[0], c[1], z))
    return b, ins


# ================================================================== CHURCHES
CHURCH = {
    "gothic":     dict(wall="#E9E1D2", roof="#5D6675", trim="#F3EEE5", pitch=55, win="window_lancet",
                       tower="west_spire", buttress=True, apse="cone"),
    "romanesque": dict(wall="#E6D6BE", roof="#B76A4A", trim="#F1E7D8", pitch=35, win="window_arched",
                       tower="twin", buttress=False, apse="cone"),
    "orthodox":   dict(wall="#F4F0E8", roof="#4F7FB8", trim="#FFFFFF", pitch=30, win="window_arched",
                       tower=None, buttress=False, apse="dome", domes="onion", dome="#D8B45A", small_dome="#3D6FB6"),
    "byzantine":  dict(wall="#E8C9A8", roof="#B5704F", trim="#F2E6D6", pitch=24, win="window_arched",
                       tower=None, buttress=False, apse="dome", domes="byzantine", dome="#B5704F"),
}


def _apse(b, F, u, r, z_wall, color, roofc, kind, pitch):
    half = orient(Point(F.p(u, 0)).buffer(r, quad_segs=6).intersection(F.rect(u, u + r + 1, -r - 1, r + 1)), 1.0)
    build_walls(b, half, z_wall, color)
    a = F.angle()
    if kind == "dome":
        roofs.dome(b, F.p(u, 0), r * 1.02, z_wall, "hemi", roofc, sections=8, a0=a - math.pi / 2, a1=a + math.pi / 2)
    else:
        h = r * math.tan(math.radians(pitch))
        lathe(b, [(r + 0.35, 0.0), (0.0, h)], 8, lambda z: roofc, center=(*F.p(u, 0), z_wall - 0.2),
              a0=a - math.pi / 2, a1=a + math.pi / 2)


def build_church(spec):
    st = spec.get("style", "gothic")
    C = CHURCH[st]
    wall, roofc, trim = H_(C["wall"]), H_(C["roof"]), H_(C["trim"])
    F, L, W = frame_from_spec(spec, 42.0, 15.0)
    b, ins = MeshBuilder(), []
    orth = st in ("orthodox", "byzantine")
    Hn = float(spec.get("height", W * (1.25 if st == "gothic" else 0.95)))
    if orth:
        # cross-in-square: equal arms around a central crossing
        S = min(L, W * 1.6)
        arm = S * 0.36
        cu = S / 2
        nave = F.rect(0, S, -arm / 2 * 1.0, arm / 2 * 1.0)
        tran = F.rect(cu - arm / 2, cu + arm / 2, -S / 2 * 0.95, S / 2 * 0.95)
        L_eff, W_eff = S, arm
    else:
        nave = F.rect(0, L, -W / 2, W / 2)
        tc = L * 0.64
        tran = F.rect(tc - W * 0.45, tc + W * 0.45, -W * 0.95, W * 0.95) if L > 2.2 * W else None
        L_eff, W_eff = L, W
    plan = unary_union([nave] + ([tran] if tran is not None else []))
    plan = orient(plan, 1.0)
    edges = build_walls(b, plan, Hn, wall)
    for ring, _ in rings_of(plan):
        sweep(b, ring, PROFILES["plinth"], 0.0, trim, support=0.0)
    R = roofs.roof_for_footprint(b, plan, Hn, kind="gable", pitch=C["pitch"], color=roofc, wall_color=wall,
                                 trim_color=trim, overhang=0.5)
    _apse(b, F, L_eff, W_eff * 0.45, Hn * 0.82, wall, roofc, C["apse"], C["pitch"])

    # side windows + buttresses along the long walls
    tr_u = (tran.bounds if tran is not None else None)
    win_scale = min(max((Hn - 2.4) / 3.2, 0.6), 1.9) if C["win"] == "window_lancet" else min(Hn / 6.0, 1.8)
    for e in edges:
        if e["hole"] or e["L"] < 4:
            continue
        along_axis = abs(e["t"] @ F.a) > 0.9
        if not along_axis:
            continue
        slots = window_slots(e["L"], 4.2)
        for u in slots:
            p = e["p0"] + e["t"] * u
            ins.append(inst(C["win"], p, 1.6, e["n"], scale=win_scale))
        if C["buttress"] and e["L"] > 8:
            for u in [(slots[i] + slots[i + 1]) / 2 for i in range(len(slots) - 1)]:
                ins.append(inst("buttress", e["p0"] + e["t"] * u, 0.0, e["n"], scale=min(Hn * 0.75 / 6.0, 2.0)))

    entrance_n = -F.a
    front = F.p(0, 0)
    tower = C["tower"]
    if tower == "west_spire":
        s = W * 0.72
        tw = F.rect(-s + 0.6, 0.6, -s / 2, s / 2)
        Ht = Hn * 2.1
        build_walls(b, tw, Ht, wall)
        for ring, _ in rings_of(tw):
            for zf in (Hn * 0.55, Hn + 0.5, Ht * 0.78):
                sweep(b, ring, PROFILES["band"], zf, trim)
            sweep(b, ring, PROFILES["parapet"], Ht, trim)
        build_flat_roof(b, tw, Ht)
        cu = -s / 2 + 0.6
        for d in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            n = F.d(*d)
            p = F.p(cu, 0) + n * (s / 2)
            ins.append(inst("window_lancet", p, Ht * 0.8, n, scale=0.75))
            ins.append(inst("clock", p, Ht * 0.66, n, scale=1.0))
        ins.append(inst("door_arched", F.p(-s + 0.6, 0), 0.0, entrance_n, scale=1.5))
        ins.append(inst("rose_window", F.p(-s + 0.6, 0), Hn * 0.6, entrance_n, scale=0.8))
        sp_h = s * 2.6
        lathe(b, [(s * 0.46, 0.0), (s * 0.36, sp_h * 0.3), (s * 0.18, sp_h * 0.7), (0.1, sp_h * 0.97), (0.0, sp_h)],
              8, lambda z: roofc, center=(*F.p(cu, 0), Ht - 0.2))
        for du in (-1, 1):
            for dv in (-1, 1):
                q = F.p(cu + du * (s / 2 - 0.5), dv * (s / 2 - 0.5))
                roofs.cone(b, q, 0.5, 3.2, Ht + 0.6, trim, sections=6)
        ins.append(inst("finial_cross", F.p(cu, 0), Ht - 0.2 + sp_h - 0.2, entrance_n))
    elif tower == "twin":
        s = W * 0.4
        Ht = Hn * 1.75
        for dv in (-1, 1):
            vc = dv * (W / 2 - s / 2 + 0.6)
            tw = F.rect(-s + 0.8, 0.8, vc - s / 2, vc + s / 2)
            build_walls(b, tw, Ht, wall)
            for ring, _ in rings_of(tw):
                for zf in (Hn * 0.6, Hn + 0.5):
                    sweep(b, ring, PROFILES["band"], zf, trim)
            rr = np.array(tw.exterior.coords)[:-1]
            Rt = roofs.ConvexRoof(roofs.offset_convex(rr, 0.35), Ht - 0.2, 58.0)
            roofs.build_convex_roof(b, Rt, roofc)
            roofs.roof_boards(b, Rt, Rt.host, trim)
            for d in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                n = F.d(*d)
                ins.append(inst("window_arched", F.p(-s / 2 + 0.8, vc) + n * s / 2, Ht - 4.2, n, scale=0.9))
        ins.append(inst("door_arched", front, 0.0, entrance_n, scale=1.6))
        ins.append(inst("window_round", front, Hn * 0.62, entrance_n, scale=2.2))
    else:
        ins.append(inst("door_arched", front, 0.0, entrance_n, scale=1.4))
        ins.append(inst("window_arched", front, Hn * 0.55, entrance_n, scale=1.0))

    if orth:
        cu = L_eff / 2
        top = R.top_z
        r = W_eff * 0.38
        dz = roofs.drum(b, F.p(cu, 0), r * 1.03, Hn, top - Hn + r * 0.9, wall, sides=12, cornice_color=trim)
        for k in range(8):
            a = 2 * math.pi * k / 8
            n = np.array([math.cos(a), math.sin(a)])
            ins.append(inst("window_arched", F.p(cu, 0) + n * r * 1.03, dz - r * 0.85, n, scale=0.55))
        if C["domes"] == "onion":
            zt = roofs.dome(b, F.p(cu, 0), r * 0.98, dz, "onion", H_(C["dome"]), sections=14)
            ins.append(inst("finial_cross", F.p(cu, 0), zt - 0.3, F.a, scale=1.0))
            for du in (-1, 1):
                for dv in (-1, 1):
                    q = F.p(cu + du * W_eff * 0.75, dv * W_eff * 0.75)
                    zq = R.z(q) or Hn
                    rr_ = r * 0.45
                    d2 = roofs.drum(b, q, rr_ * 1.03, zq - 0.5, top - zq + 0.5, wall, sides=10, cornice_color=trim)
                    zt2 = roofs.dome(b, q, rr_, d2, "onion", H_(C["small_dome"]), sections=12)
                    ins.append(inst("finial_cross", q, zt2 - 0.2, F.a, scale=0.6))
        else:
            zt = roofs.dome(b, F.p(cu, 0), r * 1.0, dz, "hemi", H_(C["dome"]), sections=16, lip_color=trim)
            ins.append(inst("finial_cross", F.p(cu, 0), zt - 0.2, F.a, scale=0.8))
    return b, ins


# ================================================================== MOSQUES
MOSQUE = {
    "ottoman": dict(wall="#EEE6D8", dome="#8E9AA8", trim="#F6F1E8", dome_kind="ottoman", drum=0.14,
                    semi=True, turrets=True, minaret="pencil", court=True),
    "persian": dict(wall="#D9BE96", dome="#3FA7B5", trim="#2F7F9C", dome_kind="pointed", drum=0.30,
                    semi=False, turrets=False, minaret="persian", court=False, iwan=True),
    "mughal": dict(wall="#F4F1EA", dome="#F6F3EE", trim="#D9CFC0", dome_kind="onion", drum=0.26,
                   semi=False, turrets=False, minaret="mughal", court=False, iwan=True, plinth=True),
}


def _minaret(b, ins, base_xy, z0, top, kind, C, r=1.25):
    wall, trim, domec = H_(C["wall"]), H_(C["trim"]), H_(C["dome"])
    sq = orient(Polygon([(base_xy[0] - r * 1.35, base_xy[1] - r * 1.35), (base_xy[0] + r * 1.35, base_xy[1] - r * 1.35),
                         (base_xy[0] + r * 1.35, base_xy[1] + r * 1.35), (base_xy[0] - r * 1.35, base_xy[1] + r * 1.35)]), 1.0)
    zb = z0 + max(4.0, (top - z0) * 0.12)
    prism(b, sq, z0, zb, wall, top=True)
    if kind == "pencil":
        shaft_top = top - 9.0
        lathe(b, [(r * 1.1, zb - z0), (r, zb - z0 + 1.0), (r * 0.92, shaft_top - z0)], 16,
              lambda z: wall, center=(base_xy[0], base_xy[1], z0))
        n_bal = 2 if top - z0 < 60 else 3
        for k in range(n_bal):
            zk = zb + (shaft_top - zb) * (0.55 + 0.4 * k / max(n_bal - 1, 1)) if n_bal > 1 else zb + (shaft_top - zb) * 0.8
            ring = np.array(Point(base_xy).buffer(r * 0.92, quad_segs=4).exterior.coords)[:-1]
            sweep(b, ring, PROFILES["balcony_ring"], zk, trim, support=0.0)
        roofs.cone(b, base_xy, r * 1.0, 9.0, shaft_top, domec, sections=12)
        ins.append(inst("finial_alem", base_xy, top - 0.1, (1, 0), scale=0.8))
    elif kind == "persian":
        shaft_top = top - 3.0
        lathe(b, [(r * 1.25, zb - z0), (r * 1.1, shaft_top - z0)], 16, lambda z: wall,
              center=(base_xy[0], base_xy[1], z0))
        for zz in np.linspace(zb + 3, shaft_top - 2, 4):
            ring = np.array(Point(base_xy).buffer(r * 1.12, quad_segs=4).exterior.coords)[:-1]
            sweep(b, ring, PROFILES["band"], zz, domec, support=0.0)
        ring = np.array(Point(base_xy).buffer(r * 1.1, quad_segs=4).exterior.coords)[:-1]
        sweep(b, ring, PROFILES["balcony_ring"], shaft_top, domec, support=0.0)
        roofs.dome(b, base_xy, r * 0.9, shaft_top + 0.9, "bulb", domec, sections=12)
    else:  # mughal: tapering, three balconies, chhatri on top
        shaft_top = top - 5.0
        lathe(b, [(r * 1.3, zb - z0), (r * 0.95, shaft_top - z0)], 16, lambda z: wall,
              center=(base_xy[0], base_xy[1], z0))
        for f in (0.4, 0.7, 1.0):
            zk = zb + (shaft_top - zb) * f
            rk = r * (1.3 - 0.35 * f)
            ring = np.array(Point(base_xy).buffer(rk, quad_segs=4).exterior.coords)[:-1]
            sweep(b, ring, PROFILES["balcony_ring"], zk, trim, support=0.0)
        for k in range(6):
            a = 2 * math.pi * k / 6
            q = (base_xy[0] + math.cos(a) * r * 0.85, base_xy[1] + math.sin(a) * r * 0.85)
            lathe(b, [(0.12, 0.0), (0.12, 2.2)], 5, lambda z: trim, center=(q[0], q[1], shaft_top + 0.9))
        roofs.dome(b, base_xy, r * 1.05, shaft_top + 3.1, "onion", domec, sections=12, finial=0.9,
                   finial_color=H_("#D8B45A"))


def build_mosque(spec):
    st = spec.get("style", "ottoman")
    C = dict(MOSQUE[st])
    wall, trim, domec = H_(C["wall"]), H_(C["trim"]), H_(C["dome"])
    F, L, W = frame_from_spec(spec, 70.0, 40.0)
    b, ins = MeshBuilder(), []
    court = spec.get("courtyard", C["court"])
    D = min(L, W * 1.3)
    u_hall = 0.0
    if court and L - D >= W * 0.6:
        u_hall = L - D
    elif court and "footprint" not in spec:
        u_hall = W * 0.9
    Hw = W * (0.42 if st == "ottoman" else 0.36)
    zb = 0.0
    if C.get("plinth"):
        zb = 1.6
        plat = F.rect(u_hall - 8, u_hall + D + 8, -W / 2 - 8, W / 2 + 8)
        prism(b, plat, 0.0, zb, H_("#E2D6C6"))
    hall = F.rect(u_hall, u_hall + D, -W / 2, W / 2)
    edges = build_walls(b, hall, zb + Hw, wall, z0=zb)
    for ring, _ in rings_of(hall):
        sweep(b, ring, PROFILES["cornice_small"], zb + Hw - 0.3, trim)
    parapet_and_roof(b, hall, zb + Hw, trim, profile="parapet_thin")
    for e in edges:
        for u in window_slots(e["L"], 3.4):
            for z in (zb + 1.4, zb + Hw * 0.52):
                ins.append(inst("window_arched", e["p0"] + e["t"] * u, z, e["n"], scale=1.0 if z < Hw * 0.4 else 0.85))

    cu = u_hall + D / 2
    R = W * (0.36 if st == "ottoman" else 0.3)
    z = zb + Hw
    if C["turrets"]:
        for du in (-1, 1):
            for dv in (-1, 1):
                q = F.p(cu + du * R * 1.02, dv * R * 1.02)
                oc = orient(Point(q).buffer(W * 0.05, quad_segs=2), 1.0)
                prism(b, oc, z, z + W * C["drum"] + 2.5, wall, top=False)
                roofs.dome(b, q, W * 0.055, z + W * C["drum"] + 2.5, "hemi", domec, sections=8,
                           finial=1.0, finial_color=H_("#D8B45A"))
    dtop = roofs.drum(b, F.p(cu, 0), R * 1.03, z, W * C["drum"], wall, sides=16, cornice_color=trim)
    for k in range(16):
        a = 2 * math.pi * k / 16
        n = np.array([math.cos(a), math.sin(a)])
        ins.append(inst("window_arched", F.p(cu, 0) + n * R * 1.03, z + W * C["drum"] * 0.2, n,
                        scale=min(W * C["drum"] * 0.55 / 1.9, 1.3)))
    zt = roofs.dome(b, F.p(cu, 0), R, dtop, C["dome_kind"], domec, sections=20, lip_color=trim)
    if st == "mughal":
        for du in (-1, 1):
            for dv in (-1, 1):
                q = F.p(cu + du * (D / 2 - 3.0), dv * (W / 2 - 3.0))
                for k in range(4):
                    a = math.pi / 4 + math.pi / 2 * k
                    lathe(b, [(0.18, 0.0), (0.16, 3.0)], 5, lambda z_: trim,
                          center=(q[0] + math.cos(a) * 1.3, q[1] + math.sin(a) * 1.3, z + 0.6))
                prism(b, orient(Point(q).buffer(1.9, quad_segs=2), 1.0), z + 3.6, z + 4.0, domec)
                roofs.dome(b, q, 1.5, z + 4.0, "onion", domec, sections=10, finial=0.7, finial_color=H_("#D8B45A"))
    ins.append(inst("finial_alem", F.p(cu, 0), zt - 0.2, F.a, scale=max(R / 8, 0.8)))
    if C["semi"]:
        a = F.angle()
        for sgn in (-1, 1):
            q = F.p(cu + sgn * R, 0)
            a0 = a - math.pi / 2 if sgn > 0 else a + math.pi / 2
            roofs.dome(b, q, R * 0.8, z, "ottoman", domec, sections=10, a0=a0, a1=a0 + math.pi)
    if C.get("iwan"):
        wI, hI = W * 0.42, Hw * 1.35
        hole = [(-wI * 0.32, 0.0), (wI * 0.32, 0.0)]
        r = wI * 0.32 * 1.7
        th_a = math.acos((r - wI * 0.32) / r)
        s0 = hI * 0.82 - r * math.sin(th_a)
        right = [(wI * 0.32 - r + r * math.cos(t), s0 + r * math.sin(t)) for t in np.linspace(0, th_a, 6)]
        hole += right + [(-x, y) for x, y in reversed(right[:-1])]
        outer = [(-wI / 2, 0.0), (wI / 2, 0.0), (wI / 2, hI), (-wI / 2, hI)]
        panel(b, F.p(u_hall, 0), -F.l, -F.a, outer, 1.2, wall if st != "persian" else H_("#E6D3B3"),
              z_base=zb, holes=[hole])
        rec = F.rect(u_hall - 0.05, u_hall + 0.0, -wI * 0.33, wI * 0.33)
        prism(b, rec, zb, zb + s0 + r * math.sin(th_a), H_("#2F4F6F") if st == "persian" else H_("#C9BBA6"),
              top=False)
        ins.append(inst("door_arched", F.p(u_hall, 0), zb, -F.a, scale=1.6))
    else:
        ins.append(inst("door_arched", F.p(u_hall, 0), zb, -F.a, scale=1.8))

    # courtyard with domed portico (Ottoman avlu)
    if court and u_hall > 4:
        Dc = u_hall
        ha = Hw * 0.42
        outer = F.rect(0, Dc, -W / 2, W / 2)
        build_walls(b, outer, ha, wall)
        dep = 4.6
        flat_poly(b, orient(outer.difference(F.rect(dep, Dc + 1, -W / 2 + dep, W / 2 - dep)), 1.0), ha, True, wall)
        sc = ha / 3.6
        for side, (ua, ub, va, vb, n) in {
            "front": (dep, dep, -W / 2 + dep, W / 2 - dep, (1, 0)),
            "left": (dep, Dc, W / 2 - dep, W / 2 - dep, (0, -1)),
            "right": (dep, Dc, -W / 2 + dep, -W / 2 + dep, (0, 1)),
        }.items():
            nn = F.d(*n)
            Ls = max(abs(ub - ua), abs(vb - va))
            k = max(int(Ls // (3.0 * sc)), 1)
            for i in range(k):
                f = (i + 0.5) / k
                p = F.p(ua + (ub - ua) * f, va + (vb - va) * f)
                ins.append(inst("arch_bay", p, 0.0, nn, scale=sc))
                ins.append(inst("small_dome", p - nn * (dep / 2), ha, nn, scale=min(dep * 0.38, 2.0)))
        flat_poly(b, F.rect(dep, Dc, -W / 2 + dep, W / 2 - dep), 0.04, True, H_("#E9E4DA"))
        fc = F.p(dep + (Dc - dep) / 2, 0)
        oc = orient(Point(fc).buffer(2.2, quad_segs=2), 1.0)
        prism(b, oc, 0.0, 1.2, trim)
        roofs.dome(b, fc, 2.0, 2.6, "ottoman", domec, sections=8)
        lathe(b, [(0.15, 0), (0.15, 1.4)], 6, lambda z_: trim, center=(fc[0], fc[1], 1.2))
        ins.append(inst("door_arched", F.p(0, 0), 0.0, -F.a, scale=1.4))

    # minarets
    n_min = int(spec.get("minarets", 4 if st != "persian" else 2))
    dome_top = zt
    mtop = float(spec.get("minaret_height", max(dome_top * 1.35, 30.0)))
    pts = []
    if st == "persian":
        wI = W * 0.42
        pts = [F.p(u_hall - 0.6, -wI / 2 - 1.2), F.p(u_hall - 0.6, wI / 2 + 1.2)]
    elif st == "mughal":
        pts = [F.p(u_hall - 6.5, -W / 2 - 6.5), F.p(u_hall - 6.5, W / 2 + 6.5),
               F.p(u_hall + D + 6.5, -W / 2 - 6.5), F.p(u_hall + D + 6.5, W / 2 + 6.5)]
    else:
        hall_front = [F.p(u_hall - 1.5, -W / 2 - 1.5), F.p(u_hall - 1.5, W / 2 + 1.5)]
        hall_back = [F.p(u_hall + D + 1.5, -W / 2 - 1.5), F.p(u_hall + D + 1.5, W / 2 + 1.5)]
        court_far = [F.p(-1.5, -W / 2 - 1.5), F.p(-1.5, W / 2 + 1.5)] if court and u_hall > 4 else []
        pts = hall_front + (court_far if n_min in (4,) and court_far else hall_back) + (court_far if n_min >= 6 else [])
    for q in pts[:max(n_min, 2) if st != "mughal" else 4]:
        _minaret(b, ins, q, 0.0 if not C.get("plinth") else zb, mtop, C["minaret"], C)
    return b, ins


# ================================================================== PAGODA
def build_pagoda(spec):
    st = spec.get("style", "japanese")
    wall = H_("#5A3E36" if st == "japanese" else "#B5463A")
    roofc = H_("#4B5160" if st == "japanese" else "#3E4A44")
    trim = H_("#E9E1D2")
    F, L, W = frame_from_spec(spec, 12.0, 12.0)
    s0 = min(L, W)
    c = F.p(L / 2, 0)
    tiers = int(spec.get("tiers", 5))
    b, ins = MeshBuilder(), []
    prism(b, F.rect(L / 2 - s0 / 2 - 1.2, L / 2 + s0 / 2 + 1.2, -s0 / 2 - 1.2, s0 / 2 + 1.2), 0.0, 1.0, trim)
    z = 1.0
    for k in range(tiers):
        s = s0 * (1.0 - 0.13 * k)
        h = 3.4 if k == 0 else 2.2
        sq = F.rect(L / 2 - s / 2, L / 2 + s / 2, -s / 2, s / 2)
        build_walls(b, sq, z + h, wall, z0=z)
        for ring, _ in rings_of(sq):
            sweep(b, ring, PROFILES["band"], z + h - 0.5, trim * 0.9, support=0.0)
        ring = np.array(sq.exterior.coords)[:-1]
        top, ztop = roofs.curved_hip(b, ring, z + h, roofc, rise_ratio=0.3, overhang=s * 0.26, segments=4)
        z = z + h + 0.9
    lathe(b, [(0.6, 0.0), (0.35, 1.0)] + [(0.45 if i % 2 == 0 else 0.25, 1.0 + i * 0.7) for i in range(1, 10)] +
          [(0.0, 8.5)], 8, lambda zz: H_("#B08D4A"), center=(c[0], c[1], z - 1.2))
    return b, ins


LANDMARKS = {"tower": build_tower, "skyscraper": build_tower, "church": build_church,
             "mosque": build_mosque, "pagoda": build_pagoda}
