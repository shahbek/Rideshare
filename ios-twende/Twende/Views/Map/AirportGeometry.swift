import SceneKit
import simd

/// Full mapped airport plan with photo-led terminal architecture, no imported building assets.
enum AirportGeometry {
    static func make(_ data: AirportMapData, site: DarLandmarkSite) -> SCNScene {
        let scene = SCNScene(), root = scene.rootNode
        let boundary = data.boundary.local(origin: site.anchor.coordinate)
        AirportGroundSkin.add(data, root: root)
        AirportControlTowerGeometry.add(data, root: root)
        let protected = Set([23359828, 597787841, 1188629104, 1237792404, AirportControlTowerGeometry.sourceID])
        let bridgePoints = data.features.filter { $0.tags["aeroway"] == "jet_bridge" }.flatMap { $0.local(origin: site.anchor.coordinate) }
        for f in data.features where [23359828, 597787841, 1188629104].contains(f.id) {
            let ring = f.local(origin: site.anchor.coordinate)
            let roots = bridgePoints.filter { DioramaPolygon.distanceToRing(ring, $0) < 0.15 }
            AirportTerminalGeometry.add(f, site: site, boardingRoots: roots, root: root)
        }
        for f in data.features where f.tags["building"] != nil && f.isClosed && !protected.contains(f.id) {
            let ring = f.local(origin: site.anchor.coordinate).map { SIMD2($0.x, $0.y) }
            guard ring.count >= 3, ring.allSatisfy({ inside($0, boundary: boundary, clearance: 0.1) }) else { continue }
            let height = f.id == 438449951 ? 7.2 : min(48, max(3.2, Double(f.tags["height"] ?? "") ?? (Double(f.tags["building:levels"] ?? "") ?? 1) * 3.6))
            AirportArchitectureParts.shell(ring, height: height, id: f.id, root: root)
        }
        if let connector = data.features.first(where: { $0.id == 1237792404 }) {
            connection(connector, site: site, root: root)
        }
        AirportBoardingBridgeGeometry.add(data, site: site, root: root)
        frontage(data, site: site, boundary: boundary, root: root)
        siteFurniture(data, site: site, boundary: boundary, root: root)
        AirportLightingGeometry.add(data, site: site, root: root)
        AirportApronProps.add(data, site: site, root: root)
        return scene
    }

