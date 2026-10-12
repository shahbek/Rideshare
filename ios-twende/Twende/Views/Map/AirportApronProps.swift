import SceneKit
import simd

/// Deterministic illustrative parked activity, not live aircraft/vehicle locations or a surveyed inventory.
enum AirportApronProps {
    static func add(_ data: AirportMapData, site: DarLandmarkSite, root: SCNNode) {
        let origin = site.anchor.coordinate, boundary = data.boundary.local(origin: origin)
        let occupied = data.features.filter { $0.isClosed && $0.tags["building"] != nil }.map { $0.local(origin: origin) }
        let bridges = data.features.filter { $0.tags["aeroway"] == "jet_bridge" }.map { $0.local(origin: origin) }
        let roads = data.features.filter { $0.tags["highway"] != nil }.map { $0.local(origin: origin) }
        let aprons = data.features.filter { $0.isClosed && $0.tags["aeroway"] == "apron" }.map { $0.local(origin: origin) }
        func intersects(_ a: [DV2], _ b: [DV2]) -> Bool {
            a.contains { DioramaPolygon.contains(b, $0) } || b.contains { DioramaPolygon.contains(a, $0) }
            || a.indices.contains { i in b.indices.contains { j in DioramaPolygon.segmentsIntersect(a[i], a[(i + 1) % a.count], b[j], b[(j + 1) % b.count]) } }
        }
        var placements: [[DV2]] = []
        let plane = AirportAircraftGeometry.make(), fork = AirportEquipmentGeometry.forklift(), tractor = AirportEquipmentGeometry.tractor()
        let terminals = data.features.filter { [597787841, 23359828].contains($0.id) }.map { $0.local(origin: origin) }
        for (index, f) in data.features.filter({ $0.tags["aeroway"] == "parking_position" }).sorted(by: { $0.id < $1.id }).enumerated() where index % 3 == 0 {
            let line = f.local(origin: origin)
            guard let first = line.first, let last = line.last, first.distance(to: last) > 35 else { continue }
            func distance(_ p: DV2) -> Double { terminals.map { DioramaPolygon.distanceToRing($0, p) }.min() ?? .infinity }
            let near = distance(first) < distance(last) ? first : last, far = near == first ? last : first
            let along = (far - near).normalized, centre = near + along * 25
            let area = DioramaOrientedRect(centre: centre, axis: along, halfLength: 20, halfWidth: 18.5).corners
            guard area.allSatisfy({ DioramaPolygon.contains(boundary, $0) && DioramaPolygon.distanceToRing(boundary, $0) > 1 }),
                  aprons.contains(where: { ring in area.allSatisfy { DioramaPolygon.contains(ring, $0) } }),
                  !occupied.contains(where: { intersects(area, $0) }), !placements.contains(where: { intersects(area, $0) }),
                  !bridges.contains(where: { path in path.contains { DioramaPolygon.contains(area, $0) } }) else { continue }
            placements.append(area)
            AirportInstanceGeometry.place(plane, id: "airliner", at: SIMD3(centre.x, centre.y, 0.2), angle: atan2(-along.y, -along.x), root: root)
            for (model, id, offset, radius) in [(fork, "forklift", 13.0, 3.1), (tractor, "baggageTractor", -12.0, 9.0)] {
                let p = centre + along.left * offset + along * 15
                guard DioramaPolygon.contains(boundary, p), DioramaPolygon.distanceToRing(boundary, p) > radius,
                      aprons.contains(where: { DioramaPolygon.contains($0, p) && DioramaPolygon.distanceToRing($0, p) > radius }),
                      !occupied.contains(where: { DioramaPolygon.contains($0, p) || DioramaPolygon.distanceToRing($0, p) < radius }) else { continue }
                AirportInstanceGeometry.place(model, id: id, at: SIMD3(p.x, p.y, 0.2), angle: atan2(along.y, along.x), root: root)
            }
        }
        let cars = [DioramaSwatch.carSilver, .carWhite, .carRed].map { AirportInstanceGeometry.colored(DioramaPropLibrary.makeCar($0)) }
        for f in data.features where f.isClosed && f.tags["amenity"] == "parking" {
            let ring = f.local(origin: origin), bounds = DioramaRect.bounding(ring)
            for (index, bay) in AirportGroundGeometry.parkingBays(ring, roads: roads, occupied: occupied).enumerated() where index % 4 != 0 {
                let x = bounds.minX + 12 + ((bay.centre.x - bounds.minX - 12) / 32).rounded() * 32
                let y = bounds.minY + 12 + ((bay.centre.y - bounds.minY - 12) / 32).rounded() * 32
                guard bay.centre.distance(to: DV2(x, y)) > 3, bay.corners.allSatisfy({ DioramaPolygon.contains(boundary, $0) }) else { continue }
                AirportInstanceGeometry.place(cars[index % cars.count], id: "parkedCar\(index % cars.count)", at: SIMD3(bay.centre.x, bay.centre.y, 0.2), angle: atan2(bay.axis.y, bay.axis.x), root: root)
            }
        }
        print("[DarLandmarks] JNIA illustrative activity: \(placements.count) non-overlapping aircraft placements; props use shared prototypes")
    }
}
