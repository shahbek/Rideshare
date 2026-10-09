@_spi(Experimental) import MapboxMaps
import SceneKit
import simd

/// Photo-guided Airtel House: metric east/north/up geometry, never a rotated screen overlay.
enum AirtelBuildingGeometry {
    static let glassBase: Double = 7.2
    static let glassTop: Double = 24.8
    static let officeFloor: Double = 20.4
    static let canopyHeight: Double = 26.7
    static let screenTop: Double = 29.6
    private static let canopyTop: Double = canopyHeight + 0.5
    private static let rooftopFloor: Double = canopyTop + 0.3
    private static let roofConcrete = BuildingSurfaces.make("airtel.roofConcrete", color: "#C9C2B6", roughness: 0.9, metalness: 0)
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

        addRoof(to: root, outline: outline, body: body, front: front)
        var columns = BuildingMesh(), columnBases = BuildingMesh(), columnCapitals = BuildingMesh()
        for edge in outline.indices {
            let p = outline[edge], q = outline[(edge + 1) % outline.count]
            let length = simd_distance(p, q)
            guard length > 6 else { continue }
            let count = max(2, Int(length / 6))
            for i in 0..<count {
                let xy = p + (q - p) * ((Double(i) + 0.5) / Double(count))
                let support = xy * 0.99
                LandmarkMesh.beam(&columnBases, from: v(support, 0.2), to: v(support, 0.55), radius: 0.78, sides: 12)
                LandmarkMesh.beam(&columns, from: v(support, 0.45), to: v(support, 7.05), radius: 0.62, sides: 12)
                LandmarkMesh.beam(&columnCapitals, from: v(support, 6.65), to: v(support, 7.2), radius: 0.76, sides: 12)
            }
        }
        root.addChildNode(columns.node(name: "airtelPalePodiumColumns", material: silver))
        root.addChildNode(columnBases.node(name: "airtelPodiumColumnFeet", material: white))
        root.addChildNode(columnCapitals.node(name: "airtelPodiumColumnCapitals", material: white))
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

    private static func addRoof(to root: SCNNode, outline: [SIMD2<Double>], body: [SIMD2<Double>], front: Int) {
        let a = outline[front], b = outline[(front + 1) % outline.count]
        let along = simd_normalize(b - a), outward = SIMD2(along.y, -along.x), inward = -outward
        let lengths = outline.map { simd_dot($0, along) }, depths = outline.map { simd_dot($0, inward) }
        let centre = along * ((lengths.min() ?? 0) + (lengths.max() ?? 0)) / 2
            + inward * ((depths.min() ?? 0) + (depths.max() ?? 0)) / 2
        let canopy = DioramaPolygon.offset(outline.map { DV2($0.x, $0.y) }, by: 1.05)?.map { SIMD2($0.x, $0.y) }
            ?? outline.map { centre + ($0 - centre) * 1.055 }
        // Every roof plane is level. The inset roof is a complete deck, not a single logo wall.
        root.addChildNode(LandmarkMesh.volume(canopy, bottom: canopyHeight, top: canopyTop,
            material: white, name: "airtelCantileverCanopy"))
        addCurvedRoofSupports(to: root, body: body)
        let rooftop = outline.map { p in
            let d = p - centre
            return centre + along * (simd_dot(d, along) * 0.88) + inward * (simd_dot(d, inward) * 0.76)
        }
        root.addChildNode(LandmarkMesh.volume(rooftop, bottom: canopyTop - 0.02, top: rooftopFloor,
            material: roofConcrete, name: "airtelInsetRooftopDeck"))
        addRoofParapet(to: root, ring: rooftop)
        let frontEdge = AirtelBuildingSite.frontEdge(rooftop)
        let rearEdge = rooftop.indices.filter { edge in
            let d = rooftop[(edge + 1) % rooftop.count] - rooftop[edge]
            guard simd_length(d) > 4 else { return false }
            return simd_dot(simd_normalize(SIMD2(d.y, -d.x)), inward) > 0.65
        }.max { left, right in
            simd_distance(rooftop[left], rooftop[(left + 1) % rooftop.count])
                < simd_distance(rooftop[right], rooftop[(right + 1) % rooftop.count])
        }
        addRoofSign(to: root, ring: rooftop, edge: frontEdge, name: "airtelNorthSign")
        if let rearEdge { addRoofSign(to: root, ring: rooftop, edge: rearEdge, name: "airtelRearSign") }
        let services = addRoofServices(to: root, ring: rooftop, centre: centre, along: along, inward: inward)
        let roofPolygon = rooftop.map { DV2($0.x, $0.y) }
        let mastSites = [centre + along * 4 + inward * 1.5, centre + along * 9 + inward * 1.5,
                         centre + along * 1 + inward * 4, centre - along * 3 + inward * 4]
        let mastSite = mastSites.first { site in
            let feet = [site + SIMD2(-0.65, -0.4), site + SIMD2(0.65, -0.4), site + SIMD2(0, 0.7)]
            return feet.allSatisfy { foot in
                let point = DV2(foot.x, foot.y)
                return DioramaPolygon.contains(roofPolygon, point)
                    && DioramaPolygon.distanceToRing(roofPolygon, point) > 0.65
                    && services.allSatisfy { service in
                        !DioramaPolygon.contains(service, point) && DioramaPolygon.distanceToRing(service, point) > 0.4
                    }
            }
        }
        if let mastSite { mast(root: root, at: mastSite, roofHeight: { _ in rooftopFloor }) }
    }

