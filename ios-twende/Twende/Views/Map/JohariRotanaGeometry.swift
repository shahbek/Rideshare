import SceneKit
import simd

/// Photo-composed paired crowns, cream superframes and inland pool deck on the researched MNF outlines.
enum JohariRotanaGeometry {
    private static let podiumTop: Double = 25
    private static let shoulder: Double = 98
    private static let orange = BuildingSurfaces.make("harbour.johariOchre",color:"#D88943",roughness:0.9,metalness:0)
    private static let glazing = BuildingSurfaces.make("harbour.johariGreyGreenGlass",color:"#596E65",roughness:0.72)
    private static let lightGlazing = BuildingSurfaces.make("harbour.johariLightGlass",color:"#728276",roughness:0.72)

    static func build(_ site: DarLandmarkSite, root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        guard let data = HarbourLandmarkData.bundled else { return }
        let tall = data.localPart("johari-tall-block",site:site)
        let deck = data.localPart("johari-pool-podium",site:site)
        guard tall.count >= 3, deck.count >= 3 else { return }
        let b = H.bounds(tall), width = b.z-b.x, depth = b.w-b.y
        let midX = (b.x+b.z)/2, midY = (b.y+b.w)/2+0.7
        let towerWidth = width*0.365, towerDepth = depth-5.9
        let centres = [midX-width*0.273,midX+width*0.273]
        let towerRings = centres.map { P.rectangle(x:$0,y:midY,width:towerWidth,depth:towerDepth) }
        guard towerRings.allSatisfy({ H.fits($0,inside:tall,clearance:0.3) }) else { return }
        podium(site.footprint?.rings.first.map { ring in ring.map { SIMD2(simd_dot($0,site.right),simd_dot($0,site.inward)) } } ?? [], root:root)
        connector(x:midX,y:midY,width:width*0.205,depth:towerDepth,top:site.height-18,root:root)
        for (index, ring) in towerRings.enumerated() { tower(ring,index:index,top:site.height,root:root) }
        rearTerrace(deck,root:root)
    }

    private static func podium(_ raw: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        guard raw.count >= 3 else { return }
        let ring = BuildingContour.rounded(raw,tangentDistance:0.8,segments:3)
        let bounds = H.bounds(ring)
        let centre = SIMD2((bounds.x+bounds.z)/2,(bounds.y+bounds.w)/2)
        let recessed = ring.map { centre+($0-centre)*0.987 }
        P.volume(recessed,bottom:0.2,top:podiumTop-0.6,material:H.louvre,name:"johariRecessedParkingPodium",root:root)
        // Parking louvres: the shader's ribbon facade (dark bands, slim mullions) a few cm proud of
        // the recessed body, instead of three modelled slats per level and edge.
        let louvreSkin = ring.map { centre+($0-centre)*0.9895 }
        let (louvreStorey, _) = H.facadeStorey(span:podiumTop-0.8,rows:7)
        H.facadeSkin(H.compactContour(louvreSkin,error:0.05),bottom:0.2,top:podiumTop-0.6,storey:louvreStorey,style:.ribbon,
                     color:"#30494E",root:root,name:"johariParkingLouvres")
        var bands = BuildingMesh(), fins = BuildingMesh()
        for level in 0...7 {
            H.ribbon(&bands,ring:ring,z:0.3+Double(level)*(podiumTop-0.9)/7,height:1.45,reach:0.18)
        }
        let b = H.bounds(ring)
        for i in ring.indices {
            let a = ring[i], q = ring[(i+1)%ring.count], d = q-a, length = simd_length(d)
            guard length > 4 else { continue }
            let n = simd_normalize(SIMD2(d.y,-d.x))
            let bays = max(1,Int(ceil(length/12)))
            for bay in 0...bays {
                let p = a+d*(Double(bay)/Double(bays))-n*0.20
                LandmarkMesh.leanBeam(&fins,from:P.p(p,0.4),to:P.p(p,podiumTop),radius:0.34)
            }
        }
        // Glass stair/lift bays interrupt the open parking ribbons on both long elevations.
        var bays = BuildingMesh(), surrounds = BuildingMesh()
        for x in [b.x+(b.z-b.x)*0.22,(b.x+b.z)/2,b.x+(b.z-b.x)*0.83] {
            for y in [b.y+0.4,b.w-1.2] {
                let candidate = P.rectangle(x:x,y:y,width:3.6,depth:1.0)
                guard H.fits(candidate,inside:ring,clearance:0) else { continue }
                H.box(&surrounds,x:x,y:y,width:4.9,depth:1.0,bottom:0.4,top:podiumTop+0.5)
                H.box(&bays,x:x,y:y+(y<(b.y+b.w)/2 ? -0.54 : 0.54),width:3.3,depth:0.12,bottom:0.5,top:podiumTop-0.7,bevel:0)
            }
        }
        root.addChildNode(bands.node(name:"johariContinuousParkingRibbons",material:P.plaster))
        root.addChildNode(fins.node(name:"johariPodiumPiers",material:P.plaster))
        root.addChildNode(surrounds.node(name:"johariGoldPodiumBays",material:P.gold))
        root.addChildNode(bays.node(name:"curtainGlass",material:H.glass))
    }

