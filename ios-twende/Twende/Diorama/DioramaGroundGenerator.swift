import Foundation

/// The diorama's floor. A continuous quiet grass surface covers the tile; parks and gardens are
/// near-flush lawns cut around occupied footprints, compounds get a lawn
/// and a paved drive from gate to house. Hard-surfaced
/// amenities (courts, car parks, forecourts, pools, decks) are laid on top by `DioramaAmenityGenerator`.
/// Water is built separately into the `.water` category so it can be toggled and shaded on its own.
nonisolated struct DioramaGroundGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain

    let cutouts: DioramaGroundCutouts

    /// Lift of park lawns above the plate.
    static let parkLift: Double = DioramaSurfaceLevel.lawn.rawValue

    func generate(compounds: [DioramaCompound], into mesh: inout DioramaMesh, water waterMesh: inout DioramaMesh) {
        plate(into: &mesh)
        parks(into: &mesh)
        compoundGround(compounds, into: &mesh)
        water(into: &waterMesh)
    }

    // MARK: Plate

    /// Continuous native-elevation backing under every finish and structure, including pools.
    /// Ownership cutouts apply only to the upper finishes, never to this terrain skin.
    private func plate(into mesh: inout DioramaMesh) {
        let r = data.rect
        let corners = [DV2(r.minX, r.minY), DV2(r.maxX, r.minY), DV2(r.maxX, r.maxY), DV2(r.minX, r.maxY)]
        // Colour ocean backing as seabed without deleting any terrain triangles.
        let ocean = DioramaGroundCutouts(polygons: data.water.compactMap { $0.rings.first })
        terrain.drape(corners, lift: 0, swatch: .seabed, into: &mesh)
        for piece in ocean.subtract(from: corners) {
            terrain.drape(piece, lift: 0.002, swatch: .grass, into: &mesh)
        }
        // Ocean polygon holes are land, not holes in the continuous backing.
        for area in data.water {
            for ring in area.rings.dropFirst() {
                terrain.drape(DioramaPolygon.clipPolygon(ring, to: r), lift: 0.002, swatch: .grass, into: &mesh)
            }
        }
    }

    // MARK: Green space

    /// Parks, commons and gardens as slightly raised bright lawns with a pale edging.
    private func parks(into mesh: inout DioramaMesh) {
        for park in data.landuse where ["park", "common", "garden"].contains(park.kind) {
            guard let outer = park.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect.expanded(by: -0.5))
            guard ring.count >= 3, DioramaPolygon.area(ring) > 40 else { continue }
            let lift = Self.parkLift
            draped(ring, lift: lift, .lawn, into: &mesh)
            // No raised perimeter slab: a mapped park boundary can cross a street or a building.
        }
    }

    private func compoundGround(_ compounds: [DioramaCompound], into mesh: inout DioramaMesh) {
        for compound in compounds {
            let plot = DioramaPolygon.offset(compound.ring, by: -0.35) ?? compound.ring
            draped(plot, lift: 0.02, .lawn, into: &mesh)
            if let gate = compound.gate {
                let entrance = compound.building.entrance + compound.building.entranceOut * 0.4
                let dir = (entrance - gate.point).normalized
                let across = dir.left * (config.gateWidth / 2 - 0.15)
                draped([gate.point - across, gate.point + across, entrance + across, entrance - across], lift: 0.09, .paving, into: &mesh)
                if let road = roads.nearest(to: gate.point, within: 25) {
                    let out = (gate.point - road.point).normalized
                    let kerb = road.point + out * roads.corridorHalfWidth(road.road)
                    let side = road.direction * (config.gateWidth / 2)
                    draped([kerb - side, kerb + side, gate.point + side, gate.point - side], lift: 0.09, .paving, into: &mesh)
                }
            }
        }
    }

    /// Only classified profile footprints reserve coastal ground; never draw a pale perimeter ribbon.
    static func beachPieces(data: DioramaTileData) -> [[DV2]] {
        data.shorelineLandMasks
    }

    // MARK: Water

    /// Water surface as a grid of cells clipped to the bay, each vertex carrying its distance to the
    /// real shoreline (tile-edge cuts don't count). The shader uses that distance to run waves towards
    /// the beach, lighten the shallows and break foam on the sand.
    private func water(into mesh: inout DioramaMesh) {
        let step = 4.0
        for water in data.water {
            guard let outer = water.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect.expanded(by: 0.5))
            guard ring.count >= 3 else { continue }
            let shore = data.shorelines.flatMap { segment -> [(DV2, DV2)] in
                let contact = segment.points.indices.map { i -> DV2 in
                    let p = segment.points[i]
                    let offset: Double
                    switch segment.kind {
                    case .beach: offset = 0
                    case .natural, .revetment: offset = config.revetmentWidth * 0.42
                    case .seawall, .deck:
                        let toe = max(0, terrain.height(p) + 0.11 - terrain.waterLevel + config.seawallSubmergedDepth) * config.seawallBatter
                        offset = toe + (segment.hasRevetment ? config.revetmentWidth * 0.21 : 0)
                    }
                    return p + segment.outward[i] * offset
                }
                return Array(zip(contact, contact.dropFirst()))
            }
            var shoreIndex = DioramaGrid(cell: 24)
            for i in shore.indices { shoreIndex.insert(i, rect: DioramaRect.bounding([shore[i].0, shore[i].1])) }
            func shoreDistance(_ p: DV2) -> Float {
                let reach = max(config.shallowWaterDistance, 8) + 1
                var best = reach
                for i in shoreIndex.query(DioramaRect.bounding([p]).expanded(by: reach)) {
                    best = min(best, DioramaPolygon.distanceToSegment(p, shore[i].0, shore[i].1))
                }
                return Float(best)
            }
            let uv = DioramaAtlas.uv(.sea, dark: false)
            let holes = DioramaGroundCutouts(polygons: Array(water.rings.dropFirst()))
            let bounds = DioramaRect.bounding(ring)
            var y = bounds.minY
            while y < bounds.maxY {
                var x = bounds.minX
                while x < bounds.maxX {
                    let cell = DioramaRect(minX: x, minY: y, maxX: min(x + step, bounds.maxX), maxY: min(y + step, bounds.maxY))
                    let subdivisions = shoreDistance(cell.centre) < 6 ? 4 : 1
                    let fineStep = step / Double(subdivisions)
                    for row in 0..<subdivisions {
                        for column in 0..<subdivisions {
                            let fine = DioramaRect(minX: x + Double(column) * fineStep, minY: y + Double(row) * fineStep,
                                maxX: min(x + Double(column + 1) * fineStep, bounds.maxX),
                                maxY: min(y + Double(row + 1) * fineStep, bounds.maxY))
                            let clipped = DioramaPolygon.counterClockwise(DioramaPolygon.clipPolygon(ring, to: fine))
                            for piece in (water.rings.count > 1 ? holes.subtract(from: clipped) : [clipped]) where piece.count >= 3 {
                                mesh.reserve(piece.count)
                                let base = mesh.positions.count
                                for p in piece { mesh.vertex(DV3(p, terrain.waterLevel), .up, uv, attribute: shoreDistance(p)) }
                                for (a, b, c) in DioramaPolygon.triangulate(piece) {
                                    mesh.tri(UInt32(base + a), UInt32(base + b), UInt32(base + c))
                                }
                            }
                        }
                    }
                    x += step
                }
                y += step
            }
        }
    }

    // MARK: Helpers

    private func isWater(_ p: DV2) -> Bool {
        data.water.contains { DioramaPolygon.contains(polygon: $0.rings, p) }
    }

    /// Flat-coloured polygon whose vertices follow the terrain, subdivided so large plots bend with it.
    private func draped(_ ring: [DV2], lift: Double, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        for piece in cutouts.subtract(from: ring) {
            terrain.drape(piece, lift: lift, swatch: s, into: &mesh)
        }
    }

}
