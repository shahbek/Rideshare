import Foundation

/// A single source building with real courtyard/priority cutouts, not a house per triangulation piece.
nonisolated enum DioramaClippedBuilding {
    static func build(_ f: DioramaBuildingFeature, terrain: DioramaTerrain, config: DioramaConfig, mesh: inout DioramaMesh) -> DioramaBuilt {
        let base = terrain.buildingHeight(f)
        let height = max(2.8, f.height ?? 3.2)
        let floors = max(1, Int((height / config.floorHeight).rounded()))
        let surface = DioramaStreetSurface(f.occupiedPieces)
        let edges = surface.boundary()
        for piece in f.occupiedPieces { mesh.polygon(piece, z: base + height, .roofConcrete) }
        for edge in edges {
            let a = edge.a, b = edge.b
            let axis = (b - a).normalized, out = axis.right
            mesh.quad(DV3(a, terrain.height(a) - 0.25), DV3(b, terrain.height(b) - 0.25), DV3(b, base), DV3(a, base), .concrete, normal: DV3(out, 0))
            mesh.quad(DV3(a, base), DV3(b, base), DV3(b, base + height), DV3(a, base + height), .whitewash, normal: DV3(out, 0))
            // Source facades only: no invented windows against another owner's cut face.
            let midpoint = (a + b) * 0.5
            guard DioramaPolygon.distanceToRing(f.ring, midpoint) < 0.15 else { continue }
            for station in stride(from: 1.5, to: a.distance(to: b) - 1, by: 3) {
                let p = a + axis * station + out * 0.012
                for floor in 0..<floors {
                    let z = base + Double(floor) * height / Double(floors) + 1.0
                    mesh.quad(DV3(p - axis * 0.5, z), DV3(p + axis * 0.5, z),
                              DV3(p + axis * 0.5, min(z + 1.15, base + height - 0.3)),
                              DV3(p - axis * 0.5, min(z + 1.15, base + height - 0.3)), .glass, normal: DV3(out, 0))
                }
            }
        }
        let entranceEdge = edges.max { $0.a.distance(to: $0.b) < $1.a.distance(to: $1.b) }
        return DioramaBuilt(feature: f, kind: floors > 2 ? .apartments : .villa, floors: floors, height: height,
            box: DioramaPolygon.minimumAreaRectangle(f.ring), flatRoof: true, wallColor: .whitewash,
            entrance: entranceEdge.map { ($0.a + $0.b) * 0.5 } ?? f.centroid,
            entranceOut: entranceEdge.map { ($0.b - $0.a).normalized.right } ?? DV2(1, 0))
    }
}
