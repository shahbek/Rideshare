# Region profile — Dar es Salaam (and the Swahili coast)

How Dar es Salaam is actually built, which style each building type maps to, and the importer
rules (`scripts/osm_import.py --region dar_es_salaam`) that pick styles from OSM data. Read this
before tuning the rules, or when building a profile for a similar East African city (Mombasa,
Zanzibar Town, Tanga, Maputo).

Reference render: `assets/gallery_dar_es_salaam.png` (real OSM footprints, five neighbourhoods
+ the style sheet).

## Contents
1. What the city looks like (research summary)
2. Style mapping
3. Importer rules
4. Known gaps and data caveats
5. Tuning checklist

---

## 1. What the city looks like

**Skyline.** Tall buildings cluster in the CBD around Posta and the port/ferry area: glass office
and mixed-use towers built mostly 2011–2019. The tallest listed by CTBUH are:
- PPF Headquarters, 160 m
- TPA Headquarters, 157 m
- PSPF Commercial Towers A/B, 153 m twins, 35 floors
- Mwalimu Nyerere Foundation Square, 145 m twins
- RITA Tower, 133 m
- Millennium Tower and Uhuru Heights, 105 m

Below them sits a layer of 15–25-storey towers and many 8–16-storey office/apartment blocks.
Visual signature: **teal/blue-green tinted curtain glass over light stone or concrete podiums**.
It's a cluster, not a forest; everything around it is mid- and low-rise.

**Kariakoo (commercial core).** Extremely dense, tightly packed concrete-frame mid-rises. Many
were built quickly during a construction boom, often with **shops on the ground floor and
apartments or stores above**. The street grid is regular, with the diagonal Msimbazi Street.
Rooftops are flat, with water tanks.

**Regular homes (the "Swahili house").** The dominant single-storey house type: a **rectangle
with a central corridor and rooms on both sides**, a front veranda and a rear courtyard. Houses
grow incrementally (rooms added for tenants). Materials moved from mud-and-pole with palm-leaf
roofs to **cement block and corrugated iron**.

**Planned suburbs (Mikocheni, Sinza, Mbezi, Masaki).** Detached cement-block houses with
**painted corrugated hip roofs** (red, maroon, green, blue), set in walled compounds with a steel
gate, a water tank on a stand, and garden trees (many coconut palms).

**Informal settlements (Tandale, Manzese, Kigogo).** These have long housed the majority of
residents. They're mostly single-storey detached houses laid out haphazardly with no clear plots,
reached by narrow footpaths, under a near-continuous field of **corrugated iron roofs**: rusted
browns mixed with galvanised greys. From the air, roof coverage is almost the only thing you see.

**Swahili coast heritage (Stone Town, Lamu, Bagamoyo, old Dar).**
- coral-stone walls with **lime plaster and lime wash** (white / cream)
- **carved timber doors** with brass studs and a carved lintel
- the **baraza** stone bench along the street wall
- **enclosed carved-timber balconies**
- **crenellated parapets around flat terrace roofs**
- usually two storeys

**Makuti and beach bandas.** Makuti is coconut-palm-leaf thatch, laid on a steep (~45°+) roof
and finished with a thick ridge. Beach bandas (Coco Beach, Kigamboni, the islands) are open-sided
shelters on mangrove poles under makuti, used for beach bars and resorts.

**Kiosks (vibanda) and mobile-money agents.** Mobile money (M-Pesa and the other networks) is
everywhere, from roadside stalls to restaurants. The kiosk shape used here comes from general
observation, not a source: a small timber or metal box, a serving hatch with a counter, a
deep single-slope tin roof as an awning, and bright paint. **No brand logos or colours are
reproduced.** Use a neutral bright palette.

## 2. Style mapping

