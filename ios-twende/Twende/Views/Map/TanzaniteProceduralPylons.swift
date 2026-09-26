import SceneKit
import simd

/// Continuous chamfered-box lofts reproduce the photograph's heavy portal legs and broad side blades.
/// Local X follows the road, Y spans it and Z is up. No imported model or lazy SCN primitive is used.
enum TanzaniteProceduralPylons {
    static func make(alignment: TanzaniteBridgeAlignment, station: Double, isCentral: Bool) -> SCNNode {
        let root = SCNNode()
        root.name = isCentral ? "centralProceduralPylon" : "sideProceduralPylon"
        let profile = TanzanitePylonProfile(deckElevation: alignment.deckElevation(at: station), isCentral: isCentral)
        let origin = alignment.point(at: station, elevation: 0)
        let forward = alignment.tangent(at: station)
        let across = simd_cross(SIMD3<Double>(0, 0, 1), forward)
        let concrete = BuildingSurfaces.make("surface.bridgeConcrete", color: "#E4E8E9", roughness: 0.7)
        for side in [-1.0, 1.0] {
            var leg = BuildingMesh()
            loft(&leg, sections: profile.sections, side: side, origin: origin, forward: forward, across: across)
            root.addChildNode(leg.node(name: side < 0 ? "pylonLeg.left" : "pylonLeg.right", material: concrete))
        }
        if isCentral {
            var head = BuildingMesh()
            let sections: [TanzanitePylonProfile.Section] = [
                .init(elevation: 63.8, offset: 0, width: 7.4, depth: 4.9),
                .init(elevation: 66.8, offset: 0, width: 7.0, depth: 4.9)
            ]
            loft(&head, sections: sections, side: 1, origin: origin, forward: forward, across: across)
            root.addChildNode(head.node(name: "pylonCrosshead", material: concrete))
            var seat = BuildingMesh()
            loft(&seat, sections: [
                .init(elevation: 66.8, offset: 0, width: 6.0, depth: 4.4),
                .init(elevation: 67.6, offset: 0, width: 6.0, depth: 4.4)
            ], side: 1, origin: origin, forward: forward, across: across)
            root.addChildNode(seat.node(name: "crownConcreteSeat", material: concrete))
            root.addChildNode(TanzaniteCrown.make(origin: origin, forward: forward, across: across))
        }
        return root
    }

    static func cableAnchor(alignment: TanzaniteBridgeAlignment, station: Double, isCentral: Bool, side: Double, direction: Double, index: Int) -> SIMD3<Double> {
        let profile = TanzanitePylonProfile(deckElevation: alignment.deckElevation(at: station), isCentral: isCentral)
        let section = profile.cableSection(index: index)
        let centre = alignment.point(at: station, offset: side * section.offset, elevation: section.elevation)
        return centre + alignment.tangent(at: station) * direction * (section.depth / 2 + 0.16)
    }

    private static func ring(_ section: TanzanitePylonProfile.Section, side: Double) -> [SIMD3<Double>] {
        let x = section.depth / 2, y = section.width / 2
        let c = min(0.20, min(x, y) * 0.18)
        let corners: [SIMD2<Double>] = [
            SIMD2(-x + c, -y), SIMD2(x - c, -y), SIMD2(x, -y + c), SIMD2(x, y - c),
            SIMD2(x - c, y), SIMD2(-x + c, y), SIMD2(-x, y - c), SIMD2(-x, -y + c)
        ]
        return corners.map { SIMD3($0.x, $0.y + side * section.offset, section.elevation) }
    }

    private static func loft(_ mesh: inout BuildingMesh, sections: [TanzanitePylonProfile.Section], side: Double, origin: SIMD3<Double>, forward: SIMD3<Double>, across: SIMD3<Double>) {
        guard sections.count >= 2 else { return }
        let rings = sections.map { ring($0, side: side) }
        func world(_ p: SIMD3<Double>) -> SIMD3<Double> { origin + forward * p.x + across * p.y + SIMD3(0, 0, p.z) }
        func worldNormal(_ n: SIMD3<Double>) -> SIMD3<Double> { forward * n.x + across * n.y + SIMD3(0, 0, n.z) }
        func normal(row: Int, face: Int) -> SIMD3<Double> {
            let next = (face + 1) % 8
            let before = max(0, row - 1), after = min(rings.count - 1, row + 1)
            let edge = rings[row][next] - rings[row][face]
            let rise = (rings[after][face] + rings[after][next] - rings[before][face] - rings[before][next]) / 2
            return worldNormal(simd_normalize(simd_cross(edge, rise)))
        }
        for row in 0..<(rings.count - 1) {
            for face in 0..<8 {
                let next = (face + 1) % 8
                let low = normal(row: row, face: face), high = normal(row: row + 1, face: face)
                mesh.smoothQuad(world(rings[row][face]), world(rings[row][next]), world(rings[row + 1][next]), world(rings[row + 1][face]), normals: [low, low, high, high])
            }
        }
        // End caps keep the structural volume closed and the concrete faces flat.
        for row in [0, rings.count - 1] {
            let section = sections[row]
            let centre = world(SIMD3(0, side * section.offset, section.elevation))
            for face in 0..<8 {
                let next = (face + 1) % 8
                if row == 0 { mesh.triangle(centre, world(rings[row][next]), world(rings[row][face]), normal: SIMD3(0, 0, -1)) }
                else { mesh.triangle(centre, world(rings[row][face]), world(rings[row][next]), normal: SIMD3(0, 0, 1)) }
            }
        }
    }

}
