import SceneKit
import simd

/// Reference-led Bandari/TPA structure; facade pigment is cheap, silhouette and structural beams stay three-dimensional.
enum BandariTowerGeometry {
    static func build(_ site: DarLandmarkSite, ring raw: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let bounds = H.bounds(raw), centre = SIMD2((bounds.x+bounds.z)/2,(bounds.y+bounds.w)/2)
        let podium = H.compactContour(BuildingContour.rounded(raw,tangentDistance:0.8,segments:6))
        let towerRaw = raw.map {
            centre+SIMD2(($0.x-centre.x)*0.52+(bounds.z-bounds.x)*0.14,($0.y-centre.y)*0.75)
        }
        guard H.fits(towerRaw,inside:raw,clearance:0.45) else { return }
        let tower = H.compactContour(BuildingContour.rounded(towerRaw,tangentDistance:1.2,segments:6))
        let b = H.bounds(tower), w = b.z-b.x, d = b.w-b.y, y = (b.y+b.w)/2
        let podiumTop = 20.5, eave = site.height-19.5
        let coreX = b.x+w*0.35, coreWidth = w*0.23
        let coreLeft = coreX-coreWidth/2, coreRight = coreX+coreWidth/2
        let coreY = y+d*0.12, coreDepth = d*0.65
        let core = P.rectangle(x:coreX,y:coreY,width:coreWidth,depth:coreDepth)
        guard H.fits(core,inside:raw,clearance:0.1) else { return }
        let goldStone = BuildingSurfaces.make("harbour.bandariGoldStone",color:"#F2DDA4",roughness:0.9)

        let recessedBase = podium.map { centre+($0-centre)*0.88 }
        paintedGlazing(recessedBase,bottom:0.45,top:7,rows:1,bayWidth:8.5,occupied:false,root:root)
        paintedGlazing(podium,bottom:7,top:podiumTop,rows:4,bayWidth:8.5,occupied:false,root:root)
        paintedGlazing(tower,bottom:podiumTop,top:eave,rows:17,bayWidth:10,occupied:true,root:root)
        podiumStructure(podium,top:podiumTop,spine:coreLeft,coreRight:coreRight,goldStone:goldStone,root:root)
        towerRibbons(tower,bottom:podiumTop,top:eave,spine:coreRight,root:root)
        P.volume(core,bottom:0.35,top:site.height-5.8,material:goldStone,name:"bandariFullHeightGoldCore",root:root)

        var slots = BuildingMesh(), spine = BuildingMesh()
        for face in [-1.0,1.0] {
            let faceY = coreY+face*(coreDepth/2+0.025)
            for row in 0..<29 {
                let z = podiumTop+4+Double(row)*(site.height-podiumTop-12)/29
                facadeQuad(&slots,x:coreX+coreWidth*0.24,y:faceY,width:0.82,bottom:z,top:z+1.0,outward:face)
            }
            let ribPath = (0...18).map { step -> SIMD3<Double> in
                let t = Double(step)/18
                return SIMD3(coreRight+0.48,coreY+(faceY-coreY)*pow(1-t,0.65),
                             0.35+t*(site.height-6.15))
            }
            sweep(&spine,path:ribPath,
                  lateral:SIMD3(1,0,0),width:0.95,depth:0.7)
        }
        root.addChildNode(slots.node(name:"curtainGlass",material:H.glass))
        root.addChildNode(spine.node(name:"bandariBroadStructuralSpine",material:P.plaster))

        // The slim round stair stands beside, not halfway across, the broad gold spine.
        let stairCentre = SIMD2(coreLeft-1.5,b.y+3.0)
        let stairRadius = min(2.6,d*0.11)
        var stair = BuildingMesh(), caps = BuildingMesh(), rails = BuildingMesh()
        stair.revolve(centre:stairCentre,profile:[SIMD2(stairRadius,podiumTop+6),SIMD2(stairRadius,eave+3.38)],segments:18)
        caps.revolve(centre:stairCentre,profile:[SIMD2(0,podiumTop),SIMD2(stairRadius,podiumTop),
            SIMD2(stairRadius,podiumTop+6),SIMD2(0,podiumTop+6)],segments:18)
        for step in 0..<18 {
            let a = Double(step)*Double.pi/9, b = Double(step+1)*Double.pi/9
            caps.triangle(P.p(stairCentre,eave+3.38),
                SIMD3(stairCentre.x+stairRadius*cos(a),stairCentre.y+stairRadius*sin(a),eave+3.38),
                SIMD3(stairCentre.x+stairRadius*cos(b),stairCentre.y+stairRadius*sin(b),eave+3.38))
        }
        for z in [eave-1.0,eave+2.2] {
            caps.revolve(centre:stairCentre,profile:[SIMD2(stairRadius,z),SIMD2(stairRadius+0.3,z+0.12),
                SIMD2(stairRadius+0.3,z+1.05),SIMD2(stairRadius,z+1.18),SIMD2(stairRadius,z)],segments:18)
        }
        for x in [stairCentre.x-stairRadius*0.68,stairCentre.x+stairRadius*0.68] {
            sweep(&rails,path:[SIMD3(x,stairCentre.y-stairRadius*0.78,podiumTop+6),
                              SIMD3(x,stairCentre.y-stairRadius*0.78,eave-0.7)],
                  lateral:SIMD3(1,0,0),width:0.32,depth:0.28)
        }
        root.addChildNode(stair.node(name:"curtainGlass",material:H.lightGlass))
        root.addChildNode(caps.node(name:"bandariRoundedStairCaps",material:P.plaster))
        root.addChildNode(rails.node(name:"bandariStairEdgeRails",material:P.silver))
        crown(tower,spineX:coreX,coreRight:coreRight,eave:eave,height:site.height,root:root)
        guard let sailFace = sail(podium,tower:tower,spineX:coreLeft+0.65,podiumTop:podiumTop,eave:eave,root:root) else { return }
        roundels(podium,largeX:coreLeft-19,sailFace:sailFace,root:root)
    }

