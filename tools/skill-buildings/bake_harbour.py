#!/usr/bin/env python3
"""Harbour buildings from the stylized-map-renderer skill, and nothing else.

Every harbour building is produced by the skill's own generator (`build_building.build_any`, which
dispatches to `styles.build_styled` or the `landmarks` generators) from OSM footprints imported by
the skill's `osm_import.osm_to_specs` with the Dar es Salaam region rules. This script only:

  1. swaps the importer's equirectangular projection for the app's (`DioramaProjection`: metres per
     degree of longitude and Mercator northing, both scaled by cos(origin latitude)), so footprints
     land exactly on the app's roads;
  2. keeps buildings whose centroid lies in one of the two harbour tiles;
  3. hand-authors skill tower specs for the two hero towers (the skill's advice for hero accuracy);
  4. writes the shells, the module library and the instance list into one binary for the app.

Usage:
  python3 tools/skill-buildings/bake_harbour.py [--fetch] [--out ios-twende/Twende/Resources/harbour_skill_buildings.bin]

Binary layout (little endian), read by `DioramaSkillBuildings.swift`:
  'SKB2' u32 version, f64 originLat, f64 originLon, u32 payloadBytes, then a raw-DEFLATE payload:
  u32 moduleCount, buildingCount, vertexCount, indexCount, instanceCount, ringCount
  modules  : u32 vertexStart, vertexCount, indexStart, indexCount, lightStart, lightCount, f32 radius
             (light = the skill's LOD1 form: window glass only, roof props dropped)
  buildings: u64 osmId, f64 lon, f64 lat (local origin = footprint centroid), f32 height, u8 kind,
             u8 pad[3], u32 vertexStart, vertexCount, indexStart, indexCount, instanceStart,
             instanceCount, ringStart, ringCount, then the skill's LOD2 shell (lod=2, used for the
             coarse surroundings): u32 vertexStart, vertexCount, indexStart, indexCount
  ring     : f32 x, f32 y per footprint point (building-local metres, CCW)
  vertices : i16 x, y, z (centimetres, z-up; building-local for shells, prototype-local for
             modules), i8 nx, ny, nz, u8 material (0 painted, 1 glass), u8 r, g, b, u8 ao
  indices  : u16, relative to the owning building's or module's first vertex
  instances: u16 module, u8 lit, u8 pad, f32 x, y, z (building-local), f32 yaw, f32 scale
"""
import argparse
import json
import math
import os
import struct
import sys

import numpy as np
from shapely.geometry import Polygon

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SKILL = os.path.join(ROOT, ".agents", "skills", "stylized-map-renderer", "scripts")
sys.path.insert(0, SKILL)

import osm_import  # noqa: E402  (skill)
import build_building  # noqa: E402  (skill)
import modules  # noqa: E402  (skill)
from geomlib import hex_rgb  # noqa: E402  (skill)
import zlib  # noqa: E402

TILES = [(39919, 34012), (39920, 34012)]
ZOOM = 16
OSM_SNAPSHOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "harbour_osm.json")
EARTH = 6_378_137.0

# Designed landmarks (Johari Rotana + podium, Bandari Tower, the cathedrals, PSPF) are drawn by the
# app's own landmark models; the skill leaves their footprints empty.
LANDMARK_WAYS = {635183901, 688369868, 368888931, 688369839, 368909370, 688369315, 688369331}

KINDS = {"tower": 1, "mosque": 2, "church": 3, "pagoda": 4}


def tile_bounds(x, y, z=ZOOM):
    n = 2 ** z
    lon0, lon1 = x / n * 360 - 180, (x + 1) / n * 360 - 180
    lat0 = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    lat1 = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return min(lat0, lat1), lon0, max(lat0, lat1), lon1


class AppProjection:
    """`DioramaProjection` from the app: x east, y Mercator north, metres at the origin latitude."""

    def __init__(self, lat0, lon0):
        self.lat0, self.lon0 = lat0, lon0
        rad = math.radians(lat0)
        self.kx = math.pi / 180 * EARTH * math.cos(rad)
        self.y0 = math.log(math.tan(math.pi / 4 + rad / 2))
        self.ky = EARTH * math.cos(rad)

    def __call__(self, lat, lon):
        m = math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
        return ((lon - self.lon0) * self.kx, (m - self.y0) * self.ky)

    def inverse(self, x, y):
        lon = self.lon0 + x / self.kx
        lat = math.degrees(2 * math.atan(math.exp(self.y0 + y / self.ky)) - math.pi / 2)
        return lat, lon


def glass_colours():
    """Window glass gradients from the skill's module palette (anything else is painted)."""
    def rgb(v):
        return np.array(hex_rgb(v) if isinstance(v, str) else v, float)
    return [(rgb(modules.C[f"{k}_top"]), rgb(modules.C[f"{k}_bot"])) for k in ("glass", "tint")
            if f"{k}_top" in modules.C and f"{k}_bot" in modules.C]


