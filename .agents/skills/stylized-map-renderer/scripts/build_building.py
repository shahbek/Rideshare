#!/usr/bin/env python3
"""Stylized building generator: footprints -> shells + instance lists, for every style and landmark.

Usage:
  python build_building.py --spec buildings.json --out tile.glb [--runtime-bin tile.bin] [--lod 0|1|2]
  python build_building.py --demo basic|styles|landmarks|awkward --out demo.glb
  python build_building.py --list-styles

Spec JSON: one object or a list. Common keys:
  "footprint": [[x, y], ...]     metres, map plane (x east, y north); any shape, repaired automatically
  "holes": [[[x, y], ...]]       courtyards (optional)
  "style": one of --list-styles  (ordinary buildings), or
  "type":  "tower" | "church" | "mosque" | "pagoda"   (landmarks; "style" then picks the variant)
           legacy: "rowhouse" | "office" | "house"
  "height" | "levels", "id", "street": [x, y] or "street_edge": i, "palette", "corner_radius"
  landmark extras: tower "setbacks"/"facade"/"crown"; mosque "minarets"/"courtyard"; pagoda "tiers"

Outputs:
  <out>.glb              preview (glTF Y-up; vertex colours = albedo x AO; instances baked in)
  <out>_instances.json   instances {module, pos, yaw, scale?} in glTF space
  <out>_library.glb      every module used, one mesh each (the instancing library)
  --runtime-bin          shells in the 28-byte Metal vertex format (references/metal-renderer.md)
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geomlib import MeshBuilder, export_glb, write_runtime_bin, to_gltf
import modules
import styles
import landmarks
from core import place_instances


def build_any(spec, lod=0):
    t = spec.get("type")
    if t in landmarks.LANDMARKS:
        return landmarks.LANDMARKS[t](spec)
    return styles.build_styled(spec, lod)


def _grid(specs, cell, cols):
    out = []
    for i, s in enumerate(specs):
        dx, dy = (i % cols) * cell, -(i // cols) * cell
        s = dict(s)
        s["footprint"] = [[x + dx, y + dy] for x, y in s["footprint"]]
        if "holes" in s:
            s["holes"] = [[[x + dx, y + dy] for x, y in h] for h in s["holes"]]
        if "street" in s:
            s["street"] = [s["street"][0] + dx, s["street"][1] + dy]
        out.append(s)
    return out


def demo_specs(kind):
    if kind == "basic":
        return [
            {"id": "row-blue", "type": "rowhouse", "footprint": [[0, 0], [9, 0], [9, 14], [0, 14]],
             "height": 13.0, "levels": 4, "palette": 0, "street_edge": 0},
            {"id": "row-yellow", "type": "rowhouse", "footprint": [[9.4, -1], [19, -1], [19, 14], [9.4, 14]],
             "height": 11.0, "levels": 3, "palette": 1, "street_edge": 0},
            {"id": "office", "type": "office", "footprint": [[26, -2], [64, -2], [64, 16], [26, 16]],
             "height": 16.0, "levels": 4, "corner_radius": 6.0},
            {"id": "house-1", "type": "house", "footprint": [[0, 24], [11, 24], [11, 32], [0, 32]], "levels": 1},
            {"id": "courtyard", "type": "rowhouse", "footprint": [[20, 24], [44, 24], [44, 46], [20, 46]],
             "holes": [[[27, 31], [27, 39], [37, 39], [37, 31]]], "height": 18.0, "levels": 5, "palette": 3,
             "extras": ["roof_props"]},
        ]
    if kind == "styles":
        rect = [[0, 0], [12, 0], [12, 9], [0, 9]]
        narrow = [[0, 0], [6.5, 0], [6.5, 14], [0, 14]]
        ell = [[0, 0], [13, 0], [13, 6], [7, 6], [7, 12], [0, 12]]
        fp = {"brownstone": narrow, "dutch_canal": narrow, "victorian": ell, "tudor": ell,
              "art_deco": [[0, 0], [20, 0], [20, 14], [0, 14]], "modernist": [[0, 0], [18, 0], [18, 12], [0, 12]],
              "spanish": [[0, 0], [14, 0], [14, 10], [0, 10]], "greek_revival": [[0, 0], [12, 0], [12, 16], [0, 16]]}
        specs = [{"id": f"{s}-1", "style": s, "footprint": fp.get(s, rect), "street_edge": 0}
                 for s in styles.STYLES if not s.startswith("fenn_")]
        return _grid(specs, 34, 4)
    if kind == "landmarks":
        specs = [
            {"id": "t1", "type": "tower", "style": "art_deco", "footprint": [[0, 0], [56, 0], [56, 40], [0, 40]], "height": 300},
            {"id": "t2", "type": "tower", "style": "classic", "footprint": [[0, 0], [30, 0], [30, 28], [0, 28]], "height": 150},
            {"id": "c1", "type": "church", "style": "gothic", "footprint": [[0, 0], [48, 0], [48, 16], [0, 16]], "street": [-20, 8]},
            {"id": "c2", "type": "church", "style": "orthodox", "footprint": [[0, 0], [30, 0], [30, 22], [0, 22]], "street": [-20, 11]},
            {"id": "m1", "type": "mosque", "style": "ottoman", "footprint": [[0, 0], [100, 0], [100, 44], [0, 44]], "street": [-30, 22]},
            {"id": "m2", "type": "mosque", "style": "persian", "footprint": [[0, 0], [50, 0], [50, 38], [0, 38]], "street": [-30, 19]},
        ]
        return _grid(specs, 130, 3)
    if kind == "awkward":
        shapes = {
            "L-hip": [[0, 0], [14, 0], [14, 6], [6, 6], [6, 14], [0, 14]],
            "T-gable": [[0, 0], [20, 0], [20, 6], [13, 6], [13, 16], [7, 16], [7, 6], [0, 6]],
            "U": [[0, 0], [20, 0], [20, 14], [14, 14], [14, 6], [6, 6], [6, 14], [0, 14]],
            "pentagon": [[0, 0], [10, 0], [13, 7], [5, 12], [-3, 7]],
            "notched": [[0, 0], [12, 0], [12, 9], [7, 9], [6, 7.5], [5, 9], [0, 9]],
            "boomerang": [[0, 0], [12, 0], [20, 8], [16, 11], [10, 4], [0, 4]],
            "spike+sliver": [[0, 0], [10, 0], [10.05, -6], [10.1, 0], [12, 0], [12, 8], [6, 8], [6, 8.05], [0, 8]],
            "wedge": [[0, 0], [22, 0], [3, 7]],
        }
        st = ["fenn_house", "victorian", "spanish", "fenn_house", "colonial", "fenn_house", "fenn_rowhouse", "fenn_rowhouse"]
        specs = [{"id": k, "style": st[i], "footprint": v, "levels": 2} for i, (k, v) in enumerate(shapes.items())]
        return _grid(specs, 30, 4)
    raise SystemExit(f"unknown demo {kind}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec")
    ap.add_argument("--demo", choices=["basic", "styles", "landmarks", "awkward"])
    ap.add_argument("--out")
    ap.add_argument("--lod", type=int, default=0, choices=[0, 1, 2])
    ap.add_argument("--runtime-bin")
    ap.add_argument("--no-preview-instances", action="store_true")
    ap.add_argument("--list-styles", action="store_true")
    a = ap.parse_args()

    if a.list_styles:
        print("styles   :", ", ".join(styles.STYLES))
        print("towers   :", ", ".join(landmarks.TOWER_PRESETS))
        print("churches :", ", ".join(landmarks.CHURCH))
        print("mosques  :", ", ".join(landmarks.MOSQUE))
        print("pagodas  : japanese, chinese")
        return
    if not a.out:
        ap.error("--out required")
    if a.demo:
        specs = demo_specs(a.demo)
    elif a.spec:
        specs = json.load(open(a.spec))
        specs = specs if isinstance(specs, list) else [specs]
    else:
        ap.error("--spec or --demo required")

    shell = MeshBuilder()
    all_inst = []
    print(f"{'building':<18}{'kind':<22}{'shell tris':>11}{'instances':>11}")
    for s in specs:
        b, inst = build_any(s, lod=a.lod)
        shell.append(b)
        all_inst += inst
        kind = f"{s.get('type', '')} {s.get('style', '')}".strip()
        print(f"{str(s.get('id', '?'))[:17]:<18}{kind[:21]:<22}{b.tri_count:>11}{len(inst):>11}")

    base = os.path.splitext(a.out)[0]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    preview = MeshBuilder()
    preview.append(shell, transform=lambda p: to_gltf(p), normal_transform=lambda n: to_gltf(n))
    if not a.no_preview_instances:
        place_instances(preview, all_inst, modules.get_module)
    export_glb(preview, a.out, zup_input=False)
    used = sorted({i["module"] for i in all_inst})
    if used:
        export_glb([modules.get_module(m) for m in used], base + "_library.glb", zup_input=False)
    json.dump(all_inst, open(base + "_instances.json", "w"), indent=1)

    counts = {}
    for i in all_inst:
        counts[i["module"]] = counts.get(i["module"], 0) + 1
    rendered = sum(modules.get_module(m).tri_count * c for m, c in counts.items())
    print("-" * 62)
    print(f"unique shell triangles : {shell.tri_count:,}")
    print(f"library modules used   : {len(used)} ({sum(modules.get_module(m).tri_count for m in used):,} tris total)")
    print(f"instances              : {len(all_inst):,} (rendered {rendered:,} tris, stored as {len(all_inst) * 16:,} bytes)")
    if a.runtime_bin:
        size = write_runtime_bin(shell, a.runtime_bin)
        print(f"runtime bin            : {a.runtime_bin} ({size / 1024:.1f} KB)")
    print(f"wrote {a.out}, {base}_instances.json" + (f", {base}_library.glb" if used else ""))


if __name__ == "__main__":
    main()
