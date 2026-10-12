import SceneKit
import simd

/// Many visible lenses, sparse shared illumination; no per-lamp shadows or idle animation.
enum AirportLightingGeometry {
    static func downlight() -> SCNNode {
        let node = SCNNode()
        var metal = BuildingMesh(), lens = BuildingMesh()
        metal.revolve(centre: .zero, profile: [SIMD2(0.12, -0.035), SIMD2(0.17, -0.035), SIMD2(0.17, 0.035), SIMD2(0.12, 0.035)], segments: 10)
        lens.revolve(centre: .zero, profile: [SIMD2(0, -0.04), SIMD2(0.13, -0.04), SIMD2(0.13, 0.01), SIMD2(0, 0.01)], segments: 10)
        node.addChildNode(metal.node(name: "spotlightTrim", material: DarLandmarkParts.silver))
        node.addChildNode(lens.node(name: "architecturalLighting", material: LandmarkLightingGeometry.lamp))
        return node
    }

    private static func beacon(_ color: String) -> SCNNode {
        var housing = BuildingMesh(), lens = BuildingMesh()
        housing.revolve(centre: .zero, profile: [SIMD2(0, 0), SIMD2(0.17, 0), SIMD2(0.13, 0.17), SIMD2(0, 0.17)], segments: 8)
        lens.revolve(centre: .zero, profile: [SIMD2(0, 0.17), SIMD2(0.12, 0.17), SIMD2(0.12, 0.29), SIMD2(0, 0.29)], segments: 8)
        let node = SCNNode()
        node.addChildNode(housing.node(name: "airfieldLightBase", material: DarLandmarkParts.dark))
        node.addChildNode(lens.node(name: "architecturalLighting", material: BuildingSurfaces.make("airport.airfieldLens", color: color, roughness: 0.6)))
        return node
    }

    static func add(_ data: AirportMapData, site: DarLandmarkSite, root: SCNNode) {
        let boundary = data.boundary.local(origin: site.anchor.coordinate)
        let white = beacon("#FFE3A6"), blue = beacon("#216391"), green = beacon("#638238"), red = beacon("#C13515")
        func fits(_ p: DV2, clearance: Double = 0.4) -> Bool { DioramaPolygon.contains(boundary, p) && DioramaPolygon.distanceToRing(boundary, p) > clearance }
        for f in data.features where f.tags["aeroway"] == "runway" {
            let line = f.local(origin: site.anchor.coordinate)
            guard let a = line.first, let b = line.last else { continue }
            let axis = (b - a).normalized, width = Double(f.tags["width"] ?? "") ?? 30, length = a.distance(to: b)
            for station in stride(from: 0.0, through: length, by: 60.0) {
                // Follow the mapped polyline, not a chord replacing a curved source path.
                let p = point(line, at: station)
                for side in [-1.0, 1.0] {
                    let q = p + axis.left * (side * (width / 2 + 0.6))
                    if fits(q) { AirportInstanceGeometry.place(white, id: "runwayWhite", at: SIMD3(q.x, q.y, 0.2), root: root) }
                }
                if fits(p) { AirportInstanceGeometry.place(white, id: "runwayCentre", at: SIMD3(p.x, p.y, 0.2), scale: 0.6, root: root) }
            }
            for (end, direction) in [(a, axis), (b, -axis)] {
                for x in stride(from: -width / 2 + 2, through: width / 2 - 2, by: 3.0) {
                    let q = end + direction * 2 + axis.left * x
                    guard fits(q) else { continue }
                    AirportInstanceGeometry.place(green, id: "thresholdGreen", at: SIMD3(q.x, q.y, 0.2), root: root)
                    let r = q - direction * 4
                    if fits(r) { AirportInstanceGeometry.place(red, id: "runwayEndRed", at: SIMD3(r.x, r.y, 0.2), root: root) }
                }
            }
        }
        for f in data.features where f.tags["aeroway"] == "taxiway" {
            let line = f.local(origin: site.anchor.coordinate)
            guard line.count >= 2 else { continue }
            let length = zip(line, line.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            for station in stride(from: 15.0, to: length, by: 45.0) {
                let p = point(line, at: station), q = point(line, at: min(length, station + 1)), axis = (q - p).normalized
                for side in [-1.0, 1.0] {
                    let edge = p + axis.left * (side * ((Double(f.tags["width"] ?? "") ?? 23) / 2 + 0.5))
                    if fits(edge) { AirportInstanceGeometry.place(blue, id: "taxiBlue", at: SIMD3(edge.x, edge.y, 0.2), root: root) }
                }
            }
        }
        var mast = BuildingMesh(), lamps = BuildingMesh()
        LandmarkMesh.beam(&mast, from: SIMD3(0, 0, 0), to: SIMD3(0, 0, 9), radius: 0.12, sides: 8)
        LandmarkMesh.beam(&mast, from: SIMD3(-1.6, 0, 8.8), to: SIMD3(1.6, 0, 8.8), radius: 0.09, sides: 6)
        for x in [-1.6, 1.6] { AirportArchitectureParts.box(&lamps, centre: SIMD2(x, 0), width: 0.7, depth: 0.35, bottom: 8.75, top: 8.9) }
        let parkingLight = SCNNode()
        parkingLight.addChildNode(mast.node(name: "parkingLightPole", material: DarLandmarkParts.silver))
        parkingLight.addChildNode(lamps.node(name: "architecturalLighting", material: LandmarkLightingGeometry.lamp))
        for f in data.features where f.isClosed && f.tags["amenity"] == "parking" {
            let ring = f.local(origin: site.anchor.coordinate), bounds = DioramaRect.bounding(ring)
            for x in stride(from: bounds.minX + 12, to: bounds.maxX - 8, by: 32.0) {
                for y in stride(from: bounds.minY + 12, to: bounds.maxY - 8, by: 32.0) {
                    let p = DV2(x, y)
                    guard DioramaPolygon.contains(ring, p), DioramaPolygon.distanceToRing(ring, p) > 3, fits(p, clearance: 3) else { continue }
                    AirportInstanceGeometry.place(parkingLight, id: "parkingMast", at: SIMD3(x, y, 0.2), root: root)
                    LandmarkLightingGeometry.fixture(at: SIMD3(x, y, 8.7), radius: 30, intensity: 2.2, root: root)
                }
            }
        }
    }

    private static func point(_ line: [DV2], at distance: Double) -> DV2 {
        var left = distance
        for (a, b) in zip(line, line.dropFirst()) {
            let length = a.distance(to: b)
            if left <= length { return a + (b - a) * (left / max(0.001, length)) }
            left -= length
        }
        return line.last ?? .zero
    }
}
