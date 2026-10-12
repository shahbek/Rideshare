# Dar es Salaam skyline and street styles (research, 2026-10-10)

Inspected photographs (opened and viewed, not just listed):
- Wikimedia Commons `Dar_es_Salaam_Skyline.jpg`: dense city-centre roofscape. Buff, beige, cream and salmon blocks; white towers with stacked horizontal balcony slabs; brown concrete frame grids with strong piers; dark glass towers behind; flat roofs everywhere.
- Commons `My_city,_Dar_es_Salaam.jpg` (from a city tower looking north): blue reflective glass towers with beige piers (PSPF), a beige tile tower with salmon spandrel bands, white balcony towers, a terracotta-brick frame with white infill, a low blue curtain-wall block, cream apartment blocks with tank-crowded roofs.
- Commons `DarEsSalaam-SamoraMachelAvenue.jpg`: a 1970s beige concrete slab with round porthole balconies and a castellated top, the modernist generation.
- Commons `Street_Scene_in_Asian_Quarter` and the Natwar/colonial facades: a 1936 Shia trust building in weathered grey render with a shaped name gable, corner balconies, louvred shutters, AC units and a corrugated mabati verandah over the pavement on posts. Behind it, a light-grey tile tower with navy tile bands at every floor and white-framed blue windows.
- Alamy GF0D9Y (Kisutu apartments): cream and pale-yellow facades with turquoise vertical pilasters and window surrounds, thin projecting eyebrow hoods over windows, jali screens, AC units. Taller salmon/cream towers behind with balconies.
- YouTube frame ID1e-ub7OGk (Kisutu rooftops): salmon-brick render tower with a charcoal stair band and AC-lined balconies; pale blue-grey tower with small square windows and grille panels; green-glass towers; large terracotta hip roof; the clock tower.
- YouTube frame 0hem5dw8sW8 (Oyster Bay drone): seafront apartment towers with white/grey stacked balcony bands and teal-green standing-seam hip roofs; 5–7 storey cream blocks with terracotta hip roofs; flat roofs with black tank clusters and rooftop pools.
- Alamy GF7AMR / GF7AM0 (Oyster Bay): white 8-storey slab with recessed balconies and white tank-topped stair towers; villas with terracotta hip roofs in dense tree cover; a white office with a blue glass wing; the city skyline beyond.

The research subagent could not open photos. Its unopened Commons list and its general (unverified) notes were not used as evidence.

## Initial style concepts (superseded by the structural pipeline below)

| Family | Seen in | Recipe |
|---|---|---|
| kisutu | Kisutu, Upanga | Pastel render; contrasting vertical stair strip with slot windows; pilaster strips; per-window eyebrow hoods; stacked solid-upstand balconies; AC units; 2-storey shop podium; corrugated street canopy; tank clusters |
| tiled | Newer Kisutu blocks | Grey, beige or gold tile; coloured tile band at each floor; wide white-framed windows; AC units |
| glass | Banks, hotels, Masaki offices | Blue, green or silver reflective glass; silver fins; spandrel lines; solid rounded corners; crown frame or fins; mast |
| ribbon | Offices | White spandrel bands with accent lines; continuous dark glazing; plant room |
| modernist | Samora Avenue, NHC (1970s) | Concrete eggcrate of floor ledges and vertical fins over dark glass; castellated parapet |
| coastal | Oyster Bay seafront | Stacked white balcony slabs with glass rails or wrap-around rings; dark sliding glazing; white piers; terracotta or teal hip roofs |

The palette hex values are photo estimates, not sampled albedo. Facades of individual unnamed buildings are inferred from the district family; `confidence` in `dar_skyline.json` says so per site. Named buildings carry OSM evidence (name, street, material, roof tags). Their exact elevations are not surveyed.

## Catalogue

`ios-twende/Twende/Resources/dar_skyline.json` contains 70 sites. Selection:
- **Harbour tiles** (z16 39919–39920/34012): OSM `building:levels` ≥ 10.
- **Masaki envelope:** OSM `building:levels` ≥ 8.

Exclusions:
- Already-bespoke landmarks: PSPF, TPA/Bandari, Johari, Exchange/Morocco.
- One building under construction.
- Footprints under 120 m², which are level-tag errors.

The `source` field records the Overpass selection criteria, not the full original query or photo verification per named building.

## Structural pipeline correction (2026-10-10)

The user rejected the initial generated architecture: primitive stacks, tanks/AC without detail, arbitrary rooftop cages and weak podiums. Reopened https://i.ytimg.com/vi/ID1e-ub7OGk/maxresdefault.jpg: the useful references are continuous curved curtain walls/spandrels, legible vertical structure and the Bandari sail/spine, not isolated cuboids. Existing approved Johari and airport geometry provides structural/rolled-shell examples; those landmark designs remain unchanged.

The first shared structural pipeline resolved envelope/floor/bay datums but still repeated one facade and a screened service court. The user explicitly rejected its generic result. The corrected pipeline below supersedes that shared shape language; `DarArchitecturalKit` remains a construction helper, not a requirement to put every module on every building. Services must fit the actual roof polygon, including concave notches.

Catalogue elevations remain interpretations. Historical `description` and `crown` fields are not individual photographic evidence and do not authorize restoring rejected geometry. New catalogue meshes replace their tile-owned saved shells after validation; ordinary eligible mid/high-rises use the same pipeline during explicit additive joined4 preparation, retaining joined3 and all older downloads. Low-rise/courtyard/authored exceptions retain their safe recipes. Visual quality, complete 70-site admission, HD streets/trees and device costs need current captures and measurements, not just a simulator build.

