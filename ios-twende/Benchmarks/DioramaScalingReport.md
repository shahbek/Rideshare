# Dar diorama scaling — initial audit, 2026-10-06

Status: V32 architectural instancing, CPU cutout acceleration, lossless disk packages and live diagnostics are implemented and enabled for preview. City ingestion, certified LOD and CDN streaming remain incomplete. This is not a city-scale completion report.

## V32 enabled implementation

- Full-detail prototypes now replace repeated complete window/frame assemblies, water tanks, facade boxes, upright bevelled boxes, tubes/columns/posts, repeated ring bands and scaled reef/detail spheres. Placement records now carry tint and building-relative height grading through the existing Metal main, reflection, G-buffer, glow and shadow paths. Single-use primitives are consolidated back into baked bins rather than creating one draw per unique shape. Prototype full/light buffers share storage when no distinct light mesh exists.
- Shapes retain their original tessellation. Exact dimension keys are used, not rounded dimensions or quantized vertices. Arbitrarily shaped planks, shoreline courses, rounded wall sweeps and bespoke non-primitive details remain baked; this is not a claim that every possible repeated subshape has been recognized.
- Live report under **Instancing savings and generation timings** includes placed/prototype counts, removed stored triangles and net vertex/index/instance-buffer MiB by primitive/assembly family. Complete window rows include frames (not double counted). It excludes bin metadata and any extra prototype copy for a different shader category. This is not yet the requested exhaustive per-semantic-category census or recipe generation comparison.
- CPU cutouts now cache surviving piece bounds and select candidate masks with a 32 m spatial index. Mask ordering, clipping arithmetic and thresholds remain unchanged. Legacy and optimized paths remain selectable in audits. Stage timings are stored on artifacts and shareable from the app; no speedup percentage is assumed.
- `DioramaTileArchive` writes independent 4 MiB lossless LZFSE blocks, checks SHA-256, format/layout versions and bounded decode/index ranges. Draw bins, groups, labels, lights, ground image and analytic paint are restored. These are buffer blocks, not spatial streaming chunks. `DioramaDiskCache` publishes complete packages, limits storage to 512 MiB and treats corrupt entries as misses; Regenerate invalidates disk and memory. Bundled-only fallback tiles are not persisted, so future online coverage can recover. First generation includes a separately reported package-writing cost; later cold launches can decode rather than regenerate.
- Rolling telemetry reports main-pass submitted triangles, diorama CPU encoding p50/p95 and shared Mapbox command-buffer GPU p50/p95. GPU figures are explicitly not isolated diorama timings or display FPS, and triangle figures exclude auxiliary passes.
- Validation: first focused run passed 4 tests (primitive expansion geometry/normals/winding, window/tank reuse and instance layout, runtime Metal compilation, cutout bits). After spatial indexing and storage integration, a second selection passed 2 tests: full bundled tile instancing/archive comparison and clipping bits. The tile comparison uses a 256px albedo to bound serialization-test cost: fewer unique triangles, fewer packed bytes, more placements, **equal full-detail drawn triangle counts**, unchanged albedo, exact restored GPU buffers, compressed size below uncompressed size, and corrupt/wrong-key rejection. This does not verify the live Mapbox input or pixel-identical output. Runner durations (65s and 120s) are not generation timings.
- Current simulator build and whitespace checks pass. The earlier screenshot capture failure is unresolved; no pixel-certification, device speedup, certified medium/low or 3×3 result is claimed.

The sections below retain the earlier baseline and source inventory; V32 changes above supersede their implementation status.

## Baseline and validation

