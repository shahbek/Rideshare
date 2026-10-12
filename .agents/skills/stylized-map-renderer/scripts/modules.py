"""Library modules (instanced). Every module is returned in glTF space:
x along the wall, y up, +z outward (front), origin = bottom centre on the wall surface
(free-standing pieces like columns/domes: origin = bottom centre).

Modules are authored internally Z-up with the front facing -Y, then converted.
Composite names combine a base with accessories:  'window_tall+lintel', 'window_multipane+shutters_green',
'window+eyebrow', 'window_arched+balcony'. get_module(name) caches results.
"""
import math

import numpy as np
from shapely.geometry import Polygon, Point
from shapely.geometry.polygon import orient

from geomlib import (MeshBuilder, hex_rgb, sweep, earcut_polygon, lathe, box, panel, prism, to_gltf,
                     flat_poly)

C = {k: hex_rgb(v) for k, v in {
    "frame": "#EFE8DE", "frame_dark": "#5A4637", "frame_blue": "#2F6DB5", "frame_green": "#2F5D46",
    "glass_top": "#4F6680", "glass_bot": "#7389A3", "door": "#6B4A3A", "door_blue": "#2C5FA8",
    "door_green": "#2F5D46", "door_red": "#9C3B32", "stone": "#EDE6DA", "iron": "#3A3A40",
    "brick": "#9E5B45", "chimney": "#E4DCD3", "lead": "#8E9AA8", "gold": "#D8B45A",
    "white": "#F6F4EF", "wood": "#7A5236", "clock": "#F7F3E8",
    "frame_teak": "#6B4A32", "teak": "#5C3B26", "brass": "#C9A24A", "alu": "#C9CED3",
    "tint_top": "#3E6F7A", "tint_bot": "#6FA3AC", "tank": "#454B53", "galv": "#A9B0B6",
    "concrete": "#E4E0D8", "shutter": "#9AA0A6", "pole": "#6E5236",
}.items()}

_CACHE = {}


def _wall_local_to_internal(tmp):
    """(x, up, depth) builder -> internal Z-up with front -Y."""
    out = MeshBuilder()
    T = lambda p: np.array([p[0], -p[2], p[1]])
    out.append(tmp, transform=T, normal_transform=T)
    return out


def _to_gltf(b):
    out = MeshBuilder()
    out.append(b, transform=lambda p: to_gltf(p), normal_transform=lambda n: to_gltf(n))
    return out


# ------------------------------------------------------------------ outlines
def outline(shape, w, h):
    if shape == "rect":
        return [(-w / 2, 0), (w / 2, 0), (w / 2, h), (-w / 2, h)]
    if shape == "arch":
        r = w / 2
        s = h - r
        pts = [(-w / 2, 0), (w / 2, 0), (w / 2, s)]
        pts += [(r * math.cos(a), s + r * math.sin(a)) for a in np.linspace(0, math.pi, 9)[1:-1]]
        return pts + [(-w / 2, s)]
    if shape == "lancet":
        r = w * 0.85
        th_a = math.acos((r - w / 2) / r)
        s = h - r * math.sin(th_a)
        cx = w / 2 - r
        right = [(cx + r * math.cos(a), s + r * math.sin(a)) for a in np.linspace(0, th_a, 5)]
        left = [(-x, y) for x, y in reversed(right[:-1])]
        return [(-w / 2, 0), (w / 2, 0)] + right + left
    if shape == "round":
        return [(h / 2 * math.cos(a), h / 2 + h / 2 * math.sin(a)) for a in np.linspace(0, 2 * math.pi, 17)[:-1]]
    raise ValueError(shape)