    private static func connection(_ feature: AirportMapData.Feature, site: DarLandmarkSite, root: SCNNode) {
        let ring = feature.local(origin: site.anchor.coordinate).map { SIMD2($0.x, $0.y) }
        let node = SCNNode(); node.name = "airportOpenAirConnection"; root.addChildNode(node)
        let wound = DioramaPolygon.counterClockwise(ring.map { DV2($0.x, $0.y) }).map { SIMD2($0.x, $0.y) }
        let rounded = BuildingContour.rounded(wound, tangentDistance: 1.0, segments: 6)
        AirportArchitectureParts.roundedRoof(rounded, thickness: 0.5, shoulder: 0.3,
            xStep: 200, yStep: 200, height: { _ in 4.1 }, name: "openSidedWalkwayCanopy", root: node)
        var columns = BuildingMesh(), lights = BuildingMesh()
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], length = simd_distance(a, b)
            guard length > 12 else { continue }
            for station in stride(from: 5.0, to: length, by: 18.0) {
                let p = a + (b - a) * (station / length)
                LandmarkMesh.beam(&columns, from: DarLandmarkParts.p(p, 0.2), to: DarLandmarkParts.p(p, 3.9), radius: 0.24, sides: 10)
                AirportArchitectureParts.box(&lights, centre: p, width: 0.4, depth: 0.2, bottom: 3.57, top: 3.65)
            }
        }
        node.addChildNode(columns.node(name: "openWalkwayColumns", material: DarLandmarkParts.silver))
        node.addChildNode(lights.node(name: "architecturalLighting", material: LandmarkLightingGeometry.lamp))
    }

    private static func frontage(_ data: AirportMapData, site: DarLandmarkSite, boundary: [DV2], root: SCNNode) {
        guard let terminal = data.features.first(where: { $0.id == 597787841 }) else { return }
        let ring = terminal.local(origin: site.anchor.coordinate)
        guard ring.count >= 6 else { return }
        // The mapped northwest edge of the main hall; photo-estimated planters and bollards stay here.
        let a = ring[2], b = ring[5], direction = (b - a).normalized
        let centre = DioramaPolygon.centroid(ring)
        var outward = direction.left
        if outward.dot(centre - a) > 0 { outward = -outward }
        var planters = BuildingMesh(), bollards = BuildingMesh()
        var palms: [UInt64: (node: SCNNode, radius: Double)] = [:]
        for station in stride(from: 7.0, to: a.distance(to: b) - 5, by: 13.0) {
            guard [0.30, 0.72].allSatisfy({ abs(station - a.distance(to: b) * $0) > 7 }) else { continue }
            let p = a + direction * station + outward * 3.0
            guard inside(SIMD2(p.x, p.y), boundary: boundary, clearance: 3) else { continue }
            AirportArchitectureParts.box(&planters, centre: SIMD2(p.x, p.y), width: 2.1, depth: 1.1, bottom: 0.2, top: 1.0)
            AirportVegetationGeometry.palm(at: p, base: 1.0, height: 3.8, maximumRadius: DioramaPolygon.distanceToRing(boundary, p), cache: &palms, root: root)
            for dx in [-3.0, 3.0] {
                let q = p + direction * dx
                LandmarkMesh.beam(&bollards, from: SIMD3(q.x, q.y, 0.2), to: SIMD3(q.x, q.y, 1.2), radius: 0.16, sides: 8)
            }
            let tree = p + outward * 12
            if inside(SIMD2(tree.x, tree.y), boundary: boundary, clearance: 3) { AirportVegetationGeometry.palm(at: tree, base: 0.2, height: 8.0, maximumRadius: DioramaPolygon.distanceToRing(boundary, tree), cache: &palms, root: root) }
        }
        root.addChildNode(planters.node(name: "photoEstimatedFrontagePlanters", material: DarLandmarkParts.silver))
        root.addChildNode(bollards.node(name: "entranceSecurityBollards", material: DarLandmarkParts.plaster))
    }

    private static func siteFurniture(_ data: AirportMapData, site: DarLandmarkSite, boundary: [DV2], root: SCNNode) {
        var steel = BuildingMesh(), lamps = BuildingMesh()
        for feature in data.points {
            guard let p = feature.local(origin: site.anchor.coordinate).first, inside(SIMD2(p.x, p.y), boundary: boundary, clearance: 3) else { continue }
            if feature.tags["aeroway"] == "gate", let ref = feature.tags["ref"] {
                AirportArchitectureParts.name(ref, centre: SIMD3(p.x, p.y, 4.6), facing: simd_normalize(SIMD2(1, -1)), height: 0.65, root: root)
            } else if feature.tags["natural"] == "tree" { tree(at: p, root: root) }
            else if feature.tags["barrier"] == "gate" || feature.tags["barrier"] == "lift_gate" {
                let roads = data.features.filter { $0.tags["highway"] != nil }.flatMap { f -> [(DV2, DV2)] in
                    let line = f.local(origin: site.anchor.coordinate)
                    return Array(zip(line, line.dropFirst()))
                }
                let edge = roads.min { DioramaPolygon.distanceToSegment(p, $0.0, $0.1) < DioramaPolygon.distanceToSegment(p, $1.0, $1.1) }
                let across = edge.map { ($0.1 - $0.0).normalized.left } ?? DV2(1, 0)
                let a = p - across * 2.5, b = p + across * 2.5
                for end in [a, b] { AirportArchitectureParts.box(&steel, centre: SIMD2(end.x, end.y), width: 0.3, depth: 0.3, bottom: 0.2, top: 2) }
                LandmarkMesh.beam(&steel, from: SIMD3(a.x, a.y, 1.4), to: SIMD3(b.x, b.y, 1.4), radius: 0.08, sides: 6)
            }
        }
        for f in data.features where f.tags["barrier"] != nil {
            let line = f.local(origin: site.anchor.coordinate)
            for (a, b) in zip(line, line.dropFirst()) where a.distance(to: b) > 0.5 {
                guard inside(SIMD2(a.x, a.y), boundary: boundary, clearance: 0.25), inside(SIMD2(b.x, b.y), boundary: boundary, clearance: 0.25) else { continue }
                for z in [0.4, 2.4] { LandmarkMesh.beam(&steel, from: SIMD3(a.x, a.y, z), to: SIMD3(b.x, b.y, z), radius: 0.055, sides: 4) }
                LandmarkMesh.beam(&steel, from: SIMD3(a.x, a.y, 0.2), to: SIMD3(a.x, a.y, 2.5), radius: 0.08, sides: 4)
            }
        }
        let stands = data.features.filter { $0.tags["aeroway"] == "parking_position" && $0.tags["ref"]?.hasPrefix("F") == true }
        for f in stands {
            let line = f.local(origin: site.anchor.coordinate)
            guard let p = line.first else { continue }
            let q = p + DV2(-9, 7)
            guard inside(SIMD2(q.x, q.y), boundary: boundary, clearance: 4) else { continue }
            LandmarkMesh.beam(&steel, from: SIMD3(q.x, q.y, 0.2), to: SIMD3(q.x, q.y, 24), radius: 0.22, sides: 8)
            for dx in [-1.3, 0, 1.3] { AirportArchitectureParts.box(&lamps, centre: SIMD2(q.x + dx, q.y), width: 0.85, depth: 0.55, bottom: 23.65, top: 24.1) }
            LandmarkLightingGeometry.fixture(at: SIMD3(q.x, q.y, 21), radius: 48, intensity: 2.2, root: root)
        }
        root.addChildNode(steel.node(name: "mappedGatesFencesAndEstimatedFloodMasts", material: DarLandmarkParts.silver))
        root.addChildNode(lamps.node(name: "architecturalLighting", material: LandmarkLightingGeometry.lamp))
    }

    private static func tree(at p: DV2, root: SCNNode) {
        var trunk = BuildingMesh(), crown = BuildingMesh()
        LandmarkMesh.beam(&trunk, from: SIMD3(p.x, p.y, 0.2), to: SIMD3(p.x, p.y, 4.0), radius: 0.15, sides: 6)
        crown.revolve(centre: SIMD2(p.x, p.y), profile: [SIMD2(0, 2.1), SIMD2(1.3, 3.1), SIMD2(1.5, 4.4), SIMD2(1.1, 6.0), SIMD2(0, 7.2)], segments: 10)
        root.addChildNode(trunk.node(name: "mappedTreeTrunk", material: BuildingSurfaces.make("landmark.trunk", color: "#805033", roughness: 1)))
        root.addChildNode(crown.node(name: "mappedTreeEstimatedCrown", material: BuildingSurfaces.make("landmark.foliage", color: "#638238", roughness: 1)))
    }

    private static func inside(_ point: SIMD2<Double>, boundary: [DV2], clearance: Double) -> Bool {
        let p = DV2(point.x, point.y)
        return DioramaPolygon.contains(boundary, p) && DioramaPolygon.distanceToRing(boundary, p) > clearance
    }
}
