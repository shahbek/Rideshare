import SceneKit
import simd

/// Three distinct photo-led terminals. Heights, roof profiles and furnishings are estimates.
enum AirportTerminalGeometry {
    static func add(_ feature: AirportMapData.Feature, site: DarLandmarkSite, boardingRoots: [DV2] = [], root: SCNNode) {
        let global = feature.local(origin: site.anchor.coordinate).map { SIMD2($0.x, $0.y) }
        guard feature.isClosed, global.count >= (feature.id == 597787841 ? 6 : 3) else { return }
        let international = feature.id == 597787841, domestic = feature.id == 23359828
        let axis: SIMD2<Double> = international ? simd_normalize(SIMD2(1, 1)) : domestic ? simd_normalize(SIMD2(0.38, 0.925)) : SIMD2(1, 0)
        let across = SIMD2(-axis.y, axis.x)
        let mappedRing = global.map { SIMD2(simd_dot($0, axis), simd_dot($0, across)) }
        let portals = boardingRoots.map { SIMD2(simd_dot(SIMD2($0.x, $0.y), axis), simd_dot(SIMD2($0.x, $0.y), across)) }
        let wound = DioramaPolygon.counterClockwise(mappedRing.map { DV2($0.x, $0.y) }).map { SIMD2($0.x, $0.y) }
        let ring = BuildingContour.rounded(wound, tangentDistance: international ? 2.4 : 1.0, segments: 6)
        var roofPlan = mappedRing
        if international {
            let along = simd_normalize(mappedRing[5] - mappedRing[2])
            var out = SIMD2(-along.y, along.x)
            if simd_dot(out, mappedRing[0] - mappedRing[2]) > 0 { out = -out }
            for i in 2...5 { roofPlan[i] += out * 9 }
        }
        let roofRing = international ? BuildingContour.rounded(DioramaPolygon.counterClockwise(roofPlan.map { DV2($0.x, $0.y) }).map { SIMD2($0.x, $0.y) }, tangentDistance: 2.4, segments: 6) : ring
        let terminal = SCNNode(); terminal.name = international ? "airportTerminal3" : domestic ? "airportTerminal2" : "airportTerminal1"
        terminal.simdTransform = simd_float4x4(columns: (SIMD4(Float(axis.x), Float(axis.y), 0, 0), SIMD4(Float(across.x), Float(across.y), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        root.addChildNode(terminal)
        let polygon = DioramaPolygon.counterClockwise(ring.map { DV2($0.x, $0.y) })
        let bounds = DioramaRect.bounding(polygon)
        let ceiling = international ? 13.0 : domestic ? 7.2 : 5.4
        if !international {
            terminal.addChildNode(BuildingFootprint(rings: [ring]).deck(at: 0.2, thickness: 0.12, material: DarLandmarkParts.plaster, name: "terminalFinishedFloor"))
        }
        if domestic {
            AirportDomesticTerminalGeometry.add(ring: ring, boardingRoots: portals, root: terminal)
            return
        }
        let spineFront = international ? mappedRing[1].y : bounds.maxY
        func roofHeight(_ p: DV2) -> Double {
            if international {
                let depth = max(1, (roofPlan.map(\.y).max() ?? bounds.maxY) - spineFront)
                if p.y >= spineFront {
                    // The photo's long landside sail descends continuously to the rolled nose.
                    return 17.8 - 2.55 * min(1, max(0, (p.y - spineFront) / depth))
                }
                let phase = (p.x - bounds.minX) / 24
                let t = phase - floor(phase)
                let blend = min(1, max(0, (spineFront - p.y) / 12))
                return 17.8 + 2.2 * (1 - abs(t * 2 - 1)) * blend
            }
            return 6.0
        }
        let thickness = international ? 1.1 : domestic ? 0.8 : 0.6
        var structure = BuildingMesh(), lights = BuildingMesh()
        let xStep = domestic ? 11.0 : international ? 12.0 : max(1, bounds.width)
        let yStep = domestic ? 11.0 : 12.0
        guard let roofEdge = AirportArchitectureParts.roundedRoof(roofRing, thickness: thickness, shoulder: international ? 0.8 : 0.6,
            xStep: xStep, yStep: yStep, height: roofHeight,
            name: international ? "terminal3FoldedSailRoof" : domestic ? "terminal2UmbrellaRoof" : "terminal1Roof", root: terminal) else { return }
        if international {
            AirportTerminalFacade.add(ring: ring, heights: ring.map { roofHeight(DV2($0.x, $0.y)) - thickness }, mapped: mappedRing, spineFront: spineFront, boardingRoots: portals, root: terminal)
            AirportTerminalInterior.add(ring: ring, mapped: mappedRing, spineFront: spineFront, roofHeight: roofHeight, root: terminal)
        } else {
            AirportArchitectureParts.glazing(roofEdge.ring, bottom: 0.32, top: ceiling, topHeights: roofEdge.heights, root: terminal)
        }
        for x in stride(from: bounds.minX + 11, to: bounds.maxX, by: 22.0) {
            for y in stride(from: bounds.minY + 11, to: bounds.maxY, by: international ? 26.0 : 22.0) {
                let p = DV2(x, y)
                guard DioramaPolygon.contains(polygon, p), DioramaPolygon.distanceToRing(polygon, p) > 2 else { continue }
                let z = roofHeight(p) - thickness
                LandmarkMesh.beam(&structure, from: SIMD3(x, y, 0.32), to: SIMD3(x, y, domestic ? 8.5 : z), radius: domestic ? 0.65 : 0.42, sides: 12)
                AirportArchitectureParts.box(&lights, centre: SIMD2(x, y), width: 0.75, depth: 0.32, bottom: z - 0.16, top: z - 0.08)
                if international && y > spineFront { LandmarkLightingGeometry.fixture(at: SIMD3(x, y, min(z - 0.25, 8)), radius: 19, intensity: 1.1, root: terminal) }
            }
        }
        terminal.addChildNode(structure.node(name: "terminalRoofStructure", material: DarLandmarkParts.silver))
        terminal.addChildNode(lights.node(name: "architecturalLighting", material: LandmarkLightingGeometry.lamp))
        if international {
            entranceCanopy(ring: mappedRing, axis: axis, across: across, site: site, roofHeight: roofHeight, root: terminal)
            furniture(polygon: polygon, bounds: bounds, spineFront: spineFront, root: terminal)
        }
        if !international {
            let front = mappedRing.indices.filter { simd_distance(mappedRing[$0], mappedRing[($0 + 1) % mappedRing.count]) > 12 }.max {
                (mappedRing[$0].y + mappedRing[($0 + 1) % mappedRing.count].y) < (mappedRing[$1].y + mappedRing[($1 + 1) % mappedRing.count].y)
            } ?? 0
            let a = mappedRing[front], b = mappedRing[(front + 1) % mappedRing.count], centre = (a + b) / 2
            let along = simd_normalize(b - a)
            var outward = SIMD2(along.y, -along.x)
            let interior = DioramaPolygon.centroid(polygon)
            if simd_dot(outward, SIMD2(interior.x, interior.y) - centre) > 0 { outward = -outward }
            let signCentre = centre - outward * 0.4
            let signZ = roofHeight(DV2(centre.x, centre.y)) + 0.55
            var signPosts = BuildingMesh()
            for t in [0.2, 0.5, 0.8] {
                let p = a + (b - a) * t - outward * 0.55
                LandmarkMesh.beam(&signPosts, from: DarLandmarkParts.p(p, signZ - 0.8), to: DarLandmarkParts.p(p, signZ + 0.7), radius: 0.09, sides: 6)
            }
            terminal.addChildNode(signPosts.node(name: "terminal1BlueRoofSignSupports", material: DarLandmarkParts.silver))
            AirportArchitectureParts.name("JULIUS NYERERE INTERNATIONAL AIRPORT TERMINAL 1", centre: DarLandmarkParts.p(signCentre, signZ), facing: outward, height: 1.1, root: terminal, material: AirportArchitectureParts.roofSignBlue, maximumWidth: simd_distance(a, b) * 0.90, depth: 0.26)
        }
    }

    private static func entranceCanopy(ring: [SIMD2<Double>], axis: SIMD2<Double>, across: SIMD2<Double>, site: DarLandmarkSite, roofHeight: (DV2) -> Double, root: SCNNode) {
        guard ring.count > 5, let boundary = site.footprint?.rings.first else { return }
        let a = ring[2], b = ring[5], along = simd_normalize(b - a)
        var outward = SIMD2(-along.y, along.x)
        let centre = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
        if simd_dot(outward, centre - a) > 0 { outward = -outward }
        let corners = [a - outward * 4, b - outward * 4, b + outward * 9, a + outward * 9]
        let world = corners.map { axis * $0.x + across * $0.y }
        guard HarbourArchitectureParts.fits(world, inside: boundary, clearance: 0.5) else { return }
        // The overhang is already part of the hall roof's single extended perimeter.
        // No second slab, hidden seam or overlapping soffit is built here.
        func canopyHeight(_ p: DV2) -> Double { roofHeight(p) }
        var supports = BuildingMesh()
        // Set supports behind the clear curtain wall; the projecting nose stays open.
        for station in stride(from: 8.0, to: simd_distance(a, b) - 6, by: 24.0) {
            let foot = a + along * station - outward * 1.2
            let z = canopyHeight(DV2(foot.x, foot.y)) - 1.1
            LandmarkMesh.beam(&supports, from: DarLandmarkParts.p(foot, 0.32), to: DarLandmarkParts.p(foot, z), radius: 0.48, sides: 12)
            let end = foot + outward * 5.5
            LandmarkMesh.beam(&supports, from: DarLandmarkParts.p(foot, z - 0.6), to: DarLandmarkParts.p(end, canopyHeight(DV2(end.x, end.y)) - 0.98), radius: 0.25, sides: 10)
        }
        let length = simd_distance(a, b)
        let spotlight = AirportLightingGeometry.downlight()
        for station in stride(from: 2.5, to: length - 2, by: 3.0) {
            for offset in [0.5, 3.5, 6.5] {
                let p = a + along * station + outward * offset
                let z = canopyHeight(DV2(p.x, p.y)) - 1.1
                AirportInstanceGeometry.place(spotlight, id: "soffitSpot", at: SIMD3(p.x, p.y, z - 0.06), root: root)
            }
        }
        for station in stride(from: 8.0, to: length - 4, by: 16.0) {
            let p = a + along * station + outward * 3.5
            LandmarkLightingGeometry.fixture(at: DarLandmarkParts.p(p, canopyHeight(DV2(p.x, p.y)) - 1.3), radius: 22, intensity: 2.6, root: root)
        }
        root.addChildNode(supports.node(name: "terminal3CanopyStructuralSupports", material: DarLandmarkParts.plaster))
        let nose = (a + b) / 2 + outward * 8.6
        let signZ = canopyHeight(DV2(nose.x, nose.y)) + 0.18
        var rails = BuildingMesh()
        for station in stride(from: length * 0.08, through: length * 0.92, by: 8.0) {
            let p = a + along * station + outward * 8.35
            LandmarkMesh.beam(&rails, from: DarLandmarkParts.p(p, canopyHeight(DV2(p.x, p.y)) - 0.3), to: DarLandmarkParts.p(p, signZ + 0.25), radius: 0.07, sides: 6)
        }
        root.addChildNode(rails.node(name: "terminal3FrontEdgeLetterMounts", material: DarLandmarkParts.silver))
        AirportArchitectureParts.name("JULIUS NYERERE INTERNATIONAL AIRPORT TERMINAL 3", centre: DarLandmarkParts.p(nose, signZ), facing: outward, height: 2.4, root: root, material: AirportArchitectureParts.roofSignBlue, maximumWidth: length * 0.88, depth: 0.32)
    }

    private static func furniture(polygon: [DV2], bounds: DioramaRect, spineFront: Double, root: SCNNode) {
        var counters = BuildingMesh(), displays = BuildingMesh(), seats = BuildingMesh(), metal = BuildingMesh()
        func fits(_ x: Double, _ y: Double, _ w: Double, _ d: Double) -> Bool {
            let corners = DarLandmarkParts.rectangle(x: x, y: y, width: w, depth: d)
            return corners.allSatisfy { DioramaPolygon.contains(polygon, DV2($0.x, $0.y)) && DioramaPolygon.distanceToRing(polygon, DV2($0.x, $0.y)) > 1 }
        }
        for x in stride(from: bounds.minX + 20, to: bounds.maxX - 16, by: 9.0) {
            let y = spineFront + 32
            if fits(x, y, 7.4, 5.5) {
                for dx in [-1.8, 1.8] {
                    let p = SIMD2(x + dx, y)
                    AirportArchitectureParts.box(&counters, centre: p, width: 2.8, depth: 1.1, bottom: 0.32, top: 1.43)
                    AirportArchitectureParts.box(&metal, centre: p + SIMD2(0, -1.6), width: 1.3, depth: 2.5, bottom: 0.32, top: 0.53)
                    LandmarkMesh.beam(&metal, from: SIMD3(p.x, p.y, 1.43), to: SIMD3(p.x, p.y, 2.3), radius: 0.07, sides: 6)
                    AirportArchitectureParts.box(&displays, centre: p, width: 1.15, depth: 0.15, bottom: 2.2, top: 2.85)
                }
            }
            for sy in [spineFront + 14, spineFront + 58] where fits(x, sy, 5.4, 2.3) {
                let p = SIMD2(x, sy)
                // One four-place waiting bench: joined seat/back and floor-supported rail,
                // rather than twelve separately capped furniture boxes per bank.
                AirportArchitectureParts.box(&seats, centre: p, width: 4.55, depth: 0.8, bottom: 0.8, top: 0.95)
                AirportArchitectureParts.box(&seats, centre: p + SIMD2(0, -0.32), width: 4.55, depth: 0.15, bottom: 0.9, top: 1.65)
                AirportArchitectureParts.box(&metal, centre: p, width: 4.0, depth: 0.18, bottom: 0.32, top: 0.8)
            }
        }
        root.addChildNode(counters.node(name: "illustrativeCheckInCounters", material: DarLandmarkParts.plaster))
        root.addChildNode(displays.node(name: "illustrativeFlightDisplays", material: DarLandmarkParts.dark))
        root.addChildNode(seats.node(name: "illustrativeTerminalWaitingSeats", material: AirportArchitectureParts.signBlue))
        root.addChildNode(metal.node(name: "interiorBeltsAndSeatSupports", material: DarLandmarkParts.silver))
    }
}