    /// Coplanar pigment cells and flat seam strips replace separately capped metal mullions and individual box windows.
    private static func paintedGlazing(_ ring: [SIMD2<Double>], bottom: Double, top: Double, rows: Int,
                                       bayWidth: Double, occupied: Bool, root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let normals = BuildingContour.outwardNormals(ring), storey = (top-bottom)/Double(rows)
        var panes = BuildingMesh(), light = BuildingMesh(), seams = BuildingMesh(), lit = BuildingMesh()
        for i in ring.indices {
            let a = ring[i], b = ring[(i+1)%ring.count], delta = b-a, length = simd_length(delta)
            guard length > 0.01 else { continue }
            let bays = max(1,Int(ceil(length/bayWidth)))
            for row in 0..<rows {
                let low = bottom+Double(row)*storey, high = low+storey-0.065
                for bay in 0..<bays {
                    let t = Double(bay)/Double(bays), u = Double(bay+1)/Double(bays)
                    let p = a+delta*t, q = a+delta*u
                    let na = simd_normalize(normals[i]*(1-t)+normals[(i+1)%ring.count]*t)
                    let nb = simd_normalize(normals[i]*(1-u)+normals[(i+1)%ring.count]*u)
                    let ns = [P.p(na,0),P.p(nb,0),P.p(nb,0),P.p(na,0)]
                    if occupied && length > 8 && (row*3+bay+i)%23 == 4 {
                        lit.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    } else if (bay+row+i)%4 == 0 {
                        light.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    } else {
                        panes.smoothQuad(P.p(p,low),P.p(q,low),P.p(q,high),P.p(p,high),normals:ns)
                    }
                }
                seams.smoothQuad(P.p(a,high),P.p(b,high),P.p(b,low+storey),P.p(a,low+storey),
                                 normals:[P.p(normals[i],0),P.p(normals[(i+1)%ring.count],0),
                                          P.p(normals[(i+1)%ring.count],0),P.p(normals[i],0)])
            }
        }
        root.addChildNode(panes.node(name:"curtainGlass",material:H.glass))
        root.addChildNode(light.node(name:"curtainGlass",material:H.lightGlass))
        root.addChildNode(seams.node(name:"bandariPaintedGlazingSeams",material:H.louvre))
        root.addChildNode(lit.node(name:"occupiedHarbourWindows",material:LandmarkLightingGeometry.window))
        root.addChildNode(BuildingFootprint(rings:[ring]).deck(at:top-0.25,thickness:0.25,material:P.plaster,name:"bandariClosedRoofDeck"))
    }

