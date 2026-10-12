# Awkward footprints and the roof solver

Real footprint data is dirty: rotated near-rectangles with jitter, spikes from digitising errors,
slivers, acute wedges at street corners, self-intersections, multipolygons, courtyards, curved
façades. `scripts/footprint.py` repairs and classifies footprints. `scripts/roofs.py` picks a roof
strategy per class. Both run before any geometry is generated.

Reference render: `assets/gallery_awkward.png`.

## Contents
1. Repair pipeline
2. Classification
3. Roof strategies per class
4. The exact convex hip / gable (ConvexRoof)
5. Cross-wing roofs (rect_cover)
6. Concave notches (hull roof + infill walls)
7. Mansard fallback
8. Ring stacks (curved, pagoda, stepped)
9. Failure modes and fixes

---

## 1. Repair pipeline (`footprint.repair`)

```
make_valid()                      bow-ties, self-intersections -> valid (multi)polygons
split multipolygons               every part >= 2 m² becomes its own building (kiosks are ~4 m²)
drop holes < 20 m²                light wells are not courtyards
clean ring (iterate):
    merge edges < 0.3 m           to their midpoint
    remove spikes                 interior angle < 12° or > 348°
    remove collinear              turn < 4°
chamfer acute corners             interior < 40°: cut 0.6 m (≤ 30% of each edge)
orthogonalize                     dominant angle (length-weighted, 4-fold circular mean);
                                  edges within 7° of an axis snapped H/V; then x/y values
                                  within 0.3 m clustered so collinear walls share one line
```

Why each step matters for this style:
- **Spikes and slivers** become knife-edge sweeps and needle roof facets.
- **Acute corners** make miter offsets explode. That's why the sweep clamps at
  `scale ≤ 1/0.35`, and the chamfer removes the cause.
- **Unsnapped near-right angles** split cover rectangles into slivers and produce sloppy ridges.

## 2. Classification (`footprint.classify`)

| Class | Test | Typical |
|---|---|---|
| `rect` | ≤ 5 pts, area / min-rotated-rect > 0.98 | most houses |
| `ortho` | every edge within 2° of the dominant axes | L, T, U, H, plus, stepped |
| `convex` | area / hull > 0.995 | pentagons, trapezoids, wedges |
| `curved` | convex and ≥ 40% of vertices turn < 20° (≥ 8 pts) | round towers, apses, rotundas |
| `mild_concave` | area / hull > 0.85 | small notches, recessed entrances |
| `irregular` | everything else, or any holes for pitched roofs | boomerangs, odd blocks |

## 3. Roof strategies per class

| Class | Pitched roof strategy | Flat-roof styles |
|---|---|---|
| `rect` | one `ConvexRoof` (hip, or gable on chosen edges) | parapet sweep |
| `ortho` | `rect_cover` wings → one `ConvexRoof` each, interpenetrating | parapet sweep |
| `convex` / `curved` | `ConvexRoof` over the polygon (curved → conical) | parapet sweep (smooth arc normals) |
| `mild_concave` | `ConvexRoof` of the hull, clipped to footprint + overhang; walls raised to the roof along notch edges | parapet sweep |
| `irregular` / holes | `mansard` | parapet sweep |

Flat roofs work for every class, because sweeps and `buffer()` handle any polygon. That's why
dense urban styles never need the pitched-roof machinery.

## 4. The exact convex hip / gable (`ConvexRoof`)

For a convex host polygon with inward edge normals `m_i`, the hip roof is the lower envelope of
the edge planes:

```
z(p) = z_eave + tan(pitch) * min_i  m_i · (p − a_i)        over active (eave) edges i
facet_i = host ∩ { p : m_i·(p−a_i) ≤ m_j·(p−a_j)  ∀ active j }   (half-plane clips, exact)
```

- **Gables:** exclude edges from the active set. The neighbouring planes then run to that edge,
  and `infill_walls()` raises the gable triangle along the footprint edge.