    private static func addCurvedRoofSupports(to root: SCNNode, body: [SIMD2<Double>]) {
        var supports = BuildingMesh()
        let polygon = body.map { DV2($0.x, $0.y) }
        for edge in body.indices {
            let p = body[edge], q = body[(edge + 1) % body.count], d = q - p
            let length = simd_length(d)
            guard length > 8 else { continue }
            let normal = simd_normalize(SIMD2(d.y, -d.x))
            let count = max(1, Int(length / 8))
            for bay in 0..<count {
                let xy = p + d * ((Double(bay) + 0.5) / Double(count))
                let foot = xy - normal * 1.05
                guard DioramaPolygon.contains(polygon, DV2(foot.x, foot.y)),
                      DioramaPolygon.distanceToRing(polygon, DV2(foot.x, foot.y)) > 0.3 else { continue }
                let joint = v(foot, glassTop + 0.75)
                LandmarkMesh.beam(&supports, from: v(foot, glassTop + 0.3), to: joint, radius: 0.25, sides: 10)
                for tipXY in [xy + normal * 0.65, foot - normal * 0.95] {
                    let end = v(tipXY, canopyHeight + 0.02)
                    let direction = simd_normalize(tipXY - foot)
                    curvedSupport(&supports, start: joint, controlA: v(foot, canopyHeight - 0.08),
                        controlB: v(tipXY - direction * 0.55, canopyHeight + 0.02), end: end,
                        planeNormal: SIMD3(-normal.y, normal.x, 0), radius: 0.23)
                }
            }
        }
        root.addChildNode(supports.node(name: "airtelCanopyCurvedBeams", material: white))
    }

    // Shared tube rings/normals follow a cubic curve; no faceted rods or per-segment internal caps.
    private static func curvedSupport(_ mesh: inout BuildingMesh, start: SIMD3<Double>,
                                      controlA: SIMD3<Double>, controlB: SIMD3<Double>, end: SIMD3<Double>,
                                      planeNormal: SIMD3<Double>, radius: Double) {
        let steps = 10, sides = 10
        func sample(_ step: Int, _ side: Int) -> (point: SIMD3<Double>, normal: SIMD3<Double>) {
            let t = Double(step) / Double(steps), s = 1 - t
            let centre = start * (s * s * s) + controlA * (3 * s * s * t)
                + controlB * (3 * s * t * t) + end * (t * t * t)
            let tangent = simd_normalize((controlA - start) * (3 * s * s)
                + (controlB - controlA) * (6 * s * t) + (end - controlB) * (3 * t * t))
            let across = simd_cross(tangent, planeNormal)
            let angle = Double(side) * 2 * .pi / Double(sides)
            let normal = planeNormal * cos(angle) + across * sin(angle)
            return (centre + normal * radius, normal)
        }
        for step in 0..<steps {
            for side in 0..<sides {
                let a = sample(step, side), b = sample(step, side + 1)
                let c = sample(step + 1, side + 1), d = sample(step + 1, side)
                mesh.smoothQuad(a.point, b.point, c.point, d.point, normals: [a.normal, b.normal, c.normal, d.normal])
            }
        }
        let startAxis = simd_normalize(controlA - start), endAxis = simd_normalize(end - controlB)
        for side in 0..<sides {
            mesh.triangle(start, sample(0, side + 1).point, sample(0, side).point, normal: -startAxis)
            mesh.triangle(end, sample(steps, side).point, sample(steps, side + 1).point, normal: endAxis)
        }
    }