    private static func podiumStructure(_ ring: [SIMD2<Double>], top: Double, spine: Double,
                                        coreRight: Double, goldStone: SCNMaterial, root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        var bands = BuildingMesh(), frames = BuildingMesh(), portal = BuildingMesh(), fascia = BuildingMesh()
        for z in [7.0,11.5,16.0,top] { H.ribbon(&bands,ring:ring,z:z,height:1.15,reach:0.28) }
        // Arc-length placement keeps the rounded ends from accumulating a column at every contour sample.
        var travelled = 0.0, nextPier = 0.0
        for i in ring.indices {
            let a = ring[i], b = ring[(i+1)%ring.count], delta = b-a, length = simd_length(delta)
            guard length > 0.01 else { continue }
            let tangent = delta/length, outward = SIMD2(tangent.y,-tangent.x)
            while nextPier < travelled+length {
                let p = a+delta*((nextPier-travelled)/length)-outward*0.55
                let pierTop = 7.5
                sweep(&frames,path:[P.p(p,0.35),P.p(p,pierTop)],lateral:P.p(tangent,0),width:1.65,depth:1.35)
                nextPier += 8.0
            }
            travelled += length
            if outward.y < -0.3, abs(delta.x) > 0.001 {
                let crossing = (coreRight+3-a.x)/delta.x
                let low = delta.x > 0 ? max(0,crossing) : 0
                let high = delta.x > 0 ? 1 : min(1,crossing)
                if high-low > 0.001 {
                    sweep(&fascia,path:[P.p(a+delta*low+outward*0.18,7.5),P.p(a+delta*high+outward*0.18,7.5)],
                          lateral:P.p(outward,0),width:0.6,depth:2.4)
                }
            }
            guard outward.y < -0.7, length > 10 else { continue }
            for x in [spine-37,spine-14,spine+4.5] where x > min(a.x,b.x)+1 && x < max(a.x,b.x)-1 {
                let p = a+delta*((x-a.x)/delta.x)+outward*0.18
                for offset in [-0.9,0.9] {
                    let q = p+tangent*offset
                    sweep(&portal,path:[P.p(q,0.35),P.p(q,top+0.8)],lateral:P.p(tangent,0),width:0.85,depth:0.95)
                }
            }
        }
        root.addChildNode(bands.node(name:"bandariPodiumBroadFloorBeams",material:P.plaster))
        root.addChildNode(frames.node(name:"bandariSquareGroundColonnade",material:P.plaster))
        root.addChildNode(portal.node(name:"bandariPodiumPairedStructuralFrames",material:P.plaster))
        root.addChildNode(fascia.node(name:"bandariLowGoldFrontWingFascia",material:goldStone))
    }

    private static func towerRibbons(_ ring: [SIMD2<Double>], bottom: Double, top: Double, spine: Double, root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let b = H.bounds(ring)
        var ribbons = BuildingMesh()
        for z in [top-26,top-14,top-0.4] { H.ribbon(&ribbons,ring:ring,z:z,height:1.45,reach:0.23) }
        // Lower bands retreat toward the spine as they rise; the upper glazed face is deliberately uninterrupted.
        for row in 1...23 {
            let fraction = Double(row)/25
            let z = bottom+Double(row)*(top-bottom)/34
            let endX = spine+(b.z-spine)*(1-pow(fraction,1.35))
            for i in ring.indices {
                let a = ring[i], b = ring[(i+1)%ring.count], delta = b-a
                guard abs(delta.x) > 0.001, simd_length(delta) > 0.01 else { continue }
                let t0 = (spine-a.x)/delta.x, t1 = (endX-a.x)/delta.x
                let low = max(0,min(t0,t1)), high = min(1,max(t0,t1))
                guard high-low > 0.0001 else { continue }
                let n = simd_normalize(SIMD2(delta.y,-delta.x))
                sweep(&ribbons,path:[P.p(a+delta*low+n*0.13,z+0.5),P.p(a+delta*high+n*0.13,z+0.5)],
                      lateral:P.p(n,0),width:0.4,depth:0.9)
            }
        }
        root.addChildNode(ribbons.node(name:"bandariTaperedWhiteFacadeRibbons",material:P.plaster))
    }