    private static func connector(x: Double, y: Double, width: Double, depth: Double, top: Double, root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let plan = P.rectangle(x:x,y:y,width:width,depth:depth)
        P.volume(plan,bottom:podiumTop,top:top-0.8,material:orange,name:"johariConnectedCentralBody",root:root)
        var cream = BuildingMesh(), windows = BuildingMesh(), panels = BuildingMesh()
        for face in [-1.0,1.0] {
            let faceY = y+face*(depth/2+0.05)
            for fraction in [-0.46,0.0,0.46] {
                H.box(&cream,x:x+width*fraction,y:faceY,width:fraction == 0 ? 0.65 : 0.8,depth:0.24,bottom:podiumTop,top:top-0.6,bevel:0.06)
            }
            for row in 0..<27 {
                let z = podiumTop+Double(row)*(top-podiumTop)/27
                H.box(&windows,x:x,y:faceY+face*0.14,width:0.75,depth:0.08,bottom:z+0.5,top:z+2.6,bevel:0)
            }
            // The dark crossbar is attached to the central body at the upper-shoulder break.
            H.box(&cream,x:x,y:faceY+face*0.22,width:width*1.07,depth:0.75,bottom:shoulder-3.6,top:shoulder+2.3,bevel:0.20)
            H.box(&panels,x:x,y:faceY+face*0.65,width:width*0.9,depth:0.12,bottom:shoulder-2.7,top:shoulder+1.2,bevel:0.04)
            for column in -2...2 {
                H.box(&cream,x:x+Double(column)*width*0.15,y:faceY+face*0.74,width:0.14,depth:0.08,bottom:shoulder-2.7,top:shoulder+1.2,bevel:0)
            }
        }
        root.addChildNode(cream.node(name:"johariCentralCreamSlitsAndBridgeFrame",material:P.plaster))
        root.addChildNode(windows.node(name:"curtainGlass",material:glazing))
        root.addChildNode(panels.node(name:"johariShoulderGlazedCrossbar",material:P.dark))
        // A lower open mechanical terrace joins the two crown bases; it is not a third tower.
        let equipment = P.rectangle(x:x,y:y,width:width*0.62,depth:depth*0.58)
        P.volume(equipment,bottom:top-0.7,top:top+0.6,material:P.trim,name:"johariCentralRoofPlant",root:root)
        var rail = BuildingMesh()
        for i in equipment.indices {
            let a = equipment[i], b = equipment[(i+1)%equipment.count]
            LandmarkMesh.leanBeam(&rail,from:P.p(a,top+1.5),to:P.p(b,top+1.5),radius:0.08)
            LandmarkMesh.leanBeam(&rail,from:P.p(a,top+0.6),to:P.p(a,top+1.5),radius:0.08)
        }
        root.addChildNode(rail.node(name:"johariCentralPlantGuardrail",material:P.silver))
    }

