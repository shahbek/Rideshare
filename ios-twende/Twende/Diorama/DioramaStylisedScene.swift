import CoreGraphics
import CoreLocation
import Foundation
import Metal
import simd

/// Fenn-style harbour: one small, stylised scene per tile with every light already in it.
///
/// Ordinary buildings are plain extrusions with the roof kit and a few proud window quads; the two
/// approved hero landmarks keep their full recipes while the researched skyline towers are reduced
/// to their massing; roads, lane paint, kerbs, pavements, compound walls, lawns, sand and every cast
/// shadow are painted once into a 1024 px ground image; trees, lamps and vehicles are a dozen
/// low-poly prototypes placed as instances. Sun and sky light are baked into the vertex colours and
/// the ground image, so the viewing shader only samples (`dioramaStylisedFragment`).
nonisolated enum DioramaStylisedScene {
    /// Measured output of one tile, for the bake report.
    struct Report: Sendable {
        var triangles: [DioramaCategory: Int] = [:]
        var instances: Int = 0
        var landmarkTriangles: [String: Int] = [:]
        var buildings: Int = 0
        var skippedForLandmarks: Int = 0
        var seconds: Double = 0
        var total: Int { triangles.values.reduce(0, +) }
        var lines: [String] {
            var out = ["\(total) triangles · \(instances) placements · \(buildings) buildings"]
            for category in DioramaCategory.allCases { if let n = triangles[category], n > 0 { out.append("\(category.rawValue): \(n)") } }
            for (id, n) in landmarkTriangles.sorted(by: { $0.key < $1.key }) { out.append("landmark \(id): \(n)") }
            return out
        }
    }

    static let imageSize = 1024
    static let groundStep: Double = 12
    static let maxWindowsPerBuilding = 16
    /// Day preset: sun direction and the colours the bake stores (the shader divides them back out).
    static let preset = DioramaLightingPreset.preset(for: .day)
    static let dayReference = SIMD3<Float>(1.12, 1.12, 1.12)

    // MARK: - Build

    static func build(_ data: DioramaTileData, config: DioramaConfig, landmarks: [DioramaLandmarkBake], device: MTLDevice) throws -> (DioramaResidentTile, Report) {
        let started = Date()
        var report = Report()
        try Task.checkCancellation()
        let terrain = (data.sourceTerrain ?? DioramaTerrain.load(rect: data.rect, config: config)).resolvingSurfaces(in: data)
        guard let painter = DioramaGroundPainter(rect: data.rect, size: imageSize, config: config, rasterOnly: true) else {
            throw NSError(domain: "Diorama", code: 2, userInfo: [NSLocalizedDescriptionKey: "ground image could not be created"])
        }
        let roads = DioramaRoadIndex(roads: data.roads, pavementWidth: config.pavementWidth)
        let props = DioramaStylisedProps()
        let district = DioramaDistrict.of(data.tile)
        let classifier = DioramaBuildingGenerator(config: config, roads: roads, terrain: terrain, district: district)

        // Landmark sites in this tile's frame: heroes at full detail, skyline towers as massing.
        struct Site { let id: String; let ring: [DV2]; let offset: DV2; let floor: Double; let skyline: Bool }
        var sites: [Site] = []
        for bake in landmarks {
            let offset = data.projection.local(longitude: bake.origin.longitude, latitude: bake.origin.latitude)
            let ring = bake.floorRing.map { $0 + offset }
            guard ring.count >= 3, DioramaRect.bounding(ring).intersects(data.rect.expanded(by: 20)) else { continue }
            let floor = terrain.foundationHeight(DioramaPolygon.clipPolygon(ring, to: data.rect).count >= 3 ? DioramaPolygon.clipPolygon(ring, to: data.rect) : ring) - 0.18
            sites.append(Site(id: bake.id, ring: ring, offset: offset, floor: floor, skyline: DarSkyline.isSkyline(bake.id)))
        }
        func ownedByLandmark(_ feature: DioramaBuildingFeature) -> Bool {
            sites.contains { site in
                DioramaPolygon.contains(site.ring, feature.centroid)
                    || DioramaPolygon.contains(feature.ring, DioramaPolygon.centroid(site.ring))
                    || feature.ring.contains { DioramaPolygon.contains(site.ring, $0) }
            }
        }

        var buildings = DioramaMesh(), windowGlow = DioramaMesh(), ground = DioramaMesh(), water = DioramaMesh()
        var vegetation = DioramaMesh(), propMesh = DioramaMesh(), propGlow = DioramaMesh()
        var lights: [DioramaLight] = []
        var built: [DioramaBuilt] = []
        var shadowCasters: [(ring: [DV2], height: Double)] = []

        // MARK: Buildings
        for feature in data.buildings {
            try Task.checkCancellation()
            guard feature.ring.count >= 3, feature.area > 4 else { continue }
            if ownedByLandmark(feature) { report.skippedForLandmarks += 1; continue }
            let (kind, floors) = classifier.classify(feature)
            let height = max(2.8, feature.height ?? Double(floors) * config.floorHeight)
            var rng = DioramaRandom(seed: feature.id, salt: 2)
            _ = rng.range(-1...1)
            let override = config.buildingOverrides[feature.id]
            let wallColor = override?.wallColor ?? rng.pick(district.wallColors(kind, config: config))
            let base = terrain.buildingHeight(feature)
            let oriented = DioramaPolygon.counterClockwise(feature.ring, flags: feature.clipped.count == feature.ring.count ? feature.clipped : Array(repeating: false, count: feature.ring.count))
            let ring = oriented.points
            let flags = oriented.flags.count == ring.count ? oriented.flags : Array(repeating: false, count: ring.count)
            buildings.baseZ = base
            // Walls stand a little below ground so slopes never open a gap under the footprint.
            buildings.extrude(ring, z0: -0.6, z1: height, wallColor)

            var pitched = kind == .villa
            if kind == .villa, rng.chance(1 - config.hipRoofShare) { pitched = false }
            if district == .masaki, kind == .apartments, floors <= 10, rng.chance(0.5) { pitched = true }
            if district == .city, kind == .villa, floors >= 2 { pitched = rng.chance(0.25) }
            let roofColor = override?.roofColor ?? rng.pick(district.pitchedRoofColors)
            var roofRoll = DioramaRandom(seed: feature.id, salt: 0x52_4F_4F_46)
            let roll = roofRoll.unit()
            if !pitched, override == nil, kind != .villa, floors <= 2, roofRoll.chance(district == .masaki ? 0.25 : 0.6) { pitched = true }
            var roofed = false
            if pitched, !(override?.flatRoof ?? false), !flags.contains(true), ring.count <= 24 {
                let shape = DioramaRoofKit.shape(of: ring)
                for form in DioramaRoofKit.candidates(for: shape, roll: roll, modern: district == .masaki && kind == .villa) {
                    if DioramaRoofKit.build(form, ring: ring, flags: flags, z: height, pitch: config.roofPitchDegrees * .pi / 180,
                                            overhang: 0.5, maxRise: config.hipRoofMaxRise, color: roofColor, fascia: .trimWhite,
                                            gable: wallColor, into: &buildings) {
                        roofed = true; break
                    }
                }
            }
            if !roofed {
                // Flat deck with a low parapet: the deck sits 0.4 m under the wall top.
                let deck: DioramaSwatch = override?.roofColor ?? .roofConcrete
                buildings.polygon(ring, z: height - 0.4, deck)
                if let inner = DioramaPolygon.offset(ring, by: -0.3), inner.count == ring.count {
                    for i in 0..<ring.count {
                        let a = inner[i], b = inner[(i + 1) % ring.count]
                        buildings.quad(DV3(a, height - 0.4), DV3(b, height - 0.4), DV3(b, height), DV3(a, height), wallColor,
                                       normal: DV3((b - a).normalized.left, 0))
                    }
                }
            }
            // Fenn-style windows: a few proud quads on street-facing walls, never more than sixteen.
            windows(ring: ring, flags: flags, floors: floors, height: height, kind: kind, roads: roads,
                    into: &buildings, glow: &windowGlow, rng: &rng)
            buildings.baseZ = 0
            let box = DioramaPolygon.minimumAreaRectangle(feature.ring)
            let front = frontEdge(ring, roads: roads)
            let entrance = front.map { (ring[$0] + ring[($0 + 1) % ring.count]) * 0.5 } ?? feature.centroid
            let entranceOut = front.map { (ring[($0 + 1) % ring.count] - ring[$0]).normalized.right } ?? DV2(0, -1)
            built.append(DioramaBuilt(feature: feature, kind: kind, floors: floors, height: height, box: box, flatRoof: !roofed,
                                      wallColor: wallColor, entrance: entrance, entranceOut: entranceOut))
            shadowCasters.append((ring, height))
            report.buildings += 1
        }
        windowGlow.baseZ = 0

        // MARK: Landmarks
        var landmarkGeometry: [(id: String, geometry: DioramaLandmarkBake.Geometry, move: SIMD3<Float>)] = []
        for bake in landmarks {
            guard let site = sites.first(where: { $0.id == bake.id }) else { continue }
            if site.skyline, let skyline = DarSkyline.site(bake.id) {
                var generator = DarTowerGenerator(site: skyline)
                buildings.baseZ = site.floor
                let before = buildings.triangleCount
                let ring = DioramaPolygon.counterClockwise(site.ring)
                if generator.buildContext(ring, into: &buildings) {
                    var rng = DioramaRandom(seed: skyline.osm, salt: 9)
                    windows(ring: ring, flags: Array(repeating: false, count: ring.count), floors: skyline.levels, height: skyline.height,
                            kind: .apartments, roads: roads, into: &buildings, glow: &windowGlow, rng: &rng)
                    shadowCasters.append((ring, skyline.height))
                    report.landmarkTriangles[bake.id] = buildings.triangleCount - before
                } else {
                    buildings.extrude(ring, z0: -0.6, z1: skyline.height, .whitewash, top: .roofConcrete)
                    report.landmarkTriangles[bake.id] = buildings.triangleCount - before
                }
                buildings.baseZ = 0
            } else {
                landmarkGeometry.append((bake.id, bake.geometry, SIMD3(Float(site.offset.x), Float(site.offset.y), Float(site.floor))))
                shadowCasters.append((site.ring, min(60, Double(bake.geometry.maximum.z))))
                report.landmarkTriangles[bake.id] = bake.geometry.indices.count / 3
                for light in bake.geometry.lights {
                    lights.append(DioramaLight(position: DV3(light.position.x + site.offset.x, light.position.y + site.offset.y, light.position.z + site.floor),
                                               color: light.color, radius: light.radius, intensity: light.intensity))
                }
            }
        }

        // MARK: Ground paint
        try Task.checkCancellation()
        painter.fillAll(.grass)
        for park in data.landuse where ["park", "common", "garden", "cemetery"].contains(park.kind) {
            guard let outer = park.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect)
            if ring.count >= 3, DioramaPolygon.area(ring) > 40 { painter.fill(ring, .lawn) }
        }
        for area in data.landuse where area.kind == "sand" || area.kind == "beach" || area.tags["natural"] == "beach" {
            guard area.rings.first.map({ $0.count >= 3 }) == true else { continue }
            painter.fill(area.rings.map { DioramaPolygon.clipPolygon($0, to: data.rect) }, .earth)
        }
        for area in data.landuse {
            guard let ring = area.rings.first, ring.count >= 3 else { continue }
            let clipped = DioramaPolygon.clipPolygon(ring, to: data.rect)
            guard clipped.count >= 3 else { continue }
            switch area.kind {
            case "parking": painter.fill(clipped, .paving)
            case "pitch": painter.fill(clipped, .pitchGreen)
            case "fuel", "industrial": painter.fill(clipped, .concrete)
            default: break
            }
        }
        // The wall generator's geometry is discarded; only its plots (lawns, gates, drives) are used.
        var wallSink = DioramaMesh()
        let compounds = DioramaCompoundWallGenerator(config: config, roads: roads, buildings: built, tileRect: data.rect,
                                                     terrain: terrain, landuse: data.landuse).generate(into: &wallSink)
        for compound in compounds {
            painter.fill(DioramaPolygon.offset(compound.ring, by: -0.35) ?? compound.ring, .lawn)
        }
        for compound in compounds {
            guard let gate = compound.gate else { continue }
            let entrance = compound.building.entrance + compound.building.entranceOut * 0.4
            painter.stroke([gate.point, entrance], width: config.gateWidth - 0.3, .paving, cap: .butt)
            if let road = roads.nearest(to: gate.point, within: 25) {
                let out = (gate.point - road.point).normalized
                painter.stroke([road.point + out * roads.corridorHalfWidth(road.road), gate.point], width: config.gateWidth, .paving, cap: .butt)
            }
        }
        let layout = DioramaStreetLayout(data: data, config: config)
        DioramaRoadGenerator(config: config, data: data, roads: roads, terrain: terrain, layout: layout, compounds: compounds, painter: painter).paintOnly()
        // Compound walls are paint: a pale line along every standing edge, open at the gate.
        for compound in compounds {
            let n = compound.ring.count
            for i in 0..<n where !compound.gaps[i] {
                let a = compound.ring[i], b = compound.ring[(i + 1) % n]
                guard a.distance(to: b) > 0.3 else { continue }
                if let gate = compound.gate, DioramaPolygon.distanceToSegment(gate.point, a, b) < 0.2 {
                    let dir = (b - a).normalized, half = config.gateWidth / 2
                    let t = (gate.point - a).dot(dir)
                    if t - half > 0.3 { painter.stroke([a, a + dir * (t - half)], width: compound.isHedge ? 0.8 : 0.35, compound.isHedge ? .hedge : .whitewash, cap: .butt) }
                    if t + half < a.distance(to: b) - 0.3 { painter.stroke([a + dir * (t + half), b], width: compound.isHedge ? 0.8 : 0.35, compound.isHedge ? .hedge : .whitewash, cap: .butt) }
                } else {
                    painter.stroke([a, b], width: compound.isHedge ? 0.8 : 0.35, compound.isHedge ? .hedge : .whitewash, cap: .butt)
                }
            }
        }
        // Shoreline sand along the mapped coast (never along tile cuts), then the sea floor.
        for area in data.water {
            guard let outer = area.rings.first, outer.count >= 3 else { continue }
            let n = outer.count
            for i in 0..<n where i < area.clipped.count && !area.clipped[i] {
                painter.stroke([outer[i], outer[(i + 1) % n]], width: 7, .earth)
            }
        }
        for area in data.water {
            painter.fill(area.rings.map { DioramaPolygon.clipPolygon($0, to: data.rect) }, .seabed)
        }

        // MARK: Plate and water
        plate(terrain: terrain, rect: data.rect, into: &ground, config: config)
        for area in data.water {
            guard let outer = area.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect)
            for piece in DioramaGroundCutouts(polygons: Array(area.rings.dropFirst())).subtract(from: ring) {
                water.polygon(piece, z: terrain.waterLevel, .sea, attribute: Float(config.shallowWaterDistance))
            }
        }

        // MARK: Props
        try Task.checkCancellation()
        var treeShadows: [(DV2, Double)] = []
        place(data: data, config: config, roads: roads, terrain: terrain, built: built, compounds: compounds, props: props,
              vegetation: &vegetation, propMesh: &propMesh, propGlow: &propGlow, lights: &lights, treeShadows: &treeShadows)

        // MARK: Baked shadows
        let sun = preset.sun
        let slide = DV2(Double(-sun.x / sun.z), Double(-sun.y / sun.z))
        var pieces: [[DV2]] = []
        for caster in shadowCasters {
            let reach = slide * min(caster.height, 34)
            let ring = DioramaPolygon.counterClockwise(caster.ring)
            pieces.append(ring.map { $0 + reach })
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                pieces.append([a, b, b + reach, a + reach])
            }
        }
        painter.shade(pieces, darkness: 0.30)
        for (centre, radius) in treeShadows {
            painter.shadeDisc(at: centre + slide * 3.2, radius: radius, darkness: 0.22)
        }
        let image = painter.image()

        // MARK: Pack
        try Task.checkCancellation()
        var vertices: [DioramaPackedVertex] = []
        var indices: [UInt32] = []
        var ranges: [DioramaRenderLayer.Range] = []
        var groups: [DioramaInstanceGroup] = []
        var allInstances: [DioramaInstanceData] = []
        var shadowLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude), shadowHigh = -shadowLow

        func appendMesh(_ mesh: DioramaMesh, category: DioramaCategory, rotationFree: Bool = false) -> Int {
            let base = vertices.count
            let packed = DioramaMeshPacking.vertices(mesh, category: category, config: config)
            vertices.reserveCapacity(vertices.count + packed.count)
            let shaded = category == .buildings || category == .vegetation || category == .props || category == .walls
            for v in packed {
                var color = v.color
                if shaded, v.appearance.w < 0.5, v.appearance.y < 8.5 || v.appearance.y > 9.5 {
                    let factor = light(normal: SIMD3(v.normal.x, v.normal.y, v.normal.z), rotationFree: rotationFree)
                    color = SIMD4(v.color.x * factor.x, v.color.y * factor.y, v.color.z * factor.z, v.color.w)
                }
                vertices.append(DioramaPackedVertex(BuildingRenderVertex(position: v.position, normal: v.normal, color: color, appearance: v.appearance)))
            }
            return base
        }
        func appendTriangles(_ mesh: DioramaMesh, category: DioramaCategory) {
            guard !mesh.indices.isEmpty else { return }
            let base = appendMesh(mesh, category: category)
            let flags = mesh.doubleSidedTriangles
            var cells: [Int: [UInt32]] = [:]
            for i in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
                guard Int(a) < mesh.positions.count, Int(b) < mesh.positions.count, Int(c) < mesh.positions.count else { continue }
                let p = mesh.positions[Int(a)]
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                let twoSided = i / 3 < flags.count && flags[i / 3]
                let key = (Int(floor(p.x / 120)) + 1000 + (Int(floor(p.y / 120)) + 1000) * 4000) * 2 + (twoSided ? 1 : 0)
                cells[key, default: []].append(contentsOf: [UInt32(base) + a, UInt32(base) + b, UInt32(base) + c])
            }
            for key in cells.keys.sorted() {
                guard let batch = cells[key] else { continue }
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                for index in batch {
                    let p = vertices[Int(index)].position
                    lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                }
                let padding: Float = category == .propGlow ? 6 : 1
                ranges.append(.init(category: category, start: indices.count, count: batch.count,
                                    minimum: lo - SIMD3(repeating: padding), maximum: hi + SIMD3(repeating: padding),
                                    doubleSided: key & 1 == 1 || category == .propGlow || category == .water))
                indices.append(contentsOf: batch)
                if category != .water, !category.isEmissive { shadowLow = simd_min(shadowLow, lo); shadowHigh = simd_max(shadowHigh, hi) }
            }
            report.triangles[category, default: 0] += mesh.indices.count / 3
        }
        var bakedPrototypes: [Int: (Int, Int)] = [:]
        func appendInstances(_ mesh: DioramaMesh, category: DioramaCategory) {
            var placements: [Int: [Int: [DioramaInstanceData]]] = [:]
            for placement in mesh.instances {
                guard placement.prototype >= 0, placement.prototype < props.prototypes.count else { continue }
                let t = placement.transform
                guard t.translation.x.isFinite, t.translation.y.isFinite, t.translation.z.isFinite else { continue }
                let prototype = props.prototypes[placement.prototype]
                let radius = Float(prototype.radius * max(t.scale.x, max(t.scale.y, t.scale.z)))
                let item = DioramaInstanceData(
                    placement: SIMD4(Float(t.translation.x), Float(t.translation.y), Float(t.translation.z), Float(t.rotation)),
                    scale: SIMD4(Float(t.scale.x), Float(t.scale.y), Float(t.scale.z), radius), tint: SIMD4(placement.tint, 1), grading: .zero)
                let bin = Int(floor(t.translation.x / 120)) + Int(floor(t.translation.y / 120)) * 10000
                placements[placement.prototype, default: [:]][bin, default: []].append(item)
            }
            for id in placements.keys.sorted() {
                let prototype = props.prototypes[id]
                let key = id * 2 + (category.isEmissive ? 1 : 0)
                let (start, count): (Int, Int)
                if let found = bakedPrototypes[key] { (start, count) = found } else {
                    let base = appendMesh(prototype.full, category: category, rotationFree: true)
                    start = indices.count
                    indices.append(contentsOf: prototype.full.indices.map { UInt32(base) + $0 })
                    count = indices.count - start
                    bakedPrototypes[key] = (start, count)
                    report.triangles[category, default: 0] += count / 3
                }
                guard let bins = placements[id] else { continue }
                for bin in bins.keys.sorted() {
                    guard let list = bins[bin], !list.isEmpty else { continue }
                    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                    for item in list {
                        lo = simd_min(lo, item.centre - SIMD3(repeating: item.radius)); hi = simd_max(hi, item.centre + SIMD3(repeating: item.radius))
                    }
                    groups.append(DioramaInstanceGroup(category: category, fullStart: start, fullCount: count, lightStart: start, lightCount: count,
                                                       doubleSided: prototype.full.hasDoubleSidedTriangles, instances: list,
                                                       firstInstance: allInstances.count, minimum: lo, maximum: hi))
                    allInstances.append(contentsOf: list)
                    report.instances += list.count
                    if !category.isEmissive { shadowLow = simd_min(shadowLow, lo); shadowHigh = simd_max(shadowHigh, hi) }
                }
            }
        }

        appendTriangles(ground, category: .ground)
        appendTriangles(buildings, category: .buildings)
        appendInstances(vegetation, category: .vegetation)
        appendInstances(propMesh, category: .props)
        appendTriangles(water, category: .water)
        appendTriangles(windowGlow, category: .windowGlow)
        appendTriangles(propGlow, category: .propGlow)
        appendInstances(propGlow, category: .propGlow)

        // Hero landmarks: full approved geometry, moved onto the site datum, lit like everything else.
        let clip = data.rect.expanded(by: 0.5)
        for landmark in landmarkGeometry {
            let g = landmark.geometry
            let base = vertices.count
            var moved: [SIMD3<Float>] = []
            moved.reserveCapacity(g.vertices.count)
            for v in g.vertices {
                var p = SIMD3(v.position.x, v.position.y, v.position.z) + landmark.move
                if v.position.z <= -0.299 { p.z = landmark.move.z - 0.6 }
                moved.append(p)
                var color = v.color
                if v.appearance.w < 0.5, v.appearance.y < 14.5 {
                    let factor = light(normal: SIMD3(v.normal.x, v.normal.y, v.normal.z), rotationFree: false)
                    color = SIMD4(v.color.x * factor.x, v.color.y * factor.y, v.color.z * factor.z, v.color.w)
                }
                vertices.append(DioramaPackedVertex(BuildingRenderVertex(position: SIMD4(p.x, p.y, p.z, v.position.w), normal: v.normal, color: color, appearance: v.appearance)))
            }
            for r in g.ranges {
                let start = indices.count
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                for t in stride(from: r.start, to: r.start + r.count - 2, by: 3) {
                    let a = Int(g.indices[t]), b = Int(g.indices[t + 1]), c = Int(g.indices[t + 2])
                    guard a < moved.count, b < moved.count, c < moved.count else { continue }
                    let tlo = simd_min(simd_min(moved[a], moved[b]), moved[c]), thi = simd_max(simd_max(moved[a], moved[b]), moved[c])
                    guard Double(tlo.x) <= clip.maxX, Double(thi.x) >= clip.minX, Double(tlo.y) <= clip.maxY, Double(thi.y) >= clip.minY else { continue }
                    indices.append(contentsOf: [UInt32(base + a), UInt32(base + b), UInt32(base + c)])
                    lo = simd_min(lo, tlo); hi = simd_max(hi, thi)
                }
                let count = indices.count - start
                guard count > 0 else { continue }
                ranges.append(.init(category: r.category, start: start, count: count, minimum: lo, maximum: hi, doubleSided: r.doubleSided, translucent: r.translucent))
                report.triangles[r.category, default: 0] += count / 3
                if !r.category.isEmissive { shadowLow = simd_min(shadowLow, lo); shadowHigh = simd_max(shadowHigh, hi) }
            }
        }
        guard !indices.isEmpty, vertices.count < 1 << 24 else {
            throw NSError(domain: "Diorama", code: 1, userInfo: [NSLocalizedDescriptionKey: "stylised tile produced no geometry"])
        }

        // MARK: Upload
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            let bytes = max(16, values.count * MemoryLayout<T>.stride)
            guard let b = device.makeBuffer(length: bytes, options: .storageModeShared) else { throw DioramaTileArchive.ArchiveError.invalid }
            values.withUnsafeBytes { raw in if let base = raw.baseAddress, raw.count > 0 { b.contents().copyMemory(from: base, byteCount: raw.count) } }
            return b
        }
        let vertexBuffer = try buffer(vertices)
        let indexBuffer = try buffer(indices)
        let instanceBuffer = try buffer(allInstances)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.size, height: image.size, mipmapped: false)
        descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw DioramaTileArchive.ArchiveError.invalid }
        image.rgba.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { texture.replace(region: MTLRegionMake2D(0, 0, image.size, image.size), mipmapLevel: 0, withBytes: base, bytesPerRow: image.size * 4) }
        }
        let empty = DioramaVectorPaint()
        let grid = DioramaLightGrid.build(Array(lights.prefix(config.maxLights)), rect: data.rect, cells: 16, perCell: 16)
        report.seconds = Date().timeIntervalSince(started)
        let summary = DioramaTileSummary(shorelineReport: [], optimizationReport: report.lines, stageTimings: [],
                                         totalTriangles: indices.count / 3, totalInstances: allInstances.count,
                                         totalBytes: vertices.count * MemoryLayout<DioramaPackedVertex>.stride + indices.count * 4,
                                         generationSeconds: report.seconds)
        let shadow = shadowLow.x.isFinite && shadowHigh.x > shadowLow.x ? (shadowLow, shadowHigh) : nil
        let resident = DioramaResidentTile(tile: data.tile, device: device, vertexBuffer: vertexBuffer, vertexCount: vertices.count,
            indexBuffer: indexBuffer, indexCount: indices.count, instanceBuffer: instanceBuffer, instanceCount: allInstances.count,
            ranges: ranges, groups: groups, lightGrid: grid, paintBuffer: try buffer(empty.triangles), paintTableBuffer: try buffer(empty.table),
            paintIndexBuffer: try buffer(empty.indices), groundTexture: texture, waterHeight: terrain.waterLevel, labels: [],
            poolBounds: nil, shadowBounds: shadow, materialCounts: .zero, summary: summary)
        return (resident, report)
    }

    // MARK: - Lighting

    /// Day sun plus hemisphere sky, normalised so a sunlit roof keeps its own colour. Instanced
    /// prototypes rotate freely, so they only take the sun's vertical share.
    static func light(normal n: SIMD3<Float>, rotationFree: Bool) -> SIMD3<Float> {
        let length = simd_length(n)
        let unit = length > 0.0001 ? n / length : SIMD3(0, 0, 1)
        let hemi = unit.z * 0.5 + 0.5
        let ambient = simd_mix(preset.ground, preset.sky, SIMD3(repeating: hemi)) * preset.ambientStrength
        let facing = rotationFree ? max(0, unit.z * 0.75 + 0.25) * 0.78 : max(0, simd_dot(unit, preset.sun))
        return (ambient + preset.sunColor * facing) / dayReference
    }

    // MARK: - Pieces

    /// One draped heightfield plate at a coarse step; colour comes entirely from the ground image.
    private static func plate(terrain: DioramaTerrain, rect: DioramaRect, into mesh: inout DioramaMesh, config: DioramaConfig) {
        let columns = max(2, Int(ceil(rect.width / groundStep)) + 1), rows = max(2, Int(ceil(rect.height / groundStep)) + 1)
        let uv = DioramaAtlas.uv(.painted, dark: false)
        let base = UInt32(mesh.positions.count)
        for row in 0..<rows {
            for column in 0..<columns {
                let p = DV2(min(rect.maxX, rect.minX + Double(column) * groundStep), min(rect.maxY, rect.minY + Double(row) * groundStep))
                mesh.vertex(DV3(p, terrain.height(p)), DV3(0, 0, 1), uv)
            }
        }
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let a = base + UInt32(row * columns + column), b = a + 1, d = a + UInt32(columns), c = d + 1
                mesh.face(a, b, c); mesh.face(a, c, d)
            }
        }
    }

    private static func frontEdge(_ ring: [DV2], roads: DioramaRoadIndex) -> Int? {
        var bestIndex: Int?
        var bestDistance = Double.infinity
        for i in ring.indices {
            let mid = (ring[i] + ring[(i + 1) % ring.count]) * 0.5
            guard ring[i].distance(to: ring[(i + 1) % ring.count]) > 2.4, let near = roads.nearest(to: mid, within: 40) else { continue }
            if near.distance < bestDistance { bestDistance = near.distance; bestIndex = i }
        }
        return bestIndex
    }

    /// Proud window quads on the walls nearest a street; a warm emissive twin lights up at night.
    private static func windows(ring: [DV2], flags: [Bool], floors: Int, height: Double, kind: DioramaBuildingKind, roads: DioramaRoadIndex,
                                into mesh: inout DioramaMesh, glow: inout DioramaMesh, rng: inout DioramaRandom) {
        guard floors >= 1, height > 2.5 else { return }
        let storey = height / Double(max(floors, 1))
        guard storey > 2.2 else { return }
        let n = ring.count
        var edges = (0..<n).filter { !flags[$0] && ring[$0].distance(to: ring[($0 + 1) % n]) > 3 }
            .map { i -> (Int, Double) in
                let mid = (ring[i] + ring[(i + 1) % n]) * 0.5
                return (i, roads.nearest(to: mid, within: 60)?.distance ?? 60)
            }
            .sorted { $0.1 < $1.1 }
        edges = Array(edges.prefix(2))
        var budget = maxWindowsPerBuilding
        let glowShare = kind == .villa ? 0.5 : 0.35
        // Low buildings get a window per floor; towers get one tall glazing strip per column.
        let tall = floors > 6
        let rowsShown = tall ? 1 : min(floors, 4)
        glow.baseZ = mesh.baseZ
        for (i, _) in edges where budget > 0 {
            let a = ring[i], b = ring[(i + 1) % n]
            let length = a.distance(to: b)
            let dir = (b - a).normalized, out = dir.right
            let columns = min(max(1, Int((length - 1.2) / (kind == .villa ? 3.0 : 3.6))), 4)
            let pitch = length / Double(columns)
            let width = min(tall ? 1.8 : 1.4, pitch * 0.45)
            for floor in 0..<rowsShown {
                let z0 = tall ? storey * 0.4 : Double(floor) * storey + storey * 0.3
                let z1 = tall ? height - storey * 0.5 : Double(floor) * storey + storey * 0.78
                for column in 0..<columns where budget > 0 {
                    let u = (Double(column) + 0.5) * pitch
                    let l = a + dir * (u - width / 2) + out * 0.04, r = a + dir * (u + width / 2) + out * 0.04
                    mesh.quad(DV3(l, z0), DV3(r, z0), DV3(r, z1), DV3(l, z1), .glass, normal: DV3(out, 0))
                    if rng.chance(glowShare) {
                        let lg = l + out * 0.015, rg = r + out * 0.015
                        glow.quad(DV3(lg, z0), DV3(rg, z0), DV3(rg, z1), DV3(lg, z1), .windowGlow, normal: DV3(out, 0))
                    }
                    budget -= 1
                }
            }
        }
        glow.baseZ = 0
    }

    // MARK: - Props

    private static func place(data: DioramaTileData, config: DioramaConfig, roads: DioramaRoadIndex, terrain: DioramaTerrain,
                              built: [DioramaBuilt], compounds: [DioramaCompound], props: DioramaStylisedProps,
                              vegetation: inout DioramaMesh, propMesh: inout DioramaMesh, propGlow: inout DioramaMesh,
                              lights: inout [DioramaLight], treeShadows: inout [(DV2, Double)]) {
        var rng = DioramaRandom(seed: UInt64(data.tile.x) << 32 | UInt64(data.tile.y), salt: 131)
        let inner = data.rect.expanded(by: -1)
        func isWater(_ p: DV2) -> Bool { data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) } }
        func isFree(_ p: DV2, radius: Double) -> Bool {
            guard inner.contains(p), !isWater(p), !roads.isOnRoad(p, margin: radius) else { return false }
            for b in built where b.box.expanded(by: radius).contains(p) { return false }
            return true
        }
        var placed: [DV2] = []
        func tryPlace(_ p: DV2, spacing: Double, radius: Double = 1.2) -> Bool {
            guard isFree(p, radius: radius), !placed.contains(where: { $0.distance(to: p) < spacing }) else { return false }
            placed.append(p); return true
        }
        func tree(at p: DV2, palmChance: Double, scale: ClosedRange<Double>, r: inout DioramaRandom) {
            let z = terrain.height(p)
            let s = r.range(scale) * config.propExaggeration
            if r.chance(palmChance) {
                vegetation.instance(r.pick(props.palms), DioramaTransform(rotation: r.range(0...6.28), scale: DV3(s, s, s), translation: DV3(p, z)))
                treeShadows.append((p, 2.2 * s))
            } else {
                let model = r.pick(props.trees)
                vegetation.instance(model, DioramaTransform(rotation: r.range(0...6.28), scale: DV3(s, s, s), translation: DV3(p, z)))
                treeShadows.append((p, model.radius * 0.55 * s))
            }
        }
        func distanceToWater(_ p: DV2) -> Double { data.water.map { DioramaPolygon.distanceToRing($0.rings[0], p) }.min() ?? .infinity }

        // Surveyed trees exactly where they stand.
        for p in data.trees {
            var trng = DioramaRandom(seed: UInt64(bitPattern: Int64((p.x * 10).rounded())) &* 31 &+ UInt64(bitPattern: Int64((p.y * 10).rounded())), salt: 32)
            guard tryPlace(p, spacing: 2.2, radius: 0.7) else { continue }
            tree(at: p, palmChance: distanceToWater(p) < 45 ? 0.7 : 0.12, scale: 0.8...1.1, r: &trng)
        }
        // Coconut palms along the shore.
        for water in data.water {
            guard let outer = water.rings.first else { continue }
            let n = outer.count
            for i in 0..<n where !water.clipped[i] {
                let a = outer[i], b = outer[(i + 1) % n]
                let length = a.distance(to: b), dir = (b - a).normalized, inland = dir.right
                var d = rng.range(2...config.coastPalmSpacing)
                while d < length {
                    defer { d += config.coastPalmSpacing * rng.range(0.7...1.3) }
                    let p = a + dir * d + inland * rng.range(5...12)
                    guard tryPlace(p, spacing: 6) else { continue }
                    tree(at: p, palmChance: 1, scale: 0.85...1.25, r: &rng)
                }
            }
        }
        // Compound gardens.
        for compound in compounds {
            var crng = DioramaRandom(seed: compound.building.feature.id, salt: 33)
            let bounds = DioramaRect.bounding(compound.ring)
            let count = max(Int(DioramaPolygon.area(compound.ring) / 1000 * config.treesPer1000m2), 1)
            for _ in 0..<count {
                let p = DV2(crng.range(between: bounds.minX, and: bounds.maxX), crng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(compound.ring, p), DioramaPolygon.distanceToRing(compound.ring, p) > 1.4,
                      !compound.building.box.expanded(by: 2).contains(p), tryPlace(p, spacing: 5) else { continue }
                tree(at: p, palmChance: 0.2, scale: 0.7...0.95, r: &crng)
            }
            for _ in 0..<2 {
                let p = DV2(crng.range(between: bounds.minX, and: bounds.maxX), crng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(compound.ring, p), !compound.building.box.expanded(by: 0.6).contains(p), isFree(p, radius: 0.6) else { continue }
                vegetation.instance(crng.pick(props.bushes), DioramaTransform(rotation: crng.range(0...6.28), translation: DV3(p, terrain.height(p))))
            }
        }
        // Parks.
        for park in data.landuse where ["park", "common", "garden"].contains(park.kind) {
            guard let outer = park.rings.first else { continue }
            let bounds = DioramaRect.bounding(outer)
            let count = min(Int(DioramaPolygon.area(outer) / 1000 * config.parkTreesPer1000m2), 40)
            for _ in 0..<count {
                let p = DV2(rng.range(between: bounds.minX, and: bounds.maxX), rng.range(between: bounds.minY, and: bounds.maxY))
                guard DioramaPolygon.contains(polygon: park.rings, p), tryPlace(p, spacing: 6) else { continue }
                tree(at: p, palmChance: 0.15, scale: 0.8...1.15, r: &rng)
            }
        }
        // Avenue trees.
        for road in data.roads {
            let length = DioramaPolygon.length(road.line)
            let spacing = road.isPaved ? config.streetTreeSpacing : config.streetTreeSpacing * 2
            var d = rng.range(4...12)
            var side = rng.chance(0.5) ? 1.0 : -1.0
            while d < length {
                defer { d += spacing * rng.range(0.85...1.15); side = -side }
                guard let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let p = s.point + s.direction.right * side * (roads.corridorHalfWidth(road) + 1.6)
                guard tryPlace(p, spacing: 7) else { continue }
                tree(at: p, palmChance: 0.1, scale: 0.7...0.9, r: &rng)
            }
        }
        // Vehicles in the left-hand lane.
        for road in data.roads {
            let length = DioramaPolygon.length(road.line)
            let density = road.isMain ? config.vehiclesPerKm : config.vehiclesPerKm * 0.45
            var d = rng.range(4...30)
            while d < length - 3 {
                defer { d += 1000 / density * rng.range(0.6...1.6) }
                guard let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let dir = rng.chance(0.5) ? s.direction : -s.direction
                let p = s.point + dir.left * (road.width / 4)
                guard data.rect.expanded(by: -3).contains(p) else { continue }
                let model = rng.chance(0.4) ? props.bajaji : rng.pick(props.cars)
                propMesh.instance(model, DioramaTransform(rotation: dir.angle, translation: DV3(p, terrain.height(p))))
            }
        }
        // Street lamps every 30 m on paved streets: post, lit head, halo sprite and a point light.
        for road in data.roads where road.isPaved {
            let length = DioramaPolygon.length(road.line)
            guard length > 12 else { continue }
            var d = rng.range(6...min(config.lampSpacing, length / 2))
            var side = 1.0
            while d < length - 4 {
                defer { d += config.lampSpacing; side = -side }
                guard lights.count < config.maxLights, let s = DioramaPolygon.sample(road.line, at: d) else { break }
                let p = s.point + s.direction.right * side * (road.width / 2 + config.pavementWidth * 0.55)
                guard inner.contains(p), !roads.isOnCarriageway(p, margin: 0.25), !built.contains(where: { $0.box.expanded(by: 0.4).contains(p) }) else { continue }
                let z = terrain.height(p)
                let rotation = (s.direction.right * -side).angle
                propMesh.instance(props.lamp, DioramaTransform(rotation: rotation, translation: DV3(p, z)))
                propGlow.instance(props.lampGlow, DioramaTransform(rotation: rotation, translation: DV3(p, z)))
                let head = DV3(p + DV2(cos(rotation), sin(rotation)) * 0.7, z + DioramaPropLibrary.lampHeadHeight - 0.1)
                propGlow.append(props.lampHalo, DioramaTransform(translation: head))
                lights.append(DioramaLight(position: head, color: SIMD3<Float>(1.0, 0.80, 0.52), radius: config.lampLightRadius, intensity: 1.0))
            }
        }
        // A few dhows on the water, away from the shore.
        var dhows = 0
        for water in data.water where dhows < 6 {
            guard let outer = water.rings.first, outer.count >= 3 else { continue }
            let bounds = DioramaRect.bounding(outer)
            for _ in 0..<40 where dhows < 6 {
                let p = DV2(rng.range(between: bounds.minX, and: bounds.maxX), rng.range(between: bounds.minY, and: bounds.maxY))
                guard data.rect.expanded(by: -12).contains(p), DioramaPolygon.contains(polygon: water.rings, p),
                      DioramaPolygon.distanceToRing(outer, p) > 25, !placed.contains(where: { $0.distance(to: p) < 30 }) else { continue }
                placed.append(p)
                propMesh.instance(props.dhow, DioramaTransform(rotation: rng.range(0...6.28), translation: DV3(p, terrain.waterLevel)))
                dhows += 1
            }
        }
        // Kiosks beside the busiest junction-free stretches.
        var kiosks = 0
        for road in data.roads where road.isMain && kiosks < 12 {
            guard let s = DioramaPolygon.sample(road.line, at: DioramaPolygon.length(road.line) * 0.5) else { continue }
            let p = s.point + s.direction.right * (roads.corridorHalfWidth(road) + 2.4)
            guard tryPlace(p, spacing: 20, radius: 1.5) else { continue }
            propMesh.instance(props.kiosk, DioramaTransform(rotation: s.direction.angle, translation: DV3(p, terrain.height(p))))
            kiosks += 1
        }
    }
}
