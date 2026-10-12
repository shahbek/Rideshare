#!/usr/bin/env python3
"""ZPK1: compact streaming container for one format-2 Diorama scenery package.

The phone (`DioramaStreamPackage.swift`) decodes a .zpk back into an ordinary format-2 package and
installs it, so nothing downstream changes. Techniques (meshoptimizer/Draco style, done natively):

* every vertex attribute is split into its own stream and entropy-coded with LZMA2 (xz container,
  which Apple's Compression framework decodes);
* repeated values are coded as back-references into the list of values seen so far
  (positions, colours, instance columns, paint points), new values as residuals from the previous one;
* flat-shaded vertex normals are not stored at all: the phone recomputes them from the triangle
  (77% of vertices); the rest use 2x10-bit octahedral quantisation (<0.1 degree);
* wall-height/coverage floats are quantised to 1 mm and coded relative to the vertex height;
* paint half-planes are stored as their triangle corners in millimetres and rebuilt on the phone;
  triangles that would not round-trip within 1.5 mm are stored raw;
* positions and indices stay exact (millimetres), verified by a SHA-256 over both.

Usage:  python3 zpk.py encode <package-dir> <out.zpk> [--verify]
"""
import hashlib, json, lzma, math, struct, sys
import numpy as np

try:
    import liblzfse  # pip install pyliblzfse
except ImportError:  # pragma: no cover
    liblzfse = None

MAGIC = b"ZPK1"
OCT_BITS = 10
OCT_MAX = (1 << (OCT_BITS - 1)) - 1
FLAT_DOT = 0.9999
HEIGHT_FLAG_MM = 50_000  # appearance.z above 50 is wall height + 100 m

# ---------------------------------------------------------------- format-2 package reader
FIELDS = {"vertices": [4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2, 4], "indices": [4], "paintIndices": [4],
          "lightIndices": [4], "ground": [1, 1, 1, 1], "paint": [4] * 16}


def read_section(directory, manifest, name):
    section = next(s for s in manifest["sections"] if s["name"] == name)
    out = []
    for block in section["blocks"]:
        raw = open(f"{directory}/{block['file']}", "rb").read()
        if block["compressed"]:
            raw = liblzfse.decompress(raw)
        assert len(raw) == block["bytes"]
        if manifest["format"] >= 2 and name in FIELDS:
            raw = undo_codec(raw, FIELDS[name])
        out.append(raw)
    return b"".join(out)


def undo_codec(raw, fields):
    record = sum(fields)
    n = len(raw) // record
    a = np.frombuffer(raw, np.uint8)
    res = np.zeros((n, record), np.uint8)
    po = fo = 0
    for w in fields:
        planes = a[po:po + w * n].reshape(w, n).astype(np.uint64)
        z = np.zeros(n, np.uint64)
        for i in range(w):
            z |= planes[i] << np.uint64(8 * i)
        mask = np.uint64((1 << (8 * w)) - 1)
        d = np.where(z & np.uint64(1), (~(z >> np.uint64(1))) & mask, z >> np.uint64(1))
        v = np.cumsum(d, dtype=np.uint64) & mask
        for i in range(w):
            res[:, fo + i] = ((v >> np.uint64(8 * i)) & np.uint64(255)).astype(np.uint8)
        po += w * n
        fo += w
    return res.tobytes()

# ---------------------------------------------------------------- primitives (mirrored in Swift)


def planes(values, width):
    v = np.asarray(values, np.uint64)
    return b"".join(((v >> np.uint64(8 * i)) & np.uint64(255)).astype(np.uint8).tobytes() for i in range(width))


def unplanes(data, count, width, offset=0):
    a = np.frombuffer(data, np.uint8, count * width, offset).reshape(width, count).astype(np.uint64)
    v = np.zeros(count, np.uint64)
    for i in range(width):
        v |= a[i] << np.uint64(8 * i)
    return v


