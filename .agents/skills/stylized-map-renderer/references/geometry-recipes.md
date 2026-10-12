# Geometry recipes — rounded stylized buildings from footprints

These recipes generate everything from a footprint (OSM / Overture / your own polygons) plus a few
attributes: height, levels, building type, and roof shape. They can run offline in the tile baker
(recommended) or on device. Device-side generation should run on a background thread or in a Metal
compute pass.

Libraries:
- **Clipper2** (C++/C#, ports exist) or **shapely/GEOS** (Python) — polygon offsetting and rounding.
- **earcut** (mapbox) — roof/ground triangulation.
- **Roofs:** `scripts/roofs.py` (exact convex hips + wing decomposition, no straight-skeleton
  dependency). CGAL's straight skeleton is optional for exotic concave hips.
- **meshoptimizer** — vertex-cache/overdraw optimization, quantization, compression, and
  simplification for landmarks.

## Contents
1. Footprint cleanup
2. Rounded corners
3. Wall extrusion and normals
4. Profile sweeps (cornice, parapet, bands)
5. Roofs: flat with parapet, hip
6. Façade modules: windows, bays, doors
7. Roof props
8. Baked vertex AO
9. Edge-distance attributes for the shader bevel
10. LOD chain
11. Landmarks and one-offs

---

## 1. Footprint cleanup

```
ring = orient_ccw(ring)
ring = remove_duplicate_points(ring, eps=0.05 m)
ring = remove_collinear(ring, angle_eps=3°)
ring = merge_short_edges(ring, min_len=0.3 m)
ring = orthogonalize(ring, snap_within=6°)   # near-90° corners → exactly 90°
holes: keep only courtyards > 20 m²
```

Orthogonalizing matters for the style: perfectly square corners and consistent rounding read as
"designed". It also stops micro-jitter from creating sliver faces.

## 2. Rounded corners

Round **convex** corners with a small radius. Leave concave corners sharp, or use a smaller radius:

```python
# shapely: negative buffer then positive buffer with round joins rounds convex corners.
poly = poly.buffer(-r, join_style="mitre").buffer(r, join_style="round", quad_segs=2)
# r: 0.4–0.8 m for houses, 0.8–1.5 m for offices, up to 6+ m for "stadium" office blocks.
```

`quad_segs=2` → 2 segments per 90°. With averaged normals this is visually round at map distances.
Use 3 only for very large radii (> 4 m), such as the stadium-shaped ends of office campuses.

Tag every ring vertex as `arc` (created by rounding) or `corner` (sharp). Normals depend on the tag.

## 3. Wall extrusion and normals

For each ring edge `(a, b)`, make one quad from z = base to z = top. Rules:

- Between two `arc` vertices or across an arc → **shared vertex, averaged normal** (smooth). At
  the tangent point where an arc meets a straight wall, use the straight wall's normal (it *is* the
  exact arc normal there), so the long wall doesn't get a normal gradient.
- At a `corner` vertex → **split vertices**, each with its own face normal (hard). Write the
  edge-distance attributes from section 9 so the shader softens it.
- Don't subdivide walls vertically. Floors are expressed by bands (section 4) and window instances
  (section 6), not by geometry rows.
- Bottom cap: never (the ground hides it). Top: covered by the roof.

Triangles: `2 × ring_edges`. A 12-edge footprint is 24 triangles of wall.

## 4. Profile sweeps (cornice, parapet, bands)

The thick rounded trims are a 2D profile swept along the footprint ring.

```
Profile point = (o, y, nx, ny)   # outward offset from wall, height, profile normal (2D)

CORNICE_D (rounded overhanging lip, 7 pts):
  (0.00, 0.00,  0.0,-1.0)
  (0.18, 0.02,  0.3,-0.95)
  (0.30, 0.12,  0.85,-0.5)
  (0.34, 0.30,  1.0, 0.0)
  (0.30, 0.48,  0.85, 0.5)
  (0.18, 0.58,  0.3, 0.95)
  (0.00, 0.60,  0.0, 1.0)

PARAPET (wall cap going inward, 6 pts; continues onto the roof):
  (0.00, 0.00, 1.0,0.0) (0.00, 0.55, 0.9,0.4) (-0.10,0.65, 0.0,1.0)
  (-0.25,0.62,-0.6,0.8) (-0.30,0.45,-1.0,0.0) (-0.30,0.00,-1.0,0.0)

BAND (thin floor band, 4 pts):
  (0.00,0.00, 0.2,-1.0) (0.08,0.04,1.0,0.0) (0.08,0.14,1.0,0.0) (0.00,0.18,0.2,1.0)
```

