---
name: stylized-map-renderer
description: Build, audit, and fix stylized 3D city map geometry and rendering (Fenn / Zenly style - soft rounded buildings, puffball trees, pastel colours, soft blue shadows) on Apple Metal, including architectural styles (colonial, Greek revival, Cycladic, Spanish, Victorian, Tudor, Art Deco, brownstone, modernist, Japanese, Dutch, Swahili coast, East African/Dar es Salaam) and landmarks (skyscrapers, churches, mosques, pagodas). Use this skill whenever the user mentions 3D map tiles, procedural buildings, OSM/Overture footprints, awkward footprints, roofs (hip, gable, mansard, domes), building styles in a map, stylized city rendering, high polygon counts, slow map loading, rounded/bevelled building edges, instanced trees, LODs, tile baking, or Metal shaders for maps, even if they don't name Fenn, Zenly or Metal. Also use when the user uploads map meshes (glb/gltf/obj/ply) and asks why they are heavy or how to replace them.
---

# Stylized Map Renderer

This skill turns a slow, over-modelled stylized map (millions of triangles, minutes to load) into one
that loads in about a second and looks like the reference style: rounded parapets and cornices,
inset windows, hip roofs, puffball trees, pastel palette, soft purple-blue shadows and haze.

The core idea, which every decision below follows from:

> **The rounded look comes from smooth normals, swept profiles, shading and instancing — not from
> bevel subdivisions.** Unique geometry is only the building *shell*. Everything repeated (windows,
> chimneys, AC units, trees, cars, lamp posts, shadow blobs) is an *instance* of a tiny library mesh.

## When the user brings an existing pipeline

Work through these phases in order. Don't skip the audit: the slow load is often caused by something
other than triangle count (pipeline compilation, per-building buffers, main-thread triangulation),
and you need evidence before rewriting geometry.

1. **Audit** — measure what is actually heavy (see "Phase 1").
2. **Classify every heavy mesh** into one of five fixes (see "Phase 2").
3. **Rebuild buildings from footprints** with the generator recipes (see "Phase 3"). Repair awkward
   footprints first, and pick a style or landmark generator per building (see "Phase 3b").
4. **Replace trees and props with instanced library meshes** (see "Phase 4").
5. **Move the style into shaders** (see "Phase 5").
6. **Bake tiles and fix loading** (see "Phase 6").
7. **Verify against budgets** (see "Budgets").

If the user only wants an explanation, answer from the relevant reference file rather than running
anything.

## Reference files — read the one you need

| File | Read it when |
|---|---|
| `references/style-spec.md` | You need the visual breakdown of the target look: what is geometry vs shader, palette, light/shadow values. Read first for any "make it look like this" task. |
| `references/geometry-recipes.md` | Generating buildings: footprint cleanup, rounded corners, profile sweeps (cornice, parapet, bands), window/bay placement, roofs, LOD chain. |
| `references/metal-renderer.md` | Writing Metal (MSL + Swift): pass setup for Apple TBDR GPUs, vertex formats, building/tree/ground shaders, shadows, AO, fog, instancing, argument buffers, style patterns (barrel tiles, curtain walls, timbering, domes). |
| `references/tile-pipeline.md` | Offline baker, tile binary format, streaming/loading, compression, and the checklist for diagnosing multi-minute load times. |
| `references/awkward-footprints.md` | Dirty or odd footprints (spikes, slivers, acute wedges, L/T/U, notches, curves, courtyards) and how the roof solver handles each class. |
| `references/architectural-styles.md` | Any request about building styles: the style catalog, choosing styles from OSM tags or region, style fields, extras, adding a new style. |
| `references/region-dar-es-salaam.md` | Dar es Salaam / Swahili coast: how the city is built, style mapping, importer rules; template for other regional profiles. |
| `references/landmarks.md` | Skyscrapers (setbacks, façade systems, crowns), churches, mosques, pagodas; matching a real landmark. |

## Scripts

All scripts are Python 3 and need `pip install trimesh shapely mapbox_earcut numpy scipy networkx`
(add `--break-system-packages` in sandboxed environments).

