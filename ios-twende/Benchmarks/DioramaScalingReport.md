# Dar diorama scaling — initial audit, 2026-10-06

Status: partial implementation, stopped at the visual validation gate. This is not a city-scale completion report.

## Baseline and validation

- User-reported V31 baseline: approximately 2,848,276 unique triangles, more than 356 MB, 40 seconds. Device, build configuration, source snapshot and exact memory scope are not recorded with these figures.
- The new reproducible CPU fixture uses bundled Slipway input plus V31 ownership resolution, without live Mapbox supplementation. It is not equivalent to a live-source coverage benchmark.
- `DioramaGenerationAudit` records monotonic generator-stage timing, inclusive cutout/drape timing and per-render-category baked vertex/index bytes. Audits bypass both reads and writes of the interactive tile cache.
- `DioramaScalingTests/testV31ColdGenerationBaseline`: 1 test passed; runner duration 112 seconds, NOT generation time. Two cold outputs matched SHA-256 fingerprints for geometry, placements, ground image, analytic paint, light buffers, draw metadata and shader source.
- `testCachedBoundsPreserveClippingOrderAndDoubleBits` and `testCachedCutoutBoundsPreserveFullTilePayload`: 2 tests passed; runner duration 101 seconds, NOT a before/after timing result.
- Candidate optimization caches the bounding rectangle of surviving cutout pieces instead of recomputing it against every subsequent mask. Clipping arithmetic, thresholds, mask order and piece order are retained. It is available only inside an explicitly opted-in audit; the app still uses the V31 path.
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

The existing instance layout contains placement and scale, but no per-instance color/height-attribute payload. Existing transforms support Z rotation and XYZ scale, not arbitrary orientation/shear. A conversion must preserve height grading, tint saturation, normals, winding, bin ownership and all auxiliary passes. Identical mathematical shapes do not imply identical Float-transformed rasterization.

Instancing reduces unique stored geometry and may reduce draw submission/generation overhead; it does not by itself remove triangles processed for every visible placement. Report prototype bytes + instance bytes + group/index overhead, not only gross removed vertex bytes.

## Recipes versus meshes

No category-specific recipe serializer or generation-cost comparison has been completed, so no measured per-category winner is selected yet. Likely candidates to measure are prototype references plus transforms for repeated parts, polygons plus parameters for unique buildings, and pre-baked meshes for costly clipped shore/ground structures. These are candidates, not performance conclusions. Compression, decode cost, prototype amortization and device generation time must be included.

## City-scale gaps confirmed in the source

- `DioramaBundledTile.load` reads one Slipway bundle; `DioramaTerrain.load` reads one Slipway DEM. Reusing these as nine different geographic tiles would be incorrect.
- Mapbox supplementation currently covers buildings, driving roads and POI names, not a general terrain/coast/landuse ingestion system.
- `DioramaTileManager` shows one fixed z16 tile; `DioramaRenderLayer` owns one origin/ground image/light grid. No multi-tile CDN scheduler, manifest, disk-cache budget or per-bin streaming exists yet.
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

Next required evidence is a functioning pixel-diff capture gate and accessible benchmark attachments, followed by semantic redundancy measurement. No visual acceptance threshold has been weakened and no savings have been fabricated.
