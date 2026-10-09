import SceneKit
import simd

/// Authored top-storey office below the roof, with floor-supported furniture and a clear circulation spine.
enum AirtelOfficeGeometry {
    static func add(to root: SCNNode, ring: [SIMD2<Double>], floor: Double, ceiling: Double) {
        typealias P = DarLandmarkParts
        guard ring.count >= 3, floor.isFinite, ceiling.isFinite, ceiling - floor >= 3,
              let edge = ring.indices.max(by: {
            simd_distance(ring[$0], ring[($0 + 1) % ring.count]) < simd_distance(ring[$1], ring[($1 + 1) % ring.count])
        }) else { return }
        var along = simd_normalize(ring[(edge + 1) % ring.count] - ring[edge])
        if along.x < 0 { along = -along }
        let across = SIMD2(-along.y, along.x)
        let local = ring.map { SIMD2(simd_dot($0, along), simd_dot($0, across)) }
        let room = SCNNode(); room.name = "panoramicOfficeInterior"
        let finishedFloor = floor + 0.22
        room.simdTransform = simd_float4x4(columns: (
            SIMD4(Float(along.x), Float(along.y), 0, 0), SIMD4(Float(across.x), Float(across.y), 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        root.addChildNode(room)
        let timber = BuildingSurfaces.make("surface.timber", color: "#B3987A", roughness: 0.85)
        let fabric = BuildingSurfaces.make("office.fabric", color: "#30494E", roughness: 1)
        let display = BuildingSurfaces.make("office.display", color: "#418D98", roughness: 1)
        let rug = BuildingSurfaces.make("office.rug", color: "#B9C7A6", roughness: 1)
        let floorRing = DioramaPolygon.offset(local.map { DV2($0.x, $0.y) }, by: -0.28)?.map { SIMD2($0.x, $0.y) } ?? local
        P.volume(floorRing, bottom: floor, top: finishedFloor, material: P.plaster, name: "officeTerrazzoFloor", root: room)
        let polygon = floorRing.map { DV2($0.x, $0.y) }
        let minX = local.map(\.x).min() ?? 0, maxX = local.map(\.x).max() ?? 0
        let minY = local.map(\.y).min() ?? 0, maxY = local.map(\.y).max() ?? 0
        let midY = (minY + maxY) * 0.5, length = maxX - minX, z = finishedFloor
        func fits(_ x: Double, _ y: Double, _ width: Double, _ depth: Double) -> Bool {
            let box = P.rectangle(x: x, y: y, width: width, depth: depth)
            return box.indices.allSatisfy { i in
                let a = box[i], b = box[(i + 1) % box.count]
                return (0...12).allSatisfy { step in
                    let p = a + (b - a) * (Double(step) / 12)
                    return DioramaPolygon.contains(polygon, DV2(p.x, p.y)) && DioramaPolygon.distanceToRing(polygon, DV2(p.x, p.y)) > 0.6
                }
            }
        }
        func box(_ x: Double, _ y: Double, _ w: Double, _ d: Double, _ low: Double, _ high: Double, _ material: SCNMaterial, _ name: String) {
            P.volume(P.rectangle(x: x, y: y, width: w, depth: d), bottom: low, top: high, material: material, name: name, root: room)
        }
        func chair(_ x: Double, _ y: Double, facing: Double) {
            box(x, y, 0.78, 0.74, z + 0.45, z + 0.64, fabric, "officeChairSeat")
            box(x, y - facing * 0.33, 0.78, 0.18, z + 0.55, z + 1.28, fabric, "officeChairBack")
            box(x, y, 0.15, 0.15, z + 0.1, z + 0.45, P.silver, "officeChairStem")
            box(x, y, 0.68, 0.58, z, z + 0.12, P.silver, "officeChairBase")
        }
        // Two coherent work zones flank a 2.6m unobstructed central aisle.
        for x in [minX + length * 0.34, minX + length * 0.49, minX + length * 0.64] {
            for side in [-1.0, 1.0] {
                let y = midY + side * 3.7
                guard fits(x, y, 4.0, 4.2) else { continue }
                box(x, y, 3.6, 1.65, z + 0.75, z + 0.93, timber, "pairedBenchDesk")
                for dx in [-1.35, 1.35] { box(x + dx, y, 0.22, 1.2, z, z + 0.75, P.plaster, "deskPedestal") }
                box(x, y + side * 0.60, 3.3, 0.18, z + 0.93, z + 1.35, rug, "lowAcousticDivider")
                for dx in [-0.9, 0.9] {
                    box(x + dx, y + side * 0.25, 0.13, 0.13, z + 0.93, z + 1.15, P.silver, "monitorStand")
                    box(x + dx, y + side * 0.25, 0.83, 0.18, z + 1.1, z + 1.67, fabric, "desktopMonitor")
                    box(x + dx, y + side * 0.15, 0.70, 0.025, z + 1.2, z + 1.56, display, "monitorDisplay")
                    box(x + dx, y - side * 0.23, 0.61, 0.26, z + 0.94, z + 1.0, fabric, "keyboard")
                    chair(x + dx, y - side * 1.45, facing: side)
                }
                box(x, y, 2.4, 0.22, ceiling - 0.18, ceiling - 0.10, LandmarkLightingGeometry.lamp, "architecturalLighting")
                LandmarkLightingGeometry.fixture(at: SIMD3(x, y, ceiling - 0.45), radius: 6, intensity: 0.9, root: room)
            }
        }
        let meetingX = minX + length * 0.84
        if fits(meetingX, midY, 6.6, 6.0) {
            box(meetingX, midY, 6.1, 5.5, z, z + 0.055, rug, "meetingAreaRug")
            box(meetingX, midY, 4.8, 2.15, z + 0.76, z + 0.94, timber, "roundedConferenceTable")
            for dx in [-1.5, 1.5] { box(meetingX + dx, midY, 0.38, 0.85, z, z + 0.76, P.plaster, "conferencePedestal") }
            for dx in [-1.5, 0, 1.5] {
                chair(meetingX + dx, midY - 1.75, facing: 1)
                chair(meetingX + dx, midY + 1.75, facing: -1)
            }
            box(meetingX, midY, 0.75, 0.45, z + 0.94, z + 1.00, fabric, "conferenceTablet")
        }
        let loungeX = minX + length * 0.13
        if fits(loungeX, midY, 5.3, 5.8) {
            box(loungeX, midY, 4.7, 5.0, z, z + 0.055, rug, "loungeRug")
            for side in [-1.0, 1.0] {
                box(loungeX, midY + side * 1.65, 2.95, 0.65, z + 0.055, z + 0.23, fabric, "loungeSofaPlinth")
                box(loungeX, midY + side * 1.65, 3.3, 0.9, z + 0.2, z + 0.62, P.trim, "loungeSofaSeat")
                box(loungeX, midY + side * 2.05, 3.3, 0.25, z + 0.4, z + 1.2, P.trim, "loungeSofaBack")
            }
            box(loungeX, midY, 1.2, 0.6, z + 0.055, z + 0.34, P.plaster, "loungeCoffeeTableBase")
            box(loungeX, midY, 2.5, 1.1, z + 0.32, z + 0.52, timber, "loungeCoffeeTable")
        }
        // Low joinery and greenery stay beside the glass, never across the circulation spine.
        for x in [minX + length * 0.22, minX + length * 0.74] {
            for side in [-1.0, 1.0] {
                let y = midY + side * ((maxY - minY) * 0.5 - 1.9)
                guard fits(x, y, 2.5, 1.6) else { continue }
                box(x, y, 2.1, 0.8, z, z + 0.95, timber, "perimeterCredenza")
                var plant = BuildingMesh()
                plant.revolve(centre: SIMD2(x, y), profile: [SIMD2(0.22,z+0.95), SIMD2(0.33,z+1.38), SIMD2(0.48,z+1.66), SIMD2(0.28,z+2.03), SIMD2(0,z+2.13)], segments: 16)
                room.addChildNode(plant.node(name: "officePlant", material: BuildingSurfaces.make("landmark.foliage", color: "#638238", roughness: 1)))
            }
        }
    }
}
