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
            road.quad(al, bl, br, ar, normal: SIMD3(0, 0, 1))
            let down = SIMD3<Double>(0, 0, 2.0)
            concrete.quad(al - down, bl - down, bl, al)
            concrete.quad(ar, br, br - down, ar - down)
            concrete.quad(ar - down, br - down, bl - down, al - down, normal: SIMD3(0, 0, -1))
            for side in [-1.0, 1.0] {
                let outer = side * half, inner = side * (half - 1.6)
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
        let materials: [(String, BuildingMesh, String)] = [("bridgeConcrete", concrete, "#E4E8E9"), ("bridgeRoad", road, "#59626A"), ("bridgeCables", cables, "#F4F6F7"), ("bridgeLaneMarkings", markings, "#F8F7ED"), ("bridgeCableSockets", anchors, "#AAB3B8")]
        for (name, mesh, hex) in materials where !mesh.positions.isEmpty {
            scene.rootNode.addChildNode(mesh.node(name: name, material: BuildingSurfaces.make(name == "bridgeConcrete" ? "surface.bridgeConcrete" : name, color: hex, roughness: 0.7)))
        }
        return scene
    }
}
