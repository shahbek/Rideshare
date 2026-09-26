import SceneKit
import simd

/// Contained, receding roof pavilions with rounded plans and bevelled shoulders.
/// Each level shares one contour and cap, rather than independent decorative blocks.
enum BuildingCrown {
    static func make(rectangle: [SIMD2<Double>], eave: Double, height: Double, isTower: Bool, trim: SCNMaterial, levels: Int? = nil, variant: Int = 0) -> SCNNode {
        let root = SCNNode()
        root.name = "terracedPavilion"
        guard rectangle.count == 4 else { return root }
        let u = simd_normalize(rectangle[1] - rectangle[0]), v = simd_normalize(rectangle[3] - rectangle[0])
        let shortSide = simd_distance(rectangle[0], rectangle[3])
        let longSide = simd_distance(rectangle[0], rectangle[1])
        guard min(shortSide, longSide) > 6 else { return root }
        var bottom = eave + 0.18
        let levelCount = min(3, max(1, levels ?? (isTower && shortSide > 12 ? 2 : 1)))
        for level in 0..<levelCount {
            let inset = min(3.0, shortSide * (0.16 + Double(variant % 3) * 0.015)) + Double(level) * min(1.8, shortSide * 0.085)
            guard shortSide - 2 * inset > 3, longSide - 2 * inset > 3 else { continue }
            let corners = [rectangle[0] + (u + v) * inset, rectangle[1] + (-u + v) * inset,
                           rectangle[2] - (u + v) * inset, rectangle[3] + (u - v) * inset]
            let ring = BuildingContour.rounded(corners, tangentDistance: min(2.0, (shortSide - 2 * inset) * 0.24), segments: 12)
            let bodyHeight = height * pow(0.62, Double(level))
            root.addChildNode(softVolume(ring: ring, bottom: bottom, height: bodyHeight, material: level == 0 ? BuildingSurfaces.wall(.brutalist) : BuildingSurfaces.wall(.timber), name: level == 0 ? "setbackCrown" : "upperCrown"))
            let contour = BuildingFootprint(rings: [ring])
            var lip = BuildingMesh()
            lip.perimeter(rings: [ring], bottom: bottom + bodyHeight - 0.07, top: bottom + bodyHeight + 0.13, projection: 0.13)
            root.addChildNode(lip.node(name: "roundedTerraceLip", material: trim))
            root.addChildNode(contour.deck(at: bottom + bodyHeight, thickness: 0.10, material: level == 0 && isTower ? BuildingSurfaces.membrane : BuildingSurfaces.terracotta, name: "crownRoof"))
            bottom += bodyHeight + 0.10
        }
        return root
    }

    /// A low glazed roof lantern fits safely inside irregular roof areas, including courtyard wings.
    static func atrium(footprint: BuildingFootprint, eave: Double, trim: SCNMaterial) -> SCNNode? {
        guard (footprint.rings.first?.count ?? 0) <= 64,
              footprint.rings.reduce(0, { $0 + BuildingFootprint.area($1) }) > 160,
              let site = footprint.domeSite, site.radius >= 3 else { return nil }
        let halfWidth = site.radius * 0.72, halfDepth = site.radius * 0.40
        let corners = [SIMD2(-halfWidth, -halfDepth), SIMD2(halfWidth, -halfDepth), SIMD2(halfWidth, halfDepth), SIMD2(-halfWidth, halfDepth)].map { $0 + site.centre }
        let ring = BuildingContour.rounded(corners, tangentDistance: min(1.1, halfDepth * 0.65), segments: 10)
        let root = softVolume(ring: ring, bottom: eave + 0.18, height: 0.95, material: BuildingSurfaces.glass, name: "roofAtrium")
        var lip = BuildingMesh()
        lip.perimeter(rings: [ring], bottom: eave + 0.18, top: eave + 0.32, projection: 0.12)
        root.addChildNode(lip.node(name: "atriumBase", material: trim))
        return root
    }

    private static func softVolume(ring: [SIMD2<Double>], bottom: Double, height: Double, material: SCNMaterial, name: String) -> SCNNode {
        let root = SCNNode()
        root.name = name
        let centre = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
        let ns = BuildingContour.outwardNormals(ring)
        let bevel = min(0.20, height * 0.16)
        var sides = BuildingMesh()
        let profiles: [(inset: Double, z: Double, normalZ: Double)] = [(0, bottom, 0), (0, bottom + height - bevel, 0)] + (1...6).map { step in
            let angle = Double(step) * .pi / 12
            return (bevel * (1 - cos(angle)), bottom + height - bevel + bevel * sin(angle), sin(angle))
        }
        for row in 0..<(profiles.count - 1) {
            func point(_ i: Int, _ profile: Int) -> SIMD3<Double> {
                let xy = ring[i] - ns[i] * profiles[profile].inset
                return SIMD3(xy.x, xy.y, profiles[profile].z)
            }
            func normal(_ i: Int, _ profile: Int) -> SIMD3<Double> {
                let z = profiles[profile].normalZ
                return SIMD3(ns[i].x * sqrt(max(0, 1 - z * z)), ns[i].y * sqrt(max(0, 1 - z * z)), z)
            }
            for i in ring.indices {
                let j = (i + 1) % ring.count
                sides.smoothQuad(point(i, row), point(j, row), point(j, row + 1), point(i, row + 1), normals: [normal(i, row), normal(j, row), normal(j, row + 1), normal(i, row + 1)])
            }
        }
        for i in ring.indices {
            let j = (i + 1) % ring.count
            let a = ring[i] - ns[i] * bevel, b = ring[j] - ns[j] * bevel
            sides.triangle(SIMD3(centre.x, centre.y, bottom + height), SIMD3(a.x, a.y, bottom + height), SIMD3(b.x, b.y, bottom + height), normal: SIMD3(0, 0, 1))
        }
        root.addChildNode(sides.node(name: "roundedCrownSurface", material: material))
        return root
    }
}
