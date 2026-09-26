import SceneKit
import simd

/// Limited continuous roof-edge details. Holes are excluded and long edges share one global budget.
enum BuildingRoofOrnaments {
    static func make(footprint: BuildingFootprint, eave: Double, grammar: BuildingDetailGrammar, isTerrace: Bool, budget: Int) -> SCNNode {
        let root = SCNNode()
        guard let ring = footprint.rings.first else { return root }
        var dentils = BuildingMesh(), balusters = BuildingMesh(), rail = BuildingMesh()
        var used = 0
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let length = simd_distance(a, b)
            guard length >= 3, used < budget else { continue }
            let tangent = (b - a) / length, normal = SIMD2(tangent.y, -tangent.x)
            let count = min(budget - used, min(12, max(2, Int(length / 0.8))))
            if grammar.hasDentils {
                for index in 0..<count {
                    let centre = a + tangent * (length * (Double(index) + 0.5) / Double(count))
                    let corners = [centre - tangent * 0.09, centre - tangent * 0.09 + normal * 0.16, centre + tangent * 0.09 + normal * 0.16, centre + tangent * 0.09]
                    for edge in corners.indices {
                        let p = corners[edge], q = corners[(edge + 1) % 4]
                        dentils.quad(SIMD3(p.x, p.y, eave - 0.40), SIMD3(q.x, q.y, eave - 0.40), SIMD3(q.x, q.y, eave - 0.22), SIMD3(p.x, p.y, eave - 0.22))
                    }
                    dentils.quad(SIMD3(corners[3].x, corners[3].y, eave - 0.40), SIMD3(corners[2].x, corners[2].y, eave - 0.40), SIMD3(corners[1].x, corners[1].y, eave - 0.40), SIMD3(corners[0].x, corners[0].y, eave - 0.40))
                }
                used += count
            } else if isTerrace && grammar.hasBalustrade {
                for index in 0..<count {
                    let centre = a + tangent * (0.3 + (length - 0.6) * Double(index) / Double(max(1, count - 1))) - normal * 0.12
                    balusters.revolve(centre: centre, profile: [SIMD2(0.075, eave + 0.25), SIMD2(0.10, eave + 0.33), SIMD2(0.065, eave + 0.52), SIMD2(0.045, eave + 0.78), SIMD2(0.08, eave + 0.87)], segments: 8)
                }
                let n = normal * 0.12, s = a + tangent * 0.20, t = b - tangent * 0.20
                let strip = [s - n * 2, t - n * 2, t, s]
                rail.perimeter(rings: [strip], bottom: eave + 0.84, top: eave + 0.98, projection: 0.04)
                rail.quad(SIMD3(strip[0].x, strip[0].y, eave + 0.98), SIMD3(strip[1].x, strip[1].y, eave + 0.98), SIMD3(strip[2].x, strip[2].y, eave + 0.98), SIMD3(strip[3].x, strip[3].y, eave + 0.98), normal: SIMD3(0, 0, 1))
                used += count
            }
        }
        let trim = grammar.identity.material("trim")
        for (name, mesh) in [("roofDentils", dentils), ("roofBalusters", balusters), ("roofHandrail", rail)] where !mesh.positions.isEmpty { root.addChildNode(mesh.node(name: name, material: trim)) }
        return root
    }
}