# ------------------------------------------------------------------ windows & doors
def window(shape="rect", w=1.0, h=1.4, frame=None, glass=None, panes=0, sill=True, ft=1.0,
           spokes=0, fill=None):
    """Frame ring swept along the outline + glass (or a solid fill for doors) + muntins + sill."""
    frame = C["frame"] if frame is None else frame
    gt, gb = (C["glass_top"], C["glass_bot"]) if glass is None else glass
    tmp = MeshBuilder()
    ring = np.array(outline(shape, w, h))
    ring = np.array(orient(Polygon(ring), 1.0).exterior.coords)[:-1]
    prof = [(0.05 * ft, 0.0), (0.05 * ft, 0.10), (-0.02 * ft, 0.12), (-0.05 * ft, 0.0)]
    sweep(tmp, ring, prof, 0.0, frame, support=0.0)
    inner = Polygon(ring).buffer(-0.04 * ft, join_style="mitre")
    verts, tris = earcut_polygon(orient(inner, 1.0))
    v0, v1 = inner.bounds[1], inner.bounds[3]
    ids = []
    for x, y in verts:
        t = (y - v0) / max(v1 - v0, 1e-6)
        col = fill if fill is not None else gb + (gt - gb) * t
        ids.append(tmp.v((x, y, 0.03), (0, 0, 1), col, t=t))
    for a, b_, c in tris:
        tmp.tri(ids[a], ids[b_], ids[c])
    # muntins (front-only flat bars)
    x0, y0, x1, y1 = inner.bounds

    def bar(xa, xb, ya, yb):
        q = [tmp.v((xa, ya, 0.06), (0, 0, 1), frame), tmp.v((xb, ya, 0.06), (0, 0, 1), frame),
             tmp.v((xb, yb, 0.06), (0, 0, 1), frame), tmp.v((xa, yb, 0.06), (0, 0, 1), frame)]
        tmp.quad(*q)
    if panes >= 2:
        bar(-0.025, 0.025, y0, y1)
    if panes >= 4:
        top = y1 if shape == "rect" else y0 + (y1 - y0) * 0.62
        for k in range(1, 3 if panes >= 6 else 2):
            yy = y0 + (top - y0) * k / (3 if panes >= 6 else 2)
            bar(x0, x1, yy - 0.025, yy + 0.025)
    if spokes:
        cy = (y0 + y1) / 2
        r = (y1 - y0) / 2
        for k in range(spokes):
            a = math.pi * k / spokes
            dx, dy = math.cos(a) * r, math.sin(a) * r
            nx, ny = -math.sin(a) * 0.03, math.cos(a) * 0.03
            q = [tmp.v((-dx - nx, cy - dy - ny, 0.06), (0, 0, 1), frame),
                 tmp.v((dx - nx, cy + dy - ny, 0.06), (0, 0, 1), frame),
                 tmp.v((dx + nx, cy + dy + ny, 0.06), (0, 0, 1), frame),
                 tmp.v((-dx + nx, cy - dy + ny, 0.06), (0, 0, 1), frame)]
            tmp.quad(*q)
    b = _wall_local_to_internal(tmp)
    if sill and shape != "round":
        box(b, -w / 2 - 0.12, w / 2 + 0.12, -0.18, 0.0, -0.08, 0.0, frame, faces="-y+z+x-x", ao_bottom=0.9)
    return b


def shutters(b, w, h, color):
    for sgn in (-1, 1):
        x0 = sgn * (w / 2 + 0.08)
        x1 = sgn * (w / 2 + 0.08 + w * 0.5)
        xa, xb = min(x0, x1), max(x0, x1)
        box(b, xa, xb, -0.06, 0.0, 0.05, h - 0.05, color, faces="-y+z+x-x")
        for k in range(1, 4):
            z = 0.05 + (h - 0.1) * k / 4
            box(b, xa + 0.04, xb - 0.04, -0.075, -0.06, z - 0.02, z + 0.02, color * 0.8, faces="-y")


def door(w=1.2, h=2.3, color=None, shape="rect"):
    b = window(shape, w, h, frame=C["frame"], fill=color if color is not None else C["door"], sill=False, ft=1.2)
    box(b, -w / 2 - 0.3, w / 2 + 0.3, -0.6, 0.0, 0.0, 0.15, C["stone"], faces="-y+z+x-x")
    return b


