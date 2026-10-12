# Tile pipeline — bake offline, load in under a second

A Fenn-like instant load comes from shipping **small, GPU-ready tiles**: compact data that needs no
parsing, triangulation or shader compilation at load time. This file covers the baker, the tile
format, runtime streaming, and how to diagnose a multi-minute load.

## Contents
1. Diagnose the slow load first
2. Baker architecture
3. Tile binary format
4. Compression and quantization
5. Runtime loading and streaming
6. Memory and residency
7. Validation checklist

---

## 1. Diagnose the slow load first

A GPU can rasterize millions of triangles in milliseconds. Minutes of loading almost always come from
the CPU or from I/O. Capture with Instruments → **Metal System Trace** + **Time Profiler**, then check:

| Symptom in trace | Cause | Fix |
|---|---|---|
| Long `makeRenderPipelineState` / `newFunction` calls at startup | Shader compilation on first use | `MTLBinaryArchive` + async pipeline creation (metal-renderer.md §11) |
| Main thread busy in triangulation, extrusion, normal generation, JSON/GLB parsing | Geometry built on device, synchronously | Bake offline. If generating on device, do it on background queues, nearest tiles first |
| Thousands of `makeBuffer` calls | One buffer per building/tree | One buffer per tile, sub-allocated from an `MTLHeap` |
| Huge `memcpy` / page faults | Unquantized float32 meshes, 32-byte+ vertices | Quantize (§4): 3–5× less data |
| Thousands of draw calls per frame | Per-building draws | Merge per tile/material, instance repeated meshes |
| Waiting for the whole city before first frame | All-or-nothing load | Stream tiles in priority order (§5) |
| GPU limiter "Tiled vertex", frame > 16 ms | Truly too many triangles | Regenerate geometry to the budgets in SKILL.md |

Write down the before numbers: load time to first frame, time to full detail, triangles per frame,
draw calls, memory. Re-measure after each fix.

## 2. Baker architecture

Run offline (CI or a build machine) in Python, Rust or C++. Tiles change only when source data or the
style changes.

```
sources: OSM / Overture buildings, roads, landuse, trees (or synthesized tree points from landuse)
  │
  ├─ 1. clip to tile (e.g. z16 ≈ 600 m, or a fixed 256 m grid), with a 20 m buffer for sweeps/shadows
  ├─ 2. classify: building type, levels, roof shape, palette index (hash(id) % palette_size per type)
  ├─ 3. generate shells per LOD (geometry-recipes.md), write edge/bevel attributes and AO
  ├─ 4. emit instance tables: windows, roof props, trees (+ kind, scale), cars/lamps, blob decals
  ├─ 5. ground: rasterize polygons (grass/road/sidewalk/water) → palette mesh or colour texture
  ├─ 6. bake shadows + AO into ground texture:
  │      shadow: render shells + tree proxies from the fixed sun into a 2048² ortho depth map,
  │              test ground texels, blur with σ≈1.2 m → R channel
  │      AO:     distance-to-footprint falloff (0→2.5 m) + tree canopy falloff → G channel
  ├─ 7. optimize: meshopt_optimizeVertexCache, optimizeOverdraw, optimizeVertexFetch
  ├─ 8. quantize + encode (meshopt_encodeVertexBuffer / IndexBuffer), compress textures (ASTC/BC)
  └─ 9. write tile file + manifest (tile id → byte range, hash, LOD availability)
```

Library meshes (windows, props, trees, cars, landmarks) are baked once into a single
`library.bin` that ships with the app. Tiles reference them by id.

## 3. Tile binary format

Little-endian, 16-byte aligned sections, so the runtime can `mmap` the file and hand pointers straight
to the decoder or to Metal.

```
TileHeader (64 B)
  magic 'SMT1', version, tile x/y/z, origin (float3), halfExtent (float), section count
SectionTable[n]: { type u32, lod u8, flags u8, count u32, byteOffset u32, byteSize u32, rawSize u32 }

Sections:
  SHELL_VB   lod 0..2   meshopt-encoded vertex buffer (28 B vertices, see metal-renderer.md §2)
  SHELL_IB   lod 0..2   meshopt-encoded index buffer (u16 if < 65k verts per LOD, else u32)
  SHELL_DRAW lod 0..2   ranges per material: { indexStart, indexCount }
  INST_WIN   lod 0      Instance[ ]  (16 B: pos + packed yaw/scale/palette/variant)
  INST_PROP  lod 0      Instance[ ]
  INST_TREE  lod 0..1   Instance[ ] sorted by tree kind, with per-kind ranges
  INST_BLOB             Instance[ ]  (scale = blob size, variant = tree/prop)
  INST_CAR / INST_LAMP
  GROUND_VB/IB          palette-coloured ground polygons
  GROUND_TEX            ASTC 4×4 or BC5, RG = shadow, AO, 512²
  LABELS                anchor points + string ids (text rendered by the UI layer)
```