def is_glass(rgb, glass):
    """Within 0.05 of a glass gradient (the skill shades panes top to bottom between two colours)."""
    for a, b in glass:
        t = np.clip(np.dot(rgb - a, b - a) / max(np.dot(b - a, b - a), 1e-9), 0, 1)
        if np.abs(rgb - (a + (b - a) * t)).max() < 0.05:
            return True
    return False


def zup(p):
    """glTF (x, y up, -north) back to z-up (x east, y north, z up)."""
    p = np.asarray(p, float)
    return np.stack([p[..., 0], -p[..., 2], p[..., 1]], axis=-1)


def pack_vertex(out, p, n, rgb, ao, material):
    n = np.asarray(n, float)
    n = n / (np.linalg.norm(n) + 1e-12)
    c = np.clip(np.round(np.asarray(rgb) * 255), 0, 255).astype(int)
    q = [int(np.clip(round(float(v) * 100), -32767, 32767)) for v in p[:3]]
    out += struct.pack("<3h3bB3BB", *q, *[int(round(v * 127)) for v in n], material, *c.tolist(),
                       int(round(np.clip(ao, 0, 1) * 255)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fetch", action="store_true", help="refresh the OSM snapshot through the skill importer")
    ap.add_argument("--out", default=os.path.join(ROOT, "ios-twende", "Twende", "Resources", "harbour_skill_buildings.bin"))
    a = ap.parse_args()

    bounds = [tile_bounds(x, y) for x, y in TILES]
    lat_min, lat_max = min(b[0] for b in bounds), max(b[2] for b in bounds)
    lon_min, lon_max = min(b[1] for b in bounds), max(b[3] for b in bounds)
    lat0, lon0 = (lat_min + lat_max) / 2, (lon_min + lon_max) / 2
    radius = 720.0
    if a.fetch or not os.path.exists(OSM_SNAPSHOT):
        osm = osm_import.fetch(lat0, lon0, radius)
        json.dump(osm, open(OSM_SNAPSHOT, "w"))
    osm = json.load(open(OSM_SNAPSHOT))

    proj = AppProjection(lat0, lon0)
    osm_import.Proj = lambda lat, lon: proj  # the skill importer, in the app's projection
    specs, _ = osm_import.osm_to_specs(osm, lat0, lon0, radius, "dar_es_salaam")

    def inside(spec):
        c = Polygon(spec["footprint"]).centroid
        lat, lon = proj.inverse(c.x, c.y)
        return any(b[0] <= lat < b[2] and b[1] <= lon < b[3] for b in bounds)

    specs = [s for s in specs if inside(s) and int(s["id"][3:]) not in LANDMARK_WAYS]

    glass = glass_colours()
    used, module_index = [], {}
    buildings = []
    counts, failures, shell_tris, inst_total, far_tris = {}, [], 0, 0, 0
    for s in specs:
        try:
            shell, inst = build_building.build_any(s, lod=0)
            far, _ = build_building.build_any(dict(s), lod=2)
        except Exception as ex:  # report, never substitute another generator
            failures.append(f"{s['id']} {s.get('type', '')} {s.get('style', '')}: {ex}")
            continue
        if not shell.tris:
            failures.append(f"{s['id']}: empty shell")
            continue
        c = Polygon(s["footprint"]).centroid
        cx, cy = c.x, c.y
        lat, lon = proj.inverse(cx, cy)
        P = np.array(shell.P) - np.array([cx, cy, 0.0])
        N = np.array(shell.N)
        C = np.array(shell.C)
        AO = np.array(shell.AO)
        insts = []
        for i in inst:
            name = i["module"]
            if name not in module_index:
                module_index[name] = len(used)
                used.append(name)
            p = zup(np.array(i["pos"])) - np.array([cx, cy, 0.0])
            lit = zlib.crc32(f"{s['id']}/{len(insts)}".encode()) % 100 < 35
            insts.append((module_index[name], 1 if lit else 0, p, float(i["yaw"]), float(i.get("scale", 1.0))))
        ring = np.array(Polygon(s["footprint"]).exterior.coords)[:-1] - np.array([cx, cy])
        if Polygon(ring).exterior.is_ccw is False:
            ring = ring[::-1]
        kind = KINDS.get(s.get("type", ""), 0)
        height = float(P[:, 2].max())
        buildings.append(dict(id=int(s["id"][3:]), lon=lon, lat=lat, height=height, kind=kind,
                              P=P, N=N, C=C, AO=AO, tris=np.array(shell.tris, dtype=np.uint32), insts=insts, ring=ring,
                              far=(np.array(far.P) - np.array([cx, cy, 0.0]), np.array(far.N), np.array(far.C),
                                   np.array(far.AO), np.array(far.tris, dtype=np.uint32))))
        far_tris += far.tri_count
        key = (s.get("type", "") + ":" + s.get("style", "")).strip(":")
        n, t = counts.get(key, (0, 0))
        counts[key] = (n + 1, t + shell.tri_count)
        shell_tris += shell.tri_count
        inst_total += len(inst)

    # Module library, z-up.
    mod_vertices, mod_indices, mod_table = bytearray(), bytearray(), []
    vbase, ibase = 0, 0
    lib_tris = 0
    for name in used:
        m = modules.get_module(name)
        P, N = zup(np.array(m.P)), zup(np.array(m.N))
        C, AO = np.array(m.C), np.array(m.AO)
        for k in range(len(P)):
            pack_vertex(mod_vertices, P[k], N[k], C[k], AO[k], 1 if is_glass(C[k], glass) else 0)
        tris = np.array(m.tris, dtype=np.uint32).reshape(-1, 3)
        glassy = np.array([1 if is_glass(c, glass) else 0 for c in C])
        if name.startswith("window") or name == "rose_window":
            light = tris[glassy[tris].all(axis=1)]            # LOD1: the pane reads as the window
        elif name.startswith(("door", "shop_shutter", "gate")):
            light = tris[(N[tris].mean(axis=1) @ np.array([0.0, -1.0, 0.0])) > 0.9]  # front faces
        else:
            light = tris[:1][:, [0, 0, 0]]                    # LOD1: dropped (degenerate)
        if len(light) == 0:
            light = tris[:1][:, [0, 0, 0]]
        mod_indices += tris.astype(np.uint16).tobytes()
        light_start = ibase + tris.size
        mod_indices += light.astype(np.uint16).tobytes()
        radius_m = float(np.linalg.norm(P, axis=1).max()) if len(P) else 0.0
        mod_table.append((vbase, len(P), ibase, tris.size, light_start, light.size, radius_m))
        vbase += len(P)
        ibase += tris.size + light.size
        lib_tris += len(tris)

    shell_vertices, shell_indices, instance_bytes, ring_bytes, table = bytearray(), bytearray(), bytearray(), bytearray(), []
    rbase, nbase = 0, 0
    for b in buildings:
        vstart, istart = vbase, ibase
        for k in range(len(b["P"])):
            pack_vertex(shell_vertices, b["P"][k], b["N"][k], b["C"][k], b["AO"][k], 0)
        idx = b["tris"].ravel()
        assert len(b["P"]) < 65536, b["id"]
        shell_indices += idx.astype(np.uint16).tobytes()
        vbase += len(b["P"])
        ibase += len(idx)
        fP, fN, fC, fAO, fT = b["far"]
        fvstart, fistart = vbase, ibase
        for k in range(len(fP)):
            pack_vertex(shell_vertices, fP[k], fN[k], fC[k], fAO[k], 0)
        shell_indices += fT.ravel().astype(np.uint16).tobytes()
        vbase += len(fP)
        ibase += fT.size
        for (mi, lit, p, yaw, sc) in b["insts"]:
            instance_bytes += struct.pack("<HBx5f", mi, lit, float(p[0]), float(p[1]), float(p[2]), yaw, sc)
        for x, y in b["ring"]:
            ring_bytes += struct.pack("<2f", float(x), float(y))
        table.append(struct.pack("<QddfB3x12I", b["id"], b["lon"], b["lat"], b["height"], b["kind"],
                                 vstart, len(b["P"]), istart, len(idx), nbase, len(b["insts"]), rbase, len(b["ring"]),
                                 fvstart, len(fP), fistart, fT.size))
        nbase += len(b["insts"])
        rbase += len(b["ring"])

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    payload = bytearray(struct.pack("<6I", len(used), len(buildings), vbase, ibase, nbase, rbase))
    for row in mod_table:
        payload += struct.pack("<6If", *row)
    for row in table:
        payload += row
    payload += ring_bytes + mod_vertices + shell_vertices + mod_indices + shell_indices + instance_bytes
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = packer.compress(bytes(payload)) + packer.flush()
    with open(a.out, "wb") as f:
        f.write(b"SKB2")
        f.write(struct.pack("<IddI", 2, lat0, lon0, len(payload)))
        f.write(packed)
    size = os.path.getsize(a.out)

    rendered = sum(len(modules.get_module(used[mi]).tris) for b in buildings for (mi, *_rest) in b["insts"])
    print(f"harbour tiles {TILES}: {len(buildings)} buildings from the skill, {len(failures)} failed")
    for k, (n, t) in sorted(counts.items(), key=lambda kv: -kv[1][1]):
        print(f"  {n:4} {k:<24} {t:>9,} shell tris  (mean {t // max(n, 1):,})")
    print(f"unique shell triangles : {shell_tris:,}")
    print(f"LOD2 shells (context)  : {far_tris:,}")
    print(f"library modules        : {len(used)} ({lib_tris:,} tris)")
    print(f"instances              : {inst_total:,} (rendered {rendered:,} tris)")
    print(f"binary                 : {os.path.relpath(a.out, ROOT)} ({size / 1048576:.2f} MB, {len(payload) / 1048576:.2f} MB unpacked)")
    for line in failures[:20]:
        print("  ! " + line)


if __name__ == "__main__":
    main()