def pediment(b, w, z, color, height=0.45, thick=0.15):
    panel(b, (0, 0), (1, 0), (0, -1), [(-w / 2, 0), (w / 2, 0), (0, height)], thick, color, z_base=z, back=False)
    box(b, -w / 2, w / 2, -thick - 0.04, 0.0, z - 0.12, z, color, faces="-y+z+x-x")


# ------------------------------------------------------------------ structural & decorative
def column(h=5.0, r=0.3, color=None, slim=False):
    color = C["stone"] if color is None else color
    b = MeshBuilder()
    box(b, -r * 1.35, r * 1.35, -r * 1.35, r * 1.35, 0, 0.22, color)
    rt = r * (0.85 if not slim else 0.95)
    lathe(b, [(r * 1.15, 0.22), (r, 0.36), (r, 0.5), (rt, h - 0.55), (rt * 1.05, h - 0.45),
              (r * 1.25, h - 0.3)], 12, lambda z: color, ao_fn=lambda z: 0.8 if z < 0.4 else 1.0)
    box(b, -r * 1.45, r * 1.45, -r * 1.45, r * 1.45, h - 0.3, h, color)
    return b


def balcony(w=2.4, d=0.9, color=None, rails=7):
    color = C["iron"] if color is None else color
    b = MeshBuilder()
    box(b, -w / 2, w / 2, -d, 0.0, -0.15, 0.0, C["stone"], faces="-y+z+x-x-z")
    box(b, -w / 2, w / 2, -d, -d + 0.05, 0.95, 1.0, color, faces="-y+z+y")
    for sx in (-w / 2, w / 2 - 0.05):
        box(b, sx, sx + 0.05, -d, 0.0, 0.95, 1.0, color, faces="+z+x-x")
    for k in range(rails + 1):
        x = -w / 2 + 0.05 + (w - 0.1) * k / rails
        box(b, x - 0.02, x + 0.02, -d, -d + 0.04, 0.0, 0.95, color, faces="-y+x-x")
    for k in (1, 2):
        y = -d * k / 3
        for sx in (-w / 2, w / 2 - 0.04):
            box(b, sx, sx + 0.04, y - 0.02, y + 0.02, 0.0, 0.95, color, faces="+x-x")
    return b


def dormer(w=1.6, h=1.4, d=2.4, wall=None, roof=None):
    wall = C["white"] if wall is None else wall
    roof = C["lead"] if roof is None else roof
    b = MeshBuilder()
    box(b, -w / 2, w / 2, 0.0, d, 0.0, h, wall, faces="-y+x-x")
    # gable roof on the dormer
    rh = w * 0.45
    for sgn in (-1, 1):
        a = np.array([0.0, -0.15, h + rh]); c = np.array([sgn * (w / 2 + 0.15), -0.15, h - 0.05])
        e = np.array([sgn * (w / 2 + 0.15), d, h - 0.05]); f = np.array([0.0, d, h + rh])
        n = np.cross(c - a, f - a)
        if n[2] < 0:
            n = -n
        pts = [a, c, e, f] if sgn > 0 else [a, f, e, c]
        ids = [b.v(p, n, roof) for p in pts]
        b.quad(*ids)
    panel(b, (0, 0), (1, 0), (0, -1), [(-w / 2, h), (w / 2, h), (0, h + rh)], 0.02, wall, back=False)
    win = window("rect", w * 0.6, h * 0.75, panes=4)
    b.append(win, transform=lambda p: p + np.array([0, -0.01, h * 0.12]), normal_transform=lambda n: n)
    return b


def chimney(color=None, w=0.7, h=1.0):
    color = C["chimney"] if color is None else color
    from geomlib import round_corners, rings_of
    b = MeshBuilder()
    sq = round_corners(Polygon([(-w / 2, -w / 2), (w / 2, -w / 2), (w / 2, w / 2), (-w / 2, w / 2)]), 0.08, 1)
    prism(b, sq, 0.0, h, color, top=False, ao_bottom=0.7)
    ring = rings_of(sq)[0][0]
    sweep(b, ring, [(0.0, 0.0), (0.06, 0.03), (0.06, 0.13), (-0.12, 0.16)], h, color)
    inner = sq.buffer(-0.12, join_style="mitre")
    flat_poly(b, orient(inner, 1.0), h + 0.16, True, color * 0.55)
    return b


