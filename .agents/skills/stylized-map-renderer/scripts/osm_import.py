#!/usr/bin/env python3
"""Fetch OSM buildings/roads/trees around a point and turn them into generator specs, choosing a
style per building from tags + region rules + local density. Optionally builds a preview scene.

Usage:
  python osm_import.py --center -6.8165 39.2915 --radius 300 --region dar_es_salaam \
                       --out cbd_specs.json [--scene cbd_scene.glb] [--max 400]
  python osm_import.py --osm-json saved_overpass.json --center ... --out ...   (offline)

Regions: dar_es_salaam (default), generic. Add a region by writing a rules function (see
references/region-dar-es-salaam.md for the reasoning behind the Dar rules).
Overpass mirrors are tried in order; data (c) OpenStreetMap contributors, ODbL.
"""
import argparse
import json
import math
import os
import sys
import urllib.parse
import urllib.request

import numpy as np
from shapely.geometry import Polygon, LineString, Point
from shapely.strtree import STRtree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MIRRORS = ["https://overpass-api.de/api/interpreter",
           "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
           "https://overpass.kumi.systems/api/interpreter",
           "https://overpass.private.coffee/api/interpreter"]


def overpass(query, timeout=60):
    last = None
    for url in MIRRORS:
        try:
            data = urllib.parse.urlencode({"data": query}).encode()
            with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=timeout) as r:
                txt = r.read().decode()
            if txt.lstrip().startswith("{"):
                return json.loads(txt)
            last = txt[:200]
        except Exception as e:  # mirror down: try the next one
            last = str(e)
    raise SystemExit(f"all Overpass mirrors failed: {last}")


def fetch_osm_api(lat, lon, radius, timeout=120):
    """Fallback: the main OSM API /map call (bbox must stay under 0.25 deg^2 / 50k nodes).
    Returns the same structure as an Overpass 'out geom' response."""
    import xml.etree.ElementTree as ET
    dlat = (radius + 80) / 110574
    dlon = (radius + 80) / (111320 * math.cos(math.radians(lat)))
    url = (f"https://api.openstreetmap.org/api/0.6/map?bbox={lon - dlon:.6f},{lat - dlat:.6f},"
           f"{lon + dlon:.6f},{lat + dlat:.6f}")
    req = urllib.request.Request(url, headers={"User-Agent": "stylized-map-renderer/1.0"})
    root = ET.fromstring(urllib.request.urlopen(req, timeout=timeout).read())
    nodes, els = {}, []
    for n in root.iter("node"):
        nodes[n.get("id")] = (float(n.get("lat")), float(n.get("lon")))
        tags = {t.get("k"): t.get("v") for t in n.findall("tag")}
        if tags:
            els.append({"type": "node", "id": int(n.get("id")), "lat": nodes[n.get("id")][0],
                        "lon": nodes[n.get("id")][1], "tags": tags})
    for w in root.iter("way"):
        refs = [nd.get("ref") for nd in w.findall("nd")]
        if not all(r in nodes for r in refs):
            continue
        tags = {t.get("k"): t.get("v") for t in w.findall("tag")}
        els.append({"type": "way", "id": int(w.get("id")), "tags": tags,
                    "geometry": [{"lat": nodes[r][0], "lon": nodes[r][1]} for r in refs]})
    return {"elements": els}


def fetch(lat, lon, radius):
    try:
        return _fetch_overpass(lat, lon, radius)
    except SystemExit as e:
        print(f"Overpass unavailable ({str(e)[:80]}...), falling back to the OSM API")
        return fetch_osm_api(lat, lon, radius)


def _fetch_overpass(lat, lon, radius):
    q = f"""[out:json][timeout:110];
(way["building"](around:{radius},{lat},{lon});
 way["highway"](around:{radius + 60},{lat},{lon});
 node["natural"="tree"](around:{radius},{lat},{lon});
 way["natural"="coastline"](around:{radius + 200},{lat},{lon});
 node["amenity"="place_of_worship"](around:{radius},{lat},{lon}););
out geom tags;"""
    return overpass(q)