Normals can be hand-authored as above, or derived from the profile tangents (right-hand side of
the traversal, averaged at interior points). `scripts/geomlib.py: profile_normals` does the latter.

Sweep algorithm along a closed ring (implemented in `scripts/geomlib.py: sweep`):

```
analyse ring: smooth[v] (turn < 50°), straight[e] (real wall vs arc chord)
for each ring vertex i:
    miter = normalize(n_in + n_out);  scale = 1 / max(dot(miter, n_out), 0.35)
    if smooth[i]:                       # rounded arc
        emit point (p[i], displace = miter*scale, shade = arc normal*)
    else:                               # hard footprint corner -> SUPPORT LOOPS
        emit point (p[i] - t_in*d,  displace = n_in,  shade = n_in)     d = min(0.3 m, edge/3)
        emit point (p[i],           displace = miter*scale, shade = miter)
        emit point (p[i] + t_out*d, displace = n_out, shade = n_out)
for each emitted point, for each profile point k:
    pos = point + displace * o_k ; z = z0 + y_k
    nrm = normalize(shade.xy * nx_k, ny_k)
stitch quads between consecutive points / profile points
```
\* At an arc/straight tangent point the shading normal is the straight edge's normal (that is the
exact circle normal there). That stops a long wall's cornice from inheriting a normal gradient.

Why the support loops: if a hard corner only had the bisector normal, the normal would interpolate
across the whole neighbouring edge, and a 10 m cornice would shade as one long curve. The two support
points confine the rounding to a 0.6 m strip at the corner, which reads as a rounded trim. The cost is
2 extra ring points per hard corner.

- Cost: `2 × (profile_pts − 1) × ring_points` triangles. A 7-point cornice on a 4-corner block
  (12 ring points with support loops) is 144 triangles.
- Where the façade steps (bays), the cornice follows the stepped ring automatically.

Sweep placement per building type:

| Type | Sweeps |
|---|---|
| Row house / SF / NYC walk-up | parapet at top, cornice just below, band every floor (optional at LOD0) |
| Office / campus | parapet + one band per 1–2 floors (horizontal window strips) |
| Skyscraper | crown cornice + setback parapets at each setback level; no per-floor bands, windows in shader |
| House with hip roof | thin fascia along the eave ring only |

## 5. Roofs

**Flat roof with parapet:**
1. Inset the footprint by the parapet thickness (0.3 m), which gives the inner ring.
2. Add a second inset ring 0.6–1.0 m further in. This is the **AO ring**.
3. Triangulate: a strip between the inner ring and the AO ring, plus earcut of the AO ring.
4. Vertex AO: inner ring 0.72, AO ring 1.0. This produces the soft purple darkening along the parapet
   seen in the reference.

**Pitched roofs (hip, gable, cross-gable, mansard):** use `scripts/roofs.py: roof_for_footprint`.
It classifies the footprint and builds an exact convex hip/gable per wing, interpenetrating wings for
L/T/U shapes, a clipped hull roof for notches, or a mansard fallback. It also emits fascia/barge
boards, roof underside and gable infill walls. Facets keep **flat normals**; crisp ridges are part
of the style. Details and failure modes: `references/awkward-footprints.md`.

Skyscraper setbacks, churches, mosques, pagodas: see `references/landmarks.md`.

## 6. Façade modules: windows, bays, doors

Windows are **instances**, never wall geometry.

**Window module (~36 triangles; `build_building.py` generates one, or author it in Blender):**
- Frame: a rectangular ring 1.1 × 1.5 m, 0.10 m thick, 0.12 m deep, with corners bevelled 1 segment
  and smooth normals.
- Sill: a box 1.3 × 0.08 × 0.18.
- Glass: a quad 0.04 m in front of the wall, inside the frame. The frame depth makes it read as
  recessed.
- Variants: single, double (mullion), tall, office strip (long frame with 3–4 panes), door.

