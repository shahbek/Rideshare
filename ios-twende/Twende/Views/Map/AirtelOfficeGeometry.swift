import SceneKit
import simd

/// Illustrative panoramic office, not a reconstruction of Airtel's private interior.
/// Static, chunky furniture keeps the Apple Maps-style miniature readable without an animation clock.
enum AirtelOfficeGeometry {
    static func add(to root: SCNNode, ring: [SIMD2<Double>], floor: Double, ceiling: Double) {
        typealias P = DarLandmarkParts
        let footprint = BuildingFootprint(rings: [ring])
        let inset = DioramaPolygon.offset(ring.map { DV2($0.x, $0.y) }, by: -0.8)
        let floorRing = inset?.map { SIMD2($0.x, $0.y) } ?? ring
        P.volume(floorRing, bottom: floor, top: floor + 0.22, material: P.trim, name: "officeFloor", root: root)
        let timber = BuildingSurfaces.make("surface.timber", color: "#B3987A", roughness: 0.8)
        let fabric = BuildingSurfaces.make("office.fabric", color: "#30494E", roughness: 0.9)
        let partition = BuildingSurfaces.make("office.partition", color: "#C9C2B6", roughness: 0.9)
        let screen = BuildingSurfaces.make("office.monitor", color: "#BFCBCB", roughness: 0.6)
        let minX = ring.map(\.x).min() ?? 0, maxX = ring.map(\.x).max() ?? 0
        let minY = ring.map(\.y).min() ?? 0, maxY = ring.map(\.y).max() ?? 0
        let z = floor + 0.22
        func fits(x: Double, y: Double, width: Double, depth: Double) -> Bool {
            let rectangle = P.rectangle(x: x, y: y, width: width, depth: depth)
            let polygon = ring.map { DV2($0.x, $0.y) }
            return rectangle.allSatisfy { footprint.path.contains(CGPoint(x: $0.x, y: $0.y)) }
                && !polygon.contains { abs($0.x - x) < width / 2 && abs($0.y - y) < depth / 2 }
        }
        func box(_ x: Double, _ y: Double, _ width: Double, _ depth: Double, _ low: Double, _ high: Double, _ material: SCNMaterial, _ name: String) {
            P.volume(P.rectangle(x: x, y: y, width: width, depth: depth), bottom: low, top: high, material: material, name: name, root: root)
        }
        var count = 0
        for y in stride(from: minY + 3.3, through: maxY - 3.3, by: 5.0) {
            for x in stride(from: minX + 3.3, through: maxX - 3.3, by: 4.8) {
                guard count < 16, fits(x: x, y: y, width: 4.1, depth: 4.1) else { continue }
                count += 1
                box(x, y, 2.7, 1.35, z + 0.78, z + 0.97, timber, "roundedOfficeDesk")
                for dx in [-1.05, 1.05] { box(x + dx, y, 0.22, 0.9, z, z + 0.78, P.silver, "deskPedestal") }
                box(x, y + 0.3, 0.14, 0.14, z + 0.97, z + 1.25, P.silver, "monitorStand")
                box(x, y + 0.3, 0.92, 0.20, z + 1.20, z + 1.85, fabric, "desktopMonitor")
                box(x, y + 0.18, 0.75, 0.025, z + 1.30, z + 1.73, screen, "monitorDisplay")
                box(x, y - 0.2, 0.70, 0.27, z + 0.97, z + 1.04, fabric, "keyboard")
                box(x, y - 1.3, 0.9, 0.8, z + 0.45, z + 0.67, fabric, "officeChairSeat")
                box(x, y - 1.65, 0.9, 0.22, z + 0.6, z + 1.43, fabric, "officeChairBack")
                box(x, y - 1.3, 0.22, 0.22, z + 0.08, z + 0.45, P.silver, "chairStem")
                box(x, y - 1.3, 0.85, 0.7, z, z + 0.12, fabric, "chairBase")
                box(x, y + 1.0, 3.3, 0.25, z, z + 1.55, partition, "cubicleBack")
                box(x - 1.6, y + 0.25, 0.25, 1.6, z, z + 1.55, partition, "cubicleSide")
                box(x, y, 1.8, 0.48, ceiling - 0.22, ceiling - 0.10, LandmarkLightingGeometry.lamp, "architecturalLighting")
                LandmarkLightingGeometry.fixture(at: SIMD3(x, y, ceiling - 0.65), radius: 6, intensity: 1.1, root: root)
            }
        }
    }
}