class Proj:
    def __init__(self, lat0, lon0):
        self.lat0, self.lon0 = lat0, lon0
        self.kx = 111320 * math.cos(math.radians(lat0))
        self.ky = 110574

    def __call__(self, lat, lon):
        return ((lon - self.lon0) * self.kx, (lat - self.lat0) * self.ky)


def _num(v, default=None):
    try:
        return float(str(v).split(";")[0].replace("m", "").strip())
    except Exception:
        return default


ROOF_COLOURS = {"red": "#A33B32", "maroon": "#8C2F39", "green": "#2F6B4F", "blue": "#3C5E9C",
                "grey": "#9AA3AD", "gray": "#9AA3AD", "brown": "#8B5A3C", "white": "#E9E6E0",
                "black": "#3F3F46", "orange": "#C8643B", "silver": "#A9B0B6"}


# ------------------------------------------------------------------ region rules
def rules_dar_es_salaam(t, area, levels, height, density, nb=None):
    """Returns a partial spec (style/type and overrides) for one building. Reasoning and sources:
    references/region-dar-es-salaam.md."""
    b = t.get("building", "yes")
    rmat = t.get("roof:material", "")
    rshape = t.get("roof:shape", "")
    spec = {}
    if t.get("amenity") == "place_of_worship" or b in ("mosque", "church", "cathedral", "chapel"):
        rel = t.get("religion", "")
        if rel == "muslim" or b == "mosque":
            if area > 250:
                return {"type": "mosque", "style": "ottoman", "minarets": 2, "courtyard": False}
            return {"style": "swahili_coastal", "extras": ["crenellations"]}
        if rel == "christian" or b in ("church", "cathedral", "chapel"):
            return {"type": "church", "style": "gothic" if area > 400 else "romanesque"}
    if b in ("kiosk",) or (area < 14 and b not in ("house", "residential")):
        return {"style": "kiosk"}
    if b in ("hut", "roof", "shelter", "pavilion", "gazebo") or rmat in ("thatch", "palm_leaves", "makuti"):
        return {"style": "beach_banda", "levels": 1}
    nb = nb or {}
    core = nb.get("max", 0) >= 6 or nb.get("median", 0) >= 3
    if levels is None and core:
        # untagged building in a mid/high-rise area: inherit the local median, never a 'shack'
        if area >= 80:
            levels = max(2, int(round(nb.get("median", 3))))
            if area > 120:
                spec = {"style": "dar_apartment", "levels": levels}
                return _roof_tags(spec, t, rshape, rmat)
        else:
            return {"style": "fenn_rowhouse", "levels": 1, "extras": ["water_tanks"]}
    if (levels or 0) >= 15 or (height or 0) >= 50:
        return {"type": "tower", "style": "dar_glass", "height": height or levels * 3.8}
    coastal = nb.get("coast", 1e9) < 250 and not core and (levels or 1) <= 4
    if coastal and (t.get("tourism") in ("hotel", "guest_house", "apartment", "resort")
                    or b in ("hotel", "house", "residential", "detached", "villa", "commercial", "retail")
                    or t.get("amenity") in ("restaurant", "bar", "cafe")) and area > 60:
        spec = {"style": "swahili_coastal", "levels": int(levels or (2 if area > 150 else 1))}
        if spec["levels"] < 2:
            spec["extras"] = ["baraza", "crenellations"]
        return _roof_tags(spec, t, rshape, rmat) if rshape in ("gabled", "hipped", "pitched") else spec
    if (levels or 0) >= 4 or b in ("apartments", "office") and (levels or 0) >= 3:
        spec = {"style": "dar_apartment"}
    elif b in ("commercial", "retail", "hotel", "office", "public", "civic") and (levels or 0) >= 2:
        spec = {"style": "dar_apartment"}
    elif (levels or 1) <= 2 and core:
        spec = {"style": "dar_apartment" if (area > 300 and (levels or 1) == 2) else "fenn_rowhouse",
                "extras": ["water_tanks"]}
    elif (levels or 1) <= 2:
        if density > 0.42 and area < 140 and not core:
            spec = {"style": "informal"}
        elif area < 220 and density > 0.25 and not core:
            spec = {"style": "swahili_house"}
        elif b in ("commercial", "retail", "industrial", "warehouse"):
            spec = {"style": "fenn_rowhouse", "extras": ["water_tanks"]}
        else:
            spec = {"style": "dar_house"}
            if area < 60:
                spec["extras"] = ["porch", "tank_stand"]
    else:
        spec = {"style": "dar_apartment"}
    return _roof_tags(spec, t, rshape, rmat)


