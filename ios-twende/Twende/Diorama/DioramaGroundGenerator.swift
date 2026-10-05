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

    /// Smooth-shaded height-field over the tile. Cells whose centre is in the bay drop to the seabed so
    /// the water surface has something dark beneath it and the shore slopes into it.
    private func plate(into mesh: inout DioramaMesh) {
        let r = data.rect
        let cols = max(Int((r.width / plateStep).rounded(.up)), 2)
        let rows = max(Int((r.height / plateStep).rounded(.up)), 2)
        func point(_ i: Int, _ j: Int) -> DV2 {
            DV2(r.minX + r.width * Double(i) / Double(cols), r.minY + r.height * Double(j) / Double(rows))
        }
        func z(_ p: DV2) -> Double { isWater(p) ? DioramaTerrain.seabed : terrain.height(p) }

        var heights = [Double](repeating: 0, count: (cols + 1) * (rows + 1))
        for j in 0...rows { for i in 0...cols { heights[j * (cols + 1) + i] = z(point(i, j)) } }

        mesh.reserve((cols + 1) * (rows + 1))
        let uvGrass = DioramaAtlas.uv(.grass, dark: false)
        let uvSand = DioramaAtlas.uv(.earth, dark: false)
        let uvSeabed = DioramaAtlas.uv(.seabed, dark: false)
        let base = mesh.positions.count
        for j in 0...rows {
            for i in 0...cols {
                let p = point(i, j)
                let h = heights[j * (cols + 1) + i]
                let hl = heights[j * (cols + 1) + max(i - 1, 0)], hr = heights[j * (cols + 1) + min(i + 1, cols)]
                let hd = heights[max(j - 1, 0) * (cols + 1) + i], hu = heights[min(j + 1, rows) * (cols + 1) + i]
                let dx = r.width / Double(cols) * Double(min(i + 1, cols) - max(i - 1, 0))
                let dy = r.height / Double(rows) * Double(min(j + 1, rows) - max(j - 1, 0))
                let n = DV3(-(hr - hl) / max(dx, 1), -(hu - hd) / max(dy, 1), 1).normalized
                // Vertices next to the bay are sand so the slope into the water reads as beach.
                let nearWater = hl < 0 || hr < 0 || hd < 0 || hu < 0
                mesh.vertex(DV3(p, h), n, h < 0 ? uvSeabed : (nearWater ? uvSand : uvGrass))
            }
        }
        for j in 0..<rows {
            for i in 0..<cols {
                let a = UInt32(base + j * (cols + 1) + i), b = a + 1
                let c = UInt32(base + (j + 1) * (cols + 1) + i), d = c + 1
                mesh.tri(a, b, d)
                mesh.tri(a, d, c)
            }
        }
        // Skirt down the four tile edges so the plate reads as a solid slab from a low camera.
        let corners = [DV2(r.minX, r.minY), DV2(r.maxX, r.minY), DV2(r.maxX, r.maxY), DV2(r.minX, r.maxY)]
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            let dense = DioramaPolygon.densify([a, b], maxStep: plateStep)
            for s in 0..<(dense.count - 1) {
                let p = dense[s], q = dense[s + 1]
                let out = DV3((q - p).normalized.right, 0)
                mesh.quad(DV3(p, -2.5), DV3(q, -2.5), DV3(q, z(q)), DV3(p, z(p)), .soil, dark: true, normal: out)
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

    /// Pale sand along the shore: a strip inland of each real water edge.
    private func shoreline(into mesh: inout DioramaMesh) {
        for water in data.water {
            guard let outer = water.rings.first else { continue }
            let n = outer.count
            for i in 0..<n where !water.clipped[i] {
                let a = outer[i], b = outer[(i + 1) % n]
                guard a.distance(to: b) > 1, data.rect.expanded(by: 5).contains((a + b) * 0.5) else { continue }
                // Water rings are counter-clockwise, so land lies to the right of travel.
                let out = (b - a).normalized.right
                let strip = DioramaPolygon.clipPolygon([a - out * 0.5, b - out * 0.5, b + out * 6, a + out * 6], to: data.rect)
                guard strip.count >= 3 else { continue }
                draped(strip, lift: 0.04, .earth, into: &mesh)
            }
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
