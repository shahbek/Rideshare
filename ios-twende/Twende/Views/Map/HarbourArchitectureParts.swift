import SceneKit
import UIKit
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

    /// Storey the facade shader can express (2.60-4.15 m) that divides `span` into whole floors.
    static func facadeStorey(span: Double, rows: Int) -> (storey: Double, rows: Int) {
        var count = max(1, rows)
        let raw = span/Double(count)
        if raw > DioramaFacade.minimumStorey+DioramaFacade.storeyStep*31 { count = Int(ceil(span/4.15)) }
        else if raw < DioramaFacade.minimumStorey { count = max(1, Int(floor(span/DioramaFacade.minimumStorey))) }
        return (DioramaFacade.snapStorey(span/Double(count)), count)
    }

    /// The city's shader facade on a landmark ring: one quad per edge, openings, mullions, floor
    /// lines, reveals and night windows drawn by the fragment shader. Square corners are rounded by
    /// the shader; short edges (rounded contours) keep the ring's smooth normals and sharp flags.
    /// `lit` adds a sparse set of proud lit panes (2 triangles each) that bloom at night.
    static func facadeSkin(_ input: [SIMD2<Double>], bottom: Double, top: Double, storey: Double,
                           style: DioramaFacade.Style, color: String, root: SCNNode, name: String,
                           lit: Bool = false, litBay: Double = 3.4) {
        typealias P = DarLandmarkParts
        guard input.count >= 3, top > bottom+0.1 else { return }
        let ring = ccw(input)
        let n = ring.count
        let smooth = BuildingContour.outwardNormals(ring)
        func roundable(_ corner: Int) -> Bool {
            let incoming = ring[corner]-ring[(corner+n-1)%n], outgoing = ring[(corner+1)%n]-ring[corner]
            guard simd_length(incoming) > 0.3, simd_length(outgoing) > 0.3 else { return false }
            let p = simd_normalize(incoming), q = simd_normalize(outgoing)
            return p.x*q.y-p.y*q.x > 0.5 && abs(simd_dot(p,q)) < 0.6
        }
        let snapped = DioramaFacade.snapStorey(storey)
        var walls = BuildingMesh(), panes = BuildingMesh()
        for i in ring.indices {
            let j = (i+1)%n, a = ring[i], b = ring[j], d = b-a, length = simd_length(d)
            guard length > 0.05 else { continue }
            let flat = SIMD2(d.y,-d.x)/length
            let short = length < 1.2
            let flags = (short || !roundable(i) ? 1 : 0)+(short || !roundable(j) ? 2 : 0)
            walls.facadeQuad(a,b,bottom:bottom,top:top,normals:short ? smooth[i] : flat,short ? smooth[j] : flat,flags:flags)
            guard lit, length > 3 else { continue }
            let rows = Int((top-bottom)/snapped), bays = max(1,Int(ceil(length/litBay)))
            for row in 0..<rows {
                for bay in 0..<bays where (bay+row*5+i)%17 == 2 {
                    let p = a+d*((Double(bay)+0.12)/Double(bays))+flat*0.04, q = a+d*((Double(bay)+0.88)/Double(bays))+flat*0.04
                    let low = bottom+Double(row)*snapped+0.5, high = bottom+Double(row+1)*snapped-0.15
                    panes.quad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normal:P.p(flat,0))
                }
            }
        }
        let material = BuildingSurfaces.make("landmark.facade|\(style.rawValue)|\(snapped)|0|\(bottom)",color:color,roughness:0.85)
        root.addChildNode(walls.node(name:name,material:material))
        if lit { root.addChildNode(panes.node(name:"occupiedHarbourWindows",material:LandmarkLightingGeometry.window)) }
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

    /// Curtain wall as a shader facade (glass tint from the pane material) plus light geometry for
    /// what reads at map scale: one sill ledge per storey and edge, and slim mullion fins per bay.
    static func curtain(_ ring: [SIMD2<Double>], bottom: Double, top: Double, rows: Int, bayWidth: Double,
                        root: SCNNode, occupied: Bool = true, creamSills: Bool = false, drawsSills: Bool = true,
                        paneMaterial: SCNMaterial? = nil, alternateMaterial: SCNMaterial? = nil) {
        typealias P = DarLandmarkParts
        let ring = ccw(ring)
        let (storey, count) = facadeStorey(span: top-bottom, rows: rows)
        let tint = (paneMaterial ?? glass).diffuse.contents as? UIColor ?? .darkGray
        facadeSkin(ring, bottom: bottom, top: top, storey: storey, style: .curtain, color: hex(tint),
                   root: root, name: "curtainGlass", lit: occupied, litBay: bayWidth)
        var frames = BuildingMesh()
        if drawsSills {
            let step = (top-bottom)/Double(count)
            for row in 1...count {
                ledge(&frames, ring: ring, z: bottom+Double(row)*step-(creamSills ? 0.32 : 0.16),
                      height: creamSills ? 0.32 : 0.16, reach: creamSills ? 0.3 : 0.14)
            }
        }
        for i in ring.indices {
            let a = ring[i], b = ring[(i+1)%ring.count], d = b-a, length = simd_length(d)
            guard length > 2 else { continue }
            let n = SIMD2(d.y,-d.x)/length
            let bays = max(1, Int(ceil(length/bayWidth)))
            for bay in 0..<bays {
                fin(&frames, at: a+d*(Double(bay)/Double(bays)), outward: n, bottom: bottom, top: top, width: 0.22, depth: 0.16)
            }
        }
        root.addChildNode(frames.node(name:"harbourClosedMullions",material:creamSills ? P.plaster : P.silver))
        root.addChildNode(BuildingFootprint(rings:[ring]).deck(at:top-0.25,thickness:0.25,material:P.plaster,name:"closedHarbourRoof"))
    }

    /// Counter-clockwise copy (outward is to the right of travel).
    static func ccw(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var area = 0.0
        for i in ring.indices { let a = ring[i], b = ring[(i+1)%ring.count]; area += a.x*b.y-a.y*b.x }
        return area < 0 ? Array(ring.reversed()) : ring
    }

    static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r*255).rounded()), Int((g*255).rounded()), Int((b*255).rounded()))
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
