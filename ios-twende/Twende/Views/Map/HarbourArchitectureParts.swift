import SceneKit
import simd

/// Bounded explicit-mesh facade vocabulary using the existing Slipway kit and landmark materials.
enum HarbourArchitectureParts {
    static let glass = BuildingSurfaces.make("harbour.tealGlass", color: "#326A72", roughness: 0.72)
    static let lightGlass = BuildingSurfaces.make("harbour.lightGlass", color: "#417E86", roughness: 0.72)
    static let louvre = BuildingSurfaces.make("harbour.podiumLouvre", color: "#30494E", roughness: 0.95)

    static func bounds(_ ring: [SIMD2<Double>]) -> SIMD4<Double> {
        SIMD4(ring.map(\.x).min() ?? 0, ring.map(\.y).min() ?? 0,
              ring.map(\.x).max() ?? 0, ring.map(\.y).max() ?? 0)
    }

    static func inset(_ ring: [SIMD2<Double>], by distance: Double) -> [SIMD2<Double>] {
        let polygon = ring.map { DV2($0.x, $0.y) }
        guard let result = DioramaPolygon.offset(polygon, by: -distance), result.count >= 3,
              result.allSatisfy({ DioramaPolygon.contains(polygon, $0) }) else { return [] }
        return result.map { SIMD2($0.x, $0.y) }
    }

    static func box(_ mesh: inout BuildingMesh, x: Double, y: Double, width: Double, depth: Double,
                    bottom: Double, top: Double, bevel: Double = 0.18) {
        guard width > 0, depth > 0, top > bottom else { return }
        var kit = DioramaMesh()
        kit.box(centre: DV2(x,y), z0: bottom, halfLength: width/2, halfWidth: depth/2,
                height: top-bottom, .whitewash, bevel: min(bevel, min(width,depth)*0.2), bottom: false)
        mesh.append(kit)
    }

    static func ribbon(_ mesh: inout BuildingMesh, ring: [SIMD2<Double>], z: Double, height: Double, reach: Double = 0.24) {
        // Three profile steps; the analytic normals still shade the band as a full round.
        mesh.perimeter(rings: [ring], bottom: z, top: z+height, projection: reach, profileSegments: 3)
    }

    /// Remove only redundant convex samples, bounding every original point's distance to its replacement edge.
    static func compactContour(_ ring: [SIMD2<Double>], error: Double = 0.06) -> [SIMD2<Double>] {
        guard ring.count > 4, error > 0 else { return ring }
        var kept = Array(ring.indices)
        var changed = true
        while changed && kept.count > 4 {
            changed = false
            for position in kept.indices {
                let previous = kept[(position+kept.count-1)%kept.count]
                let current = kept[position], next = kept[(position+1)%kept.count]
                let a = ring[previous], p = ring[current], b = ring[next]
                let incoming = p-a, outgoing = b-p, delta = b-a
                guard incoming.x*outgoing.y-incoming.y*outgoing.x >= 0,
                      simd_dot(incoming,outgoing) > 0, simd_length_squared(delta) > 0.0001 else { continue }
                var sample = (previous+1)%ring.count, canRemove = true
                while sample != next {
                    let t = max(0,min(1,simd_dot(ring[sample]-a,delta)/simd_length_squared(delta)))
                    if simd_distance(ring[sample],a+delta*t) > error { canRemove = false; break }
                    sample = (sample+1)%ring.count
                }
                if canRemove { kept.remove(at:position); changed = true; break }
            }
        }
        return kept.map { ring[$0] }
    }

    enum PaneKind { case pane, alternate, lit }