| Script | Purpose |
|---|---|
| `scripts/audit_meshes.py <dir_or_file> [--up y|z] [--budget N] [--json out.json]` | Reports triangles, over-tessellated planes, bevel-strip density, duplicate meshes, and a recommended fix per mesh. |
| `scripts/extract_footprints.py <dir_or_file> [--up y|z] --out footprints.json` | Slices building meshes near the ground to recover 2D footprints + heights, so heavy buildings can be regenerated. |
| `scripts/build_building.py --spec spec.json --out tile.glb [--runtime-bin tile.bin] [--lod 0|1|2]` | The generator for every building: repairs footprints, then dispatches to a style (`"style"`) or landmark (`"type": tower/church/mosque/pagoda`). Writes a preview GLB, an instance list, the module library and the Metal runtime binary. `--demo basic|styles|landmarks|awkward`, `--list-styles`. |
| `scripts/osm_import.py --center LAT LON --radius R --region dar_es_salaam --out specs.json [--scene scene.glb] [--source api]` | Fetches OSM buildings/roads/trees/coast, picks a style per building (tags + density + neighbour heights + coast distance), orients façades to streets, optionally builds a full preview scene with ground, roads, sea and trees. |
| `scripts/make_tree.py --out tree.glb [--lod 0|1] [--kind puff|cone|cypress|palm]` | Generates library trees with canopy normals, height gradient and hidden-face culling. |
| `scripts/preview_render.py model.glb --out preview.png [--az --el --dist --fog]` | CPU render with the same stylized lighting model as the Metal shaders (per-pixel normals, purple shadow tint, fog). Use it to check normals and the look before touching Xcode. |

Run `--help` on any script for details. Each prints triangle counts so you can check against budgets.

