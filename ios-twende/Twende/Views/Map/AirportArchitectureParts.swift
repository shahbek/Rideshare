import SceneKit
import simd

/// Airport-specific use of Slipway's softened masonry, closed frames and smooth roof shoulders.
enum AirportArchitectureParts {
    static func box(_ mesh: inout BuildingMesh, centre: SIMD2<Double>, width: Double, depth: Double, bottom: Double, top: Double) {
        HarbourArchitectureParts.box(&mesh, x: centre.x, y: centre.y, width: width, depth: depth,
                                     bottom: bottom, top: top, bevel: min(0.18, (top - bottom) * 0.24))
    }

    static func shell(_ source: [SIMD2<Double>], height: Double, id: Int, root: SCNNode) {
        let original = DioramaPolygon.counterClockwise(source.map { DV2($0.x, $0.y) }).map { SIMD2($0.x, $0.y) }
        let softened = BuildingContour.rounded(original, tangentDistance: DioramaConfig.slipway.cornerRadius, segments: 4)
        let ring = softened.map { DV2($0.x, $0.y) }
        let kit = DioramaBuildingKit(config: .slipway)
        let roofThickness = min(DioramaConfig.slipway.roofBevel, height * 0.18)
        var walls = DioramaMesh(), base = DioramaMesh(), crown = DioramaMesh()
        for edge in ring.indices {
            kit.wall(ring, edge: edge, z0: 0.2, z1: 0.65, .whitewash, into: &base)
            kit.wall(ring, edge: edge, z0: 0.65, z1: height - roofThickness / 2 - 0.3, .whitewash, into: &walls)
            kit.wall(ring, edge: edge, z0: height - roofThickness / 2 - 0.3, z1: height - roofThickness / 2, .whitewash, into: &crown)
        }
        walls.polygon(ring, z: 0.2, .whitewash, facingUp: false)
        func node(_ mesh: DioramaMesh, _ name: String, _ material: SCNMaterial) -> SCNNode {
            var packed = BuildingMesh(); packed.append(mesh)
            return packed.node(name: name, material: material)
        }
        guard roundedRoof(softened, thickness: roofThickness, shoulder: roofThickness,
            xStep: 5_000, yStep: 5_000, height: { _ in height }, name: "mappedAirportServiceRoof-\(id)", root: root,
            profileSegments: 3, roofMaterial: DarLandmarkParts.slate) != nil else { return }
        root.addChildNode(node(walls, "mappedAirportBuilding-\(id)", DarLandmarkParts.plaster))
        root.addChildNode(node(base, "airportServicePlinth-\(id)", DarLandmarkParts.trim))
        root.addChildNode(node(crown, "airportServiceCornice-\(id)", DarLandmarkParts.plaster))
        serviceWindows(original, height: height, root: root)
    }