def zigzag(residual, width):
    """Modular residual (already masked to `width` bytes) -> zig-zag, like DioramaArchiveCodec."""
    bits = np.uint64(8 * width)
    mask = np.uint64((1 << (8 * width)) - 1)
    r = np.asarray(residual, np.uint64) & mask
    negative = (r >> (bits - np.uint64(1))) & np.uint64(1)
    return np.where(negative == 1, ((~r & mask) << np.uint64(1) | np.uint64(1)) & mask, (r << np.uint64(1)) & mask)


def unzigzag(z, width):
    mask = np.uint64((1 << (8 * width)) - 1)
    z = np.asarray(z, np.uint64)
    return np.where(z & np.uint64(1), ~(z >> np.uint64(1)) & mask, z >> np.uint64(1))


def residuals(values, predictions, width):
    mask = (1 << (8 * width)) - 1
    v = np.asarray(values, np.int64) & mask
    p = np.asarray(predictions, np.int64) & mask
    return zigzag((v - p) & mask, width)


def delta_planes(values, width):
    v = np.asarray(values, np.int64)
    return planes(residuals(v, np.concatenate([[0], v[:-1]]), width), width)


def back_refs(keys):
    """0 for a value not seen before, else its distance back in the list of distinct values so far."""
    n = len(keys)
    if n == 0:
        return np.zeros(0, np.uint64), np.zeros(0, bool)
    _, first, inverse = np.unique(keys, return_index=True, return_inverse=True)
    order = np.argsort(first)
    rank = np.empty_like(order)
    rank[order] = np.arange(len(order))
    r = rank[inverse.ravel()]
    is_new = np.zeros(n, bool)
    is_new[first] = True
    seen = np.cumsum(is_new) - is_new
    return np.where(is_new, 0, seen - r).astype(np.uint64), is_new


def column_dictionary(columns):
    """Per-column back-references (4 planes) followed by new raw 32-bit values (4 planes)."""
    out = b""
    for col in columns:
        refs, new = back_refs(col)
        out += planes(refs, 4) + planes(col[new], 4)
    return out


def xz(data):
    if not data:
        return b""
    dictionary = 1 << max(16, min(24, math.ceil(math.log2(max(len(data), 1)))))
    return lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32,
                         filters=[{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME, "dict_size": dictionary}])


def bits(flags):
    return np.packbits(np.asarray(flags, np.uint8)).tobytes()

# ---------------------------------------------------------------- normals (decoder mirrors these)


def face_normals(pos_mm, indices):
    p = pos_mm.astype(np.float64)
    t = indices.reshape(-1, 3).astype(np.int64)
    a, b, c = p[t[:, 0]], p[t[:, 1]], p[t[:, 2]]
    u = b - a
    v = c - a
    x = u[:, 1] * v[:, 2] - u[:, 2] * v[:, 1]
    y = u[:, 2] * v[:, 0] - u[:, 0] * v[:, 2]
    z = u[:, 0] * v[:, 1] - u[:, 1] * v[:, 0]
    length = np.sqrt(x * x + y * y + z * z)
    ok = length > 0
    safe = np.where(ok, length, 1)
    return np.stack([x / safe, y / safe, z / safe], 1), ok


def first_triangle(indices, n):
    tri = np.full(n, -1, np.int64)
    order = np.arange(len(indices))[::-1]
    tri[indices[order]] = order // 3
    return tri


def oct_encode(nv):
    nv = nv / np.maximum(np.abs(nv).sum(1, keepdims=True), 1e-30)
    x, y, neg = nv[:, 0], nv[:, 1], nv[:, 2] < 0
    sx = np.where(x >= 0, 1.0, -1.0)
    sy = np.where(y >= 0, 1.0, -1.0)
    ox = np.where(neg, (1 - np.abs(y)) * sx, x)
    oy = np.where(neg, (1 - np.abs(x)) * sy, y)
    return np.round(ox * OCT_MAX).astype(np.int64), np.round(oy * OCT_MAX).astype(np.int64)