def _roof_tags(spec, t, rshape, rmat):
    if rshape in ("gabled", "hipped", "pyramidal", "flat", "pitched"):
        spec["roof"] = {"pitched": "hip"}.get(rshape, rshape)
    if rmat in ("metal", "cgi", "metal_sheet", "tin"):
        spec.setdefault("roof_colors", ["#9AA3AD", "#A9B0B6"])
    elif rmat in ("roof_tiles", "tile", "clay"):
        spec.setdefault("roof_colors", ["#C8643B", "#B9573A"])
    col = t.get("roof:colour", "").lower()
    if col.startswith("#") and len(col) == 7:
        spec["roof_colors"] = [col]
    elif col in ROOF_COLOURS:
        spec["roof_colors"] = [ROOF_COLOURS[col]]
    return spec


def rules_generic(t, area, levels, height, density, nb=None):
    if (levels or 0) >= 15 or (height or 0) >= 50:
        return {"type": "tower", "style": "modern_glass", "height": height or levels * 3.6}
    if (levels or 0) >= 4:
        return {"style": "fenn_office"}
    if area < 200:
        return {"style": "fenn_house"}
    return {"style": "fenn_rowhouse"}


REGIONS = {"dar_es_salaam": rules_dar_es_salaam, "generic": rules_generic}


def osm_to_specs(osm, lat, lon, radius, region="dar_es_salaam", max_n=None):
    P = Proj(lat, lon)
    rules = REGIONS[region]
    blds, roads, trees, coast = [], [], [], []
    for e in osm["elements"]:
        t = e.get("tags", {})
        if e["type"] == "way" and "building" in t and "geometry" in e:
            pts = [P(g["lat"], g["lon"]) for g in e["geometry"]]
            if len(pts) >= 4:
                poly = Polygon(pts).buffer(0)
                if poly.geom_type == "Polygon" and poly.area > 2:
                    blds.append((e["id"], t, poly))
        elif e["type"] == "way" and "highway" in t and "geometry" in e:
            roads.append((t, LineString([P(g["lat"], g["lon"]) for g in e["geometry"]])))
        elif e["type"] == "way" and t.get("natural") == "coastline" and "geometry" in e:
            coast.append(LineString([P(g["lat"], g["lon"]) for g in e["geometry"]]))
        elif e["type"] == "node" and t.get("natural") == "tree":
            trees.append(P(e["lat"], e["lon"]))
    blds = [b for b in blds if b[2].centroid.distance(Point(0, 0)) <= radius]
    trees = [p for p in trees if math.hypot(*p) <= radius]
    blds.sort(key=lambda x: x[2].centroid.distance(Point(0, 0)))
    if max_n:
        blds = blds[:max_n]
    polys = [p for _, _, p in blds]
    tree_idx = STRtree(polys) if polys else None
    road_geoms = [g for _, g in roads if g.length > 1]
    road_idx = STRtree(road_geoms) if road_geoms else None
    lv_tag = [(_num(t.get("building:levels")) or (_num(t.get("height")) or 0) / 3.2 or None) for _, t, _ in blds]
    specs = []
    for k_b, (bid, t, poly) in enumerate(blds):
        c = poly.centroid
        ring80 = tree_idx.query(c.buffer(80)) if tree_idx is not None else []
        nbl = [lv_tag[i] for i in ring80 if i != k_b and lv_tag[i]]
        nb = {"median": float(np.median(nbl)) if len(nbl) >= 3 else 0.0, "max": max(nbl) if nbl else 0.0,
              "coast": min((g.distance(c) for g in coast), default=1e9)}
        disk = c.buffer(35)
        near = tree_idx.query(disk) if tree_idx is not None else []
        density = sum(polys[i].intersection(disk).area for i in near) / disk.area
        levels = _num(t.get("building:levels"))
        height = _num(t.get("height"))
        if levels is None and height:
            levels = max(1, round(height / 3.2))
        spec = rules(t, poly.area, levels, height, density, nb)
        spec["id"] = f"way{bid}"
        spec["footprint"] = [[round(x, 2), round(y, 2)] for x, y in list(poly.exterior.coords)[:-1]]
        holes = [[[round(x, 2), round(y, 2)] for x, y in list(r.coords)[:-1]] for r in poly.interiors]
        if holes:
            spec["holes"] = holes
        if spec.get("type") != "tower":
            spec["levels"] = int(spec.get("levels") or levels or (1 if poly.area < 400 else 2))
        if road_idx is not None:
            k = road_idx.nearest(c)
            q = road_geoms[k].interpolate(road_geoms[k].project(c))
            spec["street"] = [round(q.x, 2), round(q.y, 2)]
        spec["_tags"] = {k: v for k, v in t.items() if k.startswith(("building", "roof", "name", "height",
                                                                       "amenity", "religion"))}
        spec["_density"] = round(density, 3)
        specs.append(spec)
    extra = {"roads": [[t.get("highway"), [list(map(lambda v: round(v, 2), xy)) for xy in g.coords],
                        _num(t.get("width"), None), t.get("lanes")] for t, g in roads],
             "trees": [[round(x, 2), round(y, 2)] for x, y in trees],
             "coast": [[list(map(lambda v: round(v, 2), xy)) for xy in g.coords] for g in coast]}
    return specs, extra


