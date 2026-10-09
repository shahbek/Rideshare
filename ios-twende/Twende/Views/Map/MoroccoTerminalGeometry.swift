import SceneKit
import simd

/// Contemporary open-air DART platform on the verified long road-median footprint.
enum MoroccoTerminalGeometry {
    static func make(_ site: DarLandmarkSite) -> SCNScene {
        typealias P = DarLandmarkParts
        let scene = SCNScene()
        guard let ring = site.footprint?.rings.first, ring.count >= 4,
              let edge = ring.indices.max(by: {
                  simd_distance(ring[$0],ring[($0+1)%ring.count]) < simd_distance(ring[$1],ring[($1+1)%ring.count])
              }) else { return scene }
        var along = simd_normalize(ring[(edge+1)%ring.count]-ring[edge])
        if along.y < 0 { along = -along }
        let across = SIMD2(along.y,-along.x)
        // x is across the platform; y is along it. Positive determinant, no mirrored winding.
        let local = ring.map { SIMD2(simd_dot($0,across),simd_dot($0,along)) }
        let root = SCNNode(); root.name = "moroccoOpenAirTerminal"
        root.simdTransform = simd_float4x4(columns: (
            SIMD4(Float(across.x),Float(across.y),0,0),SIMD4(Float(along.x),Float(along.y),0,0),
            SIMD4(0,0,1,0),SIMD4(0,0,0,1)))
        scene.rootNode.addChildNode(root)
        let minX = local.map(\.x).min() ?? 0, maxX = local.map(\.x).max() ?? 0
        let minY = local.map(\.y).min() ?? 0, maxY = local.map(\.y).max() ?? 0
        let mid = (minX+maxX)/2, half = (maxX-minX)/2-0.28
        let start = minY+0.4, end = maxY-0.4
        guard half>2, end-start>10 else { return scene }
        let canopyGreen = BuildingSurfaces.make("landmark.slate",color:"#365A2D",roughness:0.9)
        let soffit = BuildingSurfaces.make("terminal.soffit",color:"#B9C7A6",roughness:0.9)
        let steel = BuildingSurfaces.make("landmark.silver",color:"#BFCBCB",roughness:0.75)
        let graphite = BuildingSurfaces.make("terminal.steel",color:"#30494E",roughness:0.8)
        // One platform, no walls: both long boarding edges remain completely open.
        root.addChildNode(BuildingFootprint(rings:[local]).deck(at:0.15,thickness:0.68,material:P.plaster,name:"raisedDARTPlatform"))
        var greenRoof = BuildingMesh(), underside = BuildingMesh(), ribs = BuildingMesh(), columns = BuildingMesh(), lights = BuildingMesh()
        let valley = 5.35, eave = 6.15, thickness = 0.22
        // Two closed shallow butterfly roof wings, joined at the central drainage spine.
        for side in [-1.0,1.0] {
            let x = mid+side*half
            let a = SIMD3(mid,start,valley), b = SIMD3(x,start,eave), c = SIMD3(x,end,eave), d = SIMD3(mid,end,valley)
            let normal = simd_normalize(SIMD3(-side*(eave-valley)/half,0,1))
            greenRoof.quad(a,b,c,d,normal:normal)
            let drop = SIMD3(0.0,0.0,thickness)
            underside.quad(d-drop,c-drop,b-drop,a-drop,normal:-normal)
            greenRoof.quad(a-drop,b-drop,b,a,normal:SIMD3(0,-1,0))
            greenRoof.quad(c-drop,d-drop,d,c,normal:SIMD3(0,1,0))
            greenRoof.quad(b-drop,c-drop,c,b,normal:SIMD3(side,0,0))
        }
        let bays = max(2,Int(ceil((end-start)/12)))
        for bay in 0...bays {
            let y = start+(end-start)*Double(bay)/Double(bays)
            for side in [-1.0,1.0] {
                let foot = SIMD3(mid+side*1.8,y,0.83), joint = SIMD3(mid+side*1.8,y,4.25)
                LandmarkMesh.beam(&columns,from:foot,to:joint,radius:0.20,sides:10)
                LandmarkMesh.beam(&ribs,from:joint,to:SIMD3(mid,y,valley-thickness),radius:0.17,sides:8)
                LandmarkMesh.beam(&ribs,from:joint,to:SIMD3(mid+side*half,y,eave-thickness),radius:0.18,sides:8)
                LandmarkMesh.beam(&ribs,from:SIMD3(mid,y,valley-thickness),to:SIMD3(mid+side*half,y,eave-thickness),radius:0.14,sides:8)
                LandmarkMesh.beam(&lights,from:SIMD3(mid+side*half*0.50,max(start,y-1.4),5.32),to:SIMD3(mid+side*half*0.50,min(end,y+1.4),5.32),radius:0.055,sides:8)
            }
            if bay % 2 == 1 {
                P.volume(P.rectangle(x:mid,y:y,width:2.6,depth:0.8),bottom:1.13,top:1.34,material:P.trim,name:"terminalBench",root:root)
                P.volume(P.rectangle(x:mid,y:y+0.32,width:2.6,depth:0.16),bottom:1.34,top:2.08,material:graphite,name:"terminalBenchBack",root:root)
                for dx in [-0.9,0.9] {
                    P.volume(P.rectangle(x:mid+dx,y:y,width:0.2,depth:0.55),bottom:0.83,top:1.13,material:steel,name:"terminalBenchSupport",root:root)
                }
                LandmarkLightingGeometry.fixture(at:SIMD3(mid,y,4.9),radius:9,intensity:1.0,root:root)
            }
        }
        for side in [-1.0,1.0] {
            LandmarkMesh.beam(&ribs,from:SIMD3(mid+side*half,start,eave-thickness),to:SIMD3(mid+side*half,end,eave-thickness),radius:0.16,sides:8)
        }
        LandmarkMesh.beam(&ribs,from:SIMD3(mid,start,valley-thickness),to:SIMD3(mid,end,valley-thickness),radius:0.15,sides:8)
        root.addChildNode(greenRoof.node(name:"greenButterflyTerminalRoof",material:canopyGreen))
        root.addChildNode(underside.node(name:"paleGreenCanopySoffit",material:soffit))
        root.addChildNode(columns.node(name:"openAirSteelColumns",material:steel))
        root.addChildNode(ribs.node(name:"roundedBranchingRoofBeams",material:graphite))
        root.addChildNode(lights.node(name:"architecturalLighting",material:LandmarkLightingGeometry.lamp))
        // Tactile guidance and benches are platform furniture, not markings painted on the road.
        for side in [-1.0,1.0] {
            P.volume(P.rectangle(x:mid+side*(half-0.7),y:(start+end)/2,width:0.30,depth:end-start-1.0),
                bottom:0.83,top:0.86,material:P.trim,name:"platformTactileGuide",root:root)
        }
        for signY in [start+2,end-2] {
            P.volume(P.rectangle(x:mid,y:signY,width:4.8,depth:0.22),bottom:3.7,top:4.65,material:graphite,name:"terminalWayfindingBoard",root:root)
            for side in [-1.0,1.0] {
                var text = DioramaMesh()
                DioramaLettering.line("MOROCCO",centre:DV3(mid,signY+side*0.14,3.91),up:DV3(0,0,1),facing:DV3(0,side,0),
                    height:0.5,swatch:.whitewash,mesh:&text)
                var mesh = BuildingMesh(); mesh.append(text)
                root.addChildNode(mesh.node(name:"terminalName",material:P.plaster))
            }
        }
        return scene
    }
}