Library modules (import them; don't re-implement):

| Module | Holds |
|---|---|
| `geomlib.py` | MeshBuilder, profile sweep with support loops, ring analysis, earcut, lathe (with angle ranges), prism, `panel()` (extruded 2D façade shapes), `wall_strip()`, octahedral encoding, the 28-byte runtime vertex writer |
| `footprint.py` | `repair`, `classify`, `orthogonalize`, `rect_cover`, `street_edge` |
| `roofs.py` | `roof_for_footprint` (hip/gable/cross-wing/mansard), `ConvexRoof`, `ring_stack`, `curved_hip`, `dome` (hemi/ottoman/pointed/onion/bulb), `drum`, `cone` |
| `modules.py` | instanced library: windows (rect, tall, multipane, arched, lancet, round, rose), doors, shutters, lintels, pediments, balconies, columns, dormers, chimneys, buttresses, arcade bays, small domes, stoops, finials (cross, alem), clocks. Composites via `+` (e.g. `window_arched_dark+balcony`) |
| `core.py` | walls with bevel attributes, flat roofs, parapets, `PROFILES`, façade window placement, instance records |
| `styles.py` | `STYLES` table + extras, `build_styled(spec)` |
| `landmarks.py` | `build_tower`, `build_church`, `build_mosque`, `build_pagoda` |

Reference output from these scripts (at default settings) is in `assets/`:
- `assets/reference_closeup.png` — rowhouses: rounded parapets, cornices, bays, instanced windows.
- `assets/reference_street.png` — a street with rowhouses, hip-roof houses, and library trees.
- `assets/gallery_styles.png` — every architectural style.
- `assets/gallery_awkward.png` — awkward footprints through the styled pipeline.
- `assets/gallery_towers.png`, `assets/gallery_religious.png` — skyscrapers, churches, mosques, pagoda.

Compare against these when judging whether a change kept the look.

## Phase 1 — Audit

Run `scripts/audit_meshes.py` on the user's exported tiles or building/tree meshes. The report flags:

- **tris over budget** for the mesh's class (building / tree / prop).
- **plane_redundancy** — triangles ÷ coplanar regions. Above ~4 means flat walls/roofs are subdivided
  for no visual reason (usually from booleans, CSG, or subdivision modifiers).
- **tiny_face_fraction** — share of faces that are thin slivers. High values (>0.4) on a building mean
  the roundness was modelled as multi-segment bevels.
- **duplicate groups** — identical meshes stored separately. Each group should become one library mesh
  plus instances.

Also ask for (or recommend capturing) an Instruments **Metal System Trace** and an Xcode GPU frame
capture of the slow load. Check the load-time checklist in `references/tile-pipeline.md` before
concluding that polygons are the culprit.

## Phase 2 — Classify and choose the fix

| Finding | Fix |
|---|---|
| Building with multi-segment bevels, sliver faces, or > LOD0 budget | **REGENERATE** from footprint (`extract_footprints.py` → `build_building.py`). Don't decimate; decimation destroys clean silhouettes and normals. |
| Same mesh repeated (trees, windows, chimneys, cars, lamps) | **INSTANCE**: keep one library mesh, store per-instance transform + palette index. |
| Tree mesh, any count | **REPLACE** with a library tree from `make_tree.py`, matched by kind (puff / cone / cypress / blossom) and scaled by the original bounding box. |
| Landmark or one-off sculpted mesh over budget | **SIMPLIFY** with meshoptimizer (`meshopt_simplify`, error ~0.5–1% of extent, lock borders), then re-author normals as smooth with a 35–40° split angle. |
| Flat surfaces subdivided (high plane_redundancy) | **RETRIANGULATE** planar regions (merge coplanar faces, re-earcut). |

## Phase 3 — Rebuild buildings from footprints

Follow `references/geometry-recipes.md`. The short version:

1. Clean the footprint (CCW, remove collinear and <0.3 m edges, snap near-right angles).
2. Round convex corners with a small radius (0.4–1.2 m), using **2 segments per 90°**.
3. Extrude walls. Use **smooth normals across the rounded-corner segments** and hard normals at
   remaining sharp corners. The shader bevel softens those hard corners (see Phase 5).
4. **Sweep a 2D profile** (5–8 points, precomputed smooth normals) along the footprint for each
   cornice, floor band, and parapet. This is what produces the thick rounded white trims in the
   reference. Each band costs `profile_points × ring_points × 2` triangles: tens to a few hundred, not
   thousands.
5. Add a flat roof with an inner AO ring, or a hip roof (straight skeleton) for houses.
6. Emit **window instances** on a façade grid, not window geometry. A window is a protruding frame ring,
   a sill, and a glass quad placed on the wall. The frame's depth makes the glass *look* recessed, so the
   wall never needs holes.
7. Bake AO into vertex colour (base-of-wall darkening, under-cornice, parapet inner ring).

Use `build_building.py --demo` to see a working example and check triangle counts. Typical output:
a 4-storey rowhouse with bay, parapet and cornice is ~500 unique triangles plus ~40 window instances.
That replaces the 4,000–20,000 triangles of a modelled-bevel equivalent.

## Phase 3b — Awkward footprints, styles, landmarks

1. **Repair every footprint** with `footprint.repair` (the generator does this automatically).
   It splits multipolygons, removes spikes, slivers and collinear points, chamfers acute corners,
   and snaps near-right angles. Then `classify` picks the roof strategy:
   - `rect` / `ortho` → interpenetrating wings
   - `convex` / `curved` → exact hip
   - `mild_concave` → clipped hull hip
   - `irregular` → mansard

   Flat-roof styles work on any shape. See `references/awkward-footprints.md`.
2. **Pick a style per building.** Use OSM tags first (`building:architecture`, `roof:shape`,
   `building:material`, `religion`), then region defaults, then size heuristics, with a hash for
   variety. Mapping tables are in `references/architectural-styles.md`.
3. **Landmarks get generators, not meshes:**
   - `type: tower` with presets `art_deco`, `modern_glass`, `classic`, `supertall` (setbacks,
     façade system, crown)
   - `type: church` with `gothic`, `romanesque`, `orthodox`, `byzantine`
   - `type: mosque` with `ottoman` (semi-domes, courtyard), `persian`, `mughal`
   - `type: pagoda`

   Override any parameter to approach a real building. See `references/landmarks.md`.
4. **To add a style,** map each signature cue to an existing primitive (roof kind, sweep profile,
   module or composite, `panel()` outline, `wall_strip`, `edge_box`) before writing a new extra.
   Exaggerate the one cue that identifies the style; never add detail to compensate.

## Phase 4 — Trees and props

- Build 6–10 library trees: 3–4 broadleaf "puff" variants, conifer, cypress, blossom (puff with a pink
  palette index), and shrub. Use `make_tree.py`.
- Puff canopies are clusters of icospheres with **canopy normals**: each normal is blended toward the
  direction from the canopy centre. This one trick creates the soft cloud-like shading. Faces buried
  inside other blobs are removed.
- Per-instance data: position, yaw, uniform scale, palette index (~12 bytes). One instanced draw per
  tree kind per LOD per tile.
- Tree shadows on roads are **blob decals** (instanced soft ellipse quads offset along the sun
  direction), not shadow-map samples. This is what the blurry purple tree shadows in the reference are.

## Phase 5 — Style in shaders (Metal)

Implement from `references/metal-renderer.md`:

- **Stylized lighting:** wrap-Lambert diffuse into a soft ramp, multiplied toward a **purple-blue shadow
  tint** (not black), plus hemisphere ambient (sky blue above, warm ground below).
- **Shader bevel** on the remaining hard wall corners and roof edges, driven by per-vertex
  edge-distance attributes.
- **Baked AO** (vertex colour alpha) × height gradient.
- **Soft shadows:** baked into ground tiles for static buildings, blob decals for trees and props, and
  an optional single near-field shadow map with a wide PCF kernel for anything dynamic.
- **Atmosphere:** distance and height fog to the sky colour, giving the hazy horizon.
- **4× MSAA** with memoryless attachments. It's nearly free on Apple TBDR and essential for the clean
  silhouettes.
- Avoid `discard` and alpha-tested foliage. Trees are solid geometry, which keeps hidden-surface
  removal on TBDR efficient.

## Phase 6 — Bake tiles and fix loading

Follow `references/tile-pipeline.md`:

- An offline baker produces one compressed binary per tile. Each tile holds:
  - quantized shell meshes,
  - instance tables (windows, roof props, trees, decals),
  - a ground texture with baked shadows and AO,
  - style palette indices instead of colours.
- At runtime, decode tiles on background queues: meshoptimizer decode runs at GB/s, or use
  `MTLIOCommandQueue`. Upload into an `MTLHeap`, draw with one call per material per tile, and
  precompile pipelines into an `MTLBinaryArchive`.
- Show the nearest tiles first. The user should see something within ~300 ms.

## Budgets

Triangle counts are *unique* geometry per item. Instances reuse library meshes and cost only their
per-instance data.

| Item | LOD0 (< 150 m) | LOD1 (150–600 m) | LOD2 (> 600 m) |
|---|---|---|---|
| Building shell + sweeps | 300–1,500 | 80–400 (top parapet only) | 12–80, merged per tile |
| Windows | instanced frames (~36 tris each) | shader-drawn on façade | none (façade tint) |
| Roof props | instanced (~20–60 tris) | dropped | dropped |
| Puff tree | 600–1,400 instanced | 120–300 instanced | 2-tri impostor / dropped |
| Shadow blob | 2 tris instanced | 2 tris | dropped |

Landmarks (towers, churches, mosques) may use up to ~8k unique triangles each at LOD0. There are few
per tile, and their domes and spires must keep their silhouette down to LOD2.

Frame targets on an A15-class iPhone: under ~1.5 M visible triangles, under ~150 draw calls, 60 fps.
First tiles visible in under 0.5 s.

## Output expectations

When asked to fix or replace geometry, deliver:

1. the audit summary (top offenders, totals before/after),
2. the fix per mesh class,
3. generated replacement assets or code,
4. the Metal shader and pipeline changes needed for the look.

Always quote triangle counts before and after so the user can verify the reduction.