    private static func crown(_ ring: [SIMD2<Double>], spineX: Double, coreRight: Double,
                              eave: Double, height: Double, root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let b = H.bounds(ring), x1 = b.z-(b.z-b.x)*0.08
        let midY = (b.y+b.w)/2
        let y0 = midY-(b.w-b.y)*0.20, y1 = midY+(b.w-b.y)*0.20
        let crest = height-0.85, toe = eave+0.2
        var arches = BuildingMesh(), braces = BuildingMesh(), terraces = BuildingMesh()
        func point(_ t: Double, _ y: Double) -> SIMD3<Double> {
            let angle = t*Double.pi/2
            return SIMD3(spineX+(x1-spineX)*sin(angle),y,toe+(crest-toe)*cos(angle))
        }
        for y in [y0,y1] {
            let path = (0...18).map { point(Double($0)/18,y) }
            sweep(&arches,path:path,lateral:SIMD3(0,1,0),width:0.72,depth:1.15)
            sweep(&braces,path:[SIMD3(spineX,y,height-6.2),point(0,y)],lateral:SIMD3(0,1,0),width:0.7,depth:0.75)
            sweep(&braces,path:[SIMD3(x1,y,eave-0.2),SIMD3(x1,y,toe+0.4)],
                  lateral:SIMD3(0,1,0),width:0.72,depth:0.8)
            for t in [0.36,0.64,0.83] {
                let roof = point(t,y), foot = SIMD3(roof.x-3.0,y,eave-0.25)
                sweep(&braces,path:[foot,roof],lateral:SIMD3(0,1,0),width:0.45,depth:0.65)
            }
        }
        for t in [0.0,0.5,0.82,1.0] {
            sweep(&braces,path:[point(t,y0),point(t,y1)],lateral:SIMD3(1,0,0),width:0.5,depth:0.6)
        }
        // A squared ridge over the gold core leads into a descending quarter arch, never a centred dome.
        for y in [y0,y1] {
            sweep(&braces,path:[SIMD3(spineX-7,y,height-5.8),SIMD3(spineX-7,y,crest),point(0,y)],
                  lateral:SIMD3(0,1,0),width:0.55,depth:0.65)
        }
        for (offset,width,rise) in [(0.0,9.0,8.0),(9.0,8.0,4.4),(17.0,7.0,2.0)] {
            H.box(&terraces,x:coreRight+width/2+offset,y:(y0+y1)/2,width:width,depth:(y1-y0)*0.56,
                  bottom:eave,top:eave+rise,bevel:0.15)
        }
        root.addChildNode(arches.node(name:"bandariOpenWhiteArchCrown",material:P.plaster))
        root.addChildNode(braces.node(name:"bandariOpenRidgeAndTriangularBraces",material:P.plaster))
        root.addChildNode(terraces.node(name:"curtainGlass",material:H.glass))
    }