    /// The approved pigment glazing (flat glass cells coloured by a pattern, lit cells glowing at
    /// night) at a fraction of the vertices: cells of the same kind stacked in one bay column are
    /// a single tall quad, so a column only splits where a lit window interrupts it. Same cells,
    /// same colours, same smooth normals as the per-cell original; typically 3-6x fewer quads.
    static func glazing(_ ring: [SIMD2<Double>], bottom: Double, top: Double, rows: Int, bayWidth: Double,
                        minimumEdge: Double = 0.01, pattern: (_ edge: Int, _ bay: Int, _ row: Int, _ length: Double) -> PaneKind,
                        panes: inout BuildingMesh, alternate: inout BuildingMesh, lit: inout BuildingMesh) {
        typealias P = DarLandmarkParts
        guard ring.count >= 3, rows > 0, top > bottom else { return }
        let normals = BuildingContour.outwardNormals(ring), storey = (top-bottom)/Double(rows)
        for i in ring.indices {
            let j = (i+1)%ring.count, a = ring[i], delta = ring[j]-a, length = simd_length(delta)
            guard length > minimumEdge else { continue }
            let bays = max(1, Int(ceil(length/bayWidth)))
            for bay in 0..<bays {
                let t = Double(bay)/Double(bays), u = Double(bay+1)/Double(bays)
                let p = a+delta*t, q = a+delta*u
                let na = simd_normalize(normals[i]*(1-t)+normals[j]*t)
                let nb = simd_normalize(normals[i]*(1-u)+normals[j]*u)
                let ns = [P.p(na,0),P.p(nb,0),P.p(nb,0),P.p(na,0)]
                var start = 0, kind = pattern(i, bay, 0, length)
                for row in 1...rows {
                    let next: PaneKind? = row < rows ? pattern(i, bay, row, length) : nil
                    guard next != kind else { continue }
                    let low = bottom+Double(start)*storey, high = bottom+Double(row)*storey
                    switch kind {
                    case .pane: panes.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    case .alternate: alternate.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    case .lit: lit.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    }
                    if let next { start = row; kind = next }
                }
            }
        }
    }

    /// Projecting band seen from the street and the sky only: a front face and a lid (4 triangles
    /// per edge, no soffit or ends), smooth across the ring's corners.
    static func ledge(_ mesh: inout BuildingMesh, ring input: [SIMD2<Double>], z: Double, height: Double, reach: Double) {
        typealias P = DarLandmarkParts
        let ring = ccw(input)
        let normals = BuildingContour.outwardNormals(ring)
        for i in ring.indices {
            let j = (i+1)%ring.count
            guard simd_distance(ring[i],ring[j]) > 0.02 else { continue }
            let a = ring[i]+normals[i]*reach, b = ring[j]+normals[j]*reach
            mesh.smoothQuad(P.p(a,z),P.p(b,z),P.p(b,z+height),P.p(a,z+height),normals:[P.p(normals[i],0),P.p(normals[j],0),P.p(normals[j],0),P.p(normals[i],0)])
            let up = SIMD3<Double>(0,0,1)
            mesh.smoothQuad(P.p(a,z+height),P.p(b,z+height),P.p(ring[j],z+height),P.p(ring[i],z+height),normals:[up,up,up,up])
        }
    }

    /// Vertical fin: front and both cheeks, open top and bottom (6 triangles).
    static func fin(_ mesh: inout BuildingMesh, at p: SIMD2<Double>, outward n: SIMD2<Double>, bottom: Double, top: Double,
                    width: Double, depth: Double) {
        typealias P = DarLandmarkParts
        let t = SIMD2(-n.y,n.x)*(width/2)
        let a = p-t, b = p+t, fa = a+n*depth, fb = b+n*depth
        mesh.quad(P.p(fb,bottom),P.p(fa,bottom),P.p(fa,top),P.p(fb,top),normal:P.p(n,0))
        mesh.quad(P.p(b,bottom),P.p(fb,bottom),P.p(fb,top),P.p(b,top),normal:P.p(simd_normalize(t),0))
        mesh.quad(P.p(fa,bottom),P.p(a,bottom),P.p(a,top),P.p(fa,top),normal:P.p(-simd_normalize(t),0))
    }