**Placement on each wall segment (length L, floor height h_f ≈ 3.0–3.4 m):**
```
margin = clamp((L - 1.3) / 2, 0.1, 0.6)    # only walls with L >= 1.5 m
usable = L - 2*margin
n = max(floor(usable / spacing), 1)        # spacing 2.2–3.2 m by type
x_i = margin + (usable - (n-1)*spacing)/2 + i*spacing
for floor f in 0..levels-1 (skip ground floor for shops/doors):
    y = f*h_f + sill_height(0.9)
    instance(pos = wall_origin + tangent*x_i + up*y,
             yaw = atan2(n.x, n.z) in Y-up, variant = hash(building_id) % k)
```
Skip windows on edges shorter than 1.5 m, on arc segments, and on walls touching neighbours (party
walls). Detect party walls by testing whether the edge midpoint offset 0.5 m outward lands inside
another footprint.

**Instance record:** `int16 x,y,z (tile-local, 1 cm)`, `uint16 yaw`, `uint8 variant`,
`uint8 palette`. That's 10–12 bytes.

**Bay windows:** on street-facing edges longer than 6 m (residential types), push out a trapezoid
(0.6 m deep, 45° sides, ~3.2 m wide so the front still fits a window) from floor 1 to the top. Union it into the footprint *before*
extrusion so the walls, cornice and windows all follow it.

**Far LOD:** replace instances with a façade shader that draws the same window grid procedurally,
using the same spacing and colours, so the LOD switch is invisible (see `metal-renderer.md`).

## 7. Roof props

Chimneys, AC units, stair boxes and water tanks are instanced library meshes (rounded box with 1 bevel
segment and smooth normals, plus an optional inset cap).

Placement: 1–4 per flat roof, sampled inside the AO ring by hashing the building id (deterministic).
Keep them ≥ 1 m from the parapet. Each prop also gets an **AO blob decal** (an instanced soft square
on the roof).

## 8. Baked vertex AO (store in colour alpha or a separate uint8)

| Location | AO |
|---|---|
| Wall bottom vertices | 0.65 (add a horizontal vertex row 2.5 m up with AO 1.0 if you want a nicer gradient: +2 tris/edge) |
| Underside points of cornice profile | 0.75 |
| Parapet inner ring / roof AO ring | 0.72 / 1.0 |
| Concave footprint corners (wall vertices) | × 0.85 |
| Tree canopy bottom | 0.7 (also covered by the colour gradient) |

Ground-contact AO and building shadows on the ground go into the **ground tile texture**, not the
meshes.

## 9. Edge-distance attributes for the shader bevel

For hard wall corners, write per vertex:
- `float edgeU` — metres along the wall from the left corner (0 at left, L at right).
- `float wallLen` — L.
- `half3 nLeft, nRight` — face normals of the adjacent walls (octahedral-encoded, 2×snorm8 each).
- `float topDist` — metres below the wall's top (0 at top).

The fragment shader bends the normal toward `nLeft` / `nRight` / up within `bevelRadius`. Cost:
~8 bytes per vertex and zero triangles.

## 10. LOD chain (generated, not decimated)

| LOD | Distance | Content |
|---|---|---|
| 0 | < 150 m | full shell, all sweeps, window and roof-prop instances, bays |
| 1 | 150–600 m | shell, parapet sweep only (4-point profile), corner rounding 1 seg, windows in shader, no props |
| 2 | 600 m – 2 km | prism with flat roof, no rounding, façade tint; all buildings of a tile merged into one mesh |
| 3 | > 2 km | tile-level block extrusion (union of footprints per block), or skip |

Generating each LOD from the footprint is better than decimating LOD0. Silhouettes and normals stay
clean, and LOD switches are nearly invisible under fog. Use a ~15% hysteresis band and a 150 ms
dither/alpha-free cross-fade (screen-door with a 4×4 Bayer pattern on the outgoing LOD only), or just
rely on fog at distance.

## 11. Landmarks and one-offs

For hand-modelled landmarks (Empire State, Chrysler, stadiums):
- Model mid-poly: 1 bevel segment max, weighted or face-weighted normals, sweeps for trims.
- Budget: 3–8k triangles at LOD0, auto-simplified LOD1 via `meshopt_simplify` (target 25%,
  error 1%, `meshopt_SimplifyLockBorder`), then recompute normals with a 40° split angle.
- Store landmarks as library meshes referenced by tile instance records, not baked into tiles.