- **Shed roof:** keep only one active edge (porches).
- **Overhang:** `offset_convex(ring, d)` moves every edge line out by `d`, preserving vertex
  order. The eave drops to `z_eave = H − d·tan(pitch)`, so the roof crosses the wall line at
  exactly H.
- **Fascia and barge boards:** `roof_boards()` uses one rule for both: a board that follows `z(p)`
  along every outline edge. It's flat along eaves and sloped along rakes.
- **Underside:** each facet is duplicated, darker, 12 cm lower, with reversed winding. The roof
  gets visible thickness and a proper soffit for the cost of 2× roof triangles.
- **`breakpoints(p, q)`:** returns the parameters where the governing plane changes along a
  segment, from pairwise plane equalities. This makes boards and infill walls exact with no sampling.

## 5. Cross-wing roofs (`rect_cover`)

For orthogonal polygons, the cell grid comes from the unique x and y coordinates. Then rectangles
are chosen greedily to cover it:

- All candidate rectangles are scored with vectorised prefix sums: fully inside the polygon, both
  sides ≥ 1.2 m.
- Each round picks the rectangle with the largest *uncovered* area, with a tie-break on total
  area. Overlap is allowed.
- Typical results: L → 2 wings, T → 2, U → 3, H → 3.

Overlap is the point. Each wing spans its full length, and two roofs with equal pitch intersect
exactly along the valley line. The visible surface is the upper envelope, which is a correct
cross-hip or cross-gable with no boolean operations. Narrower wings get lower ridges
automatically, as in real buildings. Interior wing ends that end up under another roof are
invisible, and the cost is a few hidden triangles.

## 6. Concave notches (hull roof + infill)

When `mild_concave`:
1. Build the hip of the convex hull.
2. Clip its facets to `footprint.buffer(overhang)`.
3. Run `infill_walls` along every footprint edge. Edges inside the hull, where the roof is higher
   than H, get walls up to the roof line. They read like small gables over the notch.

Keep this for fill > 0.85. Deeper concavities make the hull roof absurdly tall over the void, so
those go to the next strategy.

## 7. Mansard fallback

`mansard()` is a `ring_stack` with two steps (steep lower slope, flatter upper), then a flat top
from `buffer(−inset)`. It works for any simple polygon, so it's the safety net for irregular
footprints and for pitched-roof styles on footprints with courtyards. A mansard looks deliberate
in most styles, so it's preferred over a broken hip.

## 8. Ring stacks (`ring_stack`)

`ring_stack` offsets a ring by miter displacement through a list of `(inset, dz)` steps. Edges
keep hard creases (ridges and hips), while the profile is smooth along each slope.

On rectangles, an inset of half the short side collapses into the ridge line, which gives an exact
hip. That makes these possible:
- `curved_hip`: concave East-Asian profile with an upturned eave
- pagoda tiers
- mansards
- stepped crowns

On irregular convex rings, cap before the first edge collapses (the cap is skipped when the last
ring is invalid).

## 9. Failure modes and fixes

| Symptom | Cause | Fix |
|---|---|---|
| Thin sliver roof wing | near-collinear walls not merged | raise `orthogonalize` clustering (0.3 → 0.5 m) |
| Roof spike at a corner | acute angle survived | lower `acute_deg` threshold or raise the chamfer |
| Gable wall floating above the roof | gable chosen on an interior wing end | use `kind: hip` for that style, or restrict gables to boundary edges |
| Huge roof over a courtyard notch | concave footprint classified mild | lower the `mild_concave` threshold (0.85 → 0.9) |
| Cornice self-intersects | very short edges next to long ones | `min_edge` 0.3 → 0.5 m; the sweep's support loops shrink to edge/3 |
| Windows missing on the street | street edge mapping failed after repair | pass `street: [x, y]` (a point on the street) instead of an edge index |
