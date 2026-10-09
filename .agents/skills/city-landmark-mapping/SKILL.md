---
name: city-landmark-mapping
description: Research and map city districts using verified geographic footprints, reference photographs, generated Twende-style concept images and image-to-3D building assets. Use whenever the user asks to map a tile, recreate a skyline, identify buildings, expand city coverage or repeat the photo-to-building workflow, even without mentioning this skill.
---

# City landmark mapping

## Intent
Create a repeatable authoring-time pipeline: identify → verify geography → inspect photographs → generate isolated style-matched concept → approve → image-to-3D → validate → place → publish a bounded district pack. This is not runtime AI generation or a replacement of the map provider.

Read `.rork/DESIGN.md` before any appearance decision. Preserve approved Airtel, PSPF, churches, Morocco and bridge geometry unless explicitly asked to replace them. The user approved Airtel's raised rooftop/signs/curved supports/dishes on 2026-10-09.

For the first harbour pilot, read `references/harbour-inventory.json`. Its entries are research records, not a completed runtime catalog. The pilot is incomplete and not installed.

## 1. Establish geographic scope
- Open the supplied skyline. Identify viewpoints and historical construction states; do not infer identity from resemblance alone.
- Query official project/architect/operator sources, inspect labelled comparison images and cross-check OSM geometry. Store exact source URLs, OSM IDs/rings, identity confidence, height evidence and orientation evidence.
- Derive real addressed tile boundaries from coordinates. A skyline can span multiple z16 tiles: keep its true geography and treat it as a district pack. Never move structures together to force one tile.
- List every mapped building in the chosen tile(s), preserving unnamed structures and exclusions. Track coverage counts: mapped footprints, researched landmarks, retained existing landmarks, ordinary context, unresolved identities and rejected invalid geometry. A handful of landmarks is not a whole-tile reconstruction.
- Distinguish named structure identity, photograph-to-structure match, geometry and heights as separate evidence gates. Missing identity/footprint remains unresolved; do not invent OSM IDs or use an old proposed development site.

## 2. Build reusable architectural references
- Read asset-library and reuse approved assets before spending generation credits.
- Search images with requestImages enabled and open the useful images. Prefer front, oblique and rooftop views of the same completed structure. Photographs are reference material, not automatically licensed distributable textures.
- Read assets/SKILL.md for actual tool schemas. `generateImageAsset` inputImages requires trusted Rork asset URLs: research-site images currently fail validation. Ask the user to upload those reference photographs; never invent a trusted URL or assume a downloaded filesystem path is a supported input.
- Do not repeatedly submit known-invalid external URLs. Do not retry failed image jobs; the image skill reserves retries for the user. Retrieve every scheduled task's error with waitTask and retain failure state accurately.
- Concept prompt: isolate exactly one building or connected complex, full base-to-crown, three-quarter axonometric view, neutral background, no streets/neighbours/labels/people. Preserve silhouette, source material identities and distinctive crown/podium. Use contract cream #F4EFE7, silver #BFCBCB and teal #326A72/#417E86 where appropriate; preserve building-specific accents rather than recolouring every facade identically. Broad glazing bays, rounded bevels and readable cornices match the established miniature city style. No photographic reflections, baked environment or cast-shadow textures.
- Do not pass a whole skyline into image-to-3D as though it were a single object. Reject concepts containing neighbouring towers, a ground plinth outside the footprint, missing roof/base or misleading architectural detail.

## 3. Generate and inspect geometry
- Use the generated isolated concept URL exactly as returned in generate3DAsset.imageUrls. The built-in preview/approval flow is required. Announce the model being built, not a claim that it is installed.
- Schedule independent models together and keep coding while they generate. Wait for all pending generation IDs at the end of each dependency stage; image results are needed before scheduling their image-to-3D jobs.
- Use normal geometry mode for smooth architecture unless the user requests faceted low-poly. Inspect actual output topology, triangle/material counts, bounds, base contact, axis convention, roof shape and silhouette before enabling it.
- Generate unknown rear elevations only as clearly labelled illustrative geometry, never surveyed/exact-match claims.
- Bundle completed static USDZ models with add3DModelToProject. No viewing-time asset fetches or AI calls.

## 4. Georeference and integrate
- Use a data-driven placement catalog: stable site ID, source OSM ring(s), anchor, front bearing, real/estimated height with provenance, bundled resource name, source model axis/front convention, dimension calibration, status and generation/model IDs.
- Do not insert incomplete entries into DarLandmarkSite.all. Pending, missing or invalid models keep the native/original building visible and do not register a clip or ownership mask.
- Load generated geometry through SceneKit as an authoring/baking adapter, then use the existing shared Metal landmark path and Mapbox projection/depth. Do not add per-building SceneKit views/cameras or a new renderer.
- Audit BuildingRenderGeometry first: it currently reads UIColor diffuse values, not generated USDZ texture pigment. Add validated UV/texture pigment baking or suitable material remapping before expecting generated models to retain their colours. Never claim full PBR/texture support from the existing converter.
- Normalize the model's real base, validate the axis transform determinant and align to the measured footprint/bearing. Prefer dimension-preserving calibration; never silently squeeze a wrong model into an unrelated footprint. Check neighboring streets, podium extension and coastline clearance.
- Batch/cull by tile and material rather than create unlimited independent effect hosts. Include CPU/GPU buffers/textures/decode scratch/effects in admission. Existing landmark costs are outside the certified scenery ledger; integrating city-scale models requires explicit bounded accounting, not unchecked growth of DarCityLandmarks.scenes.
- Preserve min(384 MiB, physical RAM/16) admission, view-dependent residency, local-only viewing, original 1.3 GB downloads, v36/r3/joined1/LOD, source/archive/readiness, cameras, lighting/power policy, independent fleet and no idle clock.
- Suppress only each corresponding initialized host's saved/native shell. Initialization failure/removal restores fallback. Do not blank labels/roads or hide an entire district under an incomplete model batch.
- Ordinary buildings use verified footprint/levels with existing kit-of-parts, not costly image-to-3D per house. Preserve mapped roads/landuse/terrain/coast; generated images are not geographic survey data.

## 5. Acceptance and delivery
- Run runChecks after application changes. Only run tests if the user requests them.
- Compare actual app front/rear/roof views and district skyline to inspected references; check orientation, scale/base contact, duplicate shells, native fallback, materials and Day/night lighting.
- Measure submitted triangles, resident/peak memory, upload and physical-device frame/GPU costs. Simulator build success does not certify runtime Metal or performance.
- Update the existing approved plan and design contract truthfully. Keep each original Goal independently pending until its done-when evidence exists.
- Report exact researched/generated/bundled/installed counts, unfinished identities, boundaries and blockers. Do not call a whole tile mapped until ordinary context, major landmarks and ground/site coverage are all accounted for.