def oct_decode(ox, oy):
    fx = ox.astype(np.float64) / OCT_MAX
    fy = oy.astype(np.float64) / OCT_MAX
    fz = 1 - np.abs(fx) - np.abs(fy)
    neg = fz < 0
    sx = np.where(fx >= 0, 1.0, -1.0)
    sy = np.where(fy >= 0, 1.0, -1.0)
    nx = np.where(neg, (1 - np.abs(fy)) * sx, fx)
    ny = np.where(neg, (1 - np.abs(fx)) * sy, fy)
    length = np.sqrt(nx * nx + ny * ny + fz * fz)
    return np.stack([nx / length, ny / length, fz / length], 1)

# ---------------------------------------------------------------- paint


def paint_edge(a, b):
    d = b - a
    length = np.sqrt(d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1])
    with np.errstate(all="ignore"):
        dx, dy = d[:, 0] / length, d[:, 1] / length
    ix, iy = -dy, dx
    return np.stack([ix, iy, -(ix * a[:, 0] + iy * a[:, 1])], 1)


def paint_split(paint):
    """Corners (mm) for triangles that rebuild within 1.5 mm and the same orientation; others raw."""
    e = [paint[:, 0:4].astype(np.float64), paint[:, 4:8].astype(np.float64), paint[:, 8:12].astype(np.float64)]

    def meet(f, g):
        det = f[:, 0] * g[:, 1] - f[:, 1] * g[:, 0]
        with np.errstate(all="ignore"):
            return np.stack([(-f[:, 2] * g[:, 1] + g[:, 2] * f[:, 1]) / det, (-f[:, 0] * g[:, 2] + g[:, 0] * f[:, 2]) / det], 1)
    corners = np.stack([meet(e[2], e[0]), meet(e[0], e[1]), meet(e[1], e[2])], 1)
    bad = ~np.isfinite(corners).all((1, 2)) | (np.abs(np.nan_to_num(corners, nan=1e9)) > 2e6).any((1, 2))
    q = np.round(np.nan_to_num(corners, nan=0.0) * 1000).astype(np.int64)
    rebuilt = q / 1000.0
    for k, (i, j) in enumerate([(0, 1), (1, 2), (2, 0)]):
        r = paint_edge(rebuilt[:, i], rebuilt[:, j])
        with np.errstate(all="ignore"):
            dist = np.maximum(np.abs(r[:, 0] * corners[:, i, 0] + r[:, 1] * corners[:, i, 1] + r[:, 2]),
                              np.abs(r[:, 0] * corners[:, j, 0] + r[:, 1] * corners[:, j, 1] + r[:, 2]))
            dot = r[:, 0] * e[k][:, 0] + r[:, 1] * e[k][:, 1]
        bad |= ~((dist < 1.5e-3) & (dot > 0.999))
    layer, epoch, layer2 = paint[:, 3], paint[:, 7], paint[:, 11]
    bad |= (layer != layer2) | (layer != np.round(layer)) | (epoch != np.round(epoch)) | (layer < 0) | (epoch < 0)
    return q, bad

# ---------------------------------------------------------------- meta (manifest minus sections)


def mm(values, rounding):
    return [int(rounding(v * 1000)) for v in values]


def deltas(values):
    out, previous = [], 0
    for v in values:
        out.append(v - previous)
        previous = v
    return out


def bounds_columns(rows, out):
    for axis, name in enumerate("XYZ"):
        out["min" + name] = deltas([math.floor(r["minimum"][axis] * 1000) for r in rows])
        out["max" + name] = deltas([math.ceil(r["maximum"][axis] * 1000) for r in rows])


