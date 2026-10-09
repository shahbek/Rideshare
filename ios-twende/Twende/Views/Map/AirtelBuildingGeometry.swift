@_spi(Experimental) import MapboxMaps
import SceneKit
import simd

/// Photo-guided Airtel House: metric east/north/up geometry, never a rotated screen overlay.
enum AirtelBuildingGeometry {
    static let glassBase: Double = 7.2
    static let glassTop: Double = 24.8
    static let canopyHeight: Double = 26.7
    static let screenTop: Double = 31.2
    private static let white = BuildingSurfaces.make("airtel.whiteAluminium", color: "#F4EFE7", roughness: 0.55, metalness: 0.12)
    private static let silver = BuildingSurfaces.make("airtel.silverSpandrel", color: "#BFCBCB", roughness: 0.48, metalness: 0.25)
    private static let frame = BuildingSurfaces.make("airtel.charcoalAluminium", color: "#30494E", roughness: 0.46, metalness: 0.35)
    static let red = BuildingSurfaces.make("airtel.redEnamel", color: "#E22332", roughness: 0.42, metalness: 0.08)

    private static let signLight = BuildingSurfaces.make("airtel.signLight", color: "#E22332", roughness: 0.3, metalness: 0)

    static func make(geometry: Geometry) -> SCNScene {
        let scene = SCNScene()
        guard let footprint = AirtelBuildingSite.footprint(geometry), let original = footprint.rings.first else { return scene }
        let outline = BuildingContour.rounded(original, tangentDistance: 2.4, segments: 6)
        let front = AirtelBuildingSite.frontEdge(outline)
        let a = outline[front], b = outline[(front + 1) % outline.count]
        let direction = simd_normalize(b - a)
        let outward = SIMD2(direction.y, -direction.x)
        let body = recessed(outline, edge: front, depth: 2.2)
        let root = SCNNode(); root.name = "airtelHouse"
        scene.rootNode.addChildNode(root)

        // The continuous two-storey podium supports the upper curtain-wall volume.
        let podium = outline.map { $0 * 0.965 }
        facade(ring: podium, bottom: 0.25, top: glassBase, rows: 2, bayWidth: 4.5,
                colors: ["#BFCBCB", "#C6D6D6"], root: root, name: "airtelPodium")
        let officeFloor = glassTop - 4.4
        facade(ring: body, bottom: glassBase, top: officeFloor, rows: 3, bayWidth: 4.5,
                colors: ["#326A72", "#417E86", "#558C94"], root: root, name: "airtelCurtainWall")
        facade(ring: body, bottom: officeFloor, top: glassTop, rows: 1, bayWidth: 7,
                colors: ["#BFCBCB"], root: root, name: "airtelPanoramicOffice", panoramic: true)
        AirtelOfficeGeometry.add(to: root, ring: body, floor: officeFloor, ceiling: glassTop)
        for floor in 1..<4 {
            let z = glassBase + Double(floor) * 4.4
            band(body, bottom: z - 0.42, top: z + 0.15, offset: 0.035, material: silver, root: root, name: "airtelSpandrel.\(floor)")
        }
        for (z, thickness) in [(0.2, 0.25), (3.65, 0.20), (7.0, 0.7), (24.75, 1.0)] {
            var moulding = BuildingMesh()
            moulding.perimeter(rings: [outline], bottom: z, top: z + thickness, projection: 0.32)
            root.addChildNode(moulding.node(name: "airtelWhiteFascia", material: white))
        }
        root.addChildNode(LandmarkMesh.volume(body, bottom: glassTop, top: glassTop + 0.3, material: white, name: "airtelClosedRoof"))
        root.addChildNode(LandmarkMesh.volume(outline, bottom: 7.0, top: 7.25, material: white, name: "airtelPodiumDeck"))

        let canopy = outline.map { $0 * 1.055 }
        root.addChildNode(LandmarkMesh.volume(canopy, bottom: canopyHeight, top: canopyHeight + 0.5, material: white, name: "airtelCantileverCanopy"))
        let screen = outline.map { $0 * 0.88 }
        band(screen, bottom: 28.15, top: screenTop, offset: 0, material: white, root: root, name: "airtelRoofScreen")
        facade(ring: screen, bottom: 27.4, top: 28.15, rows: 1, bayWidth: 2.5,
                colors: ["#558C94"], root: root, name: "airtelRoofRibbon")
        root.addChildNode(LandmarkMesh.volume(screen, bottom: screenTop - 0.22, top: screenTop, material: white, name: "airtelScreenCap"))
        var supports = BuildingMesh(), columns = BuildingMesh()
        for edge in outline.indices {
            let p = outline[edge], q = outline[(edge + 1) % outline.count]
            let length = simd_distance(p, q)
            guard length > 6 else { continue }
            let count = max(2, Int(length / 6))
            for i in 0..<count {
                let xy = p + (q - p) * ((Double(i) + 0.5) / Double(count))
                LandmarkMesh.beam(&supports, from: v(xy * 0.89, 28.3), to: v(xy * 1.04, 26.9), radius: 0.24, sides: 8)
                LandmarkMesh.beam(&columns, from: v(xy * 0.99, 0.3), to: v(xy * 0.99, 7.05), radius: 0.28, sides: 12)
            }
        }
        root.addChildNode(supports.node(name: "airtelCanopyBraces", material: white))
        root.addChildNode(columns.node(name: "airtelRedPodiumColumns", material: red))

        // Letter faces point outwards; two signs are visible in the supplied corner photograph.
        addSign(root: root, ring: screen, edge: AirtelBuildingSite.frontEdge(screen), width: 13, name: "airtelNorthSign")
        if let westEdge = screen.indices.filter({ i in
            let d = screen[(i + 1) % screen.count] - screen[i]
            return d.y < -5
        }).max(by: { simd_distance(screen[$0], screen[($0 + 1) % screen.count]) < simd_distance(screen[$1], screen[($1 + 1) % screen.count]) }) {
            addSign(root: root, ring: screen, edge: westEdge, width: 9, name: "airtelWestSign")
        }
        // Entrance under the recessed bay, with a projecting shallow canopy.
        let entrance = a + (b - a) * 0.655 - outward * 1.4
        let u = -direction * 3.3, n = outward * 1.1
        let entranceRing = [entrance - u - n, entrance + u - n, entrance + u + n, entrance - u + n]
        var ordered = entranceRing
        if BuildingFootprint.area(ordered) < 0 { ordered.reverse() }
        root.addChildNode(LandmarkMesh.volume(ordered, bottom: 3.0, top: 3.28, material: white, name: "airtelEntranceCanopy"))
        mast(root: root, at: SIMD2(3, -3))
        DioramaLandmarkEnvironment.add(to: scene, ring: original, airtel: true)
        return scene
    }