Typical sizes for a dense Manhattan tile (256 m):
- shells LOD0: 300–800 KB raw → 80–200 KB encoded
- instances: ~20–60 KB
- ground texture: ~170 KB

That's roughly 0.3–0.5 MB per tile, so a full screen of tiles is a few MB.

## 4. Compression and quantization

- **Positions:** int16 normalized relative to tile origin and halfExtent. At 256 m tiles that's ~0.8 cm
  precision, well below a pixel.
- **Normals:** octahedral, 2 × snorm8. Smooth sweeps and canopies look identical to float.
- **Colours:** never store colours per vertex. Store a palette index (u8) and keep the palette in a
  uniform buffer, so restyling the whole city (seasons, dark mode) is free.
- **Bevel attributes:** half precision.
- **meshoptimizer codecs:** `meshopt_encodeVertexBuffer` / `meshopt_encodeIndexBuffer` after
  `optimizeVertexCache` + `optimizeVertexFetch`. Decoding runs at several GB/s on an A-series CPU
  core and can be followed by LZ4/zstd for another ~20–30%.
- **Instances:** sort by kind then Morton order before encoding. That improves compression and spatial
  coherence for culling.

## 5. Runtime loading and streaming

```
camera update
  └─ tile selector: visible tiles + 1-ring prefetch, LOD per tile by screen-space error
       priority = distance to camera focus (nearest first), visible before prefetch
  └─ loader (concurrent background queue, 3–4 workers):
       read: mmap or MTLIOCommandQueue (iOS 16+, direct-to-buffer, optional built-in compression)
       decode: meshopt decode directly into a staging MTLBuffer (shared storage)
       upload: blit staging → private heap allocation; signal fence
  └─ main thread: only swaps tile state from "loading" to "ready" (no heavy work)
```

Rules:
- **First frame within ~300 ms:** load LOD2 (merged prisms, tiny) for all visible tiles first, then
  refine nearest-first. That's why a well-built map appears instantly and sharpens a moment later.
- Never block rendering on a tile. Draw whatever LOD is resident.
- Cache decoded tiles on disk (Caches dir) only if decode cost shows up in traces. With meshopt it
  usually doesn't.
- Precompile pipelines and load `library.bin` during the splash screen. They're small and shared.

```swift
// MTLIO example (iOS 16+/macOS 13+)
let ioQueue = try device.makeIOCommandQueue(descriptor: MTLIOCommandQueueDescriptor())
let handle  = try device.makeIOFileHandle(url: tileURL)
let cmd     = ioQueue.makeCommandBuffer()
cmd.load(stagingBuffer, offset: 0, size: section.byteSize,
         sourceHandle: handle, sourceHandleOffset: Int(section.byteOffset))
cmd.addCompletedHandler { _ in decodeQueue.async { decodeAndUpload(tile, section) } }
cmd.commit()
```

## 6. Memory and residency

- Allocate tile buffers and textures from a few large `MTLHeap`s (e.g. 64 MB each) with
  `.storageModePrivate`. Recycle allocations via an LRU of tiles.
- Budget on an A15 iPhone: ~250–400 MB for map data. At ~1.5–3 MB GPU-resident per dense tile (after
  decode), that's ~120–200 tiles resident. Evict beyond the prefetch ring.
- Use `useHeap(_:)` once per heap per encoder with argument buffers, instead of per-resource
  `useResource`.
- Listen for `UIApplication.didReceiveMemoryWarningNotification` and drop LOD0 of far tiles first.

## 7. Validation checklist

Run before shipping a new bake:

- [ ] `scripts/audit_meshes.py` on a sample of baked tiles (export a tile to GLB): no building over
      budget, no sliver-heavy shells, all repeated meshes instanced.
- [ ] Dense tile (Midtown) ≤ 0.6 MB on disk, ≤ 3 MB GPU-resident.
- [ ] Cold launch → first map frame < 0.5 s; full detail in view < 1.5 s on A15.
- [ ] Main thread never blocked > 8 ms during a fast pan across 20 tiles (Time Profiler).
- [ ] Frame ≤ 16.6 ms at street-level tilt in Midtown with trees; draw calls < 150; triangles < 1.5 M.
- [ ] No visible LOD pops at the LOD0→1 distance (fog and window-shader parity).
- [ ] Palette swap (e.g. dark mode) works with no re-bake.
