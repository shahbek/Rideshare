import SceneKit
import simd

/// Complete roofing systems; every variant starts with a watertight deck matching the actual footprint.
enum BuildingRoof {
    enum Style: String, CaseIterable {
        case terrace, gable, hip, dome, vault, mansard, sawtooth
    }

    /// Use an explicit roof tag when available. A footprint or colour is not evidence of a palace or dome.
    static func style(roofShape: String?) -> Style {
        switch roofShape?.lowercased() {
        case "gabled", "gable": return .gable
        case "hipped", "hip": return .hip
        case "dome", "domed": return .dome
        case "barrel", "vault": return .vault
        case "mansard": return .mansard
        case "sawtooth": return .sawtooth
        default: return .terrace
        }
    }

    static func make(footprint: BuildingFootprint, eave: Double, style requestedStyle: Style, trim: SCNMaterial, softensEdges: Bool = false, variant: Int = 0) -> SCNNode {
        let root = SCNNode()
        let rectangle = footprint.rectangle
        let domeSite = requestedStyle == .dome ? footprint.domeSite : nil
        let needsRectangle = [Style.gable, .hip, .vault, .mansard, .sawtooth].contains(requestedStyle)
        let style: Style = needsRectangle && rectangle == nil || requestedStyle == .dome && domeSite == nil ? .terrace : requestedStyle
        let outline = softensEdges ? BuildingContour.softened(footprint) : footprint
        root.name = "roof.\(style.rawValue)"
        root.addChildNode(outline.deck(at: eave, thickness: 0.18, material: style == .terrace || style == .dome ? BuildingSurfaces.membrane : trim))
        var roof = BuildingMesh()
        if let corners = rectangle, style == .mansard {
            root.addChildNode(BuildingRoofForms.mansard(corners: corners, eave: eave, trim: trim, variant: variant))
        } else if let corners = rectangle, style == .sawtooth {
            root.addChildNode(BuildingRoofForms.sawtooth(corners: corners, eave: eave, trim: trim, variant: variant))
        } else if let corners = rectangle, style == .vault {
            let a = corners[0], b = corners[1], d = corners[3]
            let across = simd_normalize(d - a)
            let width = simd_distance(a, d)
            let rise = min(4.5, width * 0.18), edge = eave + 0.18
            var ends = BuildingMesh()
            func p(_ origin: SIMD2<Double>, _ t: Double) -> SIMD3<Double> {
                let xy = origin + across * width * t
                return SIMD3(xy.x, xy.y, edge + rise * sin(t * .pi))
            }
            func n(_ t: Double) -> SIMD3<Double> {
                let slope = rise * .pi * cos(t * .pi) / width
                return simd_normalize(SIMD3(-across.x * slope, -across.y * slope, 1))
            }
            for segment in 0..<40 {
                let t0 = Double(segment) / 40, t1 = Double(segment + 1) / 40
                roof.smoothQuad(p(a, t0), p(b, t0), p(b, t1), p(a, t1), normals: [n(t0), n(t0), n(t1), n(t1)])
                ends.quad(SIMD3(p(a, t0).x, p(a, t0).y, edge), p(a, t0), p(a, t1), SIMD3(p(a, t1).x, p(a, t1).y, edge))
                ends.quad(SIMD3(p(b, t1).x, p(b, t1).y, edge), p(b, t1), p(b, t0), SIMD3(p(b, t0).x, p(b, t0).y, edge))
            }
            root.addChildNode(roof.node(name: "continuousVault", material: BuildingSurfaces.slate))
            root.addChildNode(ends.node(name: "vaultEnds", material: trim))
        } else if let corners = rectangle, style == .gable || style == .hip {
            let a = corners[0], b = corners[1], c = corners[2], d = corners[3]
            let width = simd_distance(a, d), length = simd_distance(a, b)
            let rise = min(6.5, width * (style == .gable ? 0.30 : 0.26))
            let edge = eave + 0.18
            func p(_ v: SIMD2<Double>, _ z: Double) -> SIMD3<Double> { SIMD3(v.x, v.y, z) }
            let along = simd_normalize(b - a)
            let inset = style == .hip ? min(width * 0.45, length * 0.30) : 0
            let left = (a + d) / 2 + along * inset, right = (b + c) / 2 - along * inset
            let l = p(left, edge + rise), r = p(right, edge + rise)
            roof.quad(p(a, edge), p(b, edge), r, l)
            roof.quad(p(c, edge), p(d, edge), l, r)
            root.addChildNode(BuildingRoofDetails.tiles(a: p(a, edge), b: p(b, edge), c: r, d: l))
            root.addChildNode(BuildingRoofDetails.tiles(a: p(c, edge), b: p(d, edge), c: l, d: r))
            if style == .gable {
                var ends = BuildingMesh()
                ends.triangle(p(d, edge), p(a, edge), l)
                ends.triangle(p(b, edge), p(c, edge), r)
                root.addChildNode(ends.node(name: "gableEnds", material: trim))
            } else {
                roof.triangle(p(d, edge), p(a, edge), l)
                roof.triangle(p(b, edge), p(c, edge), r)
            }
            root.addChildNode(roof.node(name: "continuousRoof", material: style == .gable ? BuildingSurfaces.slate : BuildingSurfaces.terracotta))
        } else {
            // One closed, mitred perimeter mesh, with genuine courtyard openings, not independent coping blocks.
            var parapet = BuildingMesh()
            for ring in outline.rings {
                let inner = inset(ring, by: 0.16)
                let ns = BuildingContour.outwardNormals(ring)
                for i in ring.indices {
                    let j = (i + 1) % ring.count
                    func p(_ v: SIMD2<Double>, _ z: Double) -> SIMD3<Double> { SIMD3(v.x, v.y, z) }
                    let bottom = eave + 0.16, top = eave + 0.32
                    let n0 = SIMD3(ns[i].x, ns[i].y, 0.0), n1 = SIMD3(ns[j].x, ns[j].y, 0.0)
                    parapet.smoothQuad(p(ring[i], bottom), p(ring[j], bottom), p(ring[j], top), p(ring[i], top), normals: [n0, n1, n1, n0])
                    parapet.quad(p(inner[j], bottom), p(inner[i], bottom), p(inner[i], top), p(inner[j], top))
                    parapet.quad(p(ring[i], top), p(ring[j], top), p(inner[j], top), p(inner[i], top))
                }
            }
            var coping = BuildingMesh()
            coping.perimeter(rings: outline.rings, bottom: eave + 0.25, top: eave + 0.41, projection: 0.09)
            root.addChildNode(parapet.node(name: "continuousParapet", material: trim))
            root.addChildNode(coping.node(name: "roundedRoofCoping", material: trim))
            if let site = domeSite, style == .dome {
                let radius = site.radius
                let springLine = eave + 0.18 + min(0.65, radius * 0.12)
                var profile: [SIMD2<Double>] = [SIMD2(radius, eave + 0.17), SIMD2(radius, springLine)]
                for step in 1...32 {
                    let angle = Double(step) * .pi / 64
                    profile.append(SIMD2(radius * cos(angle), springLine + radius * 0.78 * sin(angle)))
                }
                roof.revolve(centre: site.centre, profile: profile, segments: 80)
                root.addChildNode(roof.node(name: "continuousDome", material: BuildingSurfaces.zinc))
                root.addChildNode(BuildingRoofDetails.dome(centre: site.centre, radius: radius, spring: springLine, trim: trim))
            }
        }
        return root
    }

    private static func inset(_ ring: [SIMD2<Double>], by amount: Double) -> [SIMD2<Double>] {
        ring.indices.map { i in
            let previous = ring[(i + ring.count - 1) % ring.count], point = ring[i], next = ring[(i + 1) % ring.count]
            let a = simd_normalize(point - previous), b = simd_normalize(next - point)
            let n1 = SIMD2(-a.y, a.x), n2 = SIMD2(-b.y, b.x)
            let sum = n1 + n2
            guard simd_length(sum) > 0.001 else { return point + n1 * amount }
            let normal = simd_normalize(sum)
            return point + normal * (amount / max(0.45, simd_dot(normal, n1)))
        }
    }
}
