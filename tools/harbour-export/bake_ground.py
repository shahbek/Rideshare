"""Bake a tile's ground colour (terrain vertex colours + the vector road/pavement/lane/kerb paint the
app's shader draws per pixel) into one top-down image, so Blender gets the roads as a real texture."""
import struct, zlib
import numpy as np

LAWN = np.array([120, 170, 44], np.float32) / 255

def png(rgb8):
    h, w, _ = rgb8.shape
    raw = np.concatenate([np.zeros((h, 1), np.uint8), rgb8.reshape(h, w * 3)], axis=1).tobytes()
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')

def bake(h, paint, ground_tris, size=4096):
    """ground_tris: (n,3,2) xy + (n,3,3) rgb as two arrays. paint: (n,16) float records."""
    (minx, miny, maxx, maxy) = h['bounds']; W = maxx - minx; H = maxy - miny
    img = np.empty((size, size, 3), np.float32); img[:] = LAWN
    def to_px(x, y): return (x - minx) / W * size, (maxy - y) / H * size
    xy, rgb, zz = ground_tris
    for t in range(len(xy)):
        px, py = to_px(xy[t, :, 0], xy[t, :, 1])
        x0, x1 = max(int(px.min()), 0), min(int(px.max()) + 1, size - 1); y0, y1 = max(int(py.min()), 0), min(int(py.max()) + 1, size - 1)
        if x1 < x0 or y1 < y0: continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        d = (py[1] - py[2]) * (px[0] - px[2]) + (px[2] - px[1]) * (py[0] - py[2])
        if abs(d) < 1e-9: continue
        a = ((py[1] - py[2]) * (gx - px[2]) + (px[2] - px[1]) * (gy - py[2])) / d
        b = ((py[2] - py[0]) * (gx - px[2]) + (px[0] - px[2]) * (gy - py[2])) / d
        c = 1 - a - b; m = (a >= -0.01) & (b >= -0.01) & (c >= -0.01)
        col = a[..., None] * rgb[t, 0] + b[..., None] * rgb[t, 1] + c[..., None] * rgb[t, 2]
        z = a * zz[t, 0] + b * zz[t, 1] + c * zz[t, 2]
        k = np.clip((z - 2.0) / 3.0, 0, 1)[..., None]
        col = col * (1 - k) + LAWN * k
        img[y0:y1 + 1, x0:x1 + 1][m] = col[m]
    cov = np.zeros((size, size), np.float32)
    aa = 0.12
    def raster(rec, fn):
        e = rec[:12].reshape(3, 4)
        xs = [(-e[i, 2] / 1) for i in range(3)]
        # bounding box from the triangle corners: intersect edge lines pairwise
        pts = []
        for i in range(3):
            A = np.array([e[i, :2], e[(i + 1) % 3, :2]]); bb = -np.array([e[i, 2], e[(i + 1) % 3, 2]])
            if abs(np.linalg.det(A)) > 1e-9: pts.append(np.linalg.solve(A, bb))
        if len(pts) < 3: return None
        pts = np.array(pts)
        px0, py0 = to_px(pts[:, 0].min() - 0.3, pts[:, 1].max() + 0.3); px1, py1 = to_px(pts[:, 0].max() + 0.3, pts[:, 1].min() - 0.3)
        x0, x1 = max(int(px0), 0), min(int(px1) + 1, size - 1); y0, y1 = max(int(py0), 0), min(int(py1) + 1, size - 1)
        if x1 < x0 or y1 < y0: return None
        X = minx + (np.arange(x0, x1 + 1) + 0.5) / size * W; Y = maxy - (np.arange(y0, y1 + 1) + 0.5) / size * H
        gx, gy = np.meshgrid(X, Y)
        s = [e[i, 0] * gx + e[i, 1] * gy + e[i, 2] for i in range(3)]
        return (x0, x1, y0, y1), np.minimum(np.minimum(s[0], s[1]), s[2]), s[0]
    hy = [r for r in paint if r[15] < -99.5]
    layer = None; box = None; color = None
    def flush():
        nonlocal layer, box
        if box is None: return
        x0, x1, y0, y1 = box
        c = np.clip(cov[y0:y1 + 1, x0:x1 + 1], 0, 1)[..., None]
        img[y0:y1 + 1, x0:x1 + 1] = img[y0:y1 + 1, x0:x1 + 1] * (1 - c) + color * c
        cov[y0:y1 + 1, x0:x1 + 1] = 0; box = None
    for r in hy:
        if layer != r[3]: flush(); layer = r[3]; color = r[12:15]
        o = raster(r, None)
        if o is None: continue
        (x0, x1, y0, y1), dist, _ = o
        cov[y0:y1 + 1, x0:x1 + 1] += np.clip(dist / (2 * aa) + 0.5, 0, 1)
        box = (x0, x1, y0, y1) if box is None else (min(box[0], x0), max(box[1], x1), min(box[2], y0), max(box[3], y1))
    flush()
    for r in paint:
        w = r[15]
        if w < 0: continue
        o = raster(r, None)
        if o is None: continue
        (x0, x1, y0, y1), dist, s0 = o
        c = np.clip(dist / (2 * aa) + 0.5, 0, 1)
        sub = img[y0:y1 + 1, x0:x1 + 1]
        if w > 2.5:
            s = s0 if w < 3.5 else 0.7 - s0
            c = c * (s < 0.25) * (s > -0.05)
            colr = r[12:15]
        else:
            asphalt = (sub.max(-1) - sub.min(-1)) < 0.14
            c = c * asphalt; colr = r[12:15]
        sub[:] = sub * (1 - c[..., None]) + colr * c[..., None]
    return png((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8))