def meta(manifest):
    m = {k: v for k, v in manifest.items() if k not in ("sections", "ranges", "groups", "labels", "sources")}
    r = manifest["ranges"]
    ranges = {"category": [x["category"] for x in r], "start": deltas([x["start"] for x in r]), "count": [x["count"] for x in r],
              "doubleSided": [x["doubleSided"] for x in r], "translucent": [x.get("translucent") for x in r]}
    bounds_columns(r, ranges)
    g = manifest["groups"]
    groups = {"category": [x["category"] for x in g], "fullStart": deltas([x["fullStart"] for x in g]),
              "fullCount": [x["fullCount"] for x in g], "lightStart": deltas([x["lightStart"] for x in g]),
              "lightCount": [x["lightCount"] for x in g], "first": deltas([x["first"] for x in g]),
              "count": [x["count"] for x in g], "doubleSided": [x["doubleSided"] for x in g]}
    bounds_columns(g, groups)
    lab = manifest["labels"]
    labels = {"id": [x["id"] for x in lab], "title": [x["title"] for x in lab], "isNamed": [x["isNamed"] for x in lab],
              "anchor": [v for x in lab for v in mm(x["anchor"], round)],
              "footprintCount": [len(x["footprint"]) for x in lab],
              "footprint": [v for x in lab for p in x["footprint"] for v in mm(p, round)]}
    s = manifest["sources"]
    sources = {"position": [v for x in s for v in mm(x["position"], round)], "color": [v for x in s for v in x["color"]],
               "radius": [x["radius"] for x in s], "intensity": [x["intensity"] for x in s]}
    m.update(ranges=ranges, groups=groups, labels=labels, sources=sources)
    return json.dumps(m, separators=(",", ":"), sort_keys=True).encode()

# ---------------------------------------------------------------- encoder


def load(directory):
    manifest = json.load(open(f"{directory}/manifest.json"))
    assert manifest["format"] == 2 and manifest["vertexStride"] == 32 and manifest["instanceStride"] == 64
    sec = {s["name"]: read_section(directory, manifest, s["name"]) for s in manifest["sections"]}
    return manifest, sec


