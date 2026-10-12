import Foundation

/// Closed architectural assemblies, not stacks of independently capped boxes. All dimensions are
/// metres; caller controls materials/tints and the shared tile's ground datum.
nonisolated enum DarArchitecturalKit {
    static func roundedPlan(_ rect: DioramaOrientedRect, radius: Double) -> [DV2] {
        DioramaPolygon.rounded(DioramaPolygon.counterClockwise(rect.corners), flags: Array(repeating: false, count: 4),
            radius: min(radius, min(rect.halfLength, rect.halfWidth) * 0.65), segments: 4).points
    }

    static func solid(_ ring: [DV2], bottom: Double, top: Double, shoulder: Double,
                      color: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard ring.count >= 3, top > bottom else { return }
        let bevel = min(shoulder, (top - bottom) * 0.35)
        mesh.extrude(ring, z0: bottom, z1: top - bevel, color)
        mesh.polygon(ring, z: bottom, color, facingUp: false)
        // Use the caller's material for the entire smooth shoulder, including non-white trim.
        if bevel > 0.005, let inner = DarArchitecturePlan.inset(ring, distance: bevel, minimumArea: 0.001) {
            let uv = DioramaAtlas.uv(color, dark: false)
            for i in ring.indices {
                let j = (i + 1) % ring.count
                func normal(_ k: Int) -> DV2 {
                    let before = (ring[k] - ring[(k + ring.count - 1) % ring.count]).normalized.right
                    let after = (ring[(k + 1) % ring.count] - ring[k]).normalized.right
                    return (before + after).normalized
                }
                for step in 0..<4 {
                    func vertex(_ k: Int, _ s: Int) -> UInt32 {
                        let angle = Double(s) * Double.pi / 8
                        let p = ring[k] * cos(angle) + inner[k] * (1 - cos(angle))
                        return mesh.vertex(DV3(p, top - bevel + bevel * sin(angle)),
                            DV3(normal(k) * cos(angle), sin(angle)).normalized, uv)
                    }
                    let a = vertex(i, step), b = vertex(j, step), c = vertex(j, step + 1), d = vertex(i, step + 1)
                    let out = DV3((ring[j] - ring[i]).normalized.right, 1)
                    mesh.face(a, b, c, outward: out); mesh.face(a, c, d, outward: out)
                }
            }
            mesh.polygon(inner, z: top, color)
        } else {
            mesh.extrude(ring, z0: top - bevel, z1: top, color, top: color)
        }
    }

    /// Rolled slab/parapet edge with one continuous profile around the actual footprint.
    /// The whole section lies inward, so balconies and roofs never enlarge a mapped parcel.
    static func ribbon(_ ring: [DV2], bottom: Double, top: Double, depth: Double,
                       color: DioramaSwatch, into mesh: inout DioramaMesh) {
        guard top > bottom, depth > 0 else { return }
        let options = [depth, depth * 0.5, min(depth, 0.08)]
        guard let resolved = options.compactMap({ distance -> (ring: [DV2], depth: Double)? in
            guard let inner = DarArchitecturePlan.inset(ring, distance: distance, minimumArea: 0.001) else { return nil }
            return (inner, distance)
        }).first else {
            // A tightly notched plan still gets a supported, closed slab rather than a missing floor.
            mesh.extrude(ring, z0: bottom, z1: top, color, top: color)
            mesh.polygon(ring, z: bottom, color, facingUp: false)
            return
        }
        let inner = resolved.ring
        let depth = resolved.depth
        let radius = min((top - bottom) * 0.28, depth * 0.35)
        let profile: [(Double, Double)] = [
            (depth, bottom), (radius, bottom), (radius * 0.293, bottom + radius * 0.293),
            (0, bottom + radius), (0, top - radius), (radius * 0.293, top - radius * 0.293),
            (radius, top), (depth, top)
        ]
        let uv = DioramaAtlas.uv(color, dark: false)
        func planNormal(_ k: Int) -> DV2 {
            let a = (ring[k] - ring[(k + ring.count - 1) % ring.count]).normalized.right
            let b = (ring[(k + 1) % ring.count] - ring[k]).normalized.right
            return (a + b).normalized
        }
        for s in profile.indices {
            let t = (s + 1) % profile.count
            let a = profile[s], b = profile[t]
            let sectionNormal = DV2(b.1 - a.1, b.0 - a.0).normalized
            for i in ring.indices {
                let j = (i + 1) % ring.count
                func vertex(_ k: Int, _ section: (Double, Double)) -> UInt32 {
                    let f = section.0 / depth
                    return mesh.vertex(DV3(ring[k] * (1 - f) + inner[k] * f, section.1),
                        DV3(planNormal(k) * sectionNormal.x, sectionNormal.y), uv)
                }
                let v0 = vertex(i, a), v1 = vertex(j, a), v2 = vertex(j, b), v3 = vertex(i, b)
                let out = DV3((ring[j] - ring[i]).normalized.right * sectionNormal.x, sectionNormal.y)
                mesh.face(v0, v1, v2, outward: out); mesh.face(v0, v2, v3, outward: out)
            }
        }
    }

    static func pier(at p: DV2, axis: DV2, width: Double, depth: Double, bottom: Double, top: Double,
                     color: DioramaSwatch, into mesh: inout DioramaMesh) {
        if let registry = mesh.primitiveRegistry {
            let prototype = registry.prototype(kind: "rounded structural piers", parameters: [width, depth, top - bottom],
                flags: [color.rawValue], doubleSided: false) { model in
                pier(at: .zero, axis: DV2(1, 0), width: width, depth: depth, bottom: 0, top: top - bottom, color: color, into: &model)
            }
            mesh.architecturalInstance(prototype, .init(rotation: atan2(axis.y, axis.x), translation: DV3(p, bottom)))
            return
        }
        let plan = roundedPlan(.init(centre: p, axis: axis, halfLength: width / 2, halfWidth: depth / 2), radius: min(width, depth) * 0.23)
        solid(plan, bottom: bottom, top: top, shoulder: min(0.12, width * 0.15), color: color, into: &mesh)
    }

    /// Ribbed rotationally moulded tank: base foot, rolled body ribs, domed shoulder, neck/lid,
    /// and a connected outlet riser. One continuous lathed skin with smooth profile normals.
    static func tank(at p: DV2, bottom: Double, color: DioramaSwatch, into mesh: inout DioramaMesh) {
        if let registry = mesh.primitiveRegistry {
            let prototype = registry.prototype(kind: "ribbed service tanks", parameters: [], flags: [color.rawValue], doubleSided: false) { model in
                tank(at: .zero, bottom: 0, color: color, into: &model)
            }
            mesh.architecturalInstance(prototype, .init(translation: DV3(p, bottom)))
            return
        }
        let profile: [(Double, Double)] = [
            (0.52, 0), (0.61, 0.07), (0.65, 0.15), (0.65, 0.25), (0.61, 0.29),
            (0.61, 0.45), (0.65, 0.49), (0.65, 0.56), (0.61, 0.60),
            (0.61, 0.78), (0.65, 0.82), (0.65, 0.89), (0.61, 0.93),
            (0.61, 1.11), (0.65, 1.15), (0.64, 1.24), (0.58, 1.34),
            (0.46, 1.44), (0.29, 1.50), (0.20, 1.50), (0.20, 1.60), (0.23, 1.62)
        ]
        let sides = 16, uv = DioramaAtlas.uv(color, dark: false)
        let start = UInt32(mesh.positions.count)
        for (i, section) in profile.enumerated() {
            let before = profile[max(0, i - 1)], after = profile[min(profile.count - 1, i + 1)]
            let n = DV2(after.1 - before.1, before.0 - after.0).normalized
            for k in 0..<sides {
                let angle = Double(k) * 2 * Double.pi / Double(sides)
                let d = DV2(cos(angle), sin(angle))
                mesh.vertex(DV3(p + d * section.0, bottom + section.1), DV3(d * n.x, n.y), uv)
            }
        }
        for i in 0..<(profile.count - 1) {
            for k in 0..<sides {
                let j = (k + 1) % sides
                let a = start + UInt32(i * sides + k), b = start + UInt32(i * sides + j)
                let c = start + UInt32((i + 1) * sides + j), d = start + UInt32((i + 1) * sides + k)
                mesh.tri(a, b, c); mesh.tri(a, c, d)
            }
        }
        let ring = (0..<sides).map { k in p + DV2(cos(Double(k) * 2 * .pi / Double(sides)), sin(Double(k) * 2 * .pi / Double(sides))) * 0.23 }
        mesh.polygon(ring, z: bottom + 1.62, color)
        let base = ring.map { p + ($0 - p) * (0.52 / 0.23) }
        mesh.polygon(base, z: bottom, color, facingUp: false)
        mesh.tube(from: DV3(p + DV2(0.53, 0), bottom + 0.18), to: DV3(p + DV2(0.77, 0), bottom + 0.18), r0: 0.065, r1: 0.065, sides: 6, .mastGrey)
        mesh.cylinder(centre: p + DV2(0.77, 0), z0: bottom - 0.02, z1: bottom + 0.2, r0: 0.065, r1: 0.065, sides: 6, .mastGrey)
    }

    /// A wall-mounted condenser with a radiused casing, fan grille, service panel and two brackets.
    static func condenser(at p: DV2, axis: DV2, out: DV2, bottom: Double, into mesh: inout DioramaMesh) {
        let ring = roundedPlan(.init(centre: p + out * 0.2, axis: axis, halfLength: 0.52, halfWidth: 0.24), radius: 0.1)
        solid(ring, bottom: bottom, top: bottom + 0.62, shoulder: 0.07, color: .trimWhite, into: &mesh)
        let fan = DV3(p - axis * 0.15 + out * 0.445, bottom + 0.33)
        mesh.verticalDisc(centre: fan, radius: 0.22, sides: 16, facing: out, .metalCharcoal)
        for k in -2...2 {
            let z = Double(k) * 0.066
            let half = sqrt(max(0, 0.21 * 0.21 - z * z))
            mesh.tube(from: fan + DV3(axis * -half + out * 0.012, z), to: fan + DV3(axis * half + out * 0.012, z),
                r0: 0.012, r1: 0.012, sides: 4, .mastGrey)
        }
        for u in [-0.36, 0.36] {
            mesh.tube(from: DV3(p + axis * u - out * 0.08, bottom - 0.14), to: DV3(p + axis * u + out * 0.35, bottom - 0.04),
                r0: 0.045, r1: 0.045, sides: 6, .mastGrey)
        }
        mesh.facadeBox(a: p + axis * 0.27, dir: axis, out: out, u: 0, width: 0.2,
            z0: bottom + 0.12, z1: bottom + 0.5, depth: 0.448, .mastGrey, sides: false)
    }
}
