import Foundation

/// Reference-led Ottoman massing fitted inside the mapped masjid, not a surveyed reconstruction.
nonisolated struct DioramaMosqueGenerator {
    let config: DioramaConfig
    let terrain: DioramaTerrain

    static func buildingIDs(in data: DioramaTileData) -> Set<UInt64> {
        var ids = Set(data.buildings.filter { $0.type.lowercased() == "mosque" }.map(\.id))
        for poi in data.pois where poi.kind == "mosque" {
            // A point belongs only to its enclosing footprint, never an arbitrary nearby home.
            if let host = data.buildings.filter({ DioramaPolygon.contains($0.ring, poi.point) }).min(by: { $0.area < $1.area }) {
                ids.insert(host.id)
            }
        }
        return ids
    }

    func build(_ f: DioramaBuildingFeature, into mesh: inout DioramaMesh) -> DioramaBuilt {
        let floor = terrain.buildingHeight(f)
        terrain.foundation(f.ring, top: floor, swatch: .concrete, into: &mesh)
        let old = mesh.baseZ
        mesh.baseZ = floor
        defer { mesh.baseZ = old }
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        let h = max(f.height ?? min(max(sqrt(f.area) * 0.32, 4.5), 10), 3)
        let (ring, flags) = DioramaPolygon.rounded(f.ring, flags: f.clipped, radius: 1, segments: 8)
        let kit = DioramaBuildingKit(config: config)
        mesh.extrude(ring, z0: -0.15, z1: h, .whitewash, skip: flags)
        kit.cornice(ring, flags: flags, z: h, into: &mesh)
        if kit.roofEdge(ring, flags: flags, z: h, bevel: 0.45, deck: .roofConcrete, into: &mesh) == nil {
            mesh.polygon(ring, z: h, .roofConcrete)
        }
        func clearance(_ p: DV2) -> Double {
            guard DioramaPolygon.contains(ring, p) else { return 0 }
            return ring.indices.map { DioramaPolygon.distanceToSegment(p, ring[$0], ring[($0 + 1) % ring.count]) }.min() ?? 0
        }
        let centre = clearance(box.centre) > clearance(f.centroid) ? box.centre : f.centroid
        let radius = min(clearance(centre) * 0.72, 10)
        if radius > 1 {
            dome(centre, z: h + 0.45, radius: radius, into: &mesh)
            if f.area > 280 {
                for side in [-1.0, 1.0] {
                    let p = centre + box.axis * (radius * 1.25 * side)
                    let r = min(radius * 0.52, clearance(p) * 0.8)
                    if r > 1 { dome(p, z: h + 0.45, radius: r, into: &mesh) }
                }
            }
        }
        let towerRadius = min(max(sqrt(f.area) * 0.028, 0.5), 1.25)
        let towerCount = f.area > 900 ? 4 : (f.area > 220 ? 2 : 1)
        var placed = 0
        for corner in box.corners {
            let p = corner + (centre - corner).normalized * (towerRadius * 2.8)
            guard clearance(p) > towerRadius * 1.6, placed < towerCount else { continue }
            minaret(p, z: 0, height: h + max(9, radius * 2.4), radius: towerRadius, into: &mesh)
            placed += 1
        }
        // Quiet repeated arched windows, in the same warm white / smoky-glass palette.
        for i in ring.indices where !flags[i] {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let length = a.distance(to: b)
            guard length > 3 else { continue }
            let dir = (b - a).normalized, out = dir.right
            let count = min(8, max(1, Int(length / 3.2)))
            for k in 0..<count {
                let p = a + dir * (length * (Double(k) + 0.5) / Double(count)) + out * 0.035
                arch(p, across: dir, out: out, bottom: 0.85, height: min(h - 1.5, 3.6), width: min(1.45, length / Double(count) * 0.48), into: &mesh)
            }
        }
        let entrance = (box.corners[0] + box.corners[1]) * 0.5
        return DioramaBuilt(feature: f, kind: .commercial, floors: 1, height: h + 0.45 + radius * 1.05,
                            box: box, flatRoof: true, wallColor: .whitewash, entrance: entrance,
                            entranceOut: (entrance - box.centre).normalized)
    }

    private func dome(_ p: DV2, z: Double, radius r: Double, into mesh: inout DioramaMesh) {
        mesh.cylinder(centre: p, z0: z, z1: z + r * 0.2, r0: r, r1: r, sides: 32, .whitewash)
        // A true hemispherical crown; no full sphere protruding beneath the roof.
        var profile: [(Double, Double)] = []
        for i in 0...12 {
            let a = Double(i) / 12 * .pi / 2
            profile.append((max(0.001, cos(a) * r), z + r * 0.2 + sin(a) * r * 0.8))
        }
        turned(p, profile: profile, color: .roofSlate, into: &mesh)
        mesh.tube(from: DV3(p, z + r), to: DV3(p, z + r + 0.7), r0: 0.09, r1: 0.025, sides: 8, .sunflower)
    }

    private func minaret(_ p: DV2, z: Double, height h: Double, radius r: Double, into mesh: inout DioramaMesh) {
        let profile: [(Double, Double)] = [
            (r * 1.35, z), (r * 1.35, z + 0.3), (r * 1.15, z + 0.5), (r, z + 1.2),
            (r * 0.8, z + h * 0.5), (r * 0.95, z + h * 0.53), (r * 1.45, z + h * 0.55),
            (r * 1.5, z + h * 0.57), (r * 1.5, z + h * 0.60), (r * 0.78, z + h * 0.61),
            (r * 0.66, z + h * 0.81), (r, z + h * 0.83), (r * 1.15, z + h * 0.85),
            (r * 1.15, z + h * 0.88), (r * 0.62, z + h * 0.89), (r * 0.6, z + h)
        ]
        turned(p, profile: profile, color: .whitewash, into: &mesh)
        turned(p, profile: [(r * 0.72, z + h), (r * 0.7, z + h + 0.15), (0.025, z + h + r * 4.8)], color: .roofRust, into: &mesh)
    }

    /// Shared rings and slope-aware normals soften the balcony shoulders without noisy ornament.
    private func turned(_ p: DV2, profile: [(Double, Double)], color: DioramaSwatch, into mesh: inout DioramaMesh) {
        let sides = 32
        mesh.reserve(profile.count * sides)
        let uv = DioramaAtlas.uv(color, dark: false)
        var rings: [[UInt32]] = []
        for i in profile.indices {
            let before = profile[max(0, i - 1)], after = profile[min(profile.count - 1, i + 1)]
            var ring: [UInt32] = []
            for k in 0..<sides {
                let a = Double(k) / Double(sides) * 2 * .pi
                let d = DV2(cos(a), sin(a))
                let n = DV3(d * (after.1 - before.1), before.0 - after.0).normalized
                ring.append(mesh.vertex(DV3(p + d * profile[i].0, profile[i].1), n, uv))
            }
            rings.append(ring)
        }
        for i in 1..<rings.count { for k in 0..<sides {
            let next = (k + 1) % sides
            mesh.tri(rings[i - 1][k], rings[i - 1][next], rings[i][next])
            mesh.tri(rings[i - 1][k], rings[i][next], rings[i][k])
        } }
    }

    private func arch(_ p: DV2, across: DV2, out: DV2, bottom: Double, height: Double, width: Double, into mesh: inout DioramaMesh) {
        guard height > 0.5 else { return }
        let half = width / 2, spring = bottom + height - half
        var outline = [DV3(p - across * half, bottom), DV3(p + across * half, bottom)]
        for k in 0...12 {
            let a = Double(k) / 12 * .pi
            outline.append(DV3(p + across * (cos(a) * half), spring + sin(a) * half))
        }
        let centre = DV3(p, bottom + height * 0.45)
        for i in outline.indices {
            mesh.triangle(centre, outline[i], outline[(i + 1) % outline.count], .glass, normal: DV3(out, 0))
            mesh.tube(from: outline[i], to: outline[(i + 1) % outline.count], r0: 0.10, r1: 0.10, sides: 6, .cream)
        }
    }
}