def buttress(h=6.0, w=0.7, d=1.4, color=None):
    color = C["stone"] if color is None else color
    b = MeshBuilder()
    box(b, -w / 2, w / 2, -d, 0.0, 0.0, h * 0.55, color, faces="-y+x-x", ao_bottom=0.75)
    # sloped cap of lower stage
    a, c = np.array([-w / 2, -d, h * 0.55]), np.array([w / 2, -d, h * 0.55])
    e, f = np.array([w / 2, -d * 0.6, h * 0.62]), np.array([-w / 2, -d * 0.6, h * 0.62])
    n = np.cross(c - a, f - a); n = n if n[2] > 0 else -n
    b.quad(*[b.v(p, n, color) for p in (a, c, e, f)])
    box(b, -w / 2 * 0.85, w / 2 * 0.85, -d * 0.6, 0.0, h * 0.55, h * 0.9, color, faces="-y+x-x")
    a, c = np.array([-w * 0.43, -d * 0.6, h * 0.9]), np.array([w * 0.43, -d * 0.6, h * 0.9])
    e, f = np.array([w * 0.43, 0.0, h]), np.array([-w * 0.43, 0.0, h])
    n = np.cross(c - a, f - a); n = n if n[2] > 0 else -n
    b.quad(*[b.v(p, n, color) for p in (a, c, e, f)])
    return b


def arch_bay(w=3.0, h=3.6, opening=2.2, spring=2.0, thick=0.45, color=None):
    """Arcade bay: wall panel with a round-arch opening; piers are what's left of the panel."""
    color = C["stone"] if color is None else color
    b = MeshBuilder()
    r = opening / 2
    hole = [(-r, 0.0), (r, 0.0)] + [(r * math.cos(a), spring + r * math.sin(a))
                                     for a in np.linspace(0, math.pi, 9)] + [(-r, 0.0)]
    hole = list(dict.fromkeys([tuple(np.round(p, 5)) for p in hole]))
    outer = Polygon([(-w / 2, 0), (w / 2, 0), (w / 2, h), (-w / 2, h)])
    shape = outer.difference(Polygon(hole))
    for part in getattr(shape, "geoms", [shape]):
        part = orient(part, 1.0)
        panel(b, (0, 0), (1, 0), (0, -1), list(part.exterior.coords)[:-1], thick, color,
              holes=[list(r_.coords)[:-1] for r_ in part.interiors])
    return b


def small_dome(r=1.0, color=None, drum_color=None):
    import roofs
    color = C["lead"] if color is None else color
    drum_color = C["stone"] if drum_color is None else drum_color
    b = MeshBuilder()
    roofs.drum(b, (0, 0), r * 1.02, 0.0, r * 0.35, drum_color, sides=8)
    roofs.dome(b, (0, 0), r, r * 0.35, "hemi", color, sections=10, finial=r * 0.5, finial_color=C["gold"])
    return b


def stoop(w=2.0, rise=1.6, steps=6, color=None):
    color = C["stone"] if color is None else color
    b = MeshBuilder()
    run = 0.32
    land = 1.1
    box(b, -w / 2, w / 2, -land, 0.0, 0.0, rise, color, faces="-y+z+x-x", ao_bottom=0.8)
    for k in range(steps):
        z1 = rise * (steps - k) / (steps + 1)
        y0 = -land - run * (k + 1)
        box(b, -w / 2, w / 2, y0, y0 + run, 0.0, z1, color, faces="-y+z+x-x", ao_bottom=0.8)
    for sx in (-w / 2 - 0.25, w / 2):
        box(b, sx, sx + 0.25, -land - run * steps, 0.0, 0.0, rise + 0.9, C["iron"] * 1.4, faces="-y+z+x-x")
    return b


