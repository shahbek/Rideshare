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
                height: top-bottom, .whitewash, bevel: min(bevel, min(width,depth)*0.2), bottom: true)
        mesh.append(kit)
    }

    static func ribbon(_ mesh: inout BuildingMesh, ring: [SIMD2<Double>], z: Double, height: Double, reach: Double = 0.24) {
        mesh.perimeter(rings: [ring], bottom: z, top: z+height, projection: reach, profileSegments: 6)
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

    static func curtain(_ ring: [SIMD2<Double>], bottom: Double, top: Double, rows: Int, bayWidth: Double,
                        root: SCNNode, occupied: Bool = true, creamSills: Bool = false, drawsSills: Bool = true,
                        paneMaterial: SCNMaterial? = nil, alternateMaterial: SCNMaterial? = nil) {
        typealias P = DarLandmarkParts
        var panes = BuildingMesh(), alternate = BuildingMesh(), lit = BuildingMesh(), frames = BuildingMesh()
        let normals = BuildingContour.outwardNormals(ring)
        let storey = (top-bottom)/Double(rows)
        for i in ring.indices {
            let a = ring[i], b = ring[(i+1)%ring.count], d = b-a, length = simd_length(d)
            guard length > 0.01 else { continue }
            let n = simd_normalize(SIMD2(d.y,-d.x))
            let bays = max(1, Int(ceil(length/bayWidth)))
            if drawsSills && length > 2 {
                // One continuous sill per edge/storey, not separately capped copies for every glass bay.
                for row in 1...rows {
                    let z = bottom+Double(row)*storey
                    LandmarkMesh.beam(&frames,from:P.p(a+n*0.10,z),to:P.p(b+n*0.10,z),radius:creamSills ? 0.20 : 0.10,sides:6)
                }
            }
            for bay in 0..<bays {
                let t = Double(bay)/Double(bays), u = Double(bay+1)/Double(bays)
                let p = a+d*t, q = a+d*u
                let na = simd_normalize(normals[i]*(1-t)+normals[(i+1)%ring.count]*t)
                let nb = simd_normalize(normals[i]*(1-u)+normals[(i+1)%ring.count]*u)
                let ns = [P.p(na,0),P.p(nb,0),P.p(nb,0),P.p(na,0)]
                for row in 0..<rows {
                    let low = bottom+Double(row)*storey, high = low+storey
                    if occupied && length > 3 && (bay+row*5+i)%17 == 2 {
                        lit.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    } else if (bay+i)%3 == 0 {
                        alternate.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    } else {
                        panes.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    }
                }
                if length > 2 {
                    LandmarkMesh.beam(&frames,from:P.p(p+n*0.10,bottom),to:P.p(p+n*0.10,top),radius:0.12,sides:6)
                }
            }
        }
        root.addChildNode(panes.node(name:"curtainGlass",material:paneMaterial ?? glass))
        root.addChildNode(alternate.node(name:"curtainGlass",material:alternateMaterial ?? lightGlass))
        root.addChildNode(lit.node(name:"occupiedHarbourWindows",material:LandmarkLightingGeometry.window))
        root.addChildNode(frames.node(name:"harbourClosedMullions",material:creamSills ? P.plaster : P.silver))
        root.addChildNode(BuildingFootprint(rings:[ring]).deck(at:top-0.25,thickness:0.25,material:P.plaster,name:"closedHarbourRoof"))
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