def encode(directory):
    manifest, sec = load(directory)
    V = np.frombuffer(sec["vertices"], np.uint8).reshape(-1, 32)
    n = len(V)
    I = np.frombuffer(sec["indices"], np.uint32).astype(np.int64)
    pos = V[:, 0:12].copy().view(np.int32).reshape(-1, 3).astype(np.int64)
    normals_half = V[:, 12:18].copy().view(np.float16).reshape(-1, 3).astype(np.float64)
    nw = V[:, 18:20].copy().view(np.uint16).ravel().astype(np.int64)
    colours = V[:, 20:26].copy().view(np.uint16).reshape(-1, 3).astype(np.int64)
    cw = V[:, 26:28].copy().view(np.uint16).ravel().astype(np.int64)
    az = V[:, 28:32].copy().view(np.float32).ravel().astype(np.float64)
    assert np.isfinite(az).all() and (np.abs(az) < 2e6).all()
    streams = {}
    streams["meta"] = meta(manifest)
    streams["indices"] = delta_planes(I, 4)
    # positions
    keys = np.ascontiguousarray(V[:, 0:12]).view(np.dtype((np.void, 12))).ravel()
    refs, new = back_refs(keys)
    streams["positionRefs"] = planes(refs, 4)
    previous = np.vstack([np.zeros((1, 3), np.int64), pos[:-1]])
    streams["positionNew"] = b"".join(planes(residuals(pos[new, k], previous[new, k], 4), 4) for k in range(3))
    # normals
    fn, ok = face_normals(pos, I)
    tri = first_triangle(I, n)
    unit = normals_half / np.maximum(np.linalg.norm(normals_half, axis=1, keepdims=True), 1e-9)
    has = tri >= 0
    face = np.zeros((n, 3))
    face[has] = fn[tri[has]]
    flat = has & np.where(has, ok[np.maximum(tri, 0)], False) & ((face * unit).sum(1) > FLAT_DOT)
    streams["flatNormals"] = bits(flat)
    ox, oy = oct_encode(unit[~flat])
    streams["octNormals"] = delta_planes(ox, 2) + delta_planes(oy, 2)
    # colours
    ckeys = np.ascontiguousarray(V[:, 20:26]).view(np.dtype((np.void, 6))).ravel()
    crefs, cnew = back_refs(ckeys)
    streams["colorRefs"] = planes(crefs, 4)
    streams["colorNew"] = b"".join(planes(colours[cnew, k], 2) for k in range(3))
    streams["colorW"] = delta_planes(cw, 2)
    streams["normalW"] = delta_planes(nw, 2)
    # heights (appearance.z): 1 mm, relative to vertex height for wall heights
    q = np.round(az * 1000).astype(np.int64)
    hflag = q > HEIGHT_FLAG_MM
    r = q - np.where(hflag, pos[:, 2], 0)
    streams["heightFlags"] = bits(hflag)
    streams["heights"] = delta_planes(r, 4)
    # instances
    inst = np.frombuffer(sec["instances"], np.uint32).reshape(-1, 16)
    instf = inst.view(np.float32).astype(np.float64)
    assert np.isfinite(instf[:, :3]).all()
    imm = np.round(instf[:, :3] * 1000).astype(np.int64)
    streams["instances"] = b"".join(delta_planes(imm[:, k], 4) for k in range(3)) + \
        column_dictionary([inst[:, k].astype(np.int64) for k in range(3, 16)])
    # paint
    paint_u = np.frombuffer(sec["paint"], np.uint32).reshape(-1, 16)
    paint = paint_u.view(np.float32).astype(np.float64)
    corners, bad = paint_split(paint)
    good = ~bad
    streams["paintFlags"] = bits(bad)
    pts = corners[good].reshape(-1, 2)
    pkeys = ((pts[:, 0].astype(np.uint64) & np.uint64(0xFFFFFFFF)) << np.uint64(32)) | (pts[:, 1].astype(np.uint64) & np.uint64(0xFFFFFFFF))
    prefs, pnew = back_refs(pkeys)
    pprev = np.vstack([np.zeros((1, 2), np.int64), pts[:-1]])
    streams["paintPoints"] = planes(prefs, 4) + b"".join(planes(residuals(pts[pnew, k], pprev[pnew, k], 4), 4) for k in range(2))
    streams["paintAttributes"] = column_dictionary([paint_u[good, k].astype(np.int64) for k in range(12, 16)]) + \
        delta_planes(paint[good, 3].astype(np.int64), 4) + delta_planes(paint[good, 7].astype(np.int64), 4)
    streams["paintRaw"] = paint_u[bad].tobytes()
    streams["paintTable"] = sec["paintTable"]
    streams["paintIndices"] = delta_planes(np.frombuffer(sec["paintIndices"], np.uint32).astype(np.int64), 4)
    streams["ground"] = sec["ground"]
    streams["lights"] = sec["lights"]
    streams["lightTable"] = sec["lightTable"]
    streams["lightIndices"] = sec["lightIndices"]

    check = hashlib.sha256(pos.astype("<i4").tobytes() + I.astype("<u4").tobytes()).hexdigest()
    stored = {k: xz(v) for k, v in streams.items()}
    header = {"version": 1, "package": manifest["key"], "vertexCount": n, "indexCount": len(I), "instanceCount": len(inst),
              "paintCount": len(paint_u), "paintRawCount": int(bad.sum()), "check": check,
              "streams": [{"name": k, "raw": len(streams[k]), "stored": len(stored[k])} for k in streams]}
    head = json.dumps(header, separators=(",", ":")).encode()
    blob = MAGIC + struct.pack("<I", len(head)) + head + b"".join(stored[k] for k in streams)
    stats = {"vertices": n, "flat": float(flat.mean()), "paintRaw": int(bad.sum()),
             "streams": {k: len(stored[k]) for k in streams}}
    return blob, stats, (manifest, sec)

# ---------------------------------------------------------------- reference decoder (for --verify)