def finial_cross(h=2.0, color=None):
    color = C["gold"] if color is None else color
    b = MeshBuilder()
    box(b, -0.07, 0.07, -0.07, 0.07, 0.0, h, color)
    box(b, -h * 0.28, h * 0.28, -0.07, 0.07, h * 0.62, h * 0.72, color)
    return b


def finial_alem(h=2.5, color=None):
    color = C["gold"] if color is None else color
    b = MeshBuilder()
    lathe(b, [(0.12, 0.0), (0.06, h * 0.25), (0.22, h * 0.35), (0.05, h * 0.45), (0.18, h * 0.55),
              (0.04, h * 0.65), (0.0, h * 0.7)], 8, lambda z: color)
    moon = Point(0, 0).buffer(h * 0.16, quad_segs=6).difference(Point(h * 0.07, 0.02).buffer(h * 0.13, quad_segs=6))
    moon = max(getattr(moon, "geoms", [moon]), key=lambda g: g.area)
    pts = [(x, y + h * 0.84) for x, y in list(orient(moon, 1.0).exterior.coords)[:-1]]
    panel(b, (0, 0.03), (1, 0), (0, -1), pts, 0.06, color)
    return b


def clock(r=0.8):
    b = MeshBuilder()
    circ = [(r * math.cos(a), r + r * math.sin(a)) for a in np.linspace(0, 2 * math.pi, 17)[:-1]]
    panel(b, (0, 0), (1, 0), (0, -1), circ, 0.08, C["clock"], back=False)
    for a in (math.pi / 2, math.pi / 6):
        box(b, -0.03, 0.03, -0.1, -0.08, r, r + r * 0.7 * (1 if a > 1 else 0.5), C["iron"], faces="-y")
    return b


# ------------------------------------------------------------------ East African / Dar es Salaam pieces
def door_swahili(arched=False):
    """Carved Swahili door: dark teak leaves, brass studs, carved lintel panel above."""
    w, h = 1.4, 2.5
    b = window("arch" if arched else "rect", w, h, frame=C["frame_teak"], fill=C["teak"], sill=False, ft=1.6)
    box(b, -0.02, 0.02, -0.07, -0.05, 0.1, h - (0.75 if arched else 0.1), C["frame_teak"] * 0.8, faces="-y")
    for i in range(3):
        for j in range(4):
            x = -0.45 + 0.9 * i / 2
            z = 0.45 + j * 0.5
            box(b, x - 0.04, x + 0.04, -0.09, -0.05, z - 0.04, z + 0.04, C["brass"], faces="-y+z")
    if not arched:
        box(b, -w / 2 - 0.25, w / 2 + 0.25, -0.12, 0.0, h + 0.08, h + 0.55, C["stone"], faces="-y+z+x-x-z")
        box(b, -w / 2 - 0.05, w / 2 + 0.05, -0.15, -0.12, h + 0.16, h + 0.46, C["frame_teak"], faces="-y")
    box(b, -w / 2 - 0.4, w / 2 + 0.4, -0.5, 0.0, 0.0, 0.18, C["stone"], faces="-y+z+x-x")
    return b


def swahili_balcony(w=2.6, d=0.9, h=2.4):
    """Enclosed carved timber balcony (Stone Town): slab, posts, fretwork band, solid lower panel, lean-to roof."""
    b = MeshBuilder()
    t = C["frame_teak"]
    box(b, -w / 2, w / 2, -d, 0.0, -0.15, 0.0, t * 0.9, faces="-y+x-x-z")
    box(b, -w / 2 + 0.05, w / 2 - 0.05, -d + 0.02, -d + 0.08, 0.0, 0.95, t, faces="-y+z")
    for sx in (-w / 2, w / 2 - 0.08):
        box(b, sx, sx + 0.08, -d, 0.0, 0.0, h, t, faces="-y+x-x")
    for k in range(9):
        x = -w / 2 + 0.15 + (w - 0.3) * k / 8
        box(b, x - 0.025, x + 0.025, -d + 0.02, -d + 0.06, 0.95, h - 0.45, t * 1.1, faces="-y")
    box(b, -w / 2, w / 2, -d, -d + 0.08, h - 0.45, h - 0.25, t, faces="-y+z")
    a, c = np.array([-w / 2 - 0.1, -d - 0.25, h - 0.1]), np.array([w / 2 + 0.1, -d - 0.25, h - 0.1])
    e, f = np.array([w / 2 + 0.1, 0.0, h + 0.3]), np.array([-w / 2 - 0.1, 0.0, h + 0.3])
    n = np.cross(c - a, f - a); n = n if n[2] > 0 else -n
    b.quad(*[b.v(p, n, C["galv"]) for p in (a, c, e, f)])
    return b