## No-clone/no-fencing correction (2026-10-10)

Reopened both Kisutu (ID1e-ub7OGk) and Oyster Bay (0hem5dw8sW8) images. Kisutu clearly contrasts dark recessed residential bays, small punched light-grey windows, curved office curtain walls and the separate Bandari sail. Oyster Bay contrasts teal/terracotta hip roofs, ordinary flat decks, projecting room galleries and occasional open equipment—not a louvred pen on every roof. Neither image verifies every catalogue elevation.

The earlier six forms (now superseded for skyline sites by the explicit compositions below) used different construction rules: Kisutu punched render with narrow stair bays/selected hoods; tiled masonry with flush courses; curtain walls with vertical silver seams/no white floor rings; horizontal office windows; deep concrete eggcrates with quiet short ends; principal-elevation coastal galleries with structural room dividers and solid/glass balustrades. Stable source-ID variation controls opening proportions, bay spacing, corners and selected occupied upper setbacks without changing mapped height. Ground floors distinguish office lobbies from residential street fronts; hip roofs remain on selected/catalogued residential forms.

Do not restore service fences, automatic paired tanks/AC clusters or universal rising parapets. Optional residential equipment occupies a checked but invisible clearance zone, with zero/one/two open detailed tanks and separately contained access housing; office roofs stay restrained. Approved bespoke sites and low-rise/courtyard exceptions remain their own recipes. HD floating nameplates and native POI/landmark symbols are disabled, preserving Twende's custom 3D pins/fleet/landmarks.

## Individual composition correction (2026-10-10)

The user rejects the six-family result as still generic and supplies https://r2-pub.rork.com/attachments/63u85ldulqphukissen1d.jpeg. Inspected directly: a broad low roofscape, distinct high shafts, varied shoulders/podium widths, strong continuous vertical frames, horizontal office bars and rooflines of very different proportions. This is composition evidence, not a license to infer every building identity from a 612px aerial.

Additional photographs opened and inspected:
- Tiffany Diamond **Indira Gandhi/Morogoro**, not Makunganya: operator https://www.tiffanydiamondhotels.com/indira and https://www.tiffanydiamondhotels.com/assets/images/indira-gandhi/overview.jpg. Peach solid walls, broad turquoise paired windows alternating with smaller service windows, two-storey glazed/retail base, shallow horizontal eyebrows. Top cropped. Operator says 10 storeys while original mapped catalogue says 11; keep source top/levels and record conflict.
- Nikko Tower, Aggrey/Jamhuri: official https://hotelnikkotowers.co.tz/ and https://media-cdn.tripadvisor.com/media/photo-p/09/b6/f2/e9/hotel-nikko-tower.jpg. Narrow pink-grey body, tapered central silver-glass face, small flanking recessed balconies, dark side windows. Top cropped; no evidence for old invented finned crown.
- Rainbow Hotel: https://media-cdn.tripadvisor.com/media/photo-s/01/cb/e2/85/rainbow-hotel-exterior.jpg. Pale slender shaft, full-height blue corner, narrow framed windows and projecting flat roof slab. Historical image; exact current finish/rear remains unverified.
- Tanzanite Executive Suites, Mali Street/Morogoro: https://content.r9cdn.net/rimg/himg/ad/19/f8/expedia_group-409000-2f1fe9-441232.jpg?width=1200&height=630&crop=true. Identified sign, blue curtain glazing/fine silver grid, recessed entry. It does NOT establish the roof or full silhouette.
- Faykat candidate: contractor https://adventconstructions.co.tz/wp-content/uploads/2020/09/advent-front5.jpg. Gold-glazed broad shaft, strong white horizontal structure, recessed stepped upper rooms. Geographic Morocco-road setting agrees, but project caption/identity is still provisional. Retain source 47.5m; do not use unverified 162m search height.
- Golden Jubilee: https://estimconstruction.com/wp-content/uploads/2020/02/Golden-Jubilee-3.jpg. Silver-blue unequal-height glazed volumes, projecting edges, lower brown-clad podium and high projecting glazed restaurant feature. This building is NOT Golden Plaza; do not apply to its unrelated plot.
- Bank of Tanzania: https://media.istockphoto.com/id/492842106/photo/bank-of-tanzanias-twin-towers-dar-es-salaam.jpg?s=612x612&w=is&k=20&c=kGKSQ9TL99Y-oL5QwQ6O6VqXe1LLMwCHf9EK5hGmZR4=. Pale tall edge blades, blue glass shafts and stepped roof heads, with a separate low curved hall. Not newly placed: exact source/coverage is outside this pass. Wikimedia PPF/Golden Jubilee image retrievals failed; no claim to have inspected those images.

Implementation authority is now `dar_skyline_compositions.json`, one explicit design per original 70 addresses. Most are deliberately labelled inferred skyline compositions, not independently verified elevations. `DarComposedTower` resolves 135 upper parts on the full-footprint podiums with original top/floor datums; `DarComposedFacade` has distinct physical sections and special Nikko/Rainbow frontage. No per-site random massing. Original outlines/levels/bespoke models and region coverage remain unchanged. Four photo-identified hotels plus provisional Faykat are not equivalent to 70 photogrammetric reconstructions.

Offline resource/plan audit checks all 70 identities, 135 upper parts, cap area/support/nonoverlap, and discrete facade allowance. Actual Swift mesh count/containment, roof fallback rate, visible coarse/HD appearance, thermal/peak memory/frame costs still require live execution. Update only disposable `bake4-compositions`; no extra ordinary-region rebuild, archive/readiness migration, source fetch or downloads.