ROAD_W = {"motorway": 14, "trunk": 14, "primary": 12, "secondary": 10, "tertiary": 8, "residential": 6,
          "unclassified": 6, "service": 4, "living_street": 5, "footway": 2, "path": 1.5, "track": 3}


def build_scene(specs, extra, out_glb, radius, lod=0):
    """Ground + roads + trees + buildings (instances baked) into one preview GLB."""
    import trimesh
    from geomlib import MeshBuilder, hex_rgb, flat_poly, to_gltf, export_glb
    from shapely.ops import unary_union
    from shapely.geometry import box
    import build_building, modules, make_tree
    from core import place_instances

    g = MeshBuilder()
    R = radius + 30
    ground = Point(0, 0).buffer(R, quad_segs=16)
    flat_poly(g, ground, -0.03, True, hex_rgb("#C9B48F"))

    def polys(geom):
        for x in getattr(geom, "geoms", [geom]):
            if x.geom_type == "Polygon" and x.area > 1:
                yield x
            elif hasattr(x, "geoms"):
                yield from polys(x)

    grass = unary_union([Point(x, y).buffer(9) for x, y in extra["trees"]]) if extra["trees"] else None
    if grass is not None and not grass.is_empty:
        for part in polys(grass.simplify(0.5).intersection(ground)):
            flat_poly(g, part, -0.025, True, hex_rgb("#8DB43C"))
    if extra.get("coast"):
        # OSM coastlines run with land on the LEFT: split the ground, colour right-hand pieces as sea
        from shapely.ops import split, linemerge
        lines = linemerge([LineString(c) for c in extra["coast"] if len(c) >= 2])
        try:
            pieces = split(ground, lines)
            for part in getattr(pieces, "geoms", [pieces]):
                rp = part.representative_point()
                segs = [LineString(c) for c in extra["coast"] if len(c) >= 2]
                ln = min(segs, key=lambda L: L.distance(rp))
                d = ln.project(rp)
                a, b2 = ln.interpolate(max(d - 1, 0)), ln.interpolate(min(d + 1, ln.length))
                cross = (b2.x - a.x) * (rp.y - a.y) - (b2.y - a.y) * (rp.x - a.x)
                if cross < 0:
                    for wp in polys(part):
                        flat_poly(g, wp, -0.02, True, hex_rgb("#7FC6D6"))
        except Exception as ex:
            print("  (coast split skipped:", ex, ")")
    roads = []
    for hw, coords, width, lanes in extra["roads"]:
        w = width or (float(lanes) * 3.2 if lanes and str(lanes).isdigit() else ROAD_W.get(hw, 5))
        roads.append(LineString(coords).buffer(w / 2, cap_style=2, join_style=2))
    if roads:
        u = unary_union(roads).intersection(ground).simplify(0.3)
        for part in polys(u):
            flat_poly(g, part, -0.01, True, hex_rgb("#A49FA8"))
    shell = MeshBuilder()
    insts = []
    for s in specs:
        try:
            b, ins = build_building.build_any(s, lod=lod)
        except Exception as ex:
            print(f"  ! {s['id']}: {ex}")
            continue
        shell.append(b)
        insts += ins
    scene = MeshBuilder()
    scene.append(g, transform=to_gltf, normal_transform=to_gltf)
    scene.append(shell, transform=to_gltf, normal_transform=to_gltf)
    place_instances(scene, insts, modules.get_module)
    tree_lib = [make_tree.build("puff", 1, 3, None), make_tree.build("puff", 1, 5, None)]
    rng = np.random.default_rng(1)
    for i, (x, y) in enumerate(extra["trees"]):
        t = tree_lib[i % 2]
        sc = rng.uniform(0.7, 1.0)
        pos = to_gltf(np.array([x, y, 0.0]))
        scene.append(t, transform=lambda p, pos=pos, sc=sc: to_gltf(p) * sc + pos, normal_transform=to_gltf)
    export_glb(scene, out_glb, zup_input=False)
    return shell.tri_count, len(insts), scene.tri_count


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--center", nargs=2, type=float, required=True, metavar=("LAT", "LON"))
    ap.add_argument("--radius", type=float, default=200)
    ap.add_argument("--region", default="dar_es_salaam", choices=list(REGIONS))
    ap.add_argument("--osm-json", help="use a saved Overpass response instead of fetching")
    ap.add_argument("--save-osm", help="save the raw Overpass response")
    ap.add_argument("--source", choices=["auto", "overpass", "api"], default="auto",
                    help="auto: Overpass mirrors then the OSM API; api: straight to the OSM API (small areas)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--scene", help="also build a preview scene GLB (ground, roads, trees, buildings)")
    ap.add_argument("--max", type=int)
    a = ap.parse_args()
    lat, lon = a.center
    if a.osm_json:
        osm = json.load(open(a.osm_json))
    elif a.source == "api":
        osm = fetch_osm_api(lat, lon, a.radius)
    elif a.source == "overpass":
        osm = _fetch_overpass(lat, lon, a.radius)
    else:
        osm = fetch(lat, lon, a.radius)
    if a.save_osm:
        json.dump(osm, open(a.save_osm, "w"))
    specs, extra = osm_to_specs(osm, lat, lon, a.radius, a.region, a.max)
    json.dump(specs, open(a.out, "w"), indent=1)
    json.dump(extra, open(os.path.splitext(a.out)[0] + "_context.json", "w"))
    counts = {}
    for s in specs:
        k = s.get("type", "") + ":" + s.get("style", "")
        counts[k] = counts.get(k, 0) + 1
    print(f"{len(specs)} buildings, {len(extra['roads'])} roads, {len(extra['trees'])} trees -> {a.out}")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {v:4}  {k.strip(':')}")
    if a.scene:
        shell, ninst, total = build_scene(specs, extra, a.scene, a.radius)
        print(f"scene: {shell:,} unique shell tris, {ninst:,} instances, {total:,} preview tris -> {a.scene}")


if __name__ == "__main__":
    main()