def merlon(w=0.38, d=0.3, h=0.42):
    """One crenellation block for flat-roof parapets, with a soft rounded cap."""
    b = MeshBuilder()
    box(b, -w / 2, w / 2, -d / 2, d / 2, 0.0, h * 0.7, C["white"], faces="-y+y+x-x")
    lathe(b, [(w * 0.55, h * 0.7), (w * 0.4, h * 0.92), (0.0, h)], 4, lambda z: C["white"], a0=math.pi / 4,
          a1=math.pi / 4 + 2 * math.pi)
    return b


def water_tank(stand=False):
    """Black polyethylene roof tank (the ubiquitous Dar rooftop silhouette); optional steel stand."""
    b = MeshBuilder()
    z0 = 0.0
    if stand:
        z0 = 2.4
        for sx in (-0.55, 0.45):
            for sy in (-0.55, 0.45):
                box(b, sx, sx + 0.1, sy, sy + 0.1, 0.0, z0, C["iron"], faces="-y+y+x-x")
        box(b, -0.7, 0.7, -0.7, 0.7, z0 - 0.12, z0, C["iron"])
    lathe(b, [(0.62, 0.0), (0.66, 0.1), (0.66, 1.3), (0.48, 1.52), (0.0, 1.62)], 8,
          lambda z: C["tank"], center=(0, 0, z0), ao_fn=lambda z: 0.75 if z < 0.15 else 1.0)
    return b


def sat_dish():
    b = MeshBuilder()
    box(b, -0.04, 0.04, -0.04, 0.04, 0.0, 0.9, C["galv"], faces="-y+y+x-x")
    disc = [(0.45 * math.cos(a), 0.9 + 0.45 + 0.45 * math.sin(a)) for a in np.linspace(0, 2 * math.pi, 11)[:-1]]
    panel(b, (0, 0.05), (1, 0), (0, -1), disc, 0.06, C["white"])
    return b


def shop_shutter(w=2.8, h=2.7):
    """Roller-shutter shopfront (Kariakoo ground floors)."""
    b = MeshBuilder()
    box(b, -w / 2 - 0.15, w / 2 + 0.15, -0.12, 0.0, h, h + 0.35, C["concrete"], faces="-y+z+x-x-z")
    box(b, -w / 2, w / 2, -0.05, 0.0, 0.0, h, C["shutter"], faces="-y")
    for k in range(1, 9):
        z = h * k / 9
        box(b, -w / 2, w / 2, -0.07, -0.05, z - 0.02, z + 0.02, C["shutter"] * 0.82, faces="-y")
    return b


def pole_wood(h=3.0):
    b = MeshBuilder()
    lathe(b, [(0.14, 0.0), (0.12, h * 0.5), (0.1, h)], 6, lambda z: C["pole"],
          ao_fn=lambda z: 0.8 if z < 0.3 else 1.0)
    return b


def roof_weight():
    """Stones/tyres holding down corrugated sheets on informal roofs."""
    b = MeshBuilder()
    lathe(b, [(0.32, 0.0), (0.34, 0.08), (0.24, 0.18), (0.0, 0.2)], 7, lambda z: hex_rgb("#77726A"))
    return b


