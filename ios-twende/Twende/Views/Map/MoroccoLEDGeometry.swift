import SceneKit
import simd

/// Static illustrative campaign on the user's reported wraparound Exchange Tower LED frontage.
/// Not live advertising inventory or a claim about the advertiser currently on site.
enum MoroccoLEDGeometry {
    static func add(ring: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        let outward = BuildingContour.outwardNormals(ring)
        let screenRing = zip(ring, outward).map { $0 + $1 * 0.45 }
        var bezel = BuildingMesh()
        bezel.perimeter(rings: [screenRing], bottom: 2.05, top: 6.25, projection: 0.14)
        root.addChildNode(bezel.node(name: "exchangeLEDBlackHousing", material: P.dark))
        let colours = ["#418D98", "#C5AA76", "#E22332"]
        var panels = colours.map { _ in BuildingMesh() }
        for i in screenRing.indices {
            let a = screenRing[i], b = screenRing[(i + 1) % screenRing.count]
            let n0 = outward[i], n1 = outward[(i + 1) % screenRing.count]
            let segments = max(1, Int(ceil(simd_distance(a,b)/7)))
            for segment in 0..<segments {
                let t0 = Double(segment)/Double(segments), t1 = Double(segment+1)/Double(segments)
                let p = a+(b-a)*t0, q = a+(b-a)*t1
                let m0 = simd_normalize(n0*(1-t0)+n1*t0), m1 = simd_normalize(n0*(1-t1)+n1*t1)
                panels[(i/7+segment)%colours.count].smoothQuad(P.p(p+m0*0.16,2.3),P.p(q+m1*0.16,2.3),
                    P.p(q+m1*0.16,6.0),P.p(p+m0*0.16,6.0),normals:[P.p(m0,0),P.p(m1,0),P.p(m1,0),P.p(m0,0)])
            }
        }
        for i in colours.indices {
            root.addChildNode(panels[i].node(name: "exchangeLEDArtwork", material:
                BuildingSurfaces.make("landmark.ledScreen", color: colours[i], roughness: 1)))
        }
        guard let edge = ring.indices.filter({ simd_distance(ring[$0],ring[($0+1)%ring.count])>15 }).max(by: {
            // South/east street faces, rather than the mall-facing interior edge.
            let na = outward[$0], nb = outward[$1]
            return na.x-na.y < nb.x-nb.y
        }) else { return }
        let a = screenRing[edge], b = screenRing[(edge+1)%screenRing.count], d = simd_normalize(b-a)
        let n = SIMD2(d.y,-d.x), centre = (a+b)/2+n*0.25
        var letters = DioramaMesh()
        DioramaLettering.line("TWENDE",centre:DV3(centre.x,centre.y,3.8),up:DV3(0,0,1),facing:DV3(n.x,n.y,0),
            height:1.3,swatch:.whitewash,mesh:&letters)
        var converted = BuildingMesh(); converted.append(letters)
        root.addChildNode(converted.node(name:"exchangeLEDCampaignTitle",material:
            BuildingSurfaces.make("landmark.ledScreen",color:"#F4EFE7",roughness:1)))
    }
}