    static func recessed(_ ring: [SIMD2<Double>], edge: Int, depth: Double) -> [SIMD2<Double>] {
        let a = ring[edge], b = ring[(edge + 1) % ring.count], d = b - a
        let normal = simd_normalize(SIMD2(d.y, -d.x))
        var result: [SIMD2<Double>] = []
        for i in ring.indices {
            result.append(ring[i])
            if i == edge {
                let left = a + d * 0.61, right = a + d * 0.70
                result.append(contentsOf: [left, left - normal * depth, right - normal * depth, right])
            }
        }
        return result
    }

    private static func facade(ring: [SIMD2<Double>], bottom: Double, top: Double, rows: Int, bayWidth: Double, colors: [String], root: SCNNode, name: String, panoramic: Bool = false) {
        var panes = colors.map { _ in BuildingMesh() }, mullions = BuildingMesh(), lit = BuildingMesh()
        let normals = BuildingContour.outwardNormals(ring)
        for i in ring.indices {
            let j = (i + 1) % ring.count, a = ring[i], b = ring[j], d = b - a
            let count = max(1, Int(ceil(simd_length(d) / bayWidth)))
            let normal = simd_normalize(SIMD2(d.y, -d.x))
            for bay in 0..<count {
                let t0 = Double(bay) / Double(count), t1 = Double(bay + 1) / Double(count)
                let p = a + d * t0, q = a + d * t1
                let n0 = simd_normalize(normals[i] * (1 - t0) + normals[j] * t0)
                let n1 = simd_normalize(normals[i] * (1 - t1) + normals[j] * t1)
                let curved = simd_length(d) < 1.2
                for row in 0..<rows {
                    let low = bottom + (top - bottom) * Double(row) / Double(rows)
                    let high = bottom + (top - bottom) * Double(row + 1) / Double(rows)
                    let colorIndex = (bay / 4 + row / 4 + i / 8) % colors.count
                    let ns = curved ? [v(n0, 0), v(n1, 0), v(n1, 0), v(n0, 0)] : Array(repeating: v(normal, 0), count: 4)
                    if !panoramic && !curved && (bay + row * 3 + i) % 5 == 1 {
                        lit.smoothQuad(v(p, low), v(q, low), v(q, high), v(p, high), normals: ns)
                    } else {
                        panes[colorIndex].smoothQuad(v(p, low), v(q, low), v(q, high), v(p, high), normals: ns)
                    }
                    if !curved {
                        let offset = normal * 0.11
                        LandmarkMesh.beam(&mullions, from: v(p + offset, low), to: v(q + offset, low), radius: 0.16, sides: 8)
                    }
                }
                if !curved {
                    let offset = normal * 0.11
                    LandmarkMesh.beam(&mullions, from: v(p + offset, bottom), to: v(p + offset, top), radius: 0.19, sides: 8)
                }
            }
        }
        let group = SCNNode(); group.name = name
        for i in colors.indices {
            let material = BuildingSurfaces.make(panoramic ? "landmark.panoramicGlass" : "airtel.tealGlass", color: colors[i], roughness: 0.4, metalness: 0.08)
            if panoramic { material.transparency = 0.14 }
            group.addChildNode(panes[i].node(name: "curtainGlass", material: material))
        }
        group.addChildNode(lit.node(name: "occupiedOfficeWindows", material: LandmarkLightingGeometry.window))
        group.addChildNode(mullions.node(name: "airtelMullions", material: frame))
        root.addChildNode(group)
    }