    private static func addRoofParapet(to root: SCNNode, ring: [SIMD2<Double>]) {
        guard let inner = DioramaPolygon.offset(ring.map { DV2($0.x, $0.y) }, by: -0.48),
              inner.count == ring.count else { return }
        let normals = BuildingContour.outwardNormals(ring)
        var parapet = BuildingMesh(), coping = BuildingMesh()
        let bottom = rooftopFloor - 0.02, top = screenTop - 0.12
        for i in ring.indices {
            let j = (i + 1) % ring.count
            let a = ring[i], b = ring[j], c = SIMD2(inner[j].x, inner[j].y), d = SIMD2(inner[i].x, inner[i].y)
            let n0 = v(normals[i], 0), n1 = v(normals[j], 0)
            parapet.smoothQuad(v(a, bottom), v(b, bottom), v(b, top), v(a, top), normals: [n0, n1, n1, n0])
            parapet.smoothQuad(v(c, bottom), v(d, bottom), v(d, top), v(c, top), normals: [-n1, -n0, -n0, -n1])
            parapet.quad(v(a, top), v(b, top), v(c, top), v(d, top))
            parapet.quad(v(d, bottom), v(c, bottom), v(b, bottom), v(a, bottom))
        }
        coping.perimeter(rings: [ring], bottom: screenTop - 0.2, top: screenTop, projection: 0.10, profileSegments: 6)
        root.addChildNode(parapet.node(name: "airtelRoundedRooftopEdge", material: white))
        root.addChildNode(coping.node(name: "airtelRooftopCoping", material: white))
    }

    private static func addRoofSign(to root: SCNNode, ring: [SIMD2<Double>], edge: Int, name: String) {
        let a = ring[edge], b = ring[(edge + 1) % ring.count]
        let length = simd_distance(a, b), along = simd_normalize(b - a)
        let outward = SIMD2(along.y, -along.x)
        let width = min(11.5, length * 0.42, (screenTop - rooftopFloor - 0.35) * 3.2)
        guard width > 1 else { return }
        let sign = AirtelSignage.make(width: width, material: signLight)
        let bounds = sign.boundingBox
        let height = Double(bounds.max.y - bounds.min.y)
        let centre = (a + b) / 2 + outward * 0.12
        let baseline = (rooftopFloor + screenTop) / 2 - height / 2 - Double(bounds.min.y)
        sign.name = name
        sign.simdTransform = simd_float4x4(columns: (
            SIMD4(Float(along.x), Float(along.y), 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(Float(outward.x), Float(outward.y), 0, 0),
            SIMD4(Float(centre.x), Float(centre.y), Float(baseline), 1)))
        root.addChildNode(sign)
    }

    private static func addRoofServices(to root: SCNNode, ring: [SIMD2<Double>], centre: SIMD2<Double>,
                                        along: SIMD2<Double>, inward: SIMD2<Double>) -> [[DV2]] {
        let polygon = ring.map { DV2($0.x, $0.y) }
        var footprints: [[DV2]] = []
        for (distance, width, depth, height) in [(-6.5, 6.0, 3.5, 0.95), (2.0, 3.2, 2.2, 0.65)] {
            let origin = centre + along * distance - inward * 1.2
            let x = along * (width / 2), y = inward * (depth / 2)
            let shape = [origin - x - y, origin + x - y, origin + x + y, origin - x + y]
            guard shape.allSatisfy({
                DioramaPolygon.contains(polygon, DV2($0.x, $0.y))
                    && DioramaPolygon.distanceToRing(polygon, DV2($0.x, $0.y)) > 0.85
            }) else { continue }
            root.addChildNode(LandmarkMesh.volume(shape, bottom: rooftopFloor, top: rooftopFloor + height,
                material: white, name: "airtelRoofServiceHousing"))
            footprints.append(shape.map { DV2($0.x, $0.y) })
        }
        return footprints
    }

    private static func mast(root: SCNNode, at centre: SIMD2<Double>, roofHeight: (SIMD2<Double>) -> Double) {
        var steel = BuildingMesh(), dishes = BuildingMesh()
        let feet = [centre + SIMD2(-0.65, -0.4), centre + SIMD2(0.65, -0.4), centre + SIMD2(0, 0.7)]
        for i in feet.indices {
            let next = feet[(i + 1) % feet.count]
            LandmarkMesh.beam(&steel, from: v(feet[i], roofHeight(feet[i])), to: v(feet[i], 42), radius: 0.18, sides: 8)
            let base = max(roofHeight(feet[i]), roofHeight(next))
            let levels = max(1, Int(ceil((42 - base) / 3.2)))
            for level in 0..<levels {
                let z = base + Double(level) * 3.2
                LandmarkMesh.beam(&steel, from: v(feet[i], z), to: v(next, min(42, z + 3.2)), radius: 0.13, sides: 8)
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