    private static func tower(_ rectangle: [SIMD2<Double>], index: Int, top: Double, root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let b = H.bounds(rectangle), x = (b.x+b.z)/2, y = (b.y+b.w)/2, w = b.z-b.x, d = b.w-b.y
        let eave = top-18
        // Square plans: the facade shader rounds the corners, no contour segments needed.
        let ring = rectangle
        let upper = P.rectangle(x:x,y:y,width:w*0.96,depth:d*0.86)
        H.curtain(ring,bottom:podiumTop,top:shoulder,rows:19,bayWidth:3.4,root:root,creamSills:true,paneMaterial:glazing,alternateMaterial:lightGlazing)
        H.curtain(upper,bottom:shoulder,top:eave,rows:7,bayWidth:3.4,root:root,creamSills:true,paneMaterial:glazing,alternateMaterial:lightGlazing)
        var cream = BuildingMesh(), accents = BuildingMesh(), buttresses = BuildingMesh()
        for face in [-1.0,1.0] {
            let faceY = y+face*(d/2-0.12), upperY = y+face*(d*0.43)
            for fraction in [-0.47,-0.32,-0.16,0.0,0.16,0.32,0.47] {
                H.box(&cream,x:x+w*fraction,y:faceY,width:abs(fraction)>0.4 ? 1.0 : 0.42,depth:0.55,
                      bottom:podiumTop,top:shoulder,bevel:0.10)
                H.box(&cream,x:x+w*fraction*0.96,y:upperY,width:abs(fraction)>0.4 ? 0.95 : 0.40,depth:0.65,
                      bottom:shoulder,top:eave+0.5,bevel:0.10)
            }
            for z in [podiumTop,shoulder] {
                H.box(&cream,x:x,y:faceY,width:w+0.1,depth:0.65,bottom:z,top:z+0.95,bevel:0.16)
            }
            H.box(&cream,x:x,y:upperY,width:w*0.98,depth:0.7,bottom:eave-1.0,top:eave+0.45)
            // Orange end piers stop at the shoulder; the upper storeys retain their exposed cream frames.
            let outerSign = index == 0 ? -1.0 : 1.0
            H.box(&accents,x:x+outerSign*w*0.43,y:faceY,width:w*0.14,depth:0.85,bottom:podiumTop,top:shoulder+4.0,bevel:0.25)
            H.box(&cream,x:x+outerSign*w*0.36,y:faceY+face*0.25,width:0.6,depth:0.4,bottom:podiumTop,top:shoulder+4.1)
        }
        // The narrow side has continuous cream fins that step inward into the upper block.
        let outerX = x+(index == 0 ? -1.0 : 1.0)*(w/2-0.18)
        for fraction in [-0.29,-0.08,0.13,0.32] {
            let base = SIMD3(outerX,y+d*fraction,podiumTop)
            let bend = SIMD3(outerX,y+d*fraction,shoulder+8.0)
            let inset = SIMD3(x+(outerX-x)*0.94,y+d*fraction*0.86,shoulder+12.0)
            LandmarkMesh.leanBeam(&buttresses,from:base,to:bend,radius:0.24)
            LandmarkMesh.leanBeam(&buttresses,from:bend,to:inset,radius:0.24)
            LandmarkMesh.leanBeam(&buttresses,from:inset,to:SIMD3(inset.x,inset.y,eave),radius:0.24)
        }
        root.addChildNode(cream.node(name:"johariCreamFacadeGrid",material:P.plaster))
        root.addChildNode(accents.node(name:"johariOrangeOuterPiers",material:orange))
        root.addChildNode(buttresses.node(name:"johariSteppedSideFins",material:P.plaster))
        let cap = P.rectangle(x:x,y:y,width:w*0.98,depth:d*0.88)
        P.volume(cap,bottom:eave,top:eave+0.75,material:P.plaster,name:"johariCrownCornice",root:root)
        let peak = SIMD3(x,y,eave+6.0)
        var slopes = BuildingMesh(), seams = BuildingMesh()
        for i in cap.indices {
            let a = P.p(cap[i],eave+0.75), q = P.p(cap[(i+1)%cap.count],eave+0.75)
            slopes.triangle(a,q,peak)
            LandmarkMesh.leanBeam(&seams,from:a,to:peak,radius:0.10)
            for step in 1..<3 {
                let edge = a+(q-a)*(Double(step)/3)
                LandmarkMesh.leanBeam(&seams,from:edge,to:peak,radius:0.055)
            }
        }
        root.addChildNode(slopes.node(name:"johariPalePyramidalRoof",material:P.plaster))
        root.addChildNode(seams.node(name:"johariRoofRibs",material:P.trim))
        var spire = BuildingMesh()
        let base = eave+6.0, cageTop = top-2.2
        let cage = P.rectangle(x:x,y:y,width:0.95,depth:0.95)
        for level in 0..<4 {
            let z = base+(cageTop-base)*Double(level)/4, next = base+(cageTop-base)*Double(level+1)/4
            for leg in cage.indices {
                let p = cage[leg], q = cage[(leg+1)%cage.count]
                LandmarkMesh.leanBeam(&spire,from:P.p(p,z),to:P.p(p,next),radius:0.09)
                LandmarkMesh.leanBeam(&spire,from:P.p(p,z),to:P.p(q,z),radius:0.065)
                LandmarkMesh.leanBeam(&spire,from:P.p(p,z),to:P.p(q,next),radius:0.055)
            }
        }
        for p in cage { LandmarkMesh.leanBeam(&spire,from:P.p(p,cageTop),to:SIMD3(x,y,top),radius:0.065) }
        root.addChildNode(spire.node(name:"johariLatticeSpire\(index)",material:P.silver))
    }

