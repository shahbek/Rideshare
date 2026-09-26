import SceneKit
import simd

/// Photo-guided lantern: asymmetric flame fins cradle an octagonal cut tanzanite light.
/// Heights are illustrative metres above the same bridge datum as the concrete portal.
enum TanzaniteCrown {
    static let gemLevels: [SIMD2<Double>] = [
        SIMD2(0.55, 75.0), SIMD2(1.12, 76.2), SIMD2(1.92, 77.8),
        SIMD2(3.15, 80.0), SIMD2(2.42, 81.7), SIMD2(1.65, 83.5)
    ]

    static func make(origin: SIMD3<Double>, forward: SIMD3<Double>, across: SIMD3<Double>) -> SCNNode {
        let root = SCNNode()
        root.name = "proceduralTanzaniteCrown"
        func world(_ p: SIMD3<Double>) -> SIMD3<Double> {
            origin + forward * p.x + across * p.y + SIMD3(0, 0, p.z)
        }
        var fins = BuildingMesh(), tips = BuildingMesh(), frame = BuildingMesh()
        // Narrow solid blades, not rods: the taller rear/left fan rises beside the gem.
        for index in 0..<22 {
            let angle = Double(index) * 2 * .pi / 22
            let radial = SIMD3<Double>(cos(angle) * 0.80, sin(angle), 0)
            let tangent = simd_normalize(SIMD3<Double>(-sin(angle), cos(angle) * 0.80, 0))
            let peak = 72.1 + 9.5 * pow((1 - sin(angle)) / 2, 1.4)
            func ring(_ t: Double) -> [SIMD3<Double>] {
                let centre = radial * (1.7 + 1.4 * t * t) + SIMD3(0, 0, 67.55 + (peak - 67.55) * t)
                let halfWidth = 0.20 * (1 - 0.65 * t)
                let depth = simd_normalize(radial) * 0.09
                return [centre - tangent * halfWidth - depth, centre + tangent * halfWidth - depth,
                        centre + tangent * halfWidth + depth, centre - tangent * halfWidth + depth].map(world)
            }
            for row in 0..<10 {
                let a = ring(Double(row) / 10), b = ring(Double(row + 1) / 10)
                for face in 0..<4 {
                    let next = (face + 1) % 4
                    if row >= 8 { tips.quad(a[face], a[next], b[next], b[face]) }
                    else { fins.quad(a[face], a[next], b[next], b[face]) }
                }
            }
            let top = ring(1), bottom = ring(0)
            tips.quad(top[0], top[1], top[2], top[3])
            fins.quad(bottom[3], bottom[2], bottom[1], bottom[0])
        }
        root.addChildNode(fins.node(name: "tanzaniteCrownFins", material: BuildingSurfaces.make("crown red", color: "#BA3B38", roughness: 0.55)))
        root.addChildNode(tips.node(name: "tanzaniteCrownGoldTips", material: BuildingSurfaces.make("crown gold", color: "#E2B65F", roughness: 0.45, metalness: 0.15)))
        // The internal stem joins the lantern's lower point to the concrete seat.
        LandmarkMesh.beam(&frame, from: world(SIMD3(0, 0, 67.5)), to: world(SIMD3(0, 0, 75.1)), radius: 0.28, sides: 8)
        func gemPoint(_ row: Int, _ face: Int) -> SIMD3<Double> {
            let angle = Double(face) * 2 * .pi / 8 + .pi / 8
            let level = gemLevels[row]
            return world(SIMD3(level.x * cos(angle) * 0.82, level.x * sin(angle), level.y))
        }
        let colors = ["#426CC9", "#5362BB", "#708CE5", "#344F98"]
        for face in 0..<8 {
            var facet = BuildingMesh()
            for row in 0..<(gemLevels.count - 1) {
                let a = gemPoint(row, face), b = gemPoint(row, face + 1)
                let c = gemPoint(row + 1, face + 1), d = gemPoint(row + 1, face)
                facet.quad(a, b, c, d)
                LandmarkMesh.beam(&frame, from: a, to: b, radius: 0.035, sides: 4)
                LandmarkMesh.beam(&frame, from: a, to: d, radius: 0.04, sides: 4)
            }
            let last = gemLevels.count - 1
            facet.triangle(world(SIMD3(0, 0, gemLevels[last].y)), gemPoint(last, face), gemPoint(last, face + 1), normal: SIMD3(0, 0, 1))
            facet.triangle(world(SIMD3(0, 0, gemLevels[0].y)), gemPoint(0, face + 1), gemPoint(0, face), normal: SIMD3(0, 0, -1))
            LandmarkMesh.beam(&frame, from: gemPoint(last, face), to: gemPoint(last, face + 1), radius: 0.04, sides: 4)
            let material = BuildingSurfaces.make("landmark.tanzaniteLight", color: colors[face % colors.count], roughness: 0.22)
            material.emission.contents = material.diffuse.contents
            material.emission.intensity = 1.2
            root.addChildNode(facet.node(name: "tanzaniteGemFacet.\(face)", material: material))
        }
        root.addChildNode(frame.node(name: "tanzaniteLanternFrame", material: BuildingSurfaces.make("lantern pale metal", color: "#BFCFEC", roughness: 0.38, metalness: 0.25)))
        // A depth-tested additive shell supplies the halo in Mapbox's Metal renderer.
        // SceneKit bloom is intentionally not used: this scene only supplies triangle geometry.
        var halo = BuildingMesh()
        let profile: [SIMD2<Double>] = (0...20).map { index in
            let angle = Double(index) * .pi / 20
            return SIMD2(5.5 * sin(angle), 79.2 - 6.5 * cos(angle))
        }
        halo.revolve(centre: SIMD2(origin.x, origin.y), profile: profile, segments: 32)
        root.addChildNode(halo.node(name: "tanzaniteLightHalo", material: BuildingSurfaces.make("landmark.tanzaniteHalo", color: "#7896FF", roughness: 1)))
        return root
    }
}
