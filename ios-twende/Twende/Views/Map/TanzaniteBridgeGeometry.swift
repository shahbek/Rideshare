import SceneKit
import simd

/// Research-based, end-to-end deck and cable structure. Pylon elevations/chainages are illustrative.
/// All pylons, the torch, cables and deck are direct procedural geometry; no imported mesh is loaded.
enum TanzaniteBridgeGeometry {
    static func make(alignment: TanzaniteBridgeAlignment) -> SCNScene {
        let scene = SCNScene()
        var concrete = BuildingMesh(), road = BuildingMesh(), cables = BuildingMesh(), markings = BuildingMesh(), anchors = BuildingMesh()
        let half = alignment.record.widthMetres / 2
        var distances = Array(stride(from: 0.0, to: alignment.length, by: 8.0))
        distances.append(alignment.length)
        for i in 0..<(distances.count - 1) {
            let a = distances[i], b = distances[i + 1]
            let al = alignment.point(at: a, offset: -half), ar = alignment.point(at: a, offset: half)
            let bl = alignment.point(at: b, offset: -half), br = alignment.point(at: b, offset: half)
            road.quad(alignment.point(at: a, offset: -half + 1.6), alignment.point(at: b, offset: -half + 1.6),
                alignment.point(at: b, offset: half - 1.6), alignment.point(at: a, offset: half - 1.6), normal: SIMD3(0, 0, 1))
            let down = SIMD3<Double>(0, 0, 2.0)
            roundedDeckEdge(&concrete, alignment: alignment, from: a, to: b, half: half, side: -1)
            roundedDeckEdge(&concrete, alignment: alignment, from: a, to: b, half: half, side: 1)
            concrete.quad(ar - down, br - down, bl - down, al - down, normal: SIMD3(0, 0, -1))
            for side in [-1.0, 1.0] {
                let outer = side * (half - 0.45), inner = side * (half - 1.6)
                let p0 = alignment.point(at: a, offset: outer) + SIMD3(0, 0, 0.12)
                let p1 = alignment.point(at: b, offset: outer) + SIMD3(0, 0, 0.12)
                concrete.quad(p0, p1, alignment.point(at: b, offset: inner) + SIMD3(0, 0, 0.12), alignment.point(at: a, offset: inner) + SIMD3(0, 0, 0.12), normal: SIMD3(0, 0, 1))
                LandmarkMesh.beam(&cables, from: p0 + SIMD3(0, 0, 1.05), to: p1 + SIMD3(0, 0, 1.05), radius: 0.09)
                LandmarkMesh.beam(&cables, from: p0, to: p0 + SIMD3(0, 0, 1.05), radius: 0.065)
            }
            for offset in [-4.2, 0, 4.2] {
                let end = offset == 0 ? b : min(b, a + 4.5)
                let lift = SIMD3<Double>(0, 0, 0.035)
                markings.quad(alignment.point(at: a, offset: offset - 0.07) + lift, alignment.point(at: end, offset: offset - 0.07) + lift, alignment.point(at: end, offset: offset + 0.07) + lift, alignment.point(at: a, offset: offset + 0.07) + lift, normal: SIMD3(0, 0, 1))
            }
        }
        // Keep the main spans open as in the photograph; shorter approach spans have regular supports.
        let mainStart = max(0, (alignment.record.pylonChainages.first ?? 85) - 85)
        let mainEnd = min(alignment.length, (alignment.record.pylonChainages.last ?? alignment.length - 85) + 85)
        let approachStations = Array(stride(from: 35.0, to: mainStart - 20, by: 55))
            + [mainStart, mainEnd] + Array(stride(from: mainEnd + 50, to: alignment.length - 20, by: 55))
        for chainage in approachStations {
            for side in [-5.7, 5.7] {
                LandmarkMesh.beam(&concrete, from: alignment.point(at: chainage, offset: side, elevation: 0), to: alignment.point(at: chainage, offset: side) - SIMD3(0, 0, 2), radius: 1.05, sides: 8)
            }
        }
        for (index, station) in alignment.record.pylonChainages.enumerated() {
            let isCentral = index == 2
            scene.rootNode.addChildNode(TanzaniteProceduralPylons.make(alignment: alignment, station: station, isCentral: isCentral))
            let forward = alignment.tangent(at: station)
            for side in [-1.0, 1.0] {
                for direction in [-1.0, 1.0] {
                    for cable in 0..<10 {
                        let distance = 14.0 + Double(cable) * 4.8
                        let attach = TanzaniteProceduralPylons.cableAnchor(alignment: alignment, station: station, isCentral: isCentral, side: side, direction: direction, index: cable)
                        // Short steel sockets penetrate the true concrete face instead of floating beside it.
                        LandmarkMesh.beam(&anchors, from: attach - forward * direction * 0.34, to: attach, radius: 0.22, sides: 6)
                        let end = alignment.point(at: station + direction * distance, offset: side * (half - 0.3)) + SIMD3(0, 0, 0.25)
                        LandmarkMesh.beam(&cables, from: attach, to: end, radius: 0.10, sides: 5)
                    }
                }
            }
        }
        var lamps = BuildingMesh(), glow = BuildingMesh()
        for station in stride(from: 24.0, to: alignment.length - 16, by: 36) {
            for side in [-1.0, 1.0] {
                let foot = alignment.point(at: station, offset: side * (half - 0.7)) + SIMD3(0, 0, 0.12)
                let top = foot + SIMD3(0, 0, 6.5)
                let across = simd_cross(SIMD3<Double>(0,0,1), alignment.tangent(at: station))
                let head = top - across * side * 1.25
                LandmarkMesh.beam(&lamps, from: foot, to: top, radius: 0.12, sides: 8)
                LandmarkMesh.beam(&lamps, from: top, to: head, radius: 0.09, sides: 8)
                LandmarkMesh.beam(&glow, from: head - alignment.tangent(at: station) * 0.35,
                    to: head + alignment.tangent(at: station) * 0.35, radius: 0.13, sides: 8)
            }
        }
        scene.rootNode.addChildNode(lamps.node(name: "bridgeLightingColumns", material: DarLandmarkParts.silver))
        scene.rootNode.addChildNode(glow.node(name: "architecturalLighting", material: BuildingSurfaces.make("landmark.fixture", color: "#F1E2C4", roughness: 0.8)))
        let materials: [(String, BuildingMesh, String)] = [("bridgeConcrete", concrete, "#F4EFE7"), ("bridgeRoad", road, "#A99C97"), ("bridgeCables", cables, "#F4EFE7"), ("bridgeLaneMarkings", markings, "#F8F7ED"), ("bridgeCableSockets", anchors, "#AAB3B8")]
        for (name, mesh, hex) in materials where !mesh.positions.isEmpty {
            scene.rootNode.addChildNode(mesh.node(name: name, material: BuildingSurfaces.make(name == "bridgeConcrete" ? "surface.bridgeConcrete" : name, color: hex, roughness: 0.7)))
        }
        return scene
    }

