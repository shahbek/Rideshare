import Foundation
import simd

/// An address-specific hierarchy of occupied building wings. This replaces the one-envelope,
/// one-style skyline path without changing ordinary houses, bespoke landmarks or tile ownership.
nonisolated struct DarComposedTower {
    private struct Volume {
        let ring: [DV2]
        let roofFootprint: [DV2]
        let from: Int
        let to: Int
        let elevation: DarSkylineComposition.Elevation
        let sides: DarSkylineComposition.Elevation
        let bay: Double
        let roof: String
    }

    let site: DarSkylineSite
    let design: DarSkylineComposition

    func build(_ footprint: [DV2], into mesh: inout DioramaMesh, glow: inout DioramaMesh,
               lights: inout [DioramaLight]) -> Bool {
        guard let volumes = resolve(footprint), !volumes.isEmpty else {
            print("[DarSkyline] \(site.id) composition invalid or unsupported; retaining original saved shell")
            return false
        }
        let source = DioramaPolygon.counterClockwise(footprint)
        let ground = min(4.4, site.height / Double(site.levels) * 1.25)
        let storey = (site.height - ground) / Double(site.levels - 1)
        func floor(_ f: Int) -> Double { f == 0 ? 0.32 : ground + Double(f - 1) * storey }
        let front: DV2
        if let bearing = design.frontBearing {
            let angle = bearing * .pi / 180
            front = DV2(sin(angle), cos(angle))
        } else {
            let edge = source.indices.max { a, b in
                source[a].distance(to: source[(a + 1) % source.count]) < source[b].distance(to: source[(b + 1) % source.count])
            } ?? 0
            front = (source[(edge + 1) % source.count] - source[edge]).normalized.right
        }
        let facade = DarComposedFacade(wall: DarTowerGenerator.rgb(design.wall ?? site.wall),
            accent: DarTowerGenerator.rgb(design.accent ?? site.accent),
            glass: DarTowerGenerator.rgb(design.glass ?? site.glass), sourceID: site.osm)
        let oldTint = mesh.tint, oldHeight = mesh.recordsHeight, oldGlowTint = glow.tint
        mesh.recordsHeight = true
        glow.tint = SIMD3(repeating: 1)
        defer { mesh.tint = oldTint; mesh.recordsHeight = oldHeight; glow.tint = oldGlowTint }
        facade.pigment(facade.wall, as: .whitewash, into: &mesh)
        // Full-width bearing face: a bevel under a continuing wall would leave a hairline air gap.
        DarArchitecturalKit.solid(source, bottom: -0.3, top: 0.32, shoulder: 0, color: .whitewash, into: &mesh)

        var bayScale = 1.0
        func facadeCost(_ scale: Double) -> Int {
            volumes.reduce(0) { $0 + facade.triangleAllowance($1.ring, from: $1.from, to: $1.to,
                front: front, elevation: $1.elevation, sides: $1.sides, bayWidth: $1.bay * scale) }
        }
        // Discrete per-edge bays and rounded short edges count too. Leave 14k for decks/roofs/guards;
        // DarSkyline still validates the actual whole mesh against its unchanged 40k ceiling.
        while facadeCost(bayScale) > 26_000 && bayScale < 4 { bayScale *= 1.2 }
        guard facadeCost(bayScale) <= 26_000 else { return false }
        for volume in volumes {
            facade.build(volume.ring, from: volume.from, to: volume.to, floor: floor,
                front: front, elevation: volume.elevation, sides: volume.sides,
                bayWidth: volume.bay * bayScale, into: &mesh, glow: &glow)
            let roofHeight = floor(volume.to)
            facade.pigment(DarTowerGenerator.rgb("#C9C2B6"), as: .roofConcrete, into: &mesh)
            let above = volumes.filter { $0.from == volume.to && $0.to > volume.to }.map(\.ring)
            // Only exposed caps roll inward. Continuing walls need the full bearing face.
            DarArchitecturalKit.solid(volume.ring, bottom: roofHeight - 0.24, top: roofHeight,
                shoulder: above.isEmpty ? 0.06 : 0, color: .roofConcrete, into: &mesh)
            if volume.roof == "hip", above.isEmpty {
                mesh.tint = SIMD3(repeating: 1)
                // Preserve source roof colour and max +5m envelope. No invented roof on cropped tiers.
                let roofBuilt = DioramaRoofBuilder.hip(volume.ring, flags: Array(repeating: false, count: volume.ring.count),
                    z: roofHeight, pitch: 22 * .pi / 180, overhang: 0, maxRise: 5,
                    color: site.roof == "teal" ? .roofTeal : .roofTerracotta, fascia: .trimWhite,
                    into: &mesh, footprint: volume.roofFootprint)
                if !roofBuilt {
                    print("[DarSkyline] \(site.id) irregular hip not admitted; closed flat roof retained")
                }
            } else if volume.roof == "cornice" {
                facade.pigment(facade.wall, as: .trimWhite, into: &mesh)
                if let outer = DioramaPolygon.offset(volume.ring, by: 0.14),
                   DarArchitecturePlan.fits(outer, inside: source, clearance: -0.4) {
                    DarArchitecturalKit.ribbon(outer, bottom: roofHeight - 0.62, top: roofHeight + 0.22,
                        depth: 0.32, color: .trimWhite, into: &mesh)
                } else {
                    DarArchitecturalKit.ribbon(volume.ring, bottom: roofHeight, top: roofHeight + 0.22,
                        depth: 0.24, color: .trimWhite, into: &mesh)
                }
            } else if volume.from > 0 && (volume.to < site.levels || volume.roof == "parapet") {
                terraceEdge(volume.ring, height: roofHeight, occupied: above, facade: facade, into: &mesh)
            }
        }
        let edge = source.indices.max { a, b in
            let ea = source[(a + 1) % source.count] - source[a]
            let eb = source[(b + 1) % source.count] - source[b]
            return ea.length * max(0, ea.normalized.right.dot(front)) < eb.length * max(0, eb.normalized.right.dot(front))
        } ?? 0
        let entry = (source[edge] + source[(edge + 1) % source.count]) * 0.5
        lights.append(.init(position: DV3(entry - front * 0.08, mesh.baseZ + 2.8),
            color: SIMD3(1, 0.82, 0.58), radius: 6.5, intensity: 0.5))
        return true
    }

    /// Resolve every part before emitting any triangles: a bad upper wing cannot leave half a model
    /// that then steals ownership of the saved building underneath it.
    private func resolve(_ footprint: [DV2]) -> [Volume]? {
        let source = DioramaPolygon.counterClockwise(footprint)
        guard source.count >= 3, DioramaPolygon.isSimple(source), hasCompleteCap(source),
              site.levels > 2, design.podium >= 1, design.podium < site.levels, !design.parts.isEmpty else { return nil }
        var box = DioramaPolygon.minimumAreaRectangle(source)
        // Stable geographic sign: source ring ordering must not mirror the authored composition.
        if box.axis.x < -0.0001 || (abs(box.axis.x) <= 0.0001 && box.axis.y < 0) { box.axis = -box.axis }
        let local = source.map { p in DV2((p - box.centre).dot(box.axis), (p - box.centre).dot(box.across)) }
        var result: [Volume] = [.init(ring: source, roofFootprint: source, from: 0, to: design.podium,
            elevation: design.podiumStyle ?? .horizontal, sides: design.podiumStyle ?? .horizontal,
            bay: 5.8, roof: "flat")]
        for part in design.parts {
            guard part.zone.count == 4, part.zone.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  part.zone[0] < part.zone[2], part.zone[1] < part.zone[3] else { return nil }
            let from = part.from.map { $0 <= 0 ? site.levels + $0 : $0 } ?? design.podium
            let to = part.top <= 0 ? site.levels + part.top : part.top
            guard from >= design.podium, to > from, to <= site.levels else { return nil }
            let crop = DioramaRect(minX: (part.zone[0] * 2 - 1) * box.halfLength,
                minY: (part.zone[1] * 2 - 1) * box.halfWidth,
                maxX: (part.zone[2] * 2 - 1) * box.halfLength,
                maxY: (part.zone[3] * 2 - 1) * box.halfWidth)
            let clipped = Self.exactClip(local, to: crop)
            let raw = DioramaPolygon.counterClockwise(clipped.map { box.centre + box.axis * $0.x + box.across * $0.y })
            guard raw.count >= 3, DioramaPolygon.area(raw) > 2, DioramaPolygon.isSimple(raw),
                  DarArchitecturePlan.fits(raw, inside: source, clearance: -0.04), hasCompleteCap(raw) else { return nil }
            let radius = min(part.radius ?? 0.55, DioramaPolygon.minimumAreaRectangle(raw).halfWidth * 0.10)
            let curved = DioramaPolygon.rounded(raw, flags: Array(repeating: false, count: raw.count),
                radius: max(0.08, radius), segments: 3).points
            let ring = DioramaPolygon.isSimple(curved) && hasCompleteCap(curved)
                && DarArchitecturePlan.fits(curved, inside: raw, clearance: -0.02) ? curved : raw
            let supports = result.filter { $0.to == from }
            // No cantilevered tower bodies or disconnected decorative crown stacks.
            guard supports.contains(where: { DarArchitecturePlan.fits(ring, inside: $0.ring, clearance: -0.04) }) else { return nil }
            let roof = part.roof ?? (site.crown == "hip" && to == site.levels ? "hip" : "flat")
            result.append(.init(ring: ring, roofFootprint: raw, from: from, to: to, elevation: part.elevation,
                sides: part.sides ?? (part.elevation == .gallery ? .paired : part.elevation),
                bay: max(2.4, part.bay ?? 4.5), roof: roof))
        }
        guard result.contains(where: { $0.to == site.levels }) else { return nil }
        // Parts at the same height must be spatially disjoint. A tiny boundary tolerance is not
        // permission to overlap two whole tower shells.
        for i in result.indices {
            for j in result.indices where j > i && result[i].from < result[j].to && result[j].from < result[i].to {
                let a = result[i].ring, b = result[j].ring
                let overlap = DioramaGroundCutouts(polygons: [b]).subtract(from: a).reduce(0.0) { $0 + DioramaPolygon.area($1) }
                if DioramaPolygon.area(a) - overlap > max(0.06, DioramaPolygon.area(a) * 0.0001) { return nil }
            }
        }
        return result
    }

    /// Preserve small mapped notches at crop boundaries. Terrain's 8cm cleanup can cut across one
    /// and fail the stricter architectural containment gate. Disconnected crops are still rejected.
    private static func exactClip(_ ring: [DV2], to rect: DioramaRect) -> [DV2] {
        let mask = [DV2(rect.minX, rect.minY), DV2(rect.maxX, rect.minY),
                    DV2(rect.maxX, rect.maxY), DV2(rect.minX, rect.maxY)]
        var result = ring
        for i in mask.indices {
            result = DioramaGroundCutouts.halfPlane(result, a: mask[i], b: mask[(i + 1) % mask.count], inside: true)
        }
        var clean: [DV2] = []
        for p in result where clean.last.map({ $0.distance(to: p) > 0.000001 }) ?? true { clean.append(p) }
        if clean.count > 1, let first = clean.first, let last = clean.last, first.distance(to: last) < 0.000001 { clean.removeLast() }
        return DioramaPolygon.counterClockwise(clean)
    }

    private func hasCompleteCap(_ ring: [DV2]) -> Bool {
        let area = DioramaPolygon.area(ring)
        let triangles = DioramaPolygon.triangulate(ring)
        let filled = triangles.reduce(0.0) { $0 + abs((ring[$1.1] - ring[$1.0]).cross(ring[$1.2] - ring[$1.0])) * 0.5 }
        return !triangles.isEmpty && abs(area - filled) <= max(0.001, area * 0.000001)
    }

    /// A low solid terrace guard at the outside of a lower occupied wing, never a tank enclosure.
    private func terraceEdge(_ ring: [DV2], height: Double, occupied: [[DV2]],
                             facade: DarComposedFacade, into mesh: inout DioramaMesh) {
        facade.pigment(facade.wall, as: .trimWhite, into: &mesh)
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], out = (b - a).normalized.right
            let edge = DioramaPolygon.counterClockwise([a, b, b - out * 0.2, a - out * 0.2])
            guard DarArchitecturePlan.fits(edge, inside: ring, clearance: -0.02) else { continue }
            for piece in DioramaGroundCutouts(polygons: occupied).subtract(from: edge) {
                mesh.extrude(piece, z0: height, z1: height + 0.72, .trimWhite, top: .trimWhite)
                mesh.polygon(piece, z: height, .trimWhite, facingUp: false)
            }
        }
    }
}