| Building type | Style | Signature in the Fenn look | Shell tris |
|---|---|---|---|
| CBD glass tower | tower `dar_glass` | teal curtain glass + mullion bands, stone podium, flat crown | 2–6k |
| Mid-rise apartments / Kariakoo blocks | `dar_apartment` | pastel walls, white floor bands, slab balconies with solid parapets on the street side, tinted glass, roller-shutter shops + canopy, roof tanks, dishes | 400–900 |
| Low commercial in the core | `fenn_rowhouse` + `water_tanks` | flat roof, rounded parapet | ~300 |
| Planned suburb house | `dar_house` | painted hip roof, barred windows, veranda, **compound wall + gate**, tank stand, palms | ~90 + wall |
| Swahili house | `swahili_house` | low gable corrugated roof (galv/rust), baraza bench, centred door | ~60 |
| Informal settlement house | `informal` | very low gable, rust/grey patchwork roofs, stones on the roof, raw block or mud walls, small dark windows | ~40 |
| Kiosk | `kiosk` | bright box, hatch + counter, deep single-slope roof | ~40 |
| Beach banda | `beach_banda` | open sides, mangrove poles, thick steep makuti hip/cone, palms | ~40 + poles |
| Coastal hotel / villa / restaurant | `swahili_coastal` | lime-wash white, crenellations, carved door, baraza, timber balcony | ~160 |
| Large mosque | mosque `ottoman` (2 minarets, no courtyard) | see `landmarks.md` | ~3k |
| Cathedral / church | church `gothic` / `romanesque` | St Joseph's Cathedral is gothic | ~0.8k |

Low polygon counts are the point. A 276-building informal neighbourhood (Tandale test) costs
~23k unique triangles in total.

## 3. Importer rules (`rules_dar_es_salaam`)

Inputs per building: OSM tags, footprint area, `building:levels` / `height`, local **density**
(footprint coverage within 35 m), **neighbourhood heights** (median and max of tagged levels
within 80 m), and **distance to the coastline**.

Rules are applied in this order:
1. **Places of worship:** `religion=muslim` → mosque (≥ 250 m²) or a small Swahili-coastal
   prayer house. `religion=christian` → church: gothic if ≥ 400 m², otherwise romanesque.
2. **Kiosk:** `building=kiosk`, or under 14 m².
3. **Banda:** `building=hut|roof|shelter|pavilion`, or `roof:material=thatch|palm_leaves`.
4. **Untagged levels in a mid/high-rise area** (neighbourhood max ≥ 6 or median ≥ 3): inherit the
   neighbourhood median.
   - Over 120 m² → `dar_apartment`.
   - Small → flat-roof shop.
   - Never "informal" in the core. Without this rule, half of the CBD became shacks, because most
     CBD buildings lack levels tags.
5. **Towers:** ≥ 15 levels or ≥ 50 m → `dar_glass`.
6. **Coastal** (< 250 m from the coastline, outside the core, ≤ 4 levels): hotels, villas,
   restaurants and houses → `swahili_coastal`.
7. **Mid-rise:** ≥ 4 levels, or ≥ 3 levels for apartments/offices, or 2+ level commercial →
   `dar_apartment`.
8. **Low-rise in the core** → flat-roof shop, or an apartment if ≥ 300 m² and 2 levels.
9. **Low-rise elsewhere**, by density:
   - density > 0.42 and area < 140 m² → `informal`
   - density > 0.25 and area < 220 m² → `swahili_house`
   - commercial or industrial → flat shop
   - otherwise → `dar_house`
10. **Tag overrides:**
    - `roof:shape` → roof kind
    - `roof:material` metal/cgi → grey sheet; tiles → terracotta
    - `roof:colour` → exact colour

**Façades** face the nearest road (`street` = nearest point on the nearest highway).

## 4. Known gaps and data caveats

- **Tag coverage is uneven.** CBD towers are well tagged, but many named ones (the PSPF twins,
  TPA) may sit outside a query box or lack `building:levels`. The neighbourhood rule (step 4)
  covers most of this. For hero accuracy, hand-author specs for the ~10 tallest towers (heights
  listed above).
- **Compound walls** are added by `dar_house` (`boundary_wall`). Where OSM maps `barrier=wall`,
  drop the extra and extrude the mapped walls instead, or walls will double up.
- **Kiosks** come from general knowledge (see above). Validate against street-level imagery
  before relying on the shape.
- **Courtyard Swahili houses:** OSM footprints are usually the outer outline only, so the rear
  courtyard isn't modelled.
- **Overpass mirrors** can be down. The importer falls back to the OSM API (`--source api`), which
  is fine for radii up to ~400 m.

## 5. Tuning checklist

- If informal areas look too orderly, lower the `swahili_house` density threshold (0.25), or
  widen the rust palette.
- If the CBD looks too low, check the step-4 thresholds. Use `_density` and `_tags` in the output
  specs to debug individual buildings.
- If roof tanks look noisy, cap them (default ≤ 3 per roof, 1 per 160 m²) or move them to LOD0
  only.
- For a dry-season look, set the ground to `#C9B48F` and sparse grass. For the rainy season, use
  more grass patches.
