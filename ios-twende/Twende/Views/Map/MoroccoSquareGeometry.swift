import SceneKit
import simd

/// Four separately authored towers on mapped anchors, joined by the render-led retail podium.
enum MoroccoSquareGeometry {
    private static let glass = BuildingSurfaces.make("morocco.blueGlass", color: "#417E86", roughness: 0.75)
    private static let inkGlass = BuildingSurfaces.make("morocco.recessedGlass", color: "#30494E", roughness: 0.8)
    private static let screen = BuildingSurfaces.make("morocco.mallScreen", color: "#C9C2B6", roughness: 0.9)
    private static let roof = BuildingSurfaces.make("morocco.roof", color: "#BFCBCB", roughness: 1)
    private static let podiumTop = 8.6

    static func make(_ site: DarLandmarkSite) -> SCNScene {
        let scene = SCNScene()
        guard let data = MoroccoSquareData.bundled, let raw = site.footprint?.rings.first else { return scene }
        let root = SCNNode(); root.name = "moroccoSquare"
        scene.rootNode.addChildNode(root)
        let envelope = BuildingContour.rounded(raw, tangentDistance: 1.6, segments: 6)
        podium(envelope, root: root)
        var occupied: [[SIMD2<Double>]] = []
        for tower in data.towers {
            let source = MoroccoSquareData.local(tower.upperRing ?? tower.ring, origin: site.anchor.coordinate)
            guard source.count >= 3 else { continue }
            let ring = BuildingContour.rounded(source, tangentDistance: 0.8, segments: 6)
            occupied.append(ring)
            if tower.kind == "office" { office(tower, ring: ring, root: root) }
            else { accommodation(tower, ring: ring, root: root) }
            if tower.id == "exchange" { MoroccoLEDGeometry.add(ring: ring, root: root) }
        }
        // The atrium is a render-guided roof lantern inside the connecting mall, not a fifth tower.
        let projection = DioramaProjection(origin: site.anchor.coordinate)
        let atrium = projection.local(longitude: data.atrium[0], latitude: data.atrium[1])
        let xy = SIMD2(atrium.x, atrium.y)
        if BuildingFootprint(rings: [envelope]).path.contains(CGPoint(x: xy.x, y: xy.y)),
           !occupied.contains(where: { BuildingFootprint(rings: [$0]).path.contains(CGPoint(x: xy.x, y: xy.y)) }) {
            lantern(at: xy, root: root)
        }
        roofTerrace(envelope: envelope, occupied: occupied, atrium: xy, root: root)
        return scene
    }

