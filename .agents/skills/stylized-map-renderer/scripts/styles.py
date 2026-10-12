"""Architectural styles for ordinary buildings. A style is data (palette, roof, trims, window
modules, rhythm) plus a list of 'extras' (small generators for porticos, turrets, timbering...).

build_styled(spec, lod) -> (MeshBuilder Z-up shell, instances in glTF space)

spec keys: footprint, holes, height | levels, style | type, id, street | street_edge,
           palette (wall colour index), corner_radius, floor_height (all optional except footprint).
"""
import math

import numpy as np
from shapely.geometry import Polygon, Point
from shapely.geometry.polygon import orient
from shapely.ops import unary_union

import roofs
from core import (PROFILES, FLAT_ROOF, build_walls, build_flat_roof, parapet_and_roof, facade_windows,
                  inst, street_info, street_edge_of, window_slots, edge_box, hsh, pick)
from footprint import repair, street_edge, classify
from geomlib import (MeshBuilder, hex_rgb, round_corners, rings_of, sweep, panel, wall_strip, prism, lathe)

# ------------------------------------------------------------------ style table
STYLES = {
    # --- the original Fenn-like map styles -------------------------------------------------
    "fenn_rowhouse": dict(walls=["#7FA3D6", "#E6C48F", "#F1E6D8", "#D9A9A0", "#B9C7A8"], trim="#F2ECE4",
                          roof=dict(kind="flat", parapet="parapet", cornice="cornice"), radius=0.35,
                          floor_h=3.2, levels=4, window="window", spacing=2.6, door="door",
                          extras=["bay", "roof_props"]),
    "fenn_office": dict(walls=["#F1E6D8", "#E8E2D6", "#D9D4CC"], trim="#F2ECE4",
                        roof=dict(kind="flat", parapet="parapet", cornice="cornice"), radius=1.2,
                        floor_h=3.6, levels=5, window="window", spacing=2.4, door="door", ground_windows=False,
                        bands=True, extras=["roof_props"]),
    "fenn_house": dict(walls=["#F1E6D8", "#E6C48F", "#D9A9A0", "#B9C7A8"], trim="#F2ECE4",
                       roof=dict(kind="hip", pitch=28, colors=["#F08F78", "#8EA4D6", "#A8A2B4", "#C9B9B4"],
                                 overhang=0.4), floor_h=3.0, levels=1, window="window", spacing=3.0, door="door",
                       extras=["chimneys"]),
    # --- historic & regional styles ---------------------------------------------------------
    "colonial": dict(walls=["#B5523B", "#F3EEE6", "#E8DCC8", "#A94B37"], trim="#F7F4EE",
                     roof=dict(kind="gable", pitch=38, colors=["#4A4F5A", "#5E5552"], overhang=0.3),
                     floor_h=3.0, levels=2, window="window_multipane+shutters_green", spacing=2.3,
                     door="door+pediment_door", plinth=True, extras=["dormers", "chimneys"]),
    "greek_revival": dict(walls=["#F6F3EC", "#EFE9DD"], trim="#FFFFFF",
                          roof=dict(kind="gable", pitch=22, colors=["#8C939C", "#A27A62"], overhang=0.35,
                                    gable_mode="street"),
                          floor_h=4.0, levels=2, window="window_tall+pediment", spacing=3.0, door="door",
                          plinth=True, extras=["portico"]),
    "cycladic": dict(walls=["#FBFBF8"], trim="#FBFBF8",
                     roof=dict(kind="flat", parapet="parapet_soft", color="#F4F2EE"), radius=0.5,
                     floor_h=2.9, levels=1, window="window_small_blue", spacing=2.4, door="door_blue",
                     extras=["stacked_cubes"]),
    "spanish": dict(walls=["#F1E2C8", "#F2CDA8", "#EADBC4"], trim="#F7EFE2",
                    roof=dict(kind="hip", pitch=24, colors=["#C8643B", "#B9573A"], overhang=0.55),
                    floor_h=3.3, levels=2, window="window_arched_dark", street_window="window_arched_dark+balcony",
                    spacing=2.8, door="door_arched", extras=["arcade", "mission_parapet"]),
    "victorian": dict(walls=["#9CC5A1", "#E8B4C4", "#F2D492", "#A9B7E0", "#C7A2D6"], trim="#FBF6EE",
                      roof=dict(kind="gable", pitch=48, colors=["#5E5A6E", "#6F5F5A"], overhang=0.35),
                      floor_h=3.2, levels=2, window="window_tall+pediment", spacing=2.2, door="door_green",
                      bands=True, extras=["turret", "porch"]),
    "tudor": dict(walls=["#F1E7D2", "#EFE3CC"], trim="#3E2C22",
                  roof=dict(kind="gable", pitch=52, colors=["#5C4A42", "#6A5B52"], overhang=0.35),
                  floor_h=2.9, levels=2, window="window_multipane_dark", spacing=2.2, door="door_red",
                  extras=["half_timber", "chimneys"]),
    "art_deco": dict(walls=["#F3D9C8", "#BFE3D6", "#F6E7B0", "#E9C6D9"], trim="#FFFDF8",
                     roof=dict(kind="flat", parapet="parapet", cornice=None), radius=2.5, segs=3,
                     floor_h=3.3, levels=3, window="window+eyebrow", spacing=2.4, door="door",
                     extras=["pilasters", "stepped_parapet", "speed_bands"]),
    "brownstone": dict(walls=["#7A4E3A", "#83553F", "#6E4636"], trim="#E3D8C8",
                       roof=dict(kind="flat", parapet="parapet_thin", cornice="cornice_heavy",
                                 cornice_color="#4E4440"),
                       floor_h=3.4, levels=4, window="window_tall+lintel", spacing=2.1, door="door",
                       door_pos="side", door_z=1.6, extras=["stoop", "roof_props"]),
    "modernist": dict(walls=["#5F7489", "#6B7F93"], trim="#F2F3F5",
                      roof=dict(kind="flat", parapet="parapet_thin"), radius=0.2,
                      floor_h=3.4, levels=4, facade="bands", door="door", extras=["roof_props"]),
    "japanese": dict(walls=["#F2EEE6"], trim="#3B2E2A",
                     roof=dict(kind="curved_hip", colors=["#4B5160", "#555B66"], overhang=0.9),
                     floor_h=3.0, levels=2, window="window_multipane_dark", spacing=1.9, door="door",
                     extras=["timber_frame_jp"]),
    "dutch_canal": dict(walls=["#8A4B3A", "#5B3A33", "#A0584A"], trim="#F4F0E8",
                        roof=dict(kind="gable", pitch=55, colors=["#3F3F46"], overhang=0.15, gable_mode="street"),
                        floor_h=3.3, levels=4, window="window_tall", spacing=1.9, door="door_green",
                        extras=["dutch_gable"]),
    # --- East African coast / Dar es Salaam ------------------------------------------------
    "swahili_coastal": dict(walls=["#F4EFE6", "#EFE6D6", "#F2E9DC", "#EDE3D2"], trim="#FBF8F2",
                            roof=dict(kind="flat", parapet="parapet_thin", color="#D9D2C6"), radius=0.3,
                            floor_h=3.4, levels=2, window="window_teak+shutters_teak", spacing=2.6,
                            door="door_swahili", extras=["baraza", "swahili_balcony", "crenellations"]),
    "dar_apartment": dict(walls=["#F2E6C9", "#EAD9B8", "#F3D6C2", "#D7E4D2", "#D9E2EC", "#F5F1E8"], trim="#FAF7F0",
                          roof=dict(kind="flat", parapet="parapet"), radius=0.6, floor_h=3.1, levels=8,
                          window="window_tinted", street_window="window_tinted+balcony_slab", spacing=3.2,
                          ground_windows=False, door="door", bands=True,
                          extras=["shopfront", "water_tanks", "sat_dishes"]),
    "dar_house": dict(walls=["#F3EBDD", "#EADFC8", "#F0E2CF", "#E6EDE4", "#F5E6E0"], trim="#FBF8F2",
                      roof=dict(kind="hip", pitch=22, overhang=0.6,
                                colors=["#A33B32", "#2F6B4F", "#3C5E9C", "#8C2F39", "#9AA3AD", "#A33B32"]),
                      floor_h=3.0, levels=1, window="window_barred", spacing=2.6, door="door",
                      extras=["porch", "boundary_wall", "tank_stand", "garden_trees"]),
    "swahili_house": dict(walls=["#E9DFCF", "#DCCFB8", "#E8D8C4", "#D6D2C8", "#E3C9A8"], trim="#EFE8DC",
                          roof=dict(kind="gable", pitch=16, overhang=0.5,
                                    colors=["#8F8F8A", "#9C7A5E", "#7E8A92", "#A08068", "#8A6A52"]),
                          floor_h=2.9, levels=1, window="window_barred", spacing=2.4, door="door",
                          extras=["baraza"]),
    "informal": dict(walls=["#BDB5A8", "#A89F92", "#C9BCA6", "#B38F6E", "#9C9488", "#C7B9A3"], trim="#8A8178",
                     roof=dict(kind="gable", pitch=11, overhang=0.3,
                               colors=["#8B5A3C", "#7A4E36", "#9A6B4C", "#8E8E88", "#6E7377", "#A47457", "#7F6A5C"]),
                     floor_h=2.6, levels=1, window="window_small_dark", spacing=3.2, door="door",
                     extras=["roof_weights"]),
    "kiosk": dict(walls=["#D8343A", "#F2C230", "#2E7BD0", "#3BAA5C", "#F28C28", "#E8E2D6"], trim="#F4F1EA",
                  roof=dict(kind="shed", pitch=10, overhang=0.7, colors=["#9AA3AD", "#8B5A3C"]),
                  floor_h=2.5, levels=1, facade="none", extras=["kiosk_front"]),
    "beach_banda": dict(walls=["#E9DCC4"], trim="#5E4630", open=True,
                        roof=dict(kind="hip", pitch=48, overhang=0.9, thick=0.35,
                                  colors=["#A88B62", "#9A7F5A", "#B09468"]),
                        floor_h=3.0, levels=1, facade="none", extras=["banda", "palms"]),
}
TYPE_TO_STYLE = {"rowhouse": "fenn_rowhouse", "office": "fenn_office", "house": "fenn_house"}


