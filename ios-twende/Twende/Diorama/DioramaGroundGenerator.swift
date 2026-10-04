import Foundation

/// The diorama's floor. A continuous terrain plate covers the whole tile (sandy earth, with green plots
/// where parks, pitches and gardens are), so nothing of the grey basemap shows through. Compounds get a
/// grass plot and a paved courtyard from gate to house, and a pale sand strip runs along the shore.
/// Water is built separately into the `.water` category so it can be toggled and shaded on its own.
nonisolated struct DioramaGroundGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let roads: DioramaRoadIndex
    let terrain: DioramaTerrain

    /// Terrain plate resolution (metres between grid vertices).
    private let plateStep: Double = 12

    func generate(compounds: [DioramaCompound], into mesh: inout DioramaMesh, water waterMesh: inout DioramaMesh) {
        plate(into: &mesh)
        parks(into: &mesh)
        compoundGround(compounds, into: &mesh)
        shoreline(into: &mesh)
        water(into: &waterMesh)
    }

    // MARK: Terrain plate

    /// Smooth-shaded height-field over the tile. Cells whose centre is in the bay drop to the seabed so
    /// the water surface has something dark beneath it.
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
        let uvEarth = DioramaAtlas.uv(.earth, dark: false)
        let uvSeabed = DioramaAtlas.uv(.seabed, dark: false)
        let base = mesh.positions.count
        for j in 0...rows {
            for i in 0...cols {
                let p = point(i, j)
                let h = heights[j * (cols + 1) + i]
                // Central-difference normal from neighbouring heights for soft shading of the slopes.
                let hl = heights[j * (cols + 1) + max(i - 1, 0)], hr = heights[j * (cols + 1) + min(i + 1, cols)]
                let hd = heights[max(j - 1, 0) * (cols + 1) + i], hu = heights[min(j + 1, rows) * (cols + 1) + i]
                let dx = r.width / Double(cols) * Double(min(i + 1, cols) - max(i - 1, 0))
                let dy = r.height / Double(rows) * Double(min(j + 1, rows) - max(j - 1, 0))
                let n = DV3(-(hr - hl) / max(dx, 1), -(hu - hd) / max(dy, 1), 1).normalized
                mesh.vertex(DV3(p, h), n, h < 0 ? uvSeabed : uvEarth)
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
                mesh.quad(DV3(p, -2.5), DV3(q, -2.5), DV3(q, z(q)), DV3(p, z(p)), .earth, dark: true, normal: out)
            }
        }
    }

    // MARK: Green space

    /// Parks, pitches and gardens as slightly raised grass plots with a pale edging.
    private func parks(into mesh: inout DioramaMesh) {
        for park in data.landuse {
            guard let outer = park.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect.expanded(by: -0.5))
            guard ring.count >= 3, DioramaPolygon.area(ring) > 40 else { continue }
            draped(ring, lift: 0.22, .grass, into: &mesh)
            let n = ring.count
            for i in 0..<n {
                let a = ring[i], b = ring[(i + 1) % n]
                let out = DV3((b - a).normalized.right, 0)
                mesh.quad(DV3(a, terrain.height(a)), DV3(b, terrain.height(b)), DV3(b, terrain.height(b) + 0.22), DV3(a, terrain.height(a) + 0.22), .parkEdge, normal: out)
            }
        }
    }

    private func compoundGround(_ compounds: [DioramaCompound], into mesh: inout DioramaMesh) {
        for compound in compounds {
            var rng = DioramaRandom(seed: compound.building.feature.id, salt: 11)
            let plot = DioramaPolygon.offset(compound.ring, by: -0.35) ?? compound.ring
            draped(plot, lift: 0.06, .grass, into: &mesh)
            if let gate = compound.gate {
                let house = compound.building.box
                let toHouse = house.centre - gate.point
                let length = max(toHouse.length - min(house.halfLength, house.halfWidth) * 0.5, 2)
                let dir = toHouse.normalized
                let across = dir.left
                let width = rng.range(2.6...3.4)
                let a = gate.point - across * width, b = gate.point + across * width
                let c = gate.point + dir * length + across * width, d = gate.point + dir * length - across * width
                draped([a, b, c, d], lift: 0.09, .courtyard, into: &mesh)
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
                let strip = DioramaPolygon.clipPolygon([a - out * 0.5, b - out * 0.5, b + out * 9, a + out * 9], to: data.rect)
                guard strip.count >= 3 else { continue }
                draped(strip, lift: 0.04, .courtyard, into: &mesh)
            }
        }
    }

    // MARK: Water

    /// Flat glossy sheet at the water surface; the shader adds the sky reflection and shoreline foam.
    private func water(into mesh: inout DioramaMesh) {
        for water in data.water {
            guard let outer = water.rings.first else { continue }
            let ring = DioramaPolygon.clipPolygon(outer, to: data.rect.expanded(by: 0.5))
            guard ring.count >= 3 else { continue }
            mesh.polygon(ring, z: DioramaTerrain.waterSurface, .sea)
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
        if max(bounds.width, bounds.height) < plateStep * 1.5 {
            polygonOnTerrain(ccw, lift: lift, s, into: &mesh)
            return
        }
        // Grid cells clipped to the plot keep triangles small enough to hug the slopes.
        var y = bounds.minY
        while y < bounds.maxY {
            var x = bounds.minX
            while x < bounds.maxX {
                let cell = DioramaRect(minX: x, minY: y, maxX: min(x + plateStep, bounds.maxX), maxY: min(y + plateStep, bounds.maxY))
                let piece = clipPolygon(ccw, to: cell)
                if piece.count >= 3 { polygonOnTerrain(piece, lift: lift, s, into: &mesh) }
                x += plateStep
            }
            y += plateStep
        }
    }

    private func clipPolygon(_ ring: [DV2], to cell: DioramaRect) -> [DV2] {
        // Convex plots clip exactly; concave ones may fragment, which is harmless for flat fills.
        DioramaPolygon.clipPolygon(ring, to: cell)
    }

    private func polygonOnTerrain(_ ring: [DV2], lift: Double, _ s: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard ring.count >= 3 else { return }
        mesh.reserve(ring.count)
        let uv = DioramaAtlas.uv(s, dark: false)
        let base = mesh.positions.count
        for p in ring { mesh.vertex(DV3(p, terrain.height(p) + lift), .up, uv) }
        for (a, b, c) in DioramaPolygon.triangulate(ring) {
            mesh.tri(UInt32(base + a), UInt32(base + b), UInt32(base + c))
        }
    }
}
