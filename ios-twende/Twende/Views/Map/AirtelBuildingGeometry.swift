@_spi(Experimental) import MapboxMaps
import SceneKit
import simd

/// Photo-guided Airtel House: metric east/north/up geometry, never a rotated screen overlay.
enum AirtelBuildingGeometry {
    static let glassBase: Double = 7.2
    static let glassTop: Double = 24.8
    static let officeFloor: Double = 20.4
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
        facade(ring: body, bottom: glassBase, top: officeFloor, rows: 3, bayWidth: 4.5,
                colors: ["#326A72", "#417E86", "#558C94"], root: root, name: "airtelCurtainWall")
        facade(ring: body, bottom: officeFloor, top: glassTop, rows: 1, bayWidth: 4.5,
                colors: ["#BFCBCB"], root: root, name: "airtelPanoramicOffice", panoramic: true, includeBottomRail: false)
        AirtelOfficeGeometry.add(to: root, ring: body, floor: officeFloor, ceiling: glassTop)
        for floor in 1..<4 {
            let z = glassBase + Double(floor) * 4.4
            band(body, bottom: z - 0.42, top: z + 0.15, offset: 0.035, material: silver, root: root, name: "airtelSpandrel.\(floor)")
        }
        for (z, thickness) in [(0.2, 0.25), (3.65, 0.20), (7.0, 0.7), (24.75, 0.85)] {
            var moulding = BuildingMesh()
            moulding.perimeter(rings: [outline], bottom: z, top: z + thickness, projection: 0.32)
            root.addChildNode(moulding.node(name: "airtelWhiteFascia", material: white))
        }
        root.addChildNode(LandmarkMesh.volume(body, bottom: glassTop, top: glassTop + 0.3, material: white, name: "airtelClosedRoof"))
        root.addChildNode(LandmarkMesh.volume(outline, bottom: 7.0, top: 7.25, material: white, name: "airtelPodiumDeck"))

        addFlyingRoof(to: root, outline: outline, body: body, front: front)
        var columns = BuildingMesh()
        for edge in outline.indices {
            let p = outline[edge], q = outline[(edge + 1) % outline.count]
            let length = simd_distance(p, q)
            guard length > 6 else { continue }
            let count = max(2, Int(length / 6))
            for i in 0..<count {
                let xy = p + (q - p) * ((Double(i) + 0.5) / Double(count))
                LandmarkMesh.beam(&columns, from: v(xy * 0.99, 0.3), to: v(xy * 0.99, 7.05), radius: 0.34, sides: 12)
            }
        }
        root.addChildNode(columns.node(name: "airtelPalePodiumColumns", material: silver))
        // Entrance under the recessed bay, with a projecting shallow canopy.
        let entrance = a + (b - a) * 0.655 - outward * 1.4
        let u = -direction * 3.3, n = outward * 1.1
        let entranceRing = [entrance - u - n, entrance + u - n, entrance + u + n, entrance - u + n]
        var ordered = entranceRing
        if BuildingFootprint.area(ordered) < 0 { ordered.reverse() }
        root.addChildNode(LandmarkMesh.volume(ordered, bottom: 3.0, top: 3.28, material: white, name: "airtelEntranceCanopy"))
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