class Ctx:
    pass


# ------------------------------------------------------------------ helpers
def add_bay(poly, edge_index, width=3.2, depth=0.6):
    ring = np.array(orient(poly, 1.0).exterior.coords)[:-1]
    d = np.roll(ring, -1, axis=0) - ring
    L = np.linalg.norm(d, axis=1)
    i = edge_index % len(ring)
    if L[i] < 6.0:
        return poly
    t = d[i] / L[i]
    n = np.array([t[1], -t[0]])
    mid = ring[i] + d[i] * 0.5
    b1, b2 = mid - t * width / 2, mid + t * width / 2
    bay = Polygon([b1, b2, b2 - t * depth + n * depth, b1 + t * depth + n * depth])
    out = poly.union(bay.buffer(0.01, join_style="mitre"))
    return orient(out, 1.0) if out.geom_type == "Polygon" else poly


def door_u(L, pos):
    return L / 2 if pos == "center" else min(L * 0.2 + 0.8, L - 1.0)


def street_edge_dict(ctx):
    k = street_edge_of(ctx.edges, ctx.street)
    return ctx.edges[k] if k is not None else None


# ------------------------------------------------------------------ extras
def x_portico_pre(ctx, depth=3.2):
    s = ctx.street
    r = Polygon([s["p0"], s["p0"] + s["n"] * depth, s["p1"] + s["n"] * depth, s["p1"]])
    ctx.portico = orient(r, 1.0)
    u = unary_union([ctx.poly, r.buffer(0.01, join_style="mitre")])
    ctx.roof_poly = orient(u.buffer(0), 1.0) if u.geom_type == "Polygon" else ctx.poly