    private static func rearTerrace(_ raw: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        typealias H = HarbourArchitectureParts
        let ring = BuildingContour.rounded(raw,tangentDistance:0.65,segments:3), b = H.bounds(raw)
        let w = b.z-b.x, d = b.w-b.y
        // Southwest/inland basin is photo located, not inferred from the tower centre or nearest POI.
        let pool = BuildingContour.rounded(P.rectangle(x:b.x+w*0.29,y:b.y+d*0.51,width:w*0.29,depth:d*0.40),tangentDistance:0.45,segments:3)
        guard H.fits(pool,inside:ring,clearance:2.0) else { return }
        let copingOuter = P.rectangle(x:b.x+w*0.29,y:b.y+d*0.51,width:w*0.29+1.1,depth:d*0.40+1.1)
        guard H.fits(copingOuter,inside:ring,clearance:1.0) else { return }
        let paving = BuildingSurfaces.make("landmark.sitePaving",color:"#D9CDB7",roughness:0.95)
        root.addChildNode(BuildingFootprint(rings:[ring,Array(pool.reversed())]).deck(at:podiumTop-0.45,thickness:0.45,material:paving,name:"johariRearTerraceAroundPool"))
        let outer = BuildingContour.rounded(copingOuter,tangentDistance:0.5,segments:3)
        root.addChildNode(BuildingFootprint(rings:[outer,Array(pool.reversed())]).deck(at:podiumTop,thickness:0.20,material:P.plaster,name:"johariPoolCoping"))
        let water = BuildingSurfaces.make("landmark.poolWater",color:"#3CC4C0",roughness:0.25)
        root.addChildNode(BuildingFootprint(rings:[pool]).deck(at:podiumTop-0.18,thickness:0.035,material:water,name:"johariRooftopPoolWater"))
        var parapet = BuildingMesh(), rails = BuildingMesh(), furniture = BuildingMesh()
        H.ribbon(&parapet,ring:ring,z:podiumTop,height:1.1,reach:0.15)
        for i in ring.indices {
            let a = ring[i], q = ring[(i+1)%ring.count]
            if simd_length(q-a)>4 { LandmarkMesh.leanBeam(&rails,from:P.p(a,podiumTop+1.25),to:P.p(q,podiumTop+1.25),radius:0.095) }
        }
        // Loungers face the pool; the northeast part remains service/restaurant terrace, not another basin.
        for row in 0..<6 {
            let x = b.x+w*(0.17+Double(row)*0.045), y = b.y+d*0.84
            let footprint = P.rectangle(x:x,y:y,width:1.1,depth:2.1)
            guard H.fits(footprint,inside:ring,clearance:0.6), !H.fits(footprint,inside:outer,clearance:0) else { continue }
            H.box(&furniture,x:x,y:y,width:0.9,depth:1.9,bottom:podiumTop+0.15,top:podiumTop+0.40)
            H.box(&furniture,x:x,y:y+0.68,width:0.9,depth:0.50,bottom:podiumTop+0.4,top:podiumTop+0.7)
        }
        for fraction in [0.64,0.84] {
            let x = b.x+w*fraction, y = b.y+d*0.55
            let plan = P.rectangle(x:x,y:y,width:5.0,depth:5.2)
            guard H.fits(plan,inside:ring,clearance:1.0) else { continue }
            H.box(&furniture,x:x,y:y,width:4.6,depth:4.8,bottom:podiumTop,top:podiumTop+1.35)
            var planting = BuildingMesh()
            planting.revolve(centre:SIMD2(x,y),profile:[SIMD2(0.7,podiumTop+1.35),SIMD2(1.9,podiumTop+1.8),SIMD2(1.6,podiumTop+2.7),SIMD2(0,podiumTop+3.1)],segments:12)
            root.addChildNode(planting.node(name:"johariTerracePlanting",material:BuildingSurfaces.make("landmark.foliage",color:"#638238",roughness:1)))
            LandmarkLightingGeometry.fixture(at:SIMD3(x,y,podiumTop+2.0),radius:5,intensity:0.55,root:root)
        }
        root.addChildNode(parapet.node(name:"johariRoundedTerraceParapet",material:P.plaster))
        root.addChildNode(rails.node(name:"johariTerraceHandrail",material:P.silver))
        root.addChildNode(furniture.node(name:"johariPoolLoungersAndTerracePlanters",material:P.plaster))
    }
}