    private static func serviceWindows(_ ring: [SIMD2<Double>], height: Double, root: SCNNode) {
        var panes = BuildingMesh(), frames = BuildingMesh()
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], length = simd_distance(a, b)
            guard length > 8 else { continue }
            let along = (b - a) / length, out = SIMD2(along.y, -along.x)
            // Quiet broad clerestories rather than treating every service shed as a glass terminal.
            let p = a + along * 2 + out * 0.025, q = b - along * 2 + out * 0.025
            let z = max(1.0, height - 2.5), top = min(height - 1.05, z + 1.25)
            guard top > z else { continue }
            panes.quad(DarLandmarkParts.p(p, z), DarLandmarkParts.p(q, z), DarLandmarkParts.p(q, top), DarLandmarkParts.p(p, top), normal: SIMD3(out.x, out.y, 0))
            for level in [z, top] {
                LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(p, level), to: DarLandmarkParts.p(q, level), radius: 0.10, sides: 6)
            }
        }
        root.addChildNode(panes.node(name: "airportServiceClerestory", material: HarbourArchitectureParts.glass))
        root.addChildNode(frames.node(name: "airportServiceWindowSurround", material: DarLandmarkParts.silver))
    }

    /// Closed roof skin with a continuous rolled edge, contained within the original plan.
    /// The inset must retain topology; awkward notches fall back to a sealed thin fascia.
    @discardableResult
    static func roundedRoof(_ ring: [SIMD2<Double>], thickness: Double, shoulder: Double,
                            xStep: Double, yStep: Double, height: (DV2) -> Double,
                            name: String, root: SCNNode, profileSegments: Int = 6,
                            roofMaterial: SCNMaterial = DarLandmarkParts.plaster) -> (ring: [SIMD2<Double>], heights: [Double])? {
        let polygon = DioramaPolygon.counterClockwise(ring.map { DV2($0.x, $0.y) })
        guard polygon.count >= 3, thickness > 0, profileSegments >= 3, profileSegments <= 12,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), DioramaPolygon.isSimple(polygon) else { return nil }
        let outer = polygon.map { SIMD2($0.x, $0.y) }
        var inner = polygon
        var hasShoulder = false
        for width in [shoulder, shoulder * 0.5, shoulder * 0.25] {
            if let candidate = DioramaPolygon.offset(polygon, by: -width), candidate.count == polygon.count,
               candidate.allSatisfy({ DioramaPolygon.contains(polygon, $0) }), DioramaPolygon.isSimple(candidate) {
                inner = candidate; hasShoulder = true; break
            }
        }
        var roof = BuildingMesh(), soffit = BuildingMesh(), rim = BuildingMesh()
        let bounds = DioramaRect.bounding(inner), triangles = DioramaPolygon.triangulate(inner)
        guard completeTriangulation(inner, triangles: triangles) else { return nil }
        let xGrid = max(1, xStep), yGrid = max(1, yStep)
        for x in stride(from: bounds.minX, to: bounds.maxX, by: max(1, xStep)) {
            for y in stride(from: bounds.minY, to: bounds.maxY, by: max(1, yStep)) {
                let cell = DioramaRect(minX: x, minY: y, maxX: min(bounds.maxX, x + xStep), maxY: min(bounds.maxY, y + yStep))
                for (a, b, c) in triangles {
                    let piece = clipRoofTriangle([inner[a], inner[b], inner[c]], to: cell)
                    guard piece.count >= 3, area(piece) > 0.0000001 else { continue }
                    let faces = DioramaPolygon.triangulate(piece)
                    guard completeTriangulation(piece, triangles: faces) else { return nil }
                    for (i, j, k) in faces {
                        let ps = [piece[i], piece[j], piece[k]].map { SIMD3($0.x, $0.y, height($0)) }
                        roof.triangle(ps[0], ps[1], ps[2])
                        let drop = SIMD3(0.0, 0.0, thickness)
                        soffit.triangle(ps[2] - drop, ps[1] - drop, ps[0] - drop)
                    }
                }
            }
        }
        let normals = BuildingContour.outwardNormals(outer)
        var edgeInner: [DV2] = [], edgeOuter: [SIMD2<Double>] = [], edgeNormals: [SIMD2<Double>] = []
        // Roof cells and rolled rim share every boundary/grid intersection, preventing
        // straight rims from cutting through the nonlinear umbrella/folded roof profile.
        for i in polygon.indices {
            let j = (i + 1) % polygon.count, a = inner[i], b = inner[j], delta = b - a
            var stops: [Double] = [0]
            for (start, end, origin, step) in [(a.x, b.x, bounds.minX, xGrid), (a.y, b.y, bounds.minY, yGrid)] where abs(end - start) > 0.000001 {
                let first = Int(floor((min(start, end) - origin) / step)) + 1
                let last = Int(ceil((max(start, end) - origin) / step))
                for index in first..<max(first, last) {
                    let t = (origin + Double(index) * step - start) / (end - start)
                    if t > 0.000001, t < 0.999999 { stops.append(t) }
                }
            }
            for t in stops.sorted() {
                edgeInner.append(a + delta * t)
                edgeOuter.append(outer[i] + (outer[j] - outer[i]) * t)
                let n = normals[i] + (normals[j] - normals[i]) * t
                edgeNormals.append(simd_length(n) > 0.000001 ? simd_normalize(n) : normals[i])
            }
        }
        for i in edgeInner.indices {
            let j = (i + 1) % edgeInner.count
            if hasShoulder {
                func sample(_ index: Int, _ angle: Double) -> (SIMD3<Double>, SIMD3<Double>) {
                    let inXY = SIMD2(edgeInner[index].x, edgeInner[index].y)
                    let xy = inXY + (edgeOuter[index] - inXY) * cos(angle)
                    let z = height(edgeInner[index]) - thickness / 2 + thickness / 2 * sin(angle)
                    let n = edgeNormals[index]
                    let width = max(0.01, simd_distance(inXY, edgeOuter[index]))
                    return (SIMD3(xy.x, xy.y, z), simd_normalize(SIMD3(n.x * cos(angle) / width, n.y * cos(angle) / width, sin(angle) / (thickness / 2))))
                }
                for step in 0..<profileSegments {
                    let a = -Double.pi / 2 + Double(step) * Double.pi / Double(profileSegments)
                    let b = -Double.pi / 2 + Double(step + 1) * Double.pi / Double(profileSegments)
                    let p = sample(i, a), q = sample(j, a), r = sample(j, b), s = sample(i, b)
                    rim.smoothQuad(p.0, q.0, r.0, s.0, normals: [p.1, q.1, r.1, s.1])
                }
            } else {
                rim.quad(DarLandmarkParts.p(edgeOuter[i], height(edgeInner[i]) - thickness), DarLandmarkParts.p(edgeOuter[j], height(edgeInner[j]) - thickness),
                         DarLandmarkParts.p(edgeOuter[j], height(edgeInner[j])), DarLandmarkParts.p(edgeOuter[i], height(edgeInner[i])))
            }
        }
        root.addChildNode(roof.node(name: name, material: roofMaterial))
        root.addChildNode(soffit.node(name: "terminalPaleSoffit", material: DarLandmarkParts.trim))
        root.addChildNode(rim.node(name: "continuousRoundedAirportRoofEdge", material: DarLandmarkParts.plaster))
        return (edgeOuter, edgeInner.map { height($0) - thickness / 2 })
    }

    /// Roof fillets must not use the terrain clipper's 8cm contour cleanup: it removes
    /// narrow boundary pieces and leaves pinholes in a finely rounded silhouette.
    private static func clipRoofTriangle(_ triangle: [DV2], to rect: DioramaRect) -> [DV2] {
        var result = triangle
        for (axis, boundary, sign) in [(0, rect.minX, 1.0), (0, rect.maxX, -1.0), (1, rect.minY, 1.0), (1, rect.maxY, -1.0)] {
            guard result.count >= 3 else { return [] }
            func value(_ p: DV2) -> Double { axis == 0 ? p.x : p.y }
            var output: [DV2] = []
            for index in result.indices {
                let current = result[index], previous = result[(index + result.count - 1) % result.count]
                let inside = (value(current) - boundary) * sign >= 0
                let wasInside = (value(previous) - boundary) * sign >= 0
                if inside != wasInside {
                    let t = (boundary - value(previous)) / (value(current) - value(previous))
                    output.append(previous + (current - previous) * t)
                }
                if inside { output.append(current) }
            }
            result = output
        }
        return result
    }

    private static func area(_ polygon: [DV2]) -> Double {
        abs(polygon.indices.reduce(0.0) { sum, i in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            return sum + a.x * b.y - b.x * a.y
        }) / 2
    }

    static func completeTriangulation(_ polygon: [DV2], triangles: [(Int, Int, Int)]) -> Bool {
        guard polygon.count >= 3, !triangles.isEmpty else { return false }
        let area = area(polygon)
        let covered = triangles.reduce(0.0) { sum, face in
            let a = polygon[face.0], b = polygon[face.1], c = polygon[face.2]
            return sum + abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        return area.isFinite && covered.isFinite && area > 0.0000001 && abs(area - covered) <= max(0.0001, area * 0.000001)
    }

    static func glazing(_ ring: [SIMD2<Double>], bottom: Double, top: Double, topHeights: [Double]? = nil, openingCentres: [SIMD2<Double>] = [], root: SCNNode) {
        guard ring.count >= 3, topHeights == nil || topHeights?.count == ring.count else { return }
        var glass = BuildingMesh(), frames = BuildingMesh(), piers = BuildingMesh()
        let ns = BuildingContour.outwardNormals(ring)
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], delta = b - a, length = simd_length(delta)
            guard length > 0.01 else { continue }
            let normal = simd_normalize(SIMD2(delta.y, -delta.x)), along = delta / length
            let za = topHeights?[i] ?? top, zb = topHeights?[(i + 1) % ring.count] ?? top
            let n0 = length < 1.2 ? ns[i] : normal, n1 = length < 1.2 ? ns[(i + 1) % ring.count] : normal
            let gates = openingCentres.filter { abs(simd_dot($0 - a, normal)) < 2.2 }
            var cuts: [Double] = [0, 1]
            for gate in gates {
                for offset in [-1.85, 1.85] {
                    let t = (simd_dot(gate - a, along) + offset) / length
                    if t > 0, t < 1 { cuts.append(t) }
                }
            }
            cuts.sort()
            for (t, u) in zip(cuts, cuts.dropFirst()) where u - t > 0.00001 {
                let p = a + delta * t, q = a + delta * u
                let na = simd_normalize(n0 + (n1 - n0) * t), nb = simd_normalize(n0 + (n1 - n0) * u)
                let highA = za + (zb - za) * t, highB = za + (zb - za) * u
                let gate = gates.contains { abs(simd_dot((p + q) / 2 - $0, along)) < 1.85 }
                func pane(_ low: Double, _ ha: Double, _ hb: Double) {
                    guard min(ha, hb) > low else { return }
                    glass.smoothQuad(DarLandmarkParts.p(p, low), DarLandmarkParts.p(q, low), DarLandmarkParts.p(q, hb), DarLandmarkParts.p(p, ha),
                        normals: [SIMD3(na.x, na.y, 0), SIMD3(nb.x, nb.y, 0), SIMD3(nb.x, nb.y, 0), SIMD3(na.x, na.y, 0)])
                }
                if gate { pane(bottom, min(5.7, highA), min(5.7, highB)); pane(8.93, highA, highB) }
                else { pane(bottom, highA, highB) }
            }
            // Model the large silver frames, not a flat painted grid. Short fillet segments
            // share the curved pane and continuous transoms instead of multiplying tiny posts.
            if length > 2 {
                let bays = max(1, Int(ceil(length / 5.2)))
                for bay in 0..<bays {
                    let t = (Double(bay) + 0.5) / Double(bays)
                    let p = a + delta * t - normal * 0.08
                    let atGate = gates.contains { abs(simd_dot(p - $0, along)) < 1.85 }
                    let high = za + (zb - za) * t
                    LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(p, bottom), to: DarLandmarkParts.p(p, atGate ? min(5.7, high) : high), radius: 0.18, sides: 8)
                }
            }
            for fraction in [0.0, 0.5, 1.0] {
                let p = a - normal * 0.08, q = b - normal * 0.08
                LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(p, bottom + (za - bottom) * fraction),
                                  to: DarLandmarkParts.p(q, bottom + (zb - bottom) * fraction), radius: 0.14, sides: 8)
            }
            if length > 8 {
                for station in stride(from: 6.0, to: length - 1, by: 21.0) {
                    let p = a + along * station - normal * 0.45
                    guard !gates.contains(where: { abs(simd_dot(p - $0, along)) < 2.1 }) else { continue }
                    let z = za + (zb - za) * (station / length)
                    LandmarkMesh.beam(&piers, from: DarLandmarkParts.p(p, bottom), to: DarLandmarkParts.p(p, z), radius: 0.38, sides: 12)
                }
            }
        }
        let material = BuildingSurfaces.make("landmark.panoramicGlass", color: "#417E86", roughness: 1)
        material.transparency = 0.065; material.metalness.contents = 0
        root.addChildNode(glass.node(name: "airportClearPanoramicPanes", material: material))
        root.addChildNode(frames.node(name: "airportSilverFacadeGrid", material: DarLandmarkParts.silver))
        root.addChildNode(piers.node(name: "terminalCreamStructuralPiers", material: DarLandmarkParts.plaster))
    }

    static let signBlue = BuildingSurfaces.make("airport.signBlue", color: "#216391", roughness: 0.8)
    static let roofSignBlue = BuildingSurfaces.make("airport.roofSignBlue", color: "#216391", roughness: 0.8)

    static func clearGlass(alpha: CGFloat = 0.065) -> SCNMaterial {
        let material = BuildingSurfaces.make("landmark.panoramicGlass", color: "#417E86", roughness: 1)
        material.transparency = alpha
        material.metalness.contents = 0
        return material
    }

    /// Fit real glyph bounds rather than assuming a width per character. Centre is the baseline.
    static func name(_ title: String, centre: SIMD3<Double>, facing: SIMD2<Double>, height: Double, root: SCNNode,
                     material: SCNMaterial = DarLandmarkParts.dark, maximumWidth: Double? = nil, depth: Double = 0) {
        if depth > 0 {
            AirportDimensionalSign.add(title, centre: centre, facing: facing, height: height, maximumWidth: maximumWidth, depth: depth, material: material, root: root)
            return
        }
        var lettering = DioramaMesh()
        DioramaLettering.line(title, centre: DV3(0, 0, 0), up: .up, facing: DV3(facing.x, facing.y, 0), height: height, swatch: .whitewash, mesh: &lettering)
        var mesh = BuildingMesh(); mesh.append(lettering)
        let right = SIMD2(facing.y, -facing.x)
        let extents = mesh.positions.map { Double($0.x) * right.x + Double($0.y) * right.y }
        let width = (extents.max() ?? 0) - (extents.min() ?? 0)
        let scale = maximumWidth.map { min(1, max(0, $0) / max(0.001, width)) } ?? 1
        let node = mesh.node(name: "airportWayfinding", material: material)
        node.simdScale = SIMD3(repeating: Float(scale))
        node.simdPosition = SIMD3(Float(centre.x), Float(centre.y), Float(centre.z))
        root.addChildNode(node)
    }
}