- Earlier user-reported V31 reference: approximately 2,848,276 unique triangles, more than 356 MB, 40 seconds. This is not a controlled before/after comparison.
- Latest user-supplied live panel report (2026-10-06): V31, tile `16/39917/34000`, status `Slipway loaded • full effects • Mapbox coverage`; **3,170,781 unique triangles, 7,258 instances, 387001 KB, geometry 33.66 seconds**. Use this as the current reported live baseline, separate from the bundled-only CPU fixture. Device/build configuration and exact Mapbox input snapshot remain unspecified.
- Verified panel semantics in source: KB is `totalBytes / 1024`, so 387001 displayed KB means approximately **377.93 MiB / 396.29 decimal MB**. The counter includes packed vertices, indices, instance records and ground RGBA only; it is neither peak process memory nor compressed download size, and excludes auxiliary render targets and other allocations. Unique triangles count stored index-buffer triangles, including prototype LODs, not triangles submitted per frame. Geometry time measures the generator, excluding preceding source loading/merge and prototype-library construction, and is not time to first visible.
- User-supplied shoreline classification (rounded lengths): 5 m data deck (pier 1387736908); 11 m data deck (terrace 1321652461); 67 m data deck (terrace 180605897 over slipway-stone-waterfront); 336 m fallback natural (no coastal structure or sand tag); 97 m fallback seawall (paving/building within 15 m); 128 m override beach (southern-bay-beach-preview); 140 m override seawall (slipway-stone-waterfront). Approximately 784 m total: 83 m data, 433 m fallback, 268 m override. This is provenance/length evidence, not per-category geometry cost or visual acceptance.
- The new reproducible CPU fixture uses bundled Slipway input plus V31 ownership resolution, without live Mapbox supplementation. It is not equivalent to a live-source coverage benchmark.
- `DioramaGenerationAudit` records monotonic generator-stage timing, inclusive cutout/drape timing and per-render-category baked vertex/index bytes. Audits bypass both reads and writes of the interactive tile cache.
- `DioramaScalingTests/testV31ColdGenerationBaseline`: 1 test passed; runner duration 112 seconds, NOT generation time. Two cold outputs matched SHA-256 fingerprints for geometry, placements, ground image, analytic paint, light buffers, draw metadata and shader source.
- `testCachedBoundsPreserveClippingOrderAndDoubleBits` and `testCachedCutoutBoundsPreserveFullTilePayload`: 2 tests passed; runner duration 101 seconds, NOT a before/after timing result.
- Candidate optimization caches the bounding rectangle of surviving cutout pieces instead of recomputing it against every subsequent mask. Clipping arithmetic, thresholds, mask order and piece order are retained. It was originally audit-only; V32 enables it in production with the spatial index described above.
- Numerical JSON reports are emitted and attached to XCTest results. The managed runner returned aggregate results without these attachments. Its subsequent `/tmp/rork-swift-test-ios-twende.log` path was not present in this workspace. No numerical speedup or hotspot ranking has been inferred.
- Native fixed-camera test: hotel, white pavilion, Masjid 36 close-ups and dusk waterfront; fixed 320×320-point viewport, native-resolution RGBA comparison without tolerance/resampling, frozen wave clock, unchanged production shaders and effects. It isolates the diorama on a local background style, not changing Mapbox Standard tiles.
- The capture test compiled after a raw-string delimiter fix, then failed with `InvalidTransition { phase: idle, targetPhase: failed(deinit) }`. It did not establish screenshot equivalence. The exact failing runtime phase is unresolved without its full log.
- Simulator build and whitespace checks passed. Physical-device performance, peak memory, energy use, animated reveal and basemap integration are not validated.

## Redundancy inventory — source inspection, not measured savings

All paths in this table are under `Twende/Diorama/`. Counts and MB removable are **unmeasured**, not zero. Current render-category accounting cannot distinguish every semantic component; semantic tagging and exact prototype equivalence remain to be implemented.

