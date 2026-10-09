import CoreGraphics
import Foundation

/// The diorama's floor: one continuous draped terrain skin over the whole tile whose colour comes
/// from the painted ground image. Grass, lawns, sand, drives and (from `DioramaRoadGenerator`) roads
/// are all paint, never stacked geometry. Hard-surfaced amenities with real height (courts, car
/// parks, forecourts, pools, decks) are laid on top by `DioramaAmenityGenerator`. Water is built
/// separately into the `.water` category so it can be toggled and shaded on its own.
nonisolated struct DioramaGroundGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain
    let painter: DioramaGroundPainter

    func generate(compounds: [DioramaCompound], into mesh: inout DioramaMesh, water waterMesh: inout DioramaMesh) {
        plate(into: &mesh)
        reef(into: &mesh)
        parks()
        compoundGround(compounds)
        earthPatches()
        water(into: &waterMesh)
    }

    /// Context tiles share the exact terrain skin but omit reef geometry and small surface detail.
    func generateContext(into mesh: inout DioramaMesh, water waterMesh: inout DioramaMesh) {
        plate(into: &mesh)
        parks()
        // Coarse and HD use the identical corridor/fillet unions and material ordering.
        let layout = DioramaStreetLayout(data: data, config: config)
        DioramaRoadGenerator(config: config, data: data, roads: roads, terrain: terrain,
            layout: layout, compounds: [], painter: painter).paintSurfaces()
        for area in data.water {
            guard let outer = area.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect)
            for piece in DioramaGroundCutouts(polygons: Array(area.rings.dropFirst())).subtract(from: ring) {
                waterMesh.polygon(piece, z: terrain.waterLevel, .sea, attribute: Float(config.shallowWaterDistance))
            }
        }
        paintWater()
    }

    /// Small exposed-earth patches in unoccupied inland ground; never repaint formal gardens or beach.
    private func earthPatches() {
        var rng = DioramaRandom(seed: 30, salt: 717)
        let cutouts = DioramaGroundCutouts(data: data, pavementWidth: config.pavementWidth,
            additionalMasks: data.water.compactMap { $0.rings.first } + data.landuse.flatMap(\.rings)
                + [data.hotelCourtyardOutline, data.hotelDiningOutline])
        for y in stride(from: data.rect.minY + 14, to: data.rect.maxY - 14, by: 27) {
            for x in stride(from: data.rect.minX + 14, to: data.rect.maxX - 14, by: 27) {
                guard rng.chance(0.38) else { continue }
                let centre = DV2(x + rng.range(-7...7), y + rng.range(-7...7))
                guard terrain.coast?.isWater(centre) != true,
                      (terrain.coast?.nearest(centre, within: 24)?.distance ?? 24) >= 20 else { continue }
                let radius = rng.range(3.5...7)
                let ring = (0..<18).map { i -> DV2 in
                    let angle = Double(i) * .pi / 9
                    let r = radius * (0.86 + 0.14 * sin(angle * 3 + centre.x))
                    return centre + DV2(cos(angle) * r, sin(angle) * r * 0.72)
                }
                let pieces = cutouts.subtract(from: ring)
                painter.earthPatch(pieces, outline: ring, centre: centre)
            }
        }
    }

    /// Paints the sea floor last so coastal paving and lawns stop exactly at the mapped water edge.
    func paintWater() {
        for area in data.water {
            painter.fill(area.rings.map { DioramaPolygon.clipPolygon($0, to: data.rect) }, .grass)
        }
    }

    // MARK: Plate

    /// One indexed heightfield, without polygon subtraction, coastal holes or overlapping bank skins.
    /// Shared normals and interpolated natural pigment join seabed → wet sand → dry sand → grass.
    private func plate(into mesh: inout DioramaMesh) {
        let columns = terrain.latticeColumns, rows = terrain.latticeRows
        let base = UInt32(mesh.positions.count)
        let uv = DioramaAtlas.uv(.painted, dark: false)
        let savedTint = mesh.tint
        func pigment(_ swatch: DioramaSwatch) -> SIMD3<Float> {
            let c = DioramaAtlas.color(swatch, dark: false, config: config)
            return SIMD3(c.x, c.y, c.z)
        }
        let dry = pigment(.earth), wet = pigment(.wetSand), bed = pigment(.seabed)
        mesh.reserve(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let p = terrain.latticePoint(column: column, row: row)
                let left = terrain.latticePoint(column: max(0, column - 1), row: row)
                let right = terrain.latticePoint(column: min(columns - 1, column + 1), row: row)
                let down = terrain.latticePoint(column: column, row: max(0, row - 1))
                let up = terrain.latticePoint(column: column, row: min(rows - 1, row + 1))
                let dx = (terrain.height(right) - terrain.height(left)) / max(right.x - left.x, 0.001)
                let dy = (terrain.height(up) - terrain.height(down)) / max(up.y - down.y, 0.001)
                let near = terrain.coast?.nearest(p, within: 30)
                let isSea = terrain.coast?.isWater(p) == true
                let distance = near?.distance ?? 30
                let coverage: Float
                if isSea {
                    coverage = 1
                    let t = Float(DioramaTerrain.smooth(distance / 24))
                    mesh.tint = wet * (1 - t) + bed * t
                } else {
                    let width = near?.kind == .beach ? config.beachWidth * 0.65 : config.revetmentWidth * 0.5
                    coverage = near?.kind.easesToWater == true ? Float(1 - DioramaTerrain.smooth(distance / width)) : 0
                    let t = Float(DioramaTerrain.smooth(distance / 3))
                    mesh.tint = wet * (1 - t) + dry * t
                }
                mesh.vertex(DV3(p, terrain.height(p)), DV3(-dx, -dy, 1).normalized, uv, attribute: coverage)
            }
        }
        mesh.tint = savedTint
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let a = base + UInt32(row * columns + column), b = a + 1
                let d = a + UInt32(columns), c = d + 1
                mesh.face(a, b, c)
                mesh.face(a, c, d)
            }
        }
        painter.fillAll(.grass)
    }

    /// Bounded, deterministic illustrative reef patches, not surveyed marine habitat. They sit on the
    /// generated seabed and only where the water is more than a metre deep.
    private func reef(into mesh: inout DioramaMesh) {
        var count = 0
        for segment in data.shorelines {
            for i in segment.points.indices where i % 6 == 0 && count < 72 {
                let p = segment.points[i] + segment.outward[i] * Double(8 + (i % 3) * 6)
                let margin = [DV2(-1.5, -1.5), DV2(1.5, -1.5), DV2(1.5, 1.5), DV2(-1.5, 1.5)]
                guard data.rect.contains(p), margin.allSatisfy({ isWater(p + $0) }),
                      !data.paths.contains(where: { path in path.kind == "pier" && zip(path.line, path.line.dropFirst()).contains { DioramaPolygon.distanceToSegment(p, $0.0, $0.1) < 5 } }) else { continue }
                let base = terrain.seabed(p)
                guard terrain.waterLevel - base > 1 else { continue }
                mesh.sphere(centre: DV3(p, base + 0.12), radii: DV3(1.1, 0.8, 0.2), .rockWarm)
                for branch in 0..<7 {
                    let angle = Double(branch) * 2.399
                    let q = p + DV2(cos(angle), sin(angle)) * (0.25 + Double(branch % 3) * 0.22)
                    let stem = DV3(q, base + 0.15)
                    let tip = DV3(q + DV2(cos(angle), sin(angle)) * 0.13, base + 0.45 + Double(branch % 3) * 0.12)
                    mesh.tube(from: stem, to: tip, r0: 0.09, r1: 0.055, sides: 10, .coralStone)
                    for side in [-1.0, 1.0] {
                        let fork = tip + DV3(DV2(cos(angle + side), sin(angle + side)) * 0.18, 0.12)
                        mesh.tube(from: tip - DV3(0, 0, 0.15), to: fork, r0: 0.05, r1: 0.025, sides: 8, .coralStone)
                        mesh.sphere(centre: fork, radii: DV3(0.04, 0.04, 0.04), .cream)
                    }
                }
                mesh.sphere(centre: DV3(p + DV2(1.0, 0.4), base + 0.2), radii: DV3(0.45, 0.4, 0.26), .algaeStone)
                count += 1
            }
        }
    }

    // MARK: Green space

    /// Parks, commons and gardens as brighter lawns. Roads painted later cross them where mapped.
    private func parks() {
        for park in data.landuse where ["park", "common", "garden", "cemetery"].contains(park.kind) {
            guard let outer = park.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect)
            guard ring.count >= 3, DioramaPolygon.area(ring) > 40 else { continue }
            painter.fill(ring, .lawn)
        }
    }

    private func compoundGround(_ compounds: [DioramaCompound]) {
        for compound in compounds {
            let plot = DioramaPolygon.offset(compound.ring, by: -0.35) ?? compound.ring
            painter.fill(plot, .lawn)
            if let gate = compound.gate {
                let entrance = compound.building.entrance + compound.building.entranceOut * 0.4
                painter.stroke([gate.point, entrance], width: config.gateWidth - 0.3, .paving, cap: .butt)
                if let road = roads.nearest(to: gate.point, within: 25) {
                    let out = (gate.point - road.point).normalized
                    let kerb = road.point + out * roads.corridorHalfWidth(road.road)
                    painter.stroke([kerb, gate.point], width: config.gateWidth, .paving, cap: .butt)
                }
            }
        }
    }

    /// Only classified profile footprints reserve coastal ground; never draw a pale perimeter ribbon.
    static func beachPieces(data: DioramaTileData) -> [[DV2]] {
        data.shorelineLandMasks
    }

    // MARK: Water

    /// Water surface as a grid of 4 m cells clipped to the bay, subdivided to 1 m within 6 m of the
    /// mapped coast. Coarse cells bordering fine ones take the fine edge vertices and are fanned from
    /// their centre, so the mesh is watertight (no T-junctions) and vertex displacement stays safe.
    /// Each vertex carries its distance to the mapped shoreline for the shader's shallows and foam.
    private func water(into mesh: inout DioramaMesh) {
        let step = 4.0, fineDivisions = 4
        let coast = terrain.coast
        let reach = max(config.shallowWaterDistance, 8) + 1
        func shoreDistance(_ p: DV2) -> Double { coast?.nearest(p, within: reach)?.distance ?? reach }
        let uv = DioramaAtlas.uv(.sea, dark: false)
        for water in data.water {
            guard let outer = water.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect.expanded(by: 0.5))
            guard ring.count >= 3 else { continue }
            let holes = DioramaGroundCutouts(polygons: Array(water.rings.dropFirst()))
            let bounds = DioramaRect.bounding(ring)
            let x0 = floor(bounds.minX / step) * step, y0 = floor(bounds.minY / step) * step
            let columns = Int(ceil((bounds.maxX - x0) / step)), rows = Int(ceil((bounds.maxY - y0) / step))
            guard columns > 0, rows > 0 else { continue }
            // Lattice corners inside the bay, so clipped cells can be found without re-testing corners.
            var insideCorner = [Bool](repeating: false, count: (columns + 1) * (rows + 1))
            for r in 0...rows {
                for c in 0...columns {
                    insideCorner[r * (columns + 1) + c] = DioramaPolygon.contains(ring, DV2(x0 + Double(c) * step, y0 + Double(r) * step))
                }
            }
            func fullyInside(_ column: Int, _ row: Int) -> Bool {
                insideCorner[row * (columns + 1) + column] && insideCorner[row * (columns + 1) + column + 1]
                    && insideCorner[(row + 1) * (columns + 1) + column] && insideCorner[(row + 1) * (columns + 1) + column + 1]
            }
            // Fine cells: near the coast, or clipped by the bay outline or the tile edge, so every
            // clipped piece borders either another fine cell or a stitched coarse one.
            var fine = [Bool](repeating: false, count: columns * rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    let centre = DV2(x0 + (Double(column) + 0.5) * step, y0 + (Double(row) + 0.5) * step)
                    fine[row * columns + column] = shoreDistance(centre) < 6 + step * 0.71 || !fullyInside(column, row) || water.rings.count > 1
                }
            }
            func isFine(_ column: Int, _ row: Int) -> Bool {
                guard column >= 0, row >= 0, column < columns, row < rows else { return false }
                return fine[row * columns + column]
            }
            func emit(_ piece: [DV2], fan: Bool) {
                guard piece.count >= 3 else { return }
                mesh.reserve(piece.count + 1)
                let base = mesh.positions.count
                for p in piece { mesh.vertex(DV3(p, terrain.waterLevel), .up, uv, attribute: Float(shoreDistance(p))) }
                if fan {
                    let centre = DioramaPolygon.centroid(piece)
                    let c = mesh.vertex(DV3(centre, terrain.waterLevel), .up, uv, attribute: Float(shoreDistance(centre)))
                    for i in piece.indices { mesh.tri(UInt32(base + i), UInt32(base + (i + 1) % piece.count), c) }
                } else {
                    for (a, b, c) in DioramaPolygon.triangulate(piece) {
                        mesh.tri(UInt32(base + a), UInt32(base + b), UInt32(base + c))
                    }
                }
            }
            for row in 0..<rows {
                for column in 0..<columns {
                    let cell = DioramaRect(minX: x0 + Double(column) * step, minY: y0 + Double(row) * step,
                                           maxX: x0 + Double(column + 1) * step, maxY: y0 + Double(row + 1) * step)
                    if isFine(column, row) {
                        let fineStep = step / Double(fineDivisions)
                        for r in 0..<fineDivisions {
                            for c in 0..<fineDivisions {
                                let fine = DioramaRect(minX: cell.minX + Double(c) * fineStep, minY: cell.minY + Double(r) * fineStep,
                                                       maxX: cell.minX + Double(c + 1) * fineStep, maxY: cell.minY + Double(r + 1) * fineStep)
                                let clipped = DioramaPolygon.counterClockwise(DioramaPolygon.clipPolygon(ring, to: fine))
                                for piece in (water.rings.count > 1 ? holes.subtract(from: clipped) : [clipped]) { emit(piece, fan: false) }
                            }
                        }
                        continue
                    }
                    // Coarse cell: insert the neighbouring fine cells' edge vertices so edges match exactly.
                    var outline: [DV2] = []
                    let corners = [DV2(cell.minX, cell.minY), DV2(cell.maxX, cell.minY), DV2(cell.maxX, cell.maxY), DV2(cell.minX, cell.maxY)]
                    let neighbours = [(column, row - 1), (column + 1, row), (column, row + 1), (column - 1, row)]
                    for side in 0..<4 {
                        let a = corners[side], b = corners[(side + 1) % 4]
                        outline.append(a)
                        if isFine(neighbours[side].0, neighbours[side].1) {
                            for k in 1..<fineDivisions { outline.append(a + (b - a) * (Double(k) / Double(fineDivisions))) }
                        }
                    }
                    emit(outline, fan: true)
                }
            }
        }
    }

    // MARK: Helpers

    private func isWater(_ p: DV2) -> Bool {
        data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) }
    }
}
