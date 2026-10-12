#!/usr/bin/env python3
"""Audits map meshes (glb/gltf/obj/ply/stl) and recommends a fix per mesh.

Usage:
  python audit_meshes.py <file_or_dir> [--up y|z] [--split] [--json report.json] [--top 25]

Per mesh it reports:
  tris                triangle count
  class               building / tree / prop / other  (name hints first, then shape heuristics)
  plane_redundancy    triangles / coplanar regions   (> 4: flat surfaces subdivided for nothing)
  sliver_fraction     share of thin/needle triangles  (> 0.35 on buildings: modelled bevel strips)
  dup_group           meshes with identical geometry (should be ONE library mesh + instances)
  instanced           how many scene nodes already reference this geometry
  action              REGENERATE_FROM_FOOTPRINT | REPLACE_WITH_LIBRARY_TREE | INSTANCE |
                      SIMPLIFY | RETRIANGULATE | OK

--split   splits each mesh into connected components first (use when a whole tile was exported
          as one merged mesh).
"""
import argparse
import hashlib
import json
import os
import sys
from collections import defaultdict

import numpy as np
import trimesh

BUDGET = {"building": 1500, "tree": 1400, "prop": 300, "other": 2000}
TREE_HINTS = ("tree", "canopy", "foliage", "leaf", "leaves", "bush", "shrub", "pine", "conifer",
              "cypress", "oak", "palm", "plant", "hedge")
PROP_HINTS = ("window", "chimney", "car", "vehicle", "lamp", "light", "bench", "sign", "pole",
              "hydrant", "ac_unit", "hvac", "antenna", "door", "railing", "fence")
BUILDING_HINTS = ("building", "bldg", "house", "tower", "block", "facade", "roof", "structure")
EXTS = (".glb", ".gltf", ".obj", ".ply", ".stl", ".off")


def iter_files(path):
    if os.path.isfile(path):
        yield path
        return
    for root, _, files in os.walk(path):
        for f in sorted(files):
            if f.lower().endswith(EXTS):
                yield os.path.join(root, f)


def load_items(path, split):
    scene = trimesh.load(path, force="scene", process=False)
    refs = defaultdict(int)
    for node in scene.graph.nodes_geometry:
        _, gname = scene.graph[node]
        refs[gname] += 1
    for gname, g in scene.geometry.items():
        if not isinstance(g, trimesh.Trimesh) or len(g.faces) == 0:
            continue
        if split:
            parts = g.split(only_watertight=False)
            for i, p in enumerate(parts):
                yield f"{os.path.basename(path)}:{gname}#{i}", p, refs[gname]
        else:
            yield f"{os.path.basename(path)}:{gname}", g, refs[gname]


def classify(name, m, up):
    low = name.lower()
    for hints, cls in ((TREE_HINTS, "tree"), (PROP_HINTS, "prop"), (BUILDING_HINTS, "building")):
        if any(h in low for h in hints):
            return cls
    n = m.face_normals
    a = m.area_faces
    tot = a.sum() + 1e-12
    upc = np.abs(n[:, up])
    vert = a[upc < 0.1].sum() / tot
    horiz = a[upc > 0.95].sum() / tot
    ext = m.extents
    height = ext[up]
    if vert + horiz > 0.7 and height > 2.5:
        return "building"
    if vert + horiz < 0.45 and height > 1.0:
        return "tree"
    if max(ext) < 3.0:
        return "prop"
    return "other"


def metrics(m):
    tris = len(m.faces)
    try:
        facets = m.facets
        in_facets = sum(len(f) for f in facets)
        regions = len(facets) + (tris - in_facets)
    except Exception:
        regions = tris
    plane_redundancy = tris / max(regions, 1)

    tri = m.triangles
    e = np.stack([np.linalg.norm(tri[:, 1] - tri[:, 0], axis=1),
                  np.linalg.norm(tri[:, 2] - tri[:, 1], axis=1),
                  np.linalg.norm(tri[:, 0] - tri[:, 2], axis=1)], axis=1)
    area = m.area_faces
    quality = 4 * np.sqrt(3) * area / ((e ** 2).sum(1) + 1e-12)   # 1 = equilateral
    sliver_fraction = float((quality < 0.12).mean()) if tris else 0.0
    return plane_redundancy, sliver_fraction