    private static func roundedDeckEdge(_ mesh: inout BuildingMesh, alignment: TanzaniteBridgeAlignment,
                                        from a: Double, to b: Double, half: Double, side: Double) {
        let radius = 0.45
        var section: [(Double, Double, SIMD2<Double>)] = []
        for i in 0...6 {
            let angle = Double(i) * .pi / 12
            section.append((half - radius + radius * sin(angle), -radius + radius * cos(angle), SIMD2(sin(angle), cos(angle))))
        }
        for i in 0...6 {
            let angle = Double(i) * .pi / 12
            section.append((half - radius + radius * cos(angle), -2 + radius - radius * sin(angle), SIMD2(cos(angle), -sin(angle))))
        }
        func p(_ station: Double, _ index: Int) -> SIMD3<Double> {
            alignment.point(at: station, offset: side * section[index].0) + SIMD3(0,0,section[index].1)
        }
        func n(_ station: Double, _ index: Int) -> SIMD3<Double> {
            let across = simd_cross(SIMD3<Double>(0,0,1), alignment.tangent(at: station))
            return across * side * section[index].2.x + SIMD3(0,0,section[index].2.y)
        }
        for i in 0..<(section.count - 1) {
            mesh.smoothQuad(p(a,i), p(b,i), p(b,i+1), p(a,i+1), normals: [n(a,i),n(b,i),n(b,i+1),n(a,i+1)])
        }
    }
}