    private static func band(_ ring: [SIMD2<Double>], bottom: Double, top: Double, offset: Double, material: SCNMaterial, root: SCNNode, name: String) {
        var mesh = BuildingMesh()
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], d = simd_normalize(b - a)
            let n = SIMD2(d.y, -d.x) * offset
            mesh.quad(v(a + n, bottom), v(b + n, bottom), v(b + n, top), v(a + n, top))
        }
        root.addChildNode(mesh.node(name: name, material: material))
    }

    private static func addSign(root: SCNNode, ring: [SIMD2<Double>], edge: Int, width: Double, name: String) {
        let a = ring[edge], b = ring[(edge + 1) % ring.count]
        let along = simd_normalize(b - a), outward = SIMD2(along.y, -along.x)
        let origin = (a + b) / 2 + outward * 0.08
        let sign = AirtelSignage.make(width: min(width, simd_distance(a, b) * 0.65), material: signLight)
        sign.name = name
        sign.simdTransform = simd_float4x4(columns: (
            SIMD4(Float(along.x), Float(along.y), 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(Float(outward.x), Float(outward.y), 0, 0), SIMD4(Float(origin.x), Float(origin.y), 28.65, 1)
        ))
        root.addChildNode(sign)
    }

    private static func mast(root: SCNNode, at centre: SIMD2<Double>) {
        var steel = BuildingMesh(), dishes = BuildingMesh()
        let feet = [centre + SIMD2(-0.65, -0.4), centre + SIMD2(0.65, -0.4), centre + SIMD2(0, 0.7)]
        for i in feet.indices {
            let next = feet[(i + 1) % feet.count]
            LandmarkMesh.beam(&steel, from: v(feet[i], screenTop), to: v(feet[i], 42), radius: 0.18, sides: 8)
            for level in 0..<3 {
                let z = screenTop + Double(level) * 3.2
                LandmarkMesh.beam(&steel, from: v(feet[i], z), to: v(next, z + 3.2), radius: 0.13, sides: 8)
                LandmarkMesh.beam(&steel, from: v(feet[i], z), to: v(next, z), radius: 0.15, sides: 8)
            }
        }
        for z in [35.4, 38.5] {
            let c = SIMD3(centre.x, centre.y + 1, z)
            LandmarkMesh.beam(&steel, from: SIMD3(centre.x, centre.y, z), to: c, radius: 0.08)
            for i in 0..<24 {
                let a = Double(i) * .pi / 12, b = Double(i + 1) * .pi / 12
                let p = c + SIMD3(cos(a) * 0.6, 0.1, sin(a) * 0.6)
                let q = c + SIMD3(cos(b) * 0.6, 0.1, sin(b) * 0.6)
                dishes.triangle(c + SIMD3(0, -0.12, 0), p, q)
            }
        }
        root.addChildNode(steel.node(name: "airtelCommunicationsMast", material: silver))
        root.addChildNode(dishes.node(name: "airtelMicrowaveDishes", material: white))
    }

    private static func v(_ p: SIMD2<Double>, _ z: Double) -> SIMD3<Double> { SIMD3(p.x, p.y, z) }
}