def geom_key(m):
    v = np.asarray(m.vertices) - np.asarray(m.vertices).mean(0)
    sig = (len(m.faces), len(m.vertices), round(float(m.area), 2),
           tuple(np.round(np.sort(m.extents), 2)),
           tuple(np.round(np.sort(np.linalg.norm(v, axis=1))[:: max(1, len(v) // 16)][:16], 2)))
    return hashlib.md5(repr(sig).encode()).hexdigest()[:10]


def recommend(cls, tris, red, sliv, dup_n, refs):
    budget = BUDGET[cls]
    if cls == "tree":
        return "REPLACE_WITH_LIBRARY_TREE" if (tris > budget or dup_n > 1 or refs <= 1) else "OK"
    if dup_n > 1 and refs <= 1:
        return "INSTANCE"
    if cls == "building":
        if sliv > 0.35 or tris > budget:
            return "REGENERATE_FROM_FOOTPRINT"
        if red > 4:
            return "RETRIANGULATE"
        return "OK"
    if tris > budget:
        return "SIMPLIFY"
    if red > 4 and tris > 200:
        return "RETRIANGULATE"
    return "OK"


def projected_tris(cls, action, tris):
    """Rough unique-triangle estimate after the fix (for the summary only)."""
    if action == "REGENERATE_FROM_FOOTPRINT":
        return min(tris, 700)
    if action == "REPLACE_WITH_LIBRARY_TREE":
        return 0          # library mesh shared; instances store ~16 bytes
    if action == "INSTANCE":
        return 0          # counted once per group below
    if action == "SIMPLIFY":
        return max(int(tris * 0.25), BUDGET[cls])
    if action == "RETRIANGULATE":
        return int(tris / 3)
    return tris


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("--up", choices=["y", "z"], default="y", help="up axis (glTF = y)")
    ap.add_argument("--split", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--top", type=int, default=25)
    a = ap.parse_args()
    up = 1 if a.up == "y" else 2

    rows = []
    for f in iter_files(a.path):
        try:
            for name, m, refs in load_items(f, a.split):
                cls = classify(name, m, up)
                red, sliv = metrics(m)
                rows.append(dict(name=name, tris=int(len(m.faces)), cls=cls,
                                 plane_redundancy=round(red, 2), sliver_fraction=round(sliv, 3),
                                 key=geom_key(m), instanced=refs,
                                 height=round(float(m.extents[up]), 2)))
        except Exception as ex:
            print(f"! failed to load {f}: {ex}", file=sys.stderr)
    if not rows:
        print("no meshes found")
        return

    groups = defaultdict(list)
    for r in rows:
        groups[r["key"]].append(r)
    for r in rows:
        r["dup_group"] = len(groups[r["key"]])
        r["action"] = recommend(r["cls"], r["tris"], r["plane_redundancy"], r["sliver_fraction"],
                                r["dup_group"], r["instanced"])

    total = sum(r["tris"] * max(r["instanced"], 1) for r in rows)
    after = sum(projected_tris(r["cls"], r["action"], r["tris"]) for r in rows)
    seen = set()
    for r in rows:
        if r["action"] in ("INSTANCE",) and r["key"] not in seen:
            after += r["tris"]
            seen.add(r["key"])
    tree_groups = {r["key"] for r in rows if r["action"] == "REPLACE_WITH_LIBRARY_TREE"}
    after += 1400 * min(len(tree_groups), 8)   # one library tree (LOD0) per distinct kind, max ~8

    print(f"\n{'mesh':<44}{'class':<10}{'tris':>9}{'plane_red':>10}{'sliver':>8}{'dup':>5}  action")
    print("-" * 104)
    for r in sorted(rows, key=lambda r: -r["tris"])[: a.top]:
        print(f"{r['name'][:43]:<44}{r['cls']:<10}{r['tris']:>9}{r['plane_redundancy']:>10}"
              f"{r['sliver_fraction']:>8}{r['dup_group']:>5}  {r['action']}")
    print("-" * 104)
    by_action = defaultdict(lambda: [0, 0])
    by_class = defaultdict(lambda: [0, 0])
    for r in rows:
        by_action[r["action"]][0] += 1
        by_action[r["action"]][1] += r["tris"]
        by_class[r["cls"]][0] += 1
        by_class[r["cls"]][1] += r["tris"]
    print("by class : " + ", ".join(f"{k} {v[0]} meshes / {v[1]:,} tris" for k, v in by_class.items()))
    print("by action: " + ", ".join(f"{k} {v[0]} ({v[1]:,} tris)" for k, v in sorted(by_action.items())))
    print(f"\ntotal triangles (incl. existing instancing): {total:,}")
    print(f"projected unique triangles after fixes     : ~{after:,}  "
          f"({100 * (1 - after / max(total, 1)):.1f}% reduction; instances add per-frame cost "
          f"but no unique geometry)")
    if a.json:
        json.dump(dict(meshes=rows, total_tris=total, projected_tris=after), open(a.json, "w"), indent=1)
        print(f"wrote {a.json}")


if __name__ == "__main__":
    main()