    private static func facade(ring: [SIMD2<Double>], bottom: Double, top: Double, rows: Int, bayWidth: Double, colors: [String], root: SCNNode, name: String, panoramic: Bool = false, includeBottomRail: Bool = true) {
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

                }
                if !curved {
                    let offset = normal * 0.11
                    LandmarkMesh.beam(&mullions, from: v(p + offset, bottom), to: v(p + offset, top), radius: 0.19, sides: 8)
                }
            }
        }
        // One shared perimeter skin carries every rail around the rounded corners/recess.
        for row in (includeBottomRail ? 0 : 1)...rows {
            let z = bottom + (top - bottom) * Double(row) / Double(rows)
            mullions.perimeter(rings: [ring], bottom: z - 0.16, top: z + 0.16, projection: 0.23)
        }
        let group = SCNNode(); group.name = name
        for i in colors.indices {
            let material = BuildingSurfaces.make(panoramic ? "landmark.panoramicGlass" : "airtel.tealGlass", color: colors[i], roughness: 0.4, metalness: 0.08)
            if panoramic { material.transparency = 0.045; material.metalness.contents = 0; material.roughness.contents = 1 }
            group.addChildNode(panes[i].node(name: "curtainGlass", material: material))
        }
        group.addChildNode(lit.node(name: "occupiedOfficeWindows", material: LandmarkLightingGeometry.window))
        group.addChildNode(mullions.node(name: "airtelMullions", material: frame))
        root.addChildNode(group)
    }

    private static func band(_ ring: [SIMD2<Double>], bottom: Double, top: Double, offset: Double, material: SCNMaterial, root: SCNNode, name: String) {
        var mesh = BuildingMesh()
        mesh.perimeter(rings: [ring], bottom: bottom, top: top, projection: max(0.08, offset))
        root.addChildNode(mesh.node(name: name, material: material))
    }

    private static func addFlyingRoof(to root: SCNNode, outline: [SIMD2<Double>], body: [SIMD2<Double>], front: Int) {
        let a = outline[front], b = outline[(front + 1) % outline.count]
        let along = simd_normalize(b - a), outward = SIMD2(along.y, -along.x), inward = -outward
        let centre = outline.reduce(SIMD2<Double>.zero, +) / Double(outline.count)
        let canopy = outline.map { centre + ($0 - centre) * 1.055 }
        let depths = canopy.map { simd_dot($0, inward) }
        let near = depths.min() ?? 0, far = depths.max() ?? 1
        let pitch = (screenTop - 0.5 - canopyHeight) / max(1, far - near)
        func roofHeight(_ p: SIMD2<Double>) -> Double {
            canopyHeight + (simd_dot(p, inward) - near) * pitch
        }
        // A closed, gently sloping white sail with a real underside; it is not an occupied storey.
        let sail = LandmarkMesh.volume(canopy, bottom: 0, top: 0.5, material: white, name: "airtelCantileverCanopy")
        sail.simdTransform = simd_float4x4(columns: (
            SIMD4(1, 0, Float(inward.x * pitch), 0), SIMD4(0, 1, Float(inward.y * pitch), 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, Float(canopyHeight - near * pitch), 1)))
        root.addChildNode(sail)
        var supports = BuildingMesh()
        for edge in body.indices {
            let p = body[edge], q = body[(edge + 1) % body.count]
            let length = simd_distance(p, q)
            guard length > 8 else { continue }
            let count = max(1, Int(length / 9))
            for i in 0..<count {
                let xy = p + (q - p) * ((Double(i) + 0.5) / Double(count))
                let foot = centre + (xy - centre) * 0.87
                let tip = centre + (xy - centre) * 1.04
                LandmarkMesh.beam(&supports, from: v(foot, glassTop + 0.3), to: v(foot, roofHeight(foot)), radius: 0.18, sides: 8)
                LandmarkMesh.beam(&supports, from: v(foot, glassTop + 0.8), to: v(tip, roofHeight(tip)), radius: 0.16, sides: 8)
            }
        }
        root.addChildNode(supports.node(name: "airtelCanopyBraces", material: white))
        // A single slim sign blade sits on the canopy, rather than enclosing a fictitious glass room.
        let signA = a + (b - a) * 0.08 - outward * 2.2
        let signB = a + (b - a) * 0.92 - outward * 2.2
        let bladeRing = [signA, signB, signB - outward * 0.42, signA - outward * 0.42]
        let bladeBase = max(roofHeight(signA), roofHeight(signB)) + 0.45
        let bladeTop = max(bladeBase + 0.8, screenTop)
        root.addChildNode(LandmarkMesh.volume(bladeRing, bottom: bladeBase, top: bladeTop,
            material: white, name: "airtelRoofSignBlade"))
        let signWidth = min(11.5, simd_distance(signA, signB) * 0.60, (bladeTop - bladeBase - 0.3) * 3.2)
        let sign = AirtelSignage.make(width: signWidth, material: signLight)
        let signCentre = (signA + signB) / 2 + outward * 0.08
        sign.name = "airtelNorthSign"
        sign.simdTransform = simd_float4x4(columns: (
            SIMD4(Float(along.x), Float(along.y), 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(Float(outward.x), Float(outward.y), 0, 0),
            SIMD4(Float(signCentre.x), Float(signCentre.y), Float(bladeBase + 0.2), 1)))
        root.addChildNode(sign)
        mast(root: root, at: SIMD2(3, -3), roofHeight: { roofHeight($0) + 0.5 })
    }

    private static func mast(root: SCNNode, at centre: SIMD2<Double>, roofHeight: (SIMD2<Double>) -> Double) {
        var steel = BuildingMesh(), dishes = BuildingMesh()
        let feet = [centre + SIMD2(-0.65, -0.4), centre + SIMD2(0.65, -0.4), centre + SIMD2(0, 0.7)]
        for i in feet.indices {
            let next = feet[(i + 1) % feet.count]
            LandmarkMesh.beam(&steel, from: v(feet[i], roofHeight(feet[i])), to: v(feet[i], 42), radius: 0.18, sides: 8)
            for level in 0..<3 {
                let z = max(roofHeight(feet[i]), roofHeight(next)) + Double(level) * 3.2
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
