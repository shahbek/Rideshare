import Foundation

/// The diorama's floor. A continuous quiet grass surface covers the tile; parks and gardens are
/// near-flush lawns cut around occupied footprints, compounds get a lawn
/// and a paved drive from gate to house, and a strip of pale sand runs along the shore. Hard-surfaced
/// amenities (courts, car parks, forecourts, pools, decks) are laid on top by `DioramaAmenityGenerator`.
/// Water is built separately into the `.water` category so it can be toggled and shaded on its own.
nonisolated struct DioramaGroundGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain

    let cutouts: DioramaGroundCutouts

    /// Plate resolution (metres between grid vertices). Fine enough for a soft shoreline slope.
    private let plateStep: Double = 8

    /// Lift of park lawns above the plate.
    static let parkLift: Double = 0.025

    func generate(compounds: [DioramaCompound], into mesh: inout DioramaMesh, water waterMesh: inout DioramaMesh) {
        plate(into: &mesh)
        parks(into: &mesh)
        compoundGround(compounds, into: &mesh)
        shoreline(into: &mesh)
        water(into: &waterMesh)
    }

    // MARK: Plate

    /// Land is clipped to the SAME boundary as the sea, never classified on an 8 m vertex grid.
    /// This removes the square coastal wedges and also leaves real openings below pool water.
    private func plate(into mesh: inout DioramaMesh) {
        let r = data.rect
        let corners = [DV2(r.minX, r.minY), DV2(r.maxX, r.minY), DV2(r.maxX, r.maxY), DV2(r.minX, r.maxY)]
        let waterRings = (data.water + data.landuse.filter { $0.kind == "pool" }).compactMap { $0.rings.first }
            + [DioramaHotelGrounds.stairOutline(data: data)]
        let land = DioramaGroundCutouts(polygons: waterRings)
        mesh.polygon(corners, z: DioramaTerrain.seabed, .seabed)
        let step = config.usesElevation ? plateStep : max(r.width, r.height)
        for y in stride(from: r.minY, to: r.maxY, by: step) {
            for x in stride(from: r.minX, to: r.maxX, by: step) {
                let cell = [DV2(x, y), DV2(min(x + step, r.maxX), y),
                            DV2(min(x + step, r.maxX), min(y + step, r.maxY)), DV2(x, min(y + step, r.maxY))]
                for piece in land.subtract(from: cell) {
                    let base = mesh.positions.count
                    let uv = DioramaAtlas.uv(.grass, dark: false)
                    for p in piece { mesh.vertex(DV3(p, terrain.height(p)), .up, uv) }
                    for t in DioramaPolygon.triangulate(piece) {
                        mesh.tri(UInt32(base + t.0), UInt32(base + t.1), UInt32(base + t.2))
                    }
                }
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

    /// One disjoint inland band, with the sea and occupied hardscape subtracted before drawing.
    private func shoreline(into mesh: inout DioramaMesh) {
        var patches: [[DV2]] = []
        for water in data.water {
            guard let ring = water.rings.first else { continue }
            let inland = DioramaCoastline.offset(ring, by: 6)
            for i in ring.indices where !water.clipped[i] {
                let j = (i + 1) % ring.count
                let quad = DioramaPolygon.counterClockwise([ring[i], ring[j], inland[j], inland[i]])
                // A tight concave offset may cross itself. Local triangles remain well-defined;
                // union/subtraction below resolves overlaps instead of emitting an invalid ring.
                for triangle in [[quad[0], quad[1], quad[2]], [quad[0], quad[2], quad[3]]] {
                    let bounded = DioramaPolygon.clipPolygon(triangle, to: data.rect)
                    if DioramaPolygon.area(bounded) > 0.0001 { patches.append(bounded) }
                }
            }
        }
        let waterMask = DioramaGroundCutouts(polygons: data.water.compactMap { $0.rings.first })
        for piece in DioramaStreetSurface(patches).pieces() {
            for dry in waterMask.subtract(from: piece) { draped(dry, lift: 0.04, .earth, into: &mesh) }
        }
    }

    // MARK: Water

    /// Water surface as a grid of cells clipped to the bay, each vertex carrying its distance to the
    /// real shoreline (tile-edge cuts don't count). The shader uses that distance to run waves towards
    /// the beach, lighten the shallows and break foam on the sand.
    private func water(into mesh: inout DioramaMesh) {
        let step = 10.0
        for water in data.water {
            guard let outer = water.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect.expanded(by: 0.5))
            guard ring.count >= 3 else { continue }
            var shore: [(DV2, DV2)] = []
            let n = outer.count
            for i in 0..<n where !water.clipped[i] { shore.append((outer[i], outer[(i + 1) % n])) }
            func shoreDistance(_ p: DV2) -> Float {
                var best = 200.0
                for (a, b) in shore { best = min(best, DioramaPolygon.distanceToSegment(p, a, b)) }
                return Float(best)
            }
            let uv = DioramaAtlas.uv(.sea, dark: false)
            let bounds = DioramaRect.bounding(ring)
            var y = bounds.minY
            while y < bounds.maxY {
                var x = bounds.minX
                while x < bounds.maxX {
                    let cell = DioramaRect(minX: x, minY: y, maxX: min(x + step, bounds.maxX), maxY: min(y + step, bounds.maxY))
                    let piece = DioramaPolygon.counterClockwise(DioramaPolygon.clipPolygon(ring, to: cell))
                    if piece.count >= 3 {
                        mesh.reserve(piece.count)
                        let base = mesh.positions.count
                        for p in piece { mesh.vertex(DV3(p, DioramaTerrain.waterSurface), .up, uv, attribute: shoreDistance(p)) }
                        for (a, b, c) in DioramaPolygon.triangulate(piece) {
                            mesh.tri(UInt32(base + a), UInt32(base + b), UInt32(base + c))
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
        let ccw = DioramaPolygon.counterClockwise(ring)
        guard ccw.count >= 3 else { return }
        let bounds = DioramaRect.bounding(ccw)
        if max(bounds.width, bounds.height) < plateStep * 1.5 || !config.usesElevation {
            polygonOnTerrain(ccw, lift: lift, s, into: &mesh)
            return
        }
        var y = bounds.minY
        while y < bounds.maxY {
            var x = bounds.minX
            while x < bounds.maxX {
                let cell = DioramaRect(minX: x, minY: y, maxX: min(x + plateStep, bounds.maxX), maxY: min(y + plateStep, bounds.maxY))
                let piece = DioramaPolygon.clipPolygon(ccw, to: cell)
                if piece.count >= 3 { polygonOnTerrain(piece, lift: lift, s, into: &mesh) }
                x += plateStep
            }
            y += plateStep
        }
    }

    private func polygonOnTerrain(_ ring: [DV2], lift: Double, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard ring.count >= 3 else { return }
        let uv = DioramaAtlas.uv(s, dark: false)
        for piece in cutouts.subtract(from: ring) {
            mesh.reserve(piece.count)
            let base = mesh.positions.count
            for p in piece { mesh.vertex(DV3(p, terrain.height(p) + lift), .up, uv) }
            for (a, b, c) in DioramaPolygon.triangulate(piece) {
                mesh.tri(UInt32(base + a), UInt32(base + b), UInt32(base + c))
            }
        }
    }
}