def gate(w=3.2, h=2.3, color=None):
    color = hex_rgb("#2F5D8C") if color is None else color
    b = MeshBuilder()
    box(b, -w / 2, w / 2, -0.06, 0.0, 0.0, h, color, faces="-y+z+x-x")
    box(b, -0.03, 0.03, -0.08, -0.06, 0.0, h, color * 0.75, faces="-y")
    for k in range(1, 4):
        box(b, -w / 2, w / 2, -0.08, -0.06, h * k / 4 - 0.03, h * k / 4 + 0.03, color * 0.8, faces="-y")
    return b


# ------------------------------------------------------------------ registry
BASES = {
    "window": lambda: window("rect", 1.0, 1.4),
    "window_tall": lambda: window("rect", 1.0, 2.1),
    "window_small": lambda: window("rect", 0.65, 0.75, sill=False),
    "window_small_blue": lambda: window("rect", 0.65, 0.8, frame=C["frame_blue"], sill=False, ft=1.3),
    "window_multipane": lambda: window("rect", 0.95, 1.5, panes=6),
    "window_multipane_dark": lambda: window("rect", 0.9, 1.3, panes=4, frame=C["frame_dark"]),
    "window_arched": lambda: window("arch", 1.0, 1.9),
    "window_arched_dark": lambda: window("arch", 1.0, 1.9, frame=C["frame_dark"], panes=2),
    "window_lancet": lambda: window("lancet", 0.9, 3.2, panes=2, frame=C["stone"]),
    "window_round": lambda: window("round", 1.1, 1.1, frame=C["stone"], sill=False),
    "rose_window": lambda: window("round", 3.0, 3.0, frame=C["stone"], spokes=6, ft=2.0, sill=False),
    "window_wide": lambda: window("rect", 2.2, 1.5, panes=2),
    "door": lambda: door(),
    "door_blue": lambda: door(color=C["door_blue"]),
    "door_green": lambda: door(color=C["door_green"]),
    "door_red": lambda: door(color=C["door_red"]),
    "door_arched": lambda: door(1.6, 2.8, shape="arch"),
    "column": lambda: column(),
    "column_slim": lambda: column(r=0.18, slim=True, color=C["white"]),
    "balcony": lambda: balcony(),
    "dormer": lambda: dormer(),
    "chimney": lambda: chimney(),
    "chimney_brick": lambda: chimney(C["brick"], w=0.9, h=1.6),
    "buttress": lambda: buttress(),
    "arch_bay": lambda: arch_bay(),
    "small_dome": lambda: small_dome(),
    "stoop": lambda: stoop(),
    "finial_cross": lambda: finial_cross(),
    "finial_alem": lambda: finial_alem(),
    "clock": lambda: clock(),
    "door_swahili": lambda: door_swahili(),
    "door_swahili_arched": lambda: door_swahili(arched=True),
    "swahili_balcony": lambda: swahili_balcony(),
    "merlon": lambda: merlon(),
    "water_tank": lambda: water_tank(),
    "water_tank_stand": lambda: water_tank(stand=True),
    "sat_dish": lambda: sat_dish(),
    "shop_shutter": lambda: shop_shutter(),
    "pole_wood": lambda: pole_wood(),
    "roof_weight": lambda: roof_weight(),
    "gate": lambda: gate(),
    "tree_puff": lambda: __import__("make_tree").build("puff", 1, 3, None),
    "tree_palm": lambda: __import__("make_tree").build("palm", 0, 2, None),
    "tree_palm_b": lambda: __import__("make_tree").build("palm", 0, 7, None),
    "window_tinted": lambda: window("rect", 1.6, 1.5, frame=C["alu"], glass=(C["tint_top"], C["tint_bot"]), panes=2, ft=0.8),
    "window_barred": lambda: window("rect", 1.2, 1.2, frame=C["iron"], panes=6, ft=0.9),
    "window_small_dark": lambda: window("rect", 0.6, 0.6, frame=C["frame_dark"], sill=False),
    "window_teak": lambda: window("rect", 0.95, 1.5, frame=C["frame_teak"], panes=4, ft=1.2),
}
# window sizes (w, h) for accessory placement
SIZES = {"window": (1.0, 1.4), "window_tall": (1.0, 2.1), "window_multipane": (0.95, 1.5),
         "window_multipane_dark": (0.9, 1.3), "window_arched": (1.0, 1.9), "window_arched_dark": (1.0, 1.9),
         "window_small": (0.65, 0.75), "window_small_blue": (0.65, 0.8), "window_wide": (2.2, 1.5),
         "door": (1.2, 2.3), "door_blue": (1.2, 2.3), "door_green": (1.2, 2.3), "door_red": (1.2, 2.3),
         "door_arched": (1.6, 2.8), "window_lancet": (0.9, 3.2),
         "window_tinted": (1.6, 1.5), "window_barred": (1.2, 1.2), "window_small_dark": (0.6, 0.6),
         "window_teak": (0.95, 1.5), "door_swahili": (1.4, 2.5), "door_swahili_arched": (1.4, 2.5)}


