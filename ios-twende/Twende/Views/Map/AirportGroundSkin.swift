import SceneKit
import simd

/// Disjoint mapped ground union, subdivided on the same 240 m grid as saved airport chunks.
enum AirportGroundSkin {
    static func add(_ data: AirportMapData, root: SCNNode) {
        let origin = data.site.anchor.coordinate
        let triangles = data.groundRings(origin: origin).flatMap { source -> [[DV2]] in
            let ring = DioramaPolygon.counterClockwise(source)
            return DioramaPolygon.triangulate(ring).map { [ring[$0.0], ring[$0.1], ring[$0.2]] }
        }
        let pieces = DioramaStreetSurface(triangles).pieces()
        let bounds = data.groundRect(origin: origin)
        for x in stride(from: floor(bounds.minX / 240) * 240, to: bounds.maxX, by: 240) {
            for y in stride(from: floor(bounds.minY / 240) * 240, to: bounds.maxY, by: 240) {
                let cell = DioramaRect(minX: x, minY: y, maxX: x + 240, maxY: y + 240)
                var mesh = BuildingMesh()
                for piece in pieces where DioramaRect.bounding(piece).intersects(cell) {
                    let clipped = DioramaPolygon.clipPolygon(piece, to: cell)
                    for (a, b, c) in DioramaPolygon.triangulate(clipped) {
                        mesh.triangle(SIMD3(clipped[a].x, clipped[a].y, 0.2), SIMD3(clipped[b].x, clipped[b].y, 0.2), SIMD3(clipped[c].x, clipped[c].y, 0.2), normal: SIMD3(0, 0, 1))
                    }
                }
                root.addChildNode(mesh.node(name: "airportPaintedGround", material: BuildingSurfaces.make("landmark.airportGround", color: "#365A2D", roughness: 1)))
            }
        }
    }
}