    private static func podium(_ ring: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        root.addChildNode(BuildingFootprint(rings: [ring]).deck(at: 0.2, thickness: 0.3,
            material: P.plaster, name: "connectedRetailMallFloor"))
        root.addChildNode(BuildingFootprint(rings: [ring]).deck(at: podiumTop - 0.65, thickness: 0.65,
            material: roof, name: "continuousMallRoofTerrace"))
        var glazing = BuildingMesh(), columns = BuildingMesh(), louvres = BuildingMesh(), panels = BuildingMesh()
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], d = b - a, length = simd_length(d)
            let n = simd_normalize(SIMD2(d.y, -d.x))
            glazing.quad(P.p(a - n * 2.0, 0.6), P.p(b - n * 2.0, 0.6), P.p(b - n * 2.0, 7.8), P.p(a - n * 2.0, 7.8))
            guard length > 3 else { continue }
            let bays = max(1, Int(ceil(length / 5.8)))
            for bay in 0..<bays {
                let p = a + d * (Double(bay) / Double(bays)), q = a + d * (Double(bay + 1) / Double(bays))
                LandmarkMesh.beam(&columns, from: P.p(p, 0.2), to: P.p(p, podiumTop - 0.5), radius: 0.25, sides: 8)
                // Broad alternating screened and glazed mezzanine bays echo the rendered curved mall.
                if bay % 3 != 0 {
                    panels.quad(P.p(p, 4.6), P.p(q, 4.6), P.p(q, 7.8), P.p(p, 7.8))
                    for fraction in [0.25, 0.5, 0.75] {
                        let c = p + (q - p) * fraction + n * 0.10
                        LandmarkMesh.beam(&louvres, from: P.p(c, 4.85), to: P.p(c, 7.55), radius: 0.085, sides: 6)
                    }
                } else {
                    for fraction in [0.0, 0.5] {
                        let c = p + (q - p) * fraction + n * 0.05
                        LandmarkMesh.beam(&louvres, from: P.p(c, 0.5), to: P.p(c, 7.8), radius: 0.10, sides: 8)
                    }
                }
            }
        }
        root.addChildNode(glazing.node(name: "curtainGlass", material: inkGlass))
        root.addChildNode(columns.node(name: "mallArcadePiers", material: P.plaster))
        root.addChildNode(panels.node(name: "mallPerforatedScreenBays", material: screen))
        root.addChildNode(louvres.node(name: "mallScreenRibs", material: P.silver))
        ribbon(ring, z: 4.45, height: 0.3, projection: 0.18, material: P.plaster, name: "mallMezzanineBelt", root: root)
        ribbon(ring, z: podiumTop, height: 0.35, projection: 0.16, material: P.plaster, name: "mallRoundedCornice", root: root)
    }

    private static func office(_ tower: MoroccoSquareData.Tower, ring: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        let storey = (tower.height - podiumTop - 2.1) / Double(tower.floors - 2)
        P.volume(inset(ring, 0.65), bottom: podiumTop, top: tower.height - 1.8, material: inkGlass, name: "\(tower.id)RecessedCore", root: root)
        var panes = BuildingMesh(), lit = BuildingMesh(), mullions = BuildingMesh(), infill = BuildingMesh()
        for level in 0..<(tower.floors - 2) {
            let z = podiumTop + Double(level) * storey
            ribbon(ring, z: z, height: 0.78, projection: 0.34, material: P.plaster, name: "\(tower.id)ContinuousCreamRibbon", root: root)
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count], d = b - a, length = simd_length(d)
                let n = simd_normalize(SIMD2(d.y, -d.x)), recess = n * 0.12
                let count = max(1, Int(ceil(length / 5.5)))
                for bay in 0..<count {
                    let p = a + d * (Double(bay) / Double(count)) - recess
                    let q = a + d * (Double(bay + 1) / Double(count)) - recess
                    if length > 5 && (level * 7 + bay + i) % 9 == 2 {
                        lit.quad(P.p(p,z+0.82),P.p(q,z+0.82),P.p(q,z+storey-0.1),P.p(p,z+storey-0.1))
                    } else {
                        panes.quad(P.p(p,z+0.82),P.p(q,z+0.82),P.p(q,z+storey-0.1),P.p(p,z+storey-0.1))
                    }
                    if length > 5 {
                        LandmarkMesh.beam(&mullions, from: P.p(p,z+0.8), to: P.p(p,z+storey), radius: 0.075, sides: 6)
                        // Irregular cream spandrel runs, not a generic repeated square-window grid.
                        if (bay + level * 2 + i) % 7 < 2 {
                            infill.quad(P.p(p+n*0.14,z+0.82),P.p(q+n*0.14,z+0.82),P.p(q+n*0.14,z+1.30),P.p(p+n*0.14,z+1.30))
                        }
                    }
                }
            }
        }
        root.addChildNode(panes.node(name: "curtainGlass", material: glass))
        root.addChildNode(lit.node(name: "occupiedOfficeWindows", material: LandmarkLightingGeometry.window))
        root.addChildNode(mullions.node(name: "officeSilverMullions", material: P.silver))
        root.addChildNode(infill.node(name: "offsetCreamSpandrels", material: P.plaster))
        roofCrown(tower, ring: ring, root: root)
    }

    private static func accommodation(_ tower: MoroccoSquareData.Tower, ring: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        let top = tower.height - 2.0, rows = tower.floors - 2
        let storey = (top - podiumTop) / Double(rows)
        P.volume(inset(ring, 0.75), bottom: podiumTop, top: top, material: P.plaster, name: "\(tower.id)MasonrySpine", root: root)
        var bays = BuildingMesh(), lit = BuildingMesh(), piers = BuildingMesh(), gold = BuildingMesh(), rails = BuildingMesh()
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], d = b - a, length = simd_length(d)
            guard length > 3 else { continue }
            let n = simd_normalize(SIMD2(d.y, -d.x)), count = max(1, Int(length / 4.5))
            let broad = length > 22
            for bay in 0..<count {
                let p = a + d * ((Double(bay)+0.12)/Double(count)), q = a + d * ((Double(bay)+0.88)/Double(count))
                LandmarkMesh.beam(&piers, from: P.p(a+d*(Double(bay)/Double(count)),podiumTop),
                    to: P.p(a+d*(Double(bay)/Double(count)),top), radius: 0.22, sides: 8)
                for row in 0..<rows {
                    let z = podiumTop + Double(row) * storey
                    let low = z + (broad ? 0.55 : 1.1), high = z + storey - 0.55
                    let panelP = p - n * 0.3, panelQ = q - n * 0.3
                    if (bay + row * 3) % 11 == 1 {
                        lit.quad(P.p(panelP,low),P.p(panelQ,low),P.p(panelQ,high),P.p(panelP,high))
                    } else {
                        bays.quad(P.p(panelP,low),P.p(panelQ,low),P.p(panelQ,high),P.p(panelP,high))
                    }
                    if tower.kind == "hotel" && !broad && (row + bay) % 3 != 0 {
                        gold.quad(P.p(p,z+0.15),P.p(q,z+0.15),P.p(q,z+0.95),P.p(p,z+0.95))
                    }
                    if broad {
                        LandmarkMesh.beam(&rails, from: P.p(p+n*0.12,z+1.05), to: P.p(q+n*0.12,z+1.05), radius: 0.10, sides: 8)
                    }
                }
            }
        }
        for row in 0...rows {
            ribbon(ring, z: podiumTop+Double(row)*storey, height: 0.34, projection: 0.28,
                material: P.plaster, name: "\(tower.id)GallerySlab", root: root)
        }
        root.addChildNode(bays.node(name: "curtainGlass", material: inkGlass))
        root.addChildNode(lit.node(name: "occupiedRoomWindows", material: LandmarkLightingGeometry.window))
        root.addChildNode(piers.node(name: "creamGalleryPiers", material: P.plaster))
        root.addChildNode(gold.node(name: "hotelChampagnePanels", material: P.gold))
        root.addChildNode(rails.node(name: "recessedBalconyRails", material: P.silver))
        roofCrown(tower, ring: ring, root: root)
    }

    private static func roofCrown(_ tower: MoroccoSquareData.Tower, ring: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        root.addChildNode(BuildingFootprint(rings: [ring]).deck(at: tower.height-1.9, thickness: 0.3, material: roof, name: "\(tower.id)FlatRoof"))
        let innerParapet = inset(ring, 0.5)
        root.addChildNode(BuildingFootprint(rings: [ring, Array(innerParapet.reversed())]).deck(at: tower.height-1.6,
            thickness: 1.4, material: P.plaster, name: "\(tower.id)ClosedRoofParapet"))
        ribbon(ring, z: tower.height-0.3, height: 0.2, projection: 0.16, material: P.plaster, name: "\(tower.id)RoundedParapetCap", root: root)
        let core = inset(ring, tower.kind == "office" ? 5.2 : 2.4)
        let centre = core.reduce(SIMD2<Double>.zero,+)/Double(core.count)
        if tower.kind == "apartments", let edge = core.indices.max(by: {
            simd_distance(core[$0],core[($0+1)%core.count]) < simd_distance(core[$1],core[($1+1)%core.count])
        }) {
            let direction = simd_normalize(core[(edge+1)%core.count]-core[edge])
            let normal = SIMD2(-direction.y,direction.x)
            let length = simd_distance(core[edge],core[(edge+1)%core.count])
            let footprint = BuildingFootprint(rings: [core])
            for fraction in [-0.28,0.0,0.28] {
                let c = centre+direction*(length*fraction)
                let roofCore = [c-direction*3.4-normal*3.0,c+direction*3.4-normal*3.0,
                    c+direction*3.4+normal*3.0,c-direction*3.4+normal*3.0]
                guard roofCore.allSatisfy({ footprint.path.contains(CGPoint(x:$0.x,y:$0.y)) }) else { continue }
                P.volume(roofCore,bottom:tower.height-1.6,top:tower.height+1.1,material:P.plaster,name:"residentialSteppedRoofCore",root:root)
            }
        } else if abs(BuildingFootprint.area(core)) > 12 {
            let upper = core.map { centre+($0-centre)*0.56 }
            P.volume(upper, bottom: tower.height-1.6, top: tower.height+1.1, material: P.plaster, name: "\(tower.id)SetbackRoofCore", root: root)
        }
    }

    private static func lantern(at centre: SIMD2<Double>, root: SCNNode) {
        typealias P = DarLandmarkParts
        var roof = BuildingMesh(), ribs = BuildingMesh()
        let radius = 6.3
        for i in 0..<24 {
            let a = Double(i)*2*Double.pi/24, b = Double(i+1)*2*Double.pi/24
            let p = centre+SIMD2(cos(a),sin(a))*radius, q = centre+SIMD2(cos(b),sin(b))*radius
            let r = centre+SIMD2(cos(a),sin(a))*1.5, s = centre+SIMD2(cos(b),sin(b))*1.5
            roof.quad(P.p(p,podiumTop+0.2),P.p(q,podiumTop+0.2),P.p(s,podiumTop+6.4),P.p(r,podiumTop+6.4))
            if i % 2 == 0 { LandmarkMesh.beam(&ribs, from: P.p(p,podiumTop+0.3), to: P.p(r,podiumTop+6.5), radius: 0.13, sides: 8) }
        }
        root.addChildNode(roof.node(name: "curtainGlass", material: glass))
        let cap = (0..<24).map { centre+SIMD2(cos(Double($0)*Double.pi/12),sin(Double($0)*Double.pi/12))*1.5 }
        root.addChildNode(BuildingFootprint(rings:[cap]).deck(at:podiumTop+6.4,thickness:0.16,material:P.silver,name:"atriumLanternCap"))
        root.addChildNode(ribs.node(name: "conicalAtriumSilverRibs", material: P.plaster))
        ribbon((0..<32).map { centre+SIMD2(cos(Double($0)*Double.pi/16),sin(Double($0)*Double.pi/16))*radius },
            z: podiumTop+0.05, height: 0.35, projection: 0.2, material: P.plaster, name: "atriumBaseRing", root: root)
    }

    private static func roofTerrace(envelope: [SIMD2<Double>], occupied: [[SIMD2<Double>]], atrium: SIMD2<Double>, root: SCNNode) {
        let polygon = envelope.map { DV2($0.x,$0.y) }
        let holes = occupied.map { $0.map { DV2($0.x,$0.y) } }
        var count = 0
        for x in stride(from: envelope.map(\.x).min() ?? 0, through: envelope.map(\.x).max() ?? 0, by: 8) {
            for y in stride(from: envelope.map(\.y).min() ?? 0, through: envelope.map(\.y).max() ?? 0, by: 8) {
                let c = DV2(x,y)
                guard count < 10, DioramaPolygon.contains(polygon,c), DioramaPolygon.distanceToRing(polygon,c)>3,
                      simd_distance(SIMD2(x,y),atrium)>10,
                      !holes.contains(where: { DioramaPolygon.contains($0,c) || DioramaPolygon.distanceToRing($0,c)<3 }) else { continue }
                count += 1
                DarLandmarkParts.volume(DarLandmarkParts.rectangle(x:x,y:y,width:3.0,depth:1.3),bottom:podiumTop,top:podiumTop+0.7,
                    material:DarLandmarkParts.plaster,name:"terracePlanter",root:root)
                var foliage = BuildingMesh()
                foliage.revolve(centre:SIMD2(x,y),profile:[SIMD2(0.4,podiumTop+0.7),SIMD2(0.8,podiumTop+1.0),SIMD2(0.65,podiumTop+1.7),SIMD2(0,podiumTop+2.0)],segments:16)
                root.addChildNode(foliage.node(name:"mallTerracePlanting",material:BuildingSurfaces.make("landmark.foliage",color:"#638238",roughness:1)))
                LandmarkLightingGeometry.fixture(at:SIMD3(x,y,podiumTop+1.5),radius:5,intensity:0.65,root:root)
            }
        }
    }

    private static func inset(_ ring: [SIMD2<Double>], _ amount: Double) -> [SIMD2<Double>] {
        let polygon = ring.map { DV2($0.x,$0.y) }
        if let result = DioramaPolygon.offset(polygon,by:-amount), result.allSatisfy({
            DioramaPolygon.contains(polygon,$0) && DioramaPolygon.distanceToRing(polygon,$0) >= amount*0.8
        }) { return result.map { SIMD2($0.x,$0.y) } }
        // Insetting a tight rounded corner can fold. Clip to interior edge half-planes instead
        // of falling back to the outer shell, which would bury every recessed window.
        let minX = ring.map(\.x).min() ?? 0, maxX = ring.map(\.x).max() ?? 0
        let minY = ring.map(\.y).min() ?? 0, maxY = ring.map(\.y).max() ?? 0
        var clipped = DarLandmarkParts.rectangle(x:(minX+maxX)/2,y:(minY+maxY)/2,width:maxX-minX,depth:maxY-minY)
        for i in ring.indices {
            guard !clipped.isEmpty else { break }
            let a = ring[i], delta = ring[(i+1)%ring.count]-a
            guard simd_length(delta)>0.001 else { continue }
            let normal = simd_normalize(SIMD2(-delta.y,delta.x))
            func distance(_ p: SIMD2<Double>) -> Double { simd_dot(p-a,normal)-amount }
            var next: [SIMD2<Double>] = []
            for j in clipped.indices {
                let p = clipped[j], q = clipped[(j+1)%clipped.count], dp = distance(p), dq = distance(q)
                if dp >= 0 { next.append(p) }
                if (dp >= 0) != (dq >= 0) { next.append(p+(q-p)*(dp/(dp-dq))) }
            }
            clipped = next
        }
        if clipped.count >= 3, abs(BuildingFootprint.area(clipped)) > 1 { return clipped }
        if let site = BuildingFootprint(rings:[ring]).domeSite {
            return (0..<24).map { site.centre+SIMD2(cos(Double($0)*Double.pi/12),sin(Double($0)*Double.pi/12))*max(0.5,site.radius-amount) }
        }
        return ring
    }

    private static func ribbon(_ ring: [SIMD2<Double>], z: Double, height: Double, projection: Double,
                               material: SCNMaterial, name: String, root: SCNNode) {
        var mesh = BuildingMesh()
        mesh.perimeter(rings:[ring],bottom:z,top:z+height,projection:projection)
        root.addChildNode(mesh.node(name:name,material:material))
    }
}