    /// Curtain wall in the approved pigment look: glass cells alternating two tints by bay column,
    /// occupied windows lit at night (about one cell in seven), one sill per storey and a mullion
    /// at every bay. Columns are merged quads (`glazing`); sills are open ledges and mullions open
    /// fins on exactly the original sill and mullion lines, so nothing overlaps or doubles up.
    static func curtain(_ ring: [SIMD2<Double>], bottom: Double, top: Double, rows: Int, bayWidth: Double,
                        root: SCNNode, occupied: Bool = true, creamSills: Bool = false, drawsSills: Bool = true,
                        paneMaterial: SCNMaterial? = nil, alternateMaterial: SCNMaterial? = nil) {
        var panes = BuildingMesh(), alternate = BuildingMesh(), lit = BuildingMesh(), frames = BuildingMesh()
        glazing(ring, bottom: bottom, top: top, rows: rows, bayWidth: bayWidth, pattern: { i, bay, row, length in
            if occupied && length > 3 && (bay+row*5+i)%7 == 2 { return .lit }
            return (bay+i)%3 == 0 ? .alternate : .pane
        }, panes: &panes, alternate: &alternate, lit: &lit)
        root.addChildNode(panes.node(name:"curtainGlass",material:paneMaterial ?? glass))
        root.addChildNode(alternate.node(name:"curtainGlass",material:alternateMaterial ?? lightGlass))
        root.addChildNode(lit.node(name:"occupiedHarbourWindows",material:LandmarkLightingGeometry.window))
        let outward = ccw(ring)
        let storey = (top-bottom)/Double(rows)
        if drawsSills {
            let r = creamSills ? 0.20 : 0.10
            for row in 1...rows {
                ledge(&frames, ring: outward, z: bottom+Double(row)*storey-r, height: r*2, reach: 0.10+r)
            }
        }
        for i in outward.indices {
            let a = outward[i], b = outward[(i+1)%outward.count], d = b-a, length = simd_length(d)
            guard length > 2 else { continue }
            let n = SIMD2(d.y,-d.x)/length
            let bays = max(1, Int(ceil(length/bayWidth)))
            for bay in 0..<bays {
                fin(&frames, at: a+d*(Double(bay)/Double(bays)), outward: n, bottom: bottom, top: top, width: 0.24, depth: 0.22)
            }
        }
        root.addChildNode(frames.node(name:"harbourClosedMullions",material:creamSills ? DarLandmarkParts.plaster : DarLandmarkParts.silver))
        root.addChildNode(BuildingFootprint(rings:[ring]).deck(at:top-0.25,thickness:0.25,material:DarLandmarkParts.plaster,name:"closedHarbourRoof"))
    }

    /// Counter-clockwise copy (outward is to the right of travel).
    static func ccw(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var area = 0.0
        for i in ring.indices { let a = ring[i], b = ring[(i+1)%ring.count]; area += a.x*b.y-a.y*b.x }
        return area < 0 ? Array(ring.reversed()) : ring
    }

    /// Last human-readable rejection, surfaced in Settings so a missing tower names its actual cause.
    static var lastRejection: String = ""