| Category | Main emitters | Source-level finding | Repeated triangles / removable MB |
|---|---|---|---|
| Windows | `DioramaBuildingKit.window`, `DioramaHotelGenerator.build`, mosque `arch` | Repeated assemblies, varying dimensions, tint and height attributes | Unmeasured |
| Frames | `DioramaBuildingKit.window/reveal`, hotel glazing | Repeated jambs, lintels, sills, mullions; do not double-count inside window assemblies | Unmeasured |
| Cornice/bands | `DioramaMesh.band`, kit `cornice/stringCourse`, hotel `fishCornice` | Straight segments may repeat; curved joins and plan-following normals need distinct treatment | Unmeasured |
| Columns | Kit `verandaBay`, hotel galleries | Shafts/bases/capitals repeat; preserve independent dimensions and tessellation | Unmeasured |
| Rails | Kit `balconyRail`, hotel rails, `DioramaDeckGenerator.build` | Repeated balusters/handrail spans; scalloped sections need their own prototype | Unmeasured |
| Tanks | Kit `waterTank` | Repeated stand/body/cap, black and blue variants | Unmeasured |
| Planks | `DioramaDeckGenerator.build` | Clipped palette strips on decks, not repeated solid plank boxes; irregular ends may remain mesh | Unmeasured |
| Posts | `DioramaDeckGenerator.build`, amenity court/fence | Repeated profiles; terrain-dependent heights and supports | Unmeasured |
| Seawall courses | `DioramaShorelineGenerator.seawall/sweep` | Continuous terrain-following profile strips, not individual masonry blocks | Unmeasured |
| Rocks | `DioramaPropLibrary.makeRock`, shoreline placements, `DioramaGroundGenerator.reef` | Shoreline rocks already instanced (80-face full / 20-face light); reef spheres still baked | Unmeasured additional savings |

The V31 instance layout contained placement and scale but no per-instance color/height-attribute payload; V32 adds both. Existing transforms support Z rotation and XYZ scale, not arbitrary orientation/shear. A conversion must preserve height grading, tint saturation, normals, winding, bin ownership and all auxiliary passes. Identical mathematical shapes do not imply identical Float-transformed rasterization.

Instancing reduces unique stored geometry and may reduce draw submission/generation overhead; it does not by itself remove triangles processed for every visible placement. Report prototype bytes + instance bytes + group/index overhead, not only gross removed vertex bytes.

## Recipes versus meshes

No category-specific recipe serializer or generation-cost comparison has been completed, so no measured per-category winner is selected yet. Likely candidates to measure are prototype references plus transforms for repeated parts, polygons plus parameters for unique buildings, and pre-baked meshes for costly clipped shore/ground structures. These are candidates, not performance conclusions. Compression, decode cost, prototype amortization and device generation time must be included.

## City-scale gaps confirmed in the source

- `DioramaBundledTile.load` reads one Slipway bundle; `DioramaTerrain.load` reads one Slipway DEM. Reusing these as nine different geographic tiles would be incorrect.
- Mapbox supplementation currently covers buildings, driving roads and POI names, not a general terrain/coast/landuse ingestion system.
- `DioramaTileManager` shows one fixed z16 tile; `DioramaRenderLayer` owns one origin/ground image/light grid. V32 adds a local lossless archive manifest and bounded disk cache. Multi-tile CDN scheduling and per-bin streaming still do not exist.
- Per-tile 36 m edge easing must not be repeated at every internal city boundary. Neighbor geometry/procedural ownership also needs consistent seams.
- Existing light prototypes beyond 140 m have no certified projected-error bound; they must not be presented as the requested medium/low bake.
- No command-line generator bake, error-constrained simplifier, compressed bin format or published tile catalog was added in this pass.

## Requested final report — not yet available

| Measurement | Slipway | 3×3 Masaki |
|---|---|---|
| Full/medium/low compressed MB per tile | Not baked | No tiled inputs/bake |
| Triangles submitted per panning frame | Not measured | Not implemented |
| Time to first visible bin | Not measured | Not implemented |
| CPU/GPU frame-time distribution | Not measured | Not implemented |
| Session download bytes, cold/warm cache | Not measured | No CDN streaming |

Remaining work: exhaustive semantic redundancy/recipe measurement; repaired fixed-camera comparisons; city terrain/coast/landuse ingestion with seam ownership; generator-sharing command-line bake; certified 1-pixel medium/low simplification; spatial chunks/CDN publishing and camera-bubble streaming; 3×3 Masaki/device/session measurements. The user authorized direct preview before pixel certification; no measurements are fabricated.