    /// Low barrel roof and tall concave sail cheeks are separate, connected forms in the reference.
    private static func sail(_ podium: [SIMD2<Double>], tower: [SIMD2<Double>], spineX: Double,
                             podiumTop: Double, eave: Double, root: SCNNode) -> SIMD2<Double>? {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let b = H.bounds(podium), t = H.bounds(tower)
        let x0 = b.x+12, x1 = spineX, y0 = t.y+0.95, y1 = t.w-1.5
        guard x1>x0, y1>y0 else { return nil }
        let base = podiumTop+1.3, rise = (eave-podiumTop)*0.70, thickness = 0.48
        var cheeks = BuildingMesh(), edges = BuildingMesh(), roof = BuildingMesh(), ribs = BuildingMesh(), endGlass = BuildingMesh()
        func curve(_ u: Double, y: Double) -> SIMD3<Double> {
            let v = 1-u
            let a = SIMD2(x0,base), b = SIMD2(x0+(x1-x0)*0.94,base+1)
            let c = SIMD2(x1,base+rise*0.12), d = SIMD2(x1,base+rise)
            let p = a*(v*v*v)+b*(3*v*v*u)+c*(3*v*u*u)+d*(u*u*u)
            let ribY = (t.y+t.w)/2+(t.w-t.y)*0.12
            let convergence = pow(u,3)*0.96
            return SIMD3(p.x,y+(ribY-y)*convergence,p.y)
        }
        for y in [y0,y1] {
            let frontY = y-thickness/2, backY = y+thickness/2
            for step in 0..<24 {
                let a = curve(Double(step)/24,y:frontY), b = curve(Double(step+1)/24,y:frontY)
                let c = curve(Double(step)/24,y:backY), d = curve(Double(step+1)/24,y:backY)
                cheeks.quad(SIMD3(a.x,a.y,podiumTop),SIMD3(b.x,b.y,podiumTop),b,a)
                cheeks.quad(SIMD3(d.x,d.y,podiumTop),SIMD3(c.x,c.y,podiumTop),c,d)
                cheeks.quad(a,b,d,c)
            }
            let firstFront = curve(0,y:frontY), lastFront = curve(1,y:frontY)
            let firstBack = curve(0,y:backY), lastBack = curve(1,y:backY)
            cheeks.quad(SIMD3(firstBack.x,firstBack.y,podiumTop),SIMD3(lastBack.x,lastBack.y,podiumTop),
                        SIMD3(lastFront.x,lastFront.y,podiumTop),SIMD3(firstFront.x,firstFront.y,podiumTop))
            for u in [0.0,1.0] {
                let a = curve(u,y:frontY), b = curve(u,y:backY)
                if u == 0 { cheeks.quad(SIMD3(b.x,b.y,podiumTop),SIMD3(a.x,a.y,podiumTop),a,b) }
                else { cheeks.quad(SIMD3(a.x,a.y,podiumTop),SIMD3(b.x,b.y,podiumTop),b,a) }
            }
            sweep(&edges,path:(0...24).map { curve(Double($0)/24,y:y) },
                  lateral:SIMD3(0,1,0),width:0.72,depth:0.65)
        }
        let vaultRise = 4.5, roofThickness = 0.28
        func vault(_ y: Double) -> Double { base+vaultRise*sin(Double.pi*(y-y0)/(y1-y0)) }
        func normal(_ y: Double) -> SIMD3<Double> {
            let slope = vaultRise*Double.pi*cos(Double.pi*(y-y0)/(y1-y0))/(y1-y0)
            return simd_normalize(SIMD3(0,-slope,1))
        }
        for step in 0..<12 {
            let a = y0+(y1-y0)*Double(step)/12, b = y0+(y1-y0)*Double(step+1)/12
            let p = SIMD3(x0,a,vault(a)), q = SIMD3(x1,a,vault(a))
            let r = SIMD3(x1,b,vault(b)), s = SIMD3(x0,b,vault(b)), drop = SIMD3(0.0,0.0,roofThickness)
            roof.smoothQuad(p,q,r,s,normals:[normal(a),normal(a),normal(b),normal(b)])
            roof.smoothQuad(s-drop,r-drop,q-drop,p-drop,normals:[-normal(b),-normal(b),-normal(a),-normal(a)])
            roof.quad(s-drop,p-drop,p,s)
            roof.quad(q-drop,r-drop,r,q)
            endGlass.quad(SIMD3(x0-0.015,b,podiumTop),SIMD3(x0-0.015,a,podiumTop),
                          SIMD3(x0-0.015,a,vault(a)-roofThickness),SIMD3(x0-0.015,b,vault(b)-roofThickness))
        }
        for y in [y0,y1] {
            if y == y0 {
                roof.quad(SIMD3(x0,y,base-roofThickness),SIMD3(x1,y,base-roofThickness),SIMD3(x1,y,base),SIMD3(x0,y,base))
            } else {
                roof.quad(SIMD3(x1,y,base-roofThickness),SIMD3(x0,y,base-roofThickness),SIMD3(x0,y,base),SIMD3(x1,y,base))
            }
        }
        for rib in 0...5 {
            let x = x0+(x1-x0)*Double(rib)/5
            let path = (0...12).map { step -> SIMD3<Double> in
                let y = y0+(y1-y0)*Double(step)/12
                return SIMD3(x,y,vault(y)+0.08)
            }
            sweep(&ribs,path:path,lateral:SIMD3(-1,0,0),width:0.22,depth:0.22)
        }
        root.addChildNode(cheeks.node(name:"bandariContinuousCurvedPodiumSail",material:P.plaster))
        root.addChildNode(edges.node(name:"bandariSweepingSailSpineEdges",material:P.plaster))
        root.addChildNode(roof.node(name:"bandariLowBarrelPodiumRoof",material:P.plaster))
        root.addChildNode(ribs.node(name:"bandariSparseVaultStructuralRibs",material:P.silver))
        root.addChildNode(endGlass.node(name:"curtainGlass",material:H.glass))
        return SIMD2(x1-4,y0-thickness/2-0.035)
    }