def _accessory(b, name, base):
    w, h = SIZES.get(base, (1.0, 1.4))
    if name.startswith("shutters_"):
        col = C.get("frame_" + name.split("_", 1)[1], C["frame_green"])
        shutters(b, w, h, col)
    elif name == "lintel":
        box(b, -w / 2 - 0.15, w / 2 + 0.15, -0.12, 0.0, h + 0.06, h + 0.3, C["stone"], faces="-y+z+x-x-z")
        box(b, -0.12, 0.12, -0.15, -0.12, h + 0.04, h + 0.34, C["stone"], faces="-y+z+x-x")
    elif name == "eyebrow":
        box(b, -w / 2 - 0.25, w / 2 + 0.25, -0.45, 0.0, h + 0.12, h + 0.2, C["white"], faces="-y+z+x-x-z")
    elif name == "pediment":
        pediment(b, w + 0.4, h + 0.18, C["white"])
    elif name == "pediment_door":
        pediment(b, w + 1.0, h + 0.25, C["white"], height=0.7, thick=0.25)
        for sx in (-1, 1):
            box(b, sx * (w / 2 + 0.25) - 0.12, sx * (w / 2 + 0.25) + 0.12, -0.18, 0.0, 0.15, h + 0.13,
                C["white"], faces="-y+x-x")
    elif name == "balcony":
        bb = balcony(w + 1.0, 0.8)
        b.append(bb, transform=lambda p: p + np.array([0, 0, -0.05]), normal_transform=lambda n: n)
    elif name == "balcony_slab":
        bw = w + 1.6
        box(b, -bw / 2, bw / 2, -1.2, 0.0, -0.95, -0.75, C["concrete"], faces="-y+z+x-x-z")
        box(b, -bw / 2, bw / 2, -1.2, -1.08, -0.75, 0.25, C["white"], faces="-y+z+y+x-x")
        for sx in (-bw / 2, bw / 2 - 0.12):
            box(b, sx, sx + 0.12, -1.08, 0.0, -0.75, 0.25, C["white"], faces="+z+x-x")
    elif name == "flowerbox":
        box(b, -w / 2, w / 2, -0.3, 0.0, -0.32, -0.08, C["wood"], faces="-y+z+x-x")
        box(b, -w / 2 + 0.05, w / 2 - 0.05, -0.26, -0.04, -0.08, 0.05, hex_rgb("#C9475A"), faces="-y+z")
    else:
        raise KeyError(name)


def get_module(name):
    """Returns a MeshBuilder in glTF space (cached)."""
    if name in _CACHE:
        return _CACHE[name]
    parts = name.split("+")
    base = parts[0]
    b = MeshBuilder()
    b.append(BASES[base]())
    for acc in parts[1:]:
        _accessory(b, acc, base)
    g = _to_gltf(b)
    _CACHE[name] = g
    return g


def module_size(name):
    return SIZES.get(name.split("+")[0], (1.0, 1.4))
