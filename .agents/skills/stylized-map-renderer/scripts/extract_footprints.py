#!/usr/bin/env python3
"""Recovers 2D footprints + heights from heavy building meshes so they can be regenerated
with build_building.py (instead of decimating them).

Usage:
  python extract_footprints.py <file_or_dir> --out specs.json [--up y|z] [--slice 1.0]
                               [--simplify 0.35] [--only-names building,bldg] [--split]

How it works:
  1. slice each mesh with a horizontal plane `--slice` metres above its base
  2. polygonize the section, keep the largest polygon (with courtyards)
  3. simplify with tolerance `--simplify`, then 'resharpen' corners: short chamfer/arc remnants
     between two long walls become the walls' intersection point. This deliberately collapses
     old multi-segment bevels back to clean corners - the generator re-rounds them cheaply
  4. height = top of mesh - base; roof guessed from the area of up-facing faces near the top
Output specs use map coordinates (x east, y north). For glTF (Y-up) input: x = X, y = -Z.
"""
import argparse
import json
import os
import sys

import numpy as np
import trimesh
from shapely.geometry import Polygon
from shapely.ops import polygonize, unary_union
from shapely.geometry.polygon import orient

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audit_meshes import iter_files, load_items, classify


def resharpen(ring, max_cut=2.5):
    """Replaces chamfer/arc remnants (short edges between two long, roughly perpendicular walls)
    with the corner where the long walls' lines intersect. The generator re-rounds later."""
    pts = [np.asarray(p, float) for p in ring]
    changed = True
    while changed and len(pts) > 4:
        changed = False
        n = len(pts)
        L = [np.linalg.norm(pts[(i + 1) % n] - pts[i]) for i in range(n)]
        for i in range(n):
            ip, inx = (i - 1) % n, (i + 1) % n
            if L[i] < max_cut and L[ip] > L[i] * 1.5 and L[inx] > L[i] * 1.5:
                a0, a1 = pts[ip], pts[i]
                b0, b1 = pts[inx], pts[(inx + 1) % n]
                da, db = a1 - a0, b1 - b0
                den = da[0] * db[1] - da[1] * db[0]
                ang = np.degrees(np.arccos(np.clip(abs(da @ db) / (np.linalg.norm(da) * np.linalg.norm(db)), 0, 1)))
                if abs(den) < 1e-9 or ang < 50:
                    continue
                t = ((b0[0] - a0[0]) * db[1] - (b0[1] - a0[1]) * db[0]) / den
                corner = a0 + da * t
                if np.linalg.norm(corner - pts[i]) > max_cut:
                    continue
                pts[i] = corner
                del pts[inx]
                changed = True
                break
    return [tuple(p) for p in pts]


def footprint(m, up, slice_h, simplify):
    base = m.bounds[0][up]
    top = m.bounds[1][up]
    normal = np.zeros(3); normal[up] = 1
    origin = np.zeros(3); origin[up] = base + min(slice_h, (top - base) * 0.5)
    sec = m.section(plane_origin=origin, plane_normal=normal)
    if sec is None:
        return None
    lines = []
    for poly3 in sec.discrete:
        if up == 1:
            xy = np.stack([poly3[:, 0], -poly3[:, 2]], axis=1)
        else:
            xy = poly3[:, :2]
        if len(xy) >= 2:
            lines.append([tuple(p) for p in xy])
    from shapely.geometry import LineString
    polys = list(polygonize(unary_union([LineString(l) for l in lines if len(l) >= 2])))
    if not polys:
        return None
    # rebuild nesting: biggest polygon, holes = polygons inside it
    polys.sort(key=lambda p: -p.area)
    outer = polys[0]
    shape = outer
    for p in polys[1:]:
        if outer.contains(p.representative_point()):
            shape = shape.difference(p)
    if shape.geom_type == "MultiPolygon":
        shape = max(shape.geoms, key=lambda g: g.area)
    shape = orient(shape.simplify(simplify, preserve_topology=True), 1.0)
    holes = [resharpen(list(r.coords)[:-1]) for r in shape.interiors]
    shape = orient(Polygon(resharpen(list(shape.exterior.coords)[:-1]), holes).buffer(0), 1.0)
    if shape.geom_type == "MultiPolygon":
        shape = max(shape.geoms, key=lambda g: g.area)

    # roof guess: flat if most up-facing area near the top is horizontal
    n = m.face_normals
    c = m.triangles_center[:, up]
    near_top = c > top - max(1.0, (top - base) * 0.25)
    up_area = m.area_faces[near_top & (n[:, up] > 0.3)]
    flat_area = m.area_faces[near_top & (n[:, up] > 0.97)]
    roof = "flat" if up_area.sum() == 0 or flat_area.sum() / up_area.sum() > 0.6 else "hip"
    return shape, float(top - base), roof


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("--out", required=True)
    ap.add_argument("--up", choices=["y", "z"], default="y")
    ap.add_argument("--slice", type=float, default=1.0)
    ap.add_argument("--simplify", type=float, default=0.5)
    ap.add_argument("--only-names", default="")
    ap.add_argument("--split", action="store_true")
    a = ap.parse_args()
    up = 1 if a.up == "y" else 2
    only = [s.strip().lower() for s in a.only_names.split(",") if s.strip()]

    specs, skipped = [], 0
    for f in iter_files(a.path):
        for name, m, _ in load_items(f, a.split):
            if only and not any(s in name.lower() for s in only):
                continue
            if not only and classify(name, m, up) != "building":
                continue
            res = footprint(m, up, a.slice, a.simplify)
            if res is None:
                skipped += 1
                continue
            shape, h, roof = res
            levels = max(1, round(h / 3.2))
            btype = "house" if roof == "hip" and h < 9 else ("tower" if h > 60 else
                    ("office" if shape.area > 600 else "rowhouse"))
            specs.append({
                "id": name, "type": btype, "roof": roof,
                **({"style": "modern_glass"} if btype == "tower" else {}),
                "footprint": [list(map(lambda v: round(v, 3), p)) for p in shape.exterior.coords[:-1]],
                "holes": [[list(map(lambda v: round(v, 3), p)) for p in r.coords[:-1]] for r in shape.interiors],
                "height": round(h - (0.65 if roof == "flat" else 0.0), 2),
                "levels": levels, "source_tris": int(len(m.faces)),
            })
    json.dump(specs, open(a.out, "w"), indent=1)
    print(f"extracted {len(specs)} footprints -> {a.out}" + (f" ({skipped} skipped)" if skipped else ""))
    for s in specs[:10]:
        print(f"  {s['id'][:40]:<40} {len(s['footprint']):>3} pts  h={s['height']:>6}  {s['type']:<9} "
              f"{s['roof']:<5} (was {s['source_tris']} tris)")


if __name__ == "__main__":
    main()
