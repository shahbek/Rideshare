# Style spec — the soft, rounded "toy city" map look

This file breaks down the reference look (Fenn-style, as seen in street-level, top-down, and close-up
captures) into what is **geometry**, what is **instancing**, and what is **shading**. When the user
says "make it look like this", map each visual cue below to its technique.

## Contents
1. Buildings (close-up)
2. Houses (top-down)
3. Trees
4. Ground, roads, props
5. Lighting, shadow, atmosphere
6. Palette starting values
7. The "why it looks rounded" checklist

---

## 1. Buildings (close-up)

| Visual cue | Technique | Cost |
|---|---|---|
| Flat pastel walls (sky blue, butter yellow, cream), no texture | Per-building palette index → flat albedo. No textures at all. | 0 |
| Thick, soft, rounded white parapet/cornice running around the roof edge, stepping in and out with the façade | **Profile sweep** of a rounded "D" profile (6–8 points) along the footprint ring, offset slightly outward. Smooth normals across the profile. | ~100–300 tris |
| Rounded vertical corners on bays and building corners | Footprint corner rounding with **2 segments per 90°** plus smooth normals; remaining sharp corners get the shader bevel. | ~2–4 extra quads per corner |
| Projecting bay windows with angled sides | Footprint rule: trapezoid push-out on street-facing walls longer than ~6 m. Same extrusion and sweep code as the main shell. | ~30–60 tris |
| Windows: dark slate-blue glass with a vertical gradient, thick cream frames, a sill | **Instanced window module**: frame ring (protrudes ~0.12 m) + sill + glass quad. The frame's depth fakes the recess. Glass gradient is in the shader. | ~36 tris, instanced |
| Chimneys and AC boxes on the roof, soft-edged, with an inset cap | **Instanced rounded-box props** (one bevel segment, smooth normals). An inset cap is a second, smaller box. | ~40–60 tris, instanced |
| Purple-grey soft darkening on the roof around parapets and under chimneys | Baked AO: inner AO ring in the roof mesh (vertex colour) + an **AO blob decal** under each roof prop. | ~0 |
| Thin white band between floors / at the base | Optional extra sweep with a small rounded profile (4 points). | ~60–150 tris |
| Grey flat roof | Earcut triangulation of the inset footprint. | n−2 tris |

What it is *not*: the walls are not subdivided, there are no boolean window holes, and there are no
multi-segment bevels. The rounded silhouette appears only where a sweep profile or a rounded footprint
corner sits on the outline.

## 2. Houses (top-down)

| Visual cue | Technique |
|---|---|
| Hip roofs with crisp ridges and per-facet flat shading | **Straight skeleton** of the footprint → roof facets with *flat* (per-face) normals. This is the one place where hard normals are intended. |
| Strong pastel roof colours (coral, periwinkle, warm grey, slate) | Palette index per building (hash of building id → one of 4–6 roof colours). |
| Thin white outline along the eaves | Fascia: a thin sweep (3–4 point profile) along the offset eave ring, or a shader rim at the roof's outer edge. |
| Slight overhang beyond the walls | Offset the roof footprint outward by 0.3–0.5 m before the skeleton. |
| Solar panels, skylights, small boxes | Instanced flat props aligned to the roof facet. |
| Large soft shadows of houses on the grass | **Baked into the ground tile texture** (rasterize footprints extruded along the sun direction, then blur). |
| Pool, driveway, sidewalk | Ground-tile polygons with palette colours; curbs as tiny sweeps or a shader edge. |

## 3. Trees

| Visual cue | Technique |
|---|---|
| Broadleaf canopy = cluster of 5–9 round blobs | Icospheres (subdiv 2 at LOD0, 1 at LOD1) arranged on a jittered dome. Hidden faces inside neighbouring blobs removed. |
| Soft, cloud-like shading with no visible facets | **Canopy normals**: `n = normalize(mix(sphereNormal, normalize(p - canopyCenter), 0.55))`. |
| Dark at the bottom, bright yellow-green at the top | Vertex colour or shader gradient by height within the canopy. |
| Fine speckled painterly grain on canopies | Tiny tiling noise (world or object space) modulating brightness ±6%. |
| Y-forked brown trunk | 6-sided tapered cylinders, 2–3 branches. |
| Conifers: stacked soft cones | 3–4 stacked cones (8–10 sides) with smooth normals and a slight droop. |
| Cypress: tall soft spindle | Lathe of a spindle profile, 8 sides × 8 rings. |
| Pink blossom trees | Same puff mesh with a different palette index. |
| Blurry purple-blue tree shadows on roads | **Blob shadow decal** per tree: an instanced ellipse quad offset along the sun direction, with alpha falloff, tinted with the shadow colour. |

## 4. Ground, roads, props

- Ground is a flat tile mesh, or polygons with palette colours: grass, sidewalk (warm peach), road
  (lavender-grey), water.
- The ground texture holds baked shadow + AO (one 8-bit channel each) at ~0.5 m/px.
- Lane markings are road decals generated from centrelines (instanced dashes or a shader along a
  road UV).
- Cars, lamp posts and benches are instanced library props with palette colours. Cars can animate along
  road polylines on the GPU.
- Curbs and sidewalks have a slight rounded edge: a 3-point sweep, or a shader bevel on the sidewalk
  polygon border.

## 5. Lighting, shadow, atmosphere

- One sun from upper-left (camera-relative feel), elevation ~45–55°, **fixed**. Fixed sun is what makes
  baking shadows legitimate.
- Shadows and AO are **tinted purple-blue**, never black or grey. Shadowed albedo ≈ albedo × shadowTint.
- Low contrast: wrap lighting (`wrap ≈ 0.35–0.5`) so walls facing away from the sun are still clearly
  coloured.
- Hemisphere ambient: sky blue from above, a little warm green-yellow bounce from below.
- Very subtle rim light on canopies and cornices (fresnel, ~0.1 strength) to separate shapes.
- Atmosphere: exponential distance fog plus a screen-top haze blending to pale sky blue. This also
  hides LOD pops.
- 4× MSAA. There is no outline pass in this style; edges are defined by value contrast.

## 6. Palette starting values (sRGB, tune by eye)

```
sky / fog        #A9CBEB   haze top #CFE3F5
shadow tint      #7E7DB3   (multiply)   ambient-occlusion tint #8C86B8
grass            #8DB43C → #6E9A2A (gradient by noise)
road             #A49FA8   sidewalk #EBC9A6   curb #F2E9E1
wall pastels     #7FA3D6  #E6C48F  #F1E6D8  #D9A9A0  #B9C7A8
trim / cornice   #F2ECE4
window glass     #4F6680 (top) → #7389A3 (bottom)   frame #EFE8DE
roof (flat)      #CFC8CC
roof (hip)       #F08F78  #8EA4D6  #A8A2B4  #C9B9B4  #7F86A3
puff canopy      #5F8A2A (bottom) → #B9D64A (top)
conifer          #2F5A3A → #4E7A4A    blossom #F2A9C7 → #FFC9DD
trunk            #8A5A3C
```

## 7. The "why it looks rounded" checklist

When a build looks blocky or faceted, check these in order:

1. Are sweep/canopy/corner normals **smooth** (shared or averaged), not per-face?
2. Do rounded footprint corners have at least 2 segments, with averaged normals?
3. Are cornice and parapet profiles rounded "D" shapes that overhang the wall?
4. Is the shader bevel active on hard wall corners and roof edges?
5. Is lighting wrapped and low-contrast, with a purple shadow tint?
6. Is MSAA on?
7. Is fog on? Distant faceting disappears into haze.

Only after all seven are in place should you consider adding segments.