def decode(blob):
    assert blob[:4] == MAGIC
    (hl,) = struct.unpack("<I", blob[4:8])
    header = json.loads(blob[8:8 + hl])
    offset = 8 + hl
    s = {}
    for st in header["streams"]:
        raw = lzma.decompress(blob[offset:offset + st["stored"]]) if st["stored"] else b""
        assert len(raw) == st["raw"]
        s[st["name"]] = raw
        offset += st["stored"]
    n, m = header["vertexCount"], header["indexCount"]

    def undelta(data, count, width, off=0):
        z = unplanes(data, count, width, off)
        d = unzigzag(z, width)
        return (np.cumsum(d, dtype=np.uint64) & np.uint64((1 << (8 * width)) - 1))

    I = undelta(s["indices"], m, 4).astype(np.int64)
    refs = unplanes(s["positionRefs"], n, 4).astype(np.int64)
    k_new = int((refs == 0).sum())
    res = [unzigzag(unplanes(s["positionNew"], k_new, 4, c * 4 * k_new), 4).astype(np.int64) for c in range(3)]
    pos = np.zeros((n, 3), np.int64)
    uniq = np.zeros((k_new, 3), np.int64)
    count = 0
    prev = [0, 0, 0]
    for i in range(n):
        r = refs[i]
        if r == 0:
            p = [((prev[c] + int(res[c][count])) + 2**31) % 2**32 - 2**31 for c in range(3)]
            uniq[count] = p
            count += 1
        else:
            p = list(uniq[count - r])
        pos[i] = p
        prev = p
    check = hashlib.sha256(pos.astype("<i4").tobytes() + I.astype("<u4").tobytes()).hexdigest()
    assert check == header["check"], "position/index check failed"
    flat = np.unpackbits(np.frombuffer(s["flatNormals"], np.uint8))[:n].astype(bool)
    f = int((~flat).sum())
    ox = undelta(s["octNormals"], f, 2).astype(np.int64)
    oy = undelta(s["octNormals"], f, 2, 2 * f).astype(np.int64)
    ox = np.where(ox >= 2**15, ox - 2**16, ox)
    oy = np.where(oy >= 2**15, oy - 2**16, oy)
    normals = np.zeros((n, 3))
    fn, _ = face_normals(pos, I)
    tri = first_triangle(I, n)
    normals[flat] = fn[tri[flat]]
    normals[~flat] = oct_decode(ox, oy)
    hflag = np.unpackbits(np.frombuffer(s["heightFlags"], np.uint8))[:n].astype(bool)
    r = undelta(s["heights"], n, 4).astype(np.int64)
    r = np.where(r >= 2**31, r - 2**32, r)
    q = r + np.where(hflag, pos[:, 2], 0)
    return header, pos, I, normals, q / 1000.0


def verify(blob, original):
    manifest, sec = original
    header, pos, I, normals, az = decode(blob)
    V = np.frombuffer(sec["vertices"], np.uint8).reshape(-1, 32)
    orig_pos = V[:, 0:12].copy().view(np.int32).reshape(-1, 3)
    assert (orig_pos == pos).all()
    assert (np.frombuffer(sec["indices"], np.uint32) == I).all()
    nh = V[:, 12:18].copy().view(np.float16).reshape(-1, 3).astype(np.float64)
    nh /= np.maximum(np.linalg.norm(nh, axis=1, keepdims=True), 1e-9)
    angle = np.degrees(np.arccos(np.clip((nh * normals).sum(1), -1, 1)))
    oaz = V[:, 28:32].copy().view(np.float32).ravel()
    print(f"  positions/indices exact; normal error p50 {np.percentile(angle, 50):.3f} p99 {np.percentile(angle, 99):.3f} "
          f"max {angle.max():.3f} deg; height error max {np.abs(oaz - az).max() * 1000:.3f} mm")


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[1] != "encode":
        print(__doc__)
        sys.exit(1)
    blob, stats, original = encode(sys.argv[2])
    open(sys.argv[3], "wb").write(blob)
    print(f"{sys.argv[2]}: {len(blob):,} bytes  flat normals {stats['flat']:.1%}  paint raw {stats['paintRaw']}")
    print("  " + ", ".join(f"{k} {v:,}" for k, v in stats["streams"].items()))
    if "--verify" in sys.argv:
        verify(blob, original)