    /// Reject partial compositions and geometry outside the researched site before native ownership changes.
    static func validate(_ scene: SCNScene, site: DarLandmarkSite, airportData: AirportMapData? = nil) -> Int? {
        guard let ring = site.footprint?.rings.first else { return nil }
        let polygons: [[DV2]]
        if site.kind == "airport" {
            guard let airportData, airportData.site.id == site.id else { return nil }
            polygons = airportData.validationRings(origin: site.anchor.coordinate)
        } else { polygons = [ring.map { DV2($0.x,$0.y) }] }
        guard !polygons.isEmpty, polygons.allSatisfy({ $0.count >= 3 }) else { return nil }
        var triangles = 0, isValid = true, names: Set<String> = [], checked: Set<SIMD2<Float>> = []
        var rejection: String?
        func reject(_ reason: String) { isValid = false; if rejection == nil { rejection = reason } }
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let count = geometry.elements.reduce(0) { $0+$1.primitiveCount }
            guard count > 0 else { return }
            if let name = node.name { names.insert(name) }
            triangles += count
            // The airport campus is exempt from performance admission at the user's direction.
            // Still count its geometry and validate mapped bounds, heights and completeness.
            // Harbour towers are a bounded sanity ceiling, not a shared-allowance admission.
            if site.kind != "airport", triangles > 120_000 {
                reject("source triangle limit")
                return
            }
            guard let source = geometry.sources(for:.vertex).first,
                  source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3 else { reject("unsupported vertex layout"); return }
            let matrix = node.simdWorldTransform
            source.data.withUnsafeBytes { bytes in
                for vertex in 0..<source.vectorCount {
                    let offset = source.dataOffset+vertex*source.dataStride
                    guard offset >= 0, offset+12 <= bytes.count else { reject("truncated vertex data"); return }
                    let p = matrix*SIMD4(bytes.loadUnaligned(fromByteOffset:offset,as:Float.self),
                        bytes.loadUnaligned(fromByteOffset:offset+4,as:Float.self),
                        bytes.loadUnaligned(fromByteOffset:offset+8,as:Float.self),1)
                    guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.z >= -0.1, p.z <= Float(site.height)+1.0 else { reject("\(node.name ?? "mesh") height/nonfinite vertex"); return }
                    let xy = SIMD2(p.x,p.y)
                    guard checked.insert(xy).inserted else { continue }
                    let q = DV2(Double(p.x),Double(p.y))
                    if !polygons.contains(where: { DioramaPolygon.contains($0, q) || DioramaPolygon.distanceToRing($0, q) <= 0.9 }) {
                        let distance = polygons.map { DioramaPolygon.distanceToRing($0, q) }.min() ?? .infinity
                        reject("\(node.name ?? "mesh") outside mapped site at \(q.x),\(q.y), distance=\(distance)m")
                        return
                    }
                }
            }
        }
        let required: Set<String>
        if site.kind == "airport" {
            required = ["airportPaintedGround", "terminal3FoldedSailRoof", "terminal3ContinuousSideRoofShell", "terminal2UmbrellaRoof", "terminal1Roof", "openSidedWalkwayCanopy",
                        "terminal3UpperDepartureFloor", "terminal3CircularDoorDrumCap", "terminal2AirsideMezzanineAndBridgeLandings",
                        "airportJoinedBoardingBridgeFloor", "airportJoinedBoardingBridgeRoof", "airportControlTowerRoof"]
        } else if site.kind == "johari-rotana" {
            required = ["johariLatticeSpire0", "johariLatticeSpire1", "johariRooftopPoolWater"]
        } else {
            required = ["bandariFullHeightGoldCore", "bandariOpenWhiteArchCrown", "bandariContinuousCurvedPodiumSail"]
        }
        let missing = required.subtracting(names)
        guard isValid, triangles > 0, missing.isEmpty else {
            lastRejection = "\(rejection ?? "incomplete composition")\(missing.isEmpty ? "" : " missing " + missing.sorted().joined(separator: ",")), triangles=\(triangles)"
            #if DEBUG
            print("[DarLandmarks] \(site.id) rejected: \(rejection ?? "incomplete composition"), triangles=\(triangles), missing=\(missing.sorted().joined(separator: ","))")
            #endif
            return nil
        }
        return triangles
    }

    /// A fitted candidate may not bridge a concavity or leave its mapped host.
    static func fits(_ candidate: [SIMD2<Double>], inside ring: [SIMD2<Double>], clearance: Double = 0.15) -> Bool {
        let polygon = ring.map { DV2($0.x,$0.y) }
        return candidate.count >= 3 && candidate.indices.allSatisfy { i in
            let a = candidate[i], b = candidate[(i+1)%candidate.count]
            return (0...8).allSatisfy { step in
                let p = a+(b-a)*(Double(step)/8), q = DV2(p.x,p.y)
                return DioramaPolygon.contains(polygon,q) && DioramaPolygon.distanceToRing(polygon,q) >= clearance
            }
        }
    }
}