    private static func roundels(_ ring: [SIMD2<Double>], largeX: Double, sailFace: SIMD2<Double>, root: SCNNode) {
        typealias P = DarLandmarkParts
        guard let edge = ring.indices.filter({ ring[($0+1)%ring.count].x>ring[$0].x })
            .max(by:{ simd_distance(ring[$0],ring[($0+1)%ring.count])<simd_distance(ring[$1],ring[($1+1)%ring.count]) }) else { return }
        let a = ring[edge], b = ring[(edge+1)%ring.count], delta = b-a
        let centre = a+delta*max(0.12,min(0.88,(largeX-a.x)/max(1.0,delta.x)))
        let outward = simd_normalize(SIMD2(delta.y,-delta.x))
        for (z,radius) in [(10.4,5.5),(36.0,2.3)] {
            let faceCentre = z > 20 ? sailFace : centre+outward*0.38
            let normal = z > 20 ? SIMD2<Double>(0,-1) : outward
            let node = P.faceNode(at:faceCentre,outward:normal,height:z)
            var face = BuildingMesh(), rim = BuildingMesh(), spokes = BuildingMesh()
            for step in 0..<24 {
                let a = Double(step)*Double.pi/12, b = Double(step+1)*Double.pi/12
                let p = SIMD3(cos(a)*radius,sin(a)*radius,0.08), q = SIMD3(cos(b)*radius,sin(b)*radius,0.08)
                face.triangle(SIMD3(0,0,0.08),p,q)
            }
            let lip = radius*0.09
            rim.revolve(centre:.zero,profile:[SIMD2(radius-lip,0.04),SIMD2(radius,0.04),SIMD2(radius+lip,0.18),
                SIMD2(radius,0.34),SIMD2(radius-lip,0.24),SIMD2(radius-lip,0.04)],segments:24)
            for spoke in 0..<8 {
                let a = Double(spoke)*Double.pi/4
                LandmarkMesh.beam(&spokes,from:SIMD3(0,0,0.18),to:SIMD3(cos(a)*radius*0.91,sin(a)*radius*0.91,0.18),radius:0.065,sides:4)
            }
            node.addChildNode(face.node(name:"curtainGlass",material:HarbourArchitectureParts.glass))
            node.addChildNode(rim.node(name:"bandariGoldRoundelRim",material:P.gold))
            node.addChildNode(spokes.node(name:"bandariRadialWindowTracery",material:P.silver))
            root.addChildNode(node)
        }
    }

    private static func facadeQuad(_ mesh: inout BuildingMesh, x: Double, y: Double, width: Double,
                                   bottom: Double, top: Double, outward: Double) {
        let a = SIMD3(x-width/2,y,bottom), b = SIMD3(x+width/2,y,bottom)
        let c = SIMD3(x+width/2,y,top), d = SIMD3(x-width/2,y,top)
        if outward < 0 { mesh.quad(a,b,c,d) } else { mesh.quad(b,a,d,c) }
    }

    /// Continuous closed rectangular profiles avoid internal tube endcaps at every curve sample.
    private static func sweep(_ mesh: inout BuildingMesh, path: [SIMD3<Double>], lateral: SIMD3<Double>,
                              width: Double, depth: Double) {
        guard path.count >= 2, width > 0, depth > 0 else { return }
        let side = simd_normalize(lateral)
        let tangents = path.indices.map { i in
            simd_normalize(path[min(i+1,path.count-1)]-path[max(0,i-1)])
        }
        let ups = tangents.map { simd_normalize(simd_cross($0,side)) }
        guard ups.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return }
        let halfSide: SIMD3<Double> = side * (width / 2)
        let sections: [[SIMD3<Double>]] = path.indices.map { i in
            let halfUp: SIMD3<Double> = ups[i] * (depth / 2)
            let left: SIMD3<Double> = path[i] - halfSide
            let right: SIMD3<Double> = path[i] + halfSide
            return [left - halfUp, right - halfUp, right + halfUp, left + halfUp]
        }
        for i in 0..<(path.count-1) {
            let n0 = [-ups[i],side,ups[i],-side], n1 = [-ups[i+1],side,ups[i+1],-side]
            for edge in 0..<4 {
                let next = (edge+1)%4
                mesh.smoothQuad(sections[i][edge],sections[i][next],sections[i+1][next],sections[i+1][edge],
                                normals:[n0[edge],n0[edge],n1[edge],n1[edge]])
            }
        }
        let first = sections[0], last = sections[sections.count-1]
        mesh.quad(first[3],first[2],first[1],first[0],normal:-tangents[0])
        mesh.quad(last[0],last[1],last[2],last[3],normal:tangents[tangents.count-1])
    }
}