def x_portico(ctx, depth=3.2):
    s = ctx.street
    stone = hex_rgb("#EDE6DA")
    edge_box(ctx.b, s["p0"], s["t"], s["n"], 0.0, s["L"], 0.0, depth + 0.3, 0.0, 0.6, stone)
    for k in range(3):   # front steps
        edge_box(ctx.b, s["p0"], s["t"], s["n"], s["L"] * 0.2, s["L"] * 0.8, depth + 0.3 + k * 0.35,
                 depth + 0.65 + k * 0.35, 0.0, 0.6 - 0.2 * (k + 1), stone)
    n_col = 4 if s["L"] < 13 else 6
    h = ctx.H - 0.6 - 0.75
    for k in range(n_col):
        u = s["L"] * 0.08 + k * (s["L"] * 0.84) / (n_col - 1)
        ctx.inst.append(inst("column", s["p0"] + s["t"] * u + s["n"] * (depth - 0.45), 0.6, s["n"], scale=h / 5.0))
    edge_box(ctx.b, s["p0"], s["t"], s["n"], 0.0, s["L"], 0.0, depth, ctx.H - 0.75, ctx.H, ctx.trim, top=False)


def x_porch(ctx, depth=2.4):
    s = ctx.street
    e = street_edge_dict(ctx)
    if e is None or s["L"] < 5:
        return
    deck = 0.35
    ph = min(ctx.floor_h, 3.0) - 0.4
    p0, t, n = s["p0"], s["t"], s["n"]
    u0, u1 = 0.4, s["L"] - 0.4
    edge_box(ctx.b, p0, t, n, u0, u1, 0.0, depth, 0.0, deck, hex_rgb("#D9CFC2"))
    for k in range(int((u1 - u0) // 2.3) + 1):
        u = u0 + 0.2 + k * (u1 - u0 - 0.4) / max(int((u1 - u0) // 2.3), 1)
        ctx.inst.append(inst("column_slim", p0 + t * u + n * (depth - 0.25), deck, n, scale=ph / 5.0))
    ring = np.array([p0 + t * u0, p0 + t * u0 + n * depth, p0 + t * u1 + n * depth, p0 + t * u1])
    host = roofs.offset_convex(ring, 0.25)
    R = roofs.ConvexRoof(host, deck + ph, 14.0, gable=(0, 2, 3))
    roofs.build_convex_roof(ctx.b, R, ctx.roofc)
    roofs.roof_boards(ctx.b, R, host, ctx.trim, depth=0.18)


def x_turret(ctx, r=1.8):
    s = ctx.street
    c = s["p1"].copy()
    top = ctx.H + 2.6
    circ = orient(Point(c).buffer(r, quad_segs=3), 1.0)
    edges = build_walls(ctx.b, circ, top, ctx.wall)
    ring = np.array(circ.exterior.coords)[:-1]
    for f in range(1, int(top // ctx.floor_h) + 1):
        sweep(ctx.b, ring, PROFILES["band"], f * ctx.floor_h - 0.09, ctx.trim, support=0.0)
    away = c - np.array(ctx.poly.centroid.coords[0])
    base = math.atan2(away[1], away[0])
    for f in range(int(top // ctx.floor_h)):
        y = f * ctx.floor_h + 0.9
        if y + 1.6 > top - 0.4:
            continue
        for da in (-0.9, 0.0, 0.9):
            a = base + da
            d = np.array([math.cos(a), math.sin(a)])
            ctx.inst.append(inst("window_tall" if f else "window", c + d * r, y, d))
    roofs.cone(ctx.b, c, r + 0.25, 5.2, top, ctx.roofc, sections=12, flare=0.12, finial=1.2,
               finial_color=hex_rgb("#3A3A40"))


def x_stoop(ctx):
    e = street_edge_dict(ctx)
    if e is None:
        return
    u = door_u(e["L"], ctx.S.get("door_pos", "center"))
    ctx.inst.append(inst("stoop", e["p0"] + e["t"] * u, 0.0, e["n"]))


def x_dormers(ctx):
    if ctx.roof is None or ctx.roof.top_z - ctx.H < 2.0:
        return
    s = ctx.street
    k = 2 if s["L"] < 10 else 3
    for i in range(k):
        u = s["L"] * (i + 1) / (k + 1)
        p = s["p0"] + s["t"] * u - s["n"] * 1.4
        z = ctx.roof.z(p)
        if z is not None:
            ctx.inst.append(inst("dormer", p, z - 0.6, s["n"]))


def x_chimneys(ctx):
    if ctx.roof is None or not ctx.roof.roofs:
        return
    ring = np.array(orient(ctx.poly.minimum_rotated_rectangle, 1.0).exterior.coords)[:-1]
    L = [np.linalg.norm(ring[(i + 1) % 4] - ring[i]) for i in range(4)]
    short = sorted(range(4), key=lambda i: L[i])[:2]
    for i in short[: (2 if hsh(ctx.bid, 3) else 1)]:
        a, b_ = ring[i], ring[(i + 1) % 4]
        mid = (a + b_) / 2
        inward = np.array(ctx.poly.centroid.coords[0]) - mid
        p = mid + inward / np.linalg.norm(inward) * 0.9
        z = ctx.roof.z(p)
        if z is not None:
            ctx.inst.append(inst("chimney_brick", p, z - 0.7, inward / np.linalg.norm(inward)))


def x_roof_props(ctx):
    if ctx.flat_core is None or ctx.flat_core.area < 6.0:
        return
    rng = np.random.default_rng(hsh(ctx.bid, 2 ** 31))
    area = ctx.flat_core.buffer(-0.6)
    placed = 0
    for _ in range(40):
        if placed >= min(3, 1 + int(ctx.flat_core.area // 60)) or area.is_empty:
            break
        minx, miny, maxx, maxy = area.bounds
        pt = (rng.uniform(minx, maxx), rng.uniform(miny, maxy))
        if area.contains(Point(pt)):
            a = rng.uniform(0, 2 * math.pi)
            ctx.inst.append(inst("chimney", pt, ctx.roof_z, (math.cos(a), math.sin(a)), ao_blob=True))
            placed += 1


def x_half_timber(ctx):
    dark = hex_rgb("#4A3426")
    brick = hex_rgb("#9E5B45")
    fh, H = ctx.floor_h, ctx.H
    for e in ctx.edges:
        if e["hole"]:
            continue
        p0, t, n, L = e["p0"], e["t"], e["n"], e["L"]
        wall_strip(ctx.b, p0, p0 + t * L, n, 0.0, fh, brick, offset=0.012)
        slots = window_slots(L, ctx.S["spacing"])
        busy = [(u - 0.62, u + 0.62) for u in slots]
        u = 0.1
        while u < L - 0.1:
            if not any(a < u < b for a, b in busy):
                wall_strip(ctx.b, p0 + t * (u - 0.09), p0 + t * (u + 0.09), n, fh, H, dark, offset=0.02)
            u += 1.05
        for z in [fh] + [fh * f for f in range(2, ctx.levels)] + [H - 0.22]:
            wall_strip(ctx.b, p0, p0 + t * L, n, z, z + 0.22, dark, offset=0.022)
        for f in range(1, ctx.levels):
            z0, z1 = f * fh + 0.25, min((f + 1) * fh, H) - 0.25
            for a, sgn in ((0.15, 1), (L - 0.15, -1)):
                if L < 3:
                    continue
                q0 = p0 + t * a + n * 0.024
                q1 = p0 + t * (a + sgn * 1.0) + n * 0.024
                w = t * 0.09 * sgn
                pts = [(*(q0 - w), z0), (*(q0 + w), z0), (*(q1 + w), z1), (*(q1 - w), z1)]
                if sgn < 0:
                    pts = [pts[1], pts[0], pts[3], pts[2]]
                ids = [ctx.b.v(p, (n[0], n[1], 0.0), dark) for p in pts]
                ctx.b.quad(*ids)


def x_pilasters(ctx):
    for e in ctx.edges:
        if e["hole"] or e["L"] < 4:
            continue
        us = [0.3, e["L"] - 0.3] + ([e["L"] / 2] if e["L"] > 9 else [])
        for u in us:
            edge_box(ctx.b, e["p0"], e["t"], e["n"], u - 0.25, u + 0.25, -0.05, 0.18, 0.0, ctx.H + 1.0, ctx.trim)


def x_stepped_parapet(ctx):
    s = ctx.street
    w = min(s["L"] * 0.5, 9.0)
    u0 = s["L"] / 2 - w / 2
    shape = [(0, 0), (w, 0), (w, 1.0), (w * 0.8, 1.0), (w * 0.8, 1.8), (w * 0.62, 1.8), (w * 0.62, 2.6),
             (w * 0.38, 2.6), (w * 0.38, 1.8), (w * 0.2, 1.8), (w * 0.2, 1.0), (0, 1.0)]
    panel(ctx.b, s["p0"] + s["t"] * u0 - s["n"] * 0.2, s["t"], s["n"], shape, 0.38, ctx.trim, z_base=ctx.H)


def x_speed_bands(ctx):
    for ring, hole in rings_of(ctx.poly):
        if hole:
            continue
        for dz in (1.3, 1.75, 2.2):
            sweep(ctx.b, ring, PROFILES["band"], ctx.H - dz, ctx.trim, support=0.0)


def x_mission_parapet(ctx):
    s = ctx.street
    w = min(s["L"] * 0.6, 8.0)
    u0 = s["L"] / 2 - w / 2
    us = np.linspace(0, w, 15)
    top = [(u, 0.45 + 1.9 * max(0.0, math.cos(math.pi * (u - w / 2) / w)) ** 1.6) for u in us]
    shape = [(0.0, 0.0), (w, 0.0)] + top[::-1]
    shape = [p for i, p in enumerate(shape) if i == 0 or np.hypot(p[0] - shape[i - 1][0], p[1] - shape[i - 1][1]) > 1e-3]
    panel(ctx.b, s["p0"] + s["t"] * u0 - s["n"] * 0.15, s["t"], s["n"], shape, 0.32, ctx.wall, z_base=ctx.H - 0.1)
    ctx.inst.append(inst("window_round", s["p0"] + s["t"] * (s["L"] / 2) + s["n"] * 0.17, ctx.H + 0.55,
                         s["n"], scale=0.7))


def x_arcade(ctx):
    s = ctx.street
    if s["L"] < 8:
        return
    sc = ctx.floor_h / 3.6
    bw = 3.0 * sc
    nb = int(s["L"] * 0.92 // bw)
    if nb < 2:
        return
    u0 = (s["L"] - nb * bw) / 2
    d = 2.4
    for k in range(nb):
        u = u0 + bw * (k + 0.5)
        ctx.inst.append(inst("arch_bay", s["p0"] + s["t"] * u + s["n"] * d, 0.0, s["n"], scale=sc))
    edge_box(ctx.b, s["p0"], s["t"], s["n"], u0, s["L"] - u0, 0.0, d + 0.45 * sc, 3.6 * sc, 3.6 * sc + 0.3, ctx.wall)
    for ua, ub in ((u0 - 0.25, u0), (s["L"] - u0, s["L"] - u0 + 0.25)):   # loggia end walls
        edge_box(ctx.b, s["p0"], s["t"], s["n"], ua, ub, 0.0, d + 0.45 * sc, 0.0, 3.6 * sc, ctx.wall, top=False)


def x_stacked_cubes(ctx):
    rng = np.random.default_rng(hsh(ctx.bid, 997))
    bx0, by0, bx1, by1 = ctx.poly.bounds
    w, d = (bx1 - bx0) * 0.55, (by1 - by0) * 0.6
    if w < 3 or d < 3:
        return
    cx = bx0 if rng.random() < 0.5 else bx1 - w
    cy = by0 if rng.random() < 0.5 else by1 - d
    sub = Polygon([(cx, cy), (cx + w, cy), (cx + w, cy + d), (cx, cy + d)]).intersection(ctx.poly.buffer(-0.6))
    if sub.is_empty or sub.geom_type != "Polygon" or sub.area < 8:
        return
    sub = round_corners(orient(sub, 1.0), 0.45, 2)
    H0, H2 = ctx.H, ctx.H + 2.9
    edges = build_walls(ctx.b, sub, H2, ctx.wall, z0=H0)
    core = parapet_and_roof(ctx.b, sub, H2, ctx.trim, profile="parapet_soft", roof_color=hex_rgb("#F4F2EE"))
    ctx.inst += facade_windows(edges, 1, 2.9, H2, "window_small_blue", 2.4, z_base=H0, sill=1.0, top_margin=0.6,
                               street=ctx.street, door="door_blue")
    if rng.random() < 0.6 and core is not None:
        c = np.array(core.centroid.coords[0])
        r = min(w, d) * 0.28
        z = roofs.drum(ctx.b, c, r * 1.02, H2, 0.5, ctx.wall, sides=12)
        roofs.dome(ctx.b, c, r, z, "hemi", hex_rgb("#2C5FA8"), sections=14, finial=0.6,
                   finial_color=hex_rgb("#F4F2EE"))


def x_timber_frame_jp(ctx):
    dark = hex_rgb("#3B2E2A")
    for e in ctx.edges:
        if e["hole"]:
            continue
        p0, t, n, L = e["p0"], e["t"], e["n"], e["L"]
        k = max(int(L // 1.8), 1)
        for i in range(k + 1):
            u = min(max(L * i / k, 0.1), L - 0.1)
            wall_strip(ctx.b, p0 + t * (u - 0.1), p0 + t * (u + 0.1), n, 0.0, ctx.H, dark, offset=0.02)
        for z in [0.0] + [ctx.floor_h * f for f in range(1, ctx.levels)] + [ctx.H - 0.3]:
            wall_strip(ctx.b, p0, p0 + t * L, n, z, z + 0.3, dark, offset=0.022)


def x_dutch_gable(ctx):
    """Crow-stepped gable panel on the street façade (covers the gable end of the roof)."""
    s = ctx.street
    L = s["L"]
    G = min(L * 0.95, 7.0)
    st = L * 0.12
    h = [G * 0.25, G * 0.5, G * 0.75]
    right = [(L, 0.0), (L, h[0]), (L - st, h[0]), (L - st, h[1]), (L - 2 * st, h[1]), (L - 2 * st, h[2]),
             (L - 3 * st, h[2]), (L - 3 * st, G)]
    left = [(L - u, v) for u, v in right][::-1]
    shape = [(0.0, 0.0)] + right + left[:-1]
    shape = [p for i, p in enumerate(shape) if i == 0 or np.hypot(p[0] - shape[i - 1][0], p[1] - shape[i - 1][1]) > 1e-3]
    panel(ctx.b, s["p0"] - s["n"] * 0.05, s["t"], s["n"], shape, 0.3, ctx.wall, z_base=ctx.H - 0.05)
    ctx.inst.append(inst("window_tall", s["p0"] + s["t"] * (L / 2) + s["n"] * 0.25, ctx.H + 0.5, s["n"], scale=0.8))
    if L > 5:
        for uu in (L * 0.27, L * 0.73):
            ctx.inst.append(inst("window", s["p0"] + s["t"] * uu + s["n"] * 0.25, ctx.H + 0.25, s["n"], scale=0.65))


def x_baraza(ctx):
    """Stone bench along the street wall, broken at the door (Swahili coast)."""
    s = ctx.street
    if s["L"] < 3:
        return
    du = s["L"] / 2
    for a, b_ in ((0.4, du - 1.1), (du + 1.1, s["L"] - 0.4)):
        if b_ - a > 0.8:
            edge_box(ctx.b, s["p0"], s["t"], s["n"], a, b_, 0.0, 0.55, 0.0, 0.45, ctx.trim)


def x_swahili_balcony(ctx):
    e = street_edge_dict(ctx)
    if e is None or e["L"] < 4 or ctx.levels < 2:
        return
    for f in range(1, ctx.levels):
        ctx.inst.append(inst("swahili_balcony", e["p0"] + e["t"] * e["L"] / 2, f * ctx.floor_h, e["n"]))


def x_crenellations(ctx):
    for e in ctx.edges:
        if e["hole"]:
            continue
        k = int(e["L"] // 0.95)
        for i in range(k):
            u = (i + 0.5) * e["L"] / k
            ctx.inst.append(inst("merlon", e["p0"] + e["t"] * u - e["n"] * 0.075, ctx.H + 0.38, e["n"]))


def x_shopfront(ctx):
    """Ground-floor shops with roller shutters on every street-ish edge longer than 4 m + canopy."""
    for e in ctx.edges:
        if e["hole"] or e["L"] < 4:
            continue
        k = max(int(e["L"] // 3.4), 1)
        for i in range(k):
            u = (i + 0.5) * e["L"] / k
            ctx.inst.append(inst("shop_shutter", e["p0"] + e["t"] * u, 0.0, e["n"]))
        edge_box(ctx.b, e["p0"], e["t"], e["n"], 0.0, e["L"], 0.0, 1.4, 3.15, 3.35, ctx.trim)


def x_water_tanks(ctx):
    if ctx.flat_core is None or ctx.flat_core.area < 4:
        return
    rng = np.random.default_rng(hsh(ctx.bid, 31337))
    area = ctx.flat_core.buffer(-0.9)
    if area.is_empty:
        return
    n = min(1 + int(ctx.flat_core.area // 160), 3)
    placed, tries = [], 0
    while len(placed) < n and tries < 60:
        tries += 1
        minx, miny, maxx, maxy = area.bounds
        p = np.array([rng.uniform(minx, maxx), rng.uniform(miny, maxy)])
        if area.contains(Point(p)) and all(np.linalg.norm(p - q) > 1.6 for q in placed):
            placed.append(p)
            ctx.inst.append(inst("water_tank", p, ctx.roof_z, (1, 0)))


def x_sat_dishes(ctx):
    if ctx.flat_core is None or ctx.flat_core.area < 20:
        return
    rng = np.random.default_rng(hsh(ctx.bid, 4242))
    ring = np.array(ctx.flat_core.exterior.coords)[:-1]
    for _ in range(min(3, 1 + int(ctx.flat_core.area // 150))):
        i = int(rng.integers(len(ring)))
        p = ring[i] + (np.array(ctx.flat_core.centroid.coords[0]) - ring[i]) * 0.12
        a = rng.uniform(0, 2 * math.pi)
        ctx.inst.append(inst("sat_dish", p, ctx.roof_z, (math.cos(a), math.sin(a))))


def x_boundary_wall(ctx, gap=3.0):
    """Compound wall (ukuta) with a steel gate on the street side: typical planned Dar suburbs.
    Note: OSM often maps these separately as barrier=wall; disable this extra when importing those."""
    try:
        outer = ctx.poly.buffer(gap + 0.2, join_style="mitre").minimum_rotated_rectangle
        inner = outer.buffer(-0.2, join_style="mitre")
        ring = orient(outer.difference(inner), 1.0)
    except Exception:
        return
    if ring.is_empty or ring.geom_type != "Polygon":
        return
    prism(ctx.b, ring, 0.0, 2.3, ctx.wall * 0.97, top=True)
    rr = np.array(orient(outer, 1.0).exterior.coords)[:-1]
    s = ctx.street
    best = max(range(len(rr)), key=lambda i: (((rr[i] + rr[(i + 1) % len(rr)]) / 2 - s["mid"]) @ s["n"]))
    a, b_ = rr[best], rr[(best + 1) % len(rr)]
    t = (b_ - a) / np.linalg.norm(b_ - a)
    n = np.array([t[1], -t[0]])
    gpos = (a + b_) / 2 + n * 0.02
    ctx.inst.append(inst("gate", gpos, 0.0, n))


def x_tank_stand(ctx):
    rr = np.array(orient(ctx.poly.minimum_rotated_rectangle, 1.0).exterior.coords)[:-1]
    s = ctx.street
    back = min(range(len(rr)), key=lambda i: (rr[i] - s["mid"]) @ s["n"])
    c = np.array(ctx.poly.centroid.coords[0])
    p = rr[back] + (rr[back] - c) / np.linalg.norm(rr[back] - c) * 1.6
    ctx.inst.append(inst("water_tank_stand", p, 0.0, s["n"]))


def x_roof_weights(ctx):
    if ctx.roof is None:
        return
    rng = np.random.default_rng(hsh(ctx.bid, 777))
    minx, miny, maxx, maxy = ctx.poly.bounds
    k = 2 + int(rng.integers(4))
    for _ in range(k * 4):
        if k <= 0:
            break
        p = np.array([rng.uniform(minx, maxx), rng.uniform(miny, maxy)])
        if ctx.poly.buffer(-0.4).contains(Point(p)):
            z = ctx.roof.z(p)
            if z is not None:
                ctx.inst.append(inst("roof_weight", p, z + 0.02, (1, 0), scale=float(rng.uniform(0.5, 0.75))))
                k -= 1


def x_kiosk_front(ctx):
    """Serving hatch + counter shelf; the deep front roof overhang is the awning. Bright paint, no branding."""
    s = ctx.street
    w = min(s["L"] - 0.4, 1.8)
    u0 = s["L"] / 2 - w / 2
    dark = hex_rgb("#2A2624")
    wall_strip(ctx.b, s["p0"] + s["t"] * u0, s["p0"] + s["t"] * (u0 + w), s["n"], 0.9, 2.0, dark, offset=0.015)
    edge_box(ctx.b, s["p0"], s["t"], s["n"], u0 - 0.1, u0 + w + 0.1, 0.0, 0.45, 0.85, 0.95, hex_rgb("#E8E2D6"))


def x_banda(ctx):
    """Open-sided beach shelter: platform + mangrove poles around the outline (roof is the style roof)."""
    prism(ctx.b, ctx.poly.buffer(0.3, join_style="mitre"), 0.0, 0.25, hex_rgb("#D9C9A8"))
    for ring, hole in rings_of(ctx.poly):
        if hole:
            continue
        n = len(ring)
        for i in range(n):
            a, b_ = ring[i], ring[(i + 1) % n]
            L = np.linalg.norm(b_ - a)
            k = max(int(L // 2.6), 1)
            for j in range(k):
                p = a + (b_ - a) * j / k
                ctx.inst.append(inst("pole_wood", p, 0.25, (1, 0), scale=(ctx.H - 0.25) / 3.0))


def x_garden_trees(ctx):
    """1-3 trees (palms and shade trees) in the yard between the house and its compound wall."""
    rng = np.random.default_rng(hsh(ctx.bid, 2024))
    yard = ctx.poly.buffer(2.6, join_style="mitre").minimum_rotated_rectangle.difference(ctx.poly.buffer(1.0))
    if yard.is_empty:
        return
    placed = 0
    for _ in range(40):
        if placed >= 1 + int(rng.integers(3)):
            break
        minx, miny, maxx, maxy = yard.bounds
        p = np.array([rng.uniform(minx, maxx), rng.uniform(miny, maxy)])
        if yard.contains(Point(p)):
            kind = ["tree_palm", "tree_palm_b", "tree_puff"][int(rng.integers(3))]
            a = rng.uniform(0, 2 * math.pi)
            ctx.inst.append(inst(kind, p, 0.0, (math.cos(a), math.sin(a)), scale=float(rng.uniform(0.75, 1.0))))
            placed += 1


def x_palms(ctx):
    """A couple of coconut palms around beach bandas / coastal buildings."""
    rng = np.random.default_rng(hsh(ctx.bid, 99))
    c = np.array(ctx.poly.centroid.coords[0])
    r = math.sqrt(ctx.poly.area / math.pi) + 2.5
    for k in range(2):
        a = rng.uniform(0, 2 * math.pi)
        p = c + np.array([math.cos(a), math.sin(a)]) * r * rng.uniform(1.0, 1.6)
        ctx.inst.append(inst("tree_palm" if k % 2 == 0 else "tree_palm_b", p, 0.0,
                             (math.cos(a), math.sin(a)), scale=float(rng.uniform(0.8, 1.05))))


EXTRAS = {
    "portico": x_portico, "porch": x_porch, "turret": x_turret, "stoop": x_stoop, "dormers": x_dormers,
    "chimneys": x_chimneys, "roof_props": x_roof_props, "half_timber": x_half_timber,
    "pilasters": x_pilasters, "stepped_parapet": x_stepped_parapet, "speed_bands": x_speed_bands,
    "mission_parapet": x_mission_parapet, "arcade": x_arcade, "stacked_cubes": x_stacked_cubes,
    "timber_frame_jp": x_timber_frame_jp, "dutch_gable": x_dutch_gable,
    "baraza": x_baraza, "swahili_balcony": x_swahili_balcony, "crenellations": x_crenellations,
    "shopfront": x_shopfront, "water_tanks": x_water_tanks, "sat_dishes": x_sat_dishes,
    "boundary_wall": x_boundary_wall, "tank_stand": x_tank_stand, "roof_weights": x_roof_weights,
    "kiosk_front": x_kiosk_front, "banda": x_banda, "garden_trees": x_garden_trees, "palms": x_palms,
}
PRE = {"portico": x_portico_pre}
GEOMETRY_ONLY = {"baraza", "boundary_wall", "kiosk_front", "half_timber", "pilasters", "stepped_parapet", "speed_bands", "mission_parapet",
                 "timber_frame_jp", "dutch_gable", "stacked_cubes", "turret", "porch"}


# ------------------------------------------------------------------ builder
def build_styled(spec, lod=0):
    style = spec.get("style") or TYPE_TO_STYLE.get(spec.get("type", "rowhouse"), "fenn_rowhouse")
    S = STYLES[style]
    bid = str(spec.get("id", "b"))
    floor_h = float(spec.get("floor_height", S["floor_h"]))
    if "height" in spec:
        H = float(spec["height"])
        levels = int(spec.get("levels", max(1, round(H / floor_h))))
    else:
        levels = int(spec.get("levels", S["levels"]))
        H = levels * floor_h
    floor_h = H / levels
    wall = hex_rgb(S["walls"][int(spec["palette"]) % len(S["walls"])]) if "palette" in spec else pick(S["walls"], bid)
    trim = hex_rgb(S["trim"])
    rcfg = dict(S["roof"])
    if isinstance(spec.get("roof"), str):          # e.g. from OSM roof:shape or extract_footprints
        rk = {"gabled": "gable", "hipped": "hip", "pyramidal": "hip", "flat": "flat"}.get(spec["roof"], spec["roof"])
        if rk in ("flat", "hip", "gable", "mansard", "curved_hip"):
            rcfg["kind"] = rk
            if rk != "flat":
                rcfg.setdefault("pitch", 30)
                rcfg.setdefault("colors", ["#F08F78", "#8EA4D6", "#A8A2B4", "#C9B9B4"])
    if "roof_colors" in spec:                       # e.g. OSM roof:colour / roof:material
        rcfg["colors"] = list(spec["roof_colors"])
    roofc = pick(rcfg.get("colors", ["#CFC8CC"]), bid + "r") if "colors" in rcfg else hex_rgb(rcfg.get("color", "#CFC8CC"))
    extras = list(spec.get("extras", S.get("extras", [])))

    b = MeshBuilder()
    instances = []
    spec2 = dict(spec)
    spec2["_orig_ring"] = spec["footprint"]
    for part in repair(Polygon(spec["footprint"], spec.get("holes", []))):
        ctx = Ctx()
        ctx.b, ctx.inst, ctx.S, ctx.bid, ctx.lod = b, [], S, bid, lod
        ctx.H, ctx.levels, ctx.floor_h = H, levels, floor_h
        ctx.wall, ctx.trim, ctx.roofc = wall, trim, roofc
        st = street_edge(part, spec2)
        poly = part
        if "bay" in extras and lod == 0:
            poly = add_bay(poly, st)
        radius = float(spec.get("corner_radius", S.get("radius", 0.0)))
        if radius > 0 and lod < 2:
            segs = S.get("segs", 2) if lod == 0 else 1
            if radius >= 4.0:
                segs = max(segs, 4)
            poly = round_corners(poly, radius, segs)
        ctx.poly = ctx.roof_poly = poly
        ctx.street = street_info(part, st)
        ctx.roof, ctx.flat_core, ctx.roof_z = None, None, H
        for x in extras:
            if x in PRE:
                PRE[x](ctx)

        ctx.edges = [] if S.get("open") else build_walls(b, poly, H, wall)
        kind = rcfg["kind"]
        if lod == 2:
            ctx.flat_core = build_flat_roof(b, poly, H, parapet_t=0.0, ao_ring=0.0)
        elif kind == "flat":
            cc = hex_rgb(rcfg["cornice_color"]) if "cornice_color" in rcfg else trim
            prof = rcfg.get("parapet", "parapet") if lod == 0 else "parapet_lod1"
            if rcfg.get("cornice") and lod == 0:
                for ring, _ in rings_of(poly):
                    drop = 1.0 if rcfg["cornice"] == "cornice_heavy" else 0.62
                    sweep(b, ring, PROFILES[rcfg["cornice"]], H - drop, cc,
                          ao_fn=lambda k, p, n: 0.78 if n[1] < -0.3 else 1.0)
            ctx.flat_core = parapet_and_roof(b, poly, H, trim, profile=prof,
                                             roof_color=hex_rgb(rcfg["color"]) if "color" in rcfg else None)
            ctx.roof_z = H
        elif kind == "curved_hip" and classify(poly) in ("rect",):
            ring = np.array(orient(poly, 1.0).exterior.coords)[:-1]
            roofs.curved_hip(b, ring, H, roofc, overhang=rcfg.get("overhang", 0.9))
        else:
            k2 = "hip" if kind == "curved_hip" else kind
            ctx.roof = roofs.roof_for_footprint(
                b, ctx.roof_poly, H, kind=k2, pitch=rcfg.get("pitch", 30), color=roofc, wall_color=wall,
                trim_color=trim, overhang=rcfg.get("overhang", 0.4), gable_mode=rcfg.get("gable_mode", "short"),
                street_dir=ctx.street["t"], thick=rcfg.get("thick", 0.12))

        if lod < 2:
            for ring, hole in rings_of(poly):
                if S.get("plinth") and not hole:
                    sweep(b, ring, PROFILES["plinth"], 0.0, hex_rgb("#E7E0D4"), support=0.0)
                if S.get("bands"):
                    for f in range(1, levels):
                        sweep(b, ring, PROFILES["band"], f * floor_h - 0.09, trim)
            if S.get("facade") == "bands":
                for ring, hole in rings_of(poly):
                    for f in range(1, levels):
                        sweep(b, ring, PROFILES["slab"], f * floor_h - 0.21, trim, support=0.0)
                    sweep(b, ring, PROFILES["slab"], 0.0, trim, support=0.0)

        if S.get("facade") == "none":
            pass
        elif lod == 0 and S.get("facade", "punched") == "punched":
            top_margin = (0.9 if levels > 1 else 0.7) if rcfg["kind"] == "flat" else 0.35
            ctx.inst += facade_windows(
                ctx.edges, levels, floor_h, H, S["window"], S["spacing"],
                first=0 if S.get("ground_windows", True) else 1, top_margin=top_margin,
                street=ctx.street, door=S.get("door"), door_pos=S.get("door_pos", "center"),
                street_module=S.get("street_window"), door_z=S.get("door_z", 0.0))
        elif lod == 0 and S.get("door"):
            e = street_edge_dict(ctx)
            if e is not None:
                ctx.inst.append(inst(S["door"], e["p0"] + e["t"] * e["L"] / 2, 0.0, e["n"]))

        if lod < 2:
            for x in extras:
                if x == "bay" or (lod == 1 and x not in GEOMETRY_ONLY):
                    continue
                EXTRAS[x](ctx)
        instances += ctx.inst if lod == 0 else []
    return b, instances
