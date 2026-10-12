import SceneKit
import simd

/// Reference-led two-storey hall with an open atrium. Layout and elevations remain illustrative.
enum AirportTerminalInterior {
    static let upperFloor = 5.7

    static func add(ring: [SIMD2<Double>], mapped: [SIMD2<Double>], spineFront: Double, roofHeight: (DV2) -> Double, root: SCNNode) {
        guard mapped.count > 5 else { return }
        let polygon = ring.map { DV2($0.x, $0.y) }, bounds = DioramaRect.bounding(polygon)
        let hallMinX = min(mapped[2].x, mapped[5].x), hallMaxX = max(mapped[2].x, mapped[5].x)
        let backEdge = spineFront + 35.0, frontEdge = min(mapped[2].y, mapped[5].y) - 6
        let floor = BuildingSurfaces.make("airport.polishedFloor", color: "#C9C2B6", roughness: 0.38)
        root.addChildNode(BuildingFootprint(rings: [ring]).deck(at: 0.20, thickness: 0.12, material: floor, name: "terminal3PolishedGroundFloor"))
        func deck(_ rect: DioramaRect, name: String) {
            let clipped = DioramaPolygon.clipPolygon(polygon, to: rect)
            guard clipped.count >= 3 else { return }
            root.addChildNode(BuildingFootprint(rings: [clipped.map { SIMD2($0.x, $0.y) }]).deck(at: upperFloor - 0.35, thickness: 0.35, material: floor, name: name))
        }
        deck(DioramaRect(minX: bounds.minX, minY: bounds.minY, maxX: bounds.maxX, maxY: backEdge), name: "terminal3UpperDepartureFloor")
        for (index, x) in [hallMinX + 4.5, hallMaxX - 4.5].enumerated() {
            deck(DioramaRect(minX: x - 2.25, minY: backEdge, maxX: x + 2.25, maxY: frontEdge), name: "terminal3UpperSideGallery\(index)")
        }
        var rails = BuildingMesh(), galleryGlass = BuildingMesh(), piers = BuildingMesh()
        let rearA = SIMD2(hallMinX + 7, backEdge), rearB = SIMD2(hallMaxX - 7, backEdge)
        func railing(_ a: SIMD2<Double>, _ b: SIMD2<Double>) {
            let length = simd_distance(a, b)
            guard length > 0.01 else { return }
            let delta = (b - a) / length
            galleryGlass.quad(DarLandmarkParts.p(a, upperFloor + 0.15), DarLandmarkParts.p(b, upperFloor + 0.15), DarLandmarkParts.p(b, upperFloor + 1.18), DarLandmarkParts.p(a, upperFloor + 1.18))
            galleryGlass.quad(DarLandmarkParts.p(a, upperFloor + 1.18), DarLandmarkParts.p(b, upperFloor + 1.18), DarLandmarkParts.p(b, upperFloor + 0.15), DarLandmarkParts.p(a, upperFloor + 0.15))
            for z in [upperFloor + 0.15, upperFloor + 1.25] { LandmarkMesh.beam(&rails, from: DarLandmarkParts.p(a, z), to: DarLandmarkParts.p(b, z), radius: 0.075, sides: 8) }
            for station in stride(from: 0.0, to: length, by: 2.8) {
                let p = a + delta * station
                LandmarkMesh.beam(&rails, from: DarLandmarkParts.p(p, upperFloor), to: DarLandmarkParts.p(p, upperFloor + 1.25), radius: 0.06, sides: 8)
            }
        }
        // Leave genuine openings for both stair/escalator landings in the rear balcony rail.
        let flights = [hallMinX + 24, hallMaxX - 31]
        let sorted = flights.sorted()
        var start = rearA.x
        for x in sorted {
            railing(SIMD2(start, backEdge), SIMD2(x - 3.0, backEdge))
            start = x + 5.3
        }
        railing(SIMD2(start, backEdge), rearB)
        for x in [hallMinX + 6.75, hallMaxX - 6.75] {
            railing(SIMD2(x, backEdge), SIMD2(x, frontEdge))
            for y in stride(from: backEdge + 7, to: frontEdge, by: 16.0) {
                let p = SIMD2(x + (x < (hallMinX + hallMaxX) / 2 ? -2.0 : 2.0), y)
                guard DioramaPolygon.contains(polygon, DV2(p.x, p.y)) else { continue }
                LandmarkMesh.beam(&piers, from: DarLandmarkParts.p(p, 0.32), to: DarLandmarkParts.p(p, upperFloor - 0.35), radius: 0.35, sides: 12)
            }
        }
        for x in flights {
            circulation(at: SIMD2(x, backEdge + 17.0), polygon: polygon, root: root)
            lift(at: SIMD2(x - 7.0, backEdge - 2.5), polygon: polygon, root: root)
        }
        var panels = BuildingMesh(), ceilingFrames = BuildingMesh(), queues = BuildingMesh(), belts = BuildingMesh()
        for x in stride(from: hallMinX + 14, to: hallMaxX - 8, by: 14.0) {
            for y in stride(from: backEdge + 7, to: frontEdge - 4, by: 12.0) {
                let rectangle = DarLandmarkParts.rectangle(x: x, y: y, width: 11.0, depth: 8.6)
                guard HarbourArchitectureParts.fits(rectangle, inside: ring, clearance: 3) else { continue }
                for dx in [-3.6, -1.2, 1.2, 3.6] {
                    let p = SIMD2(x + dx, y), z = roofHeight(DV2(p.x, p.y)) - 1.6
                    AirportArchitectureParts.box(&panels, centre: p, width: 2.05, depth: 8.6, bottom: z - 0.12, top: z)
                    for offset in [-4.1, 4.1] {
                        let q = p + SIMD2(0, offset)
                        LandmarkMesh.beam(&ceilingFrames, from: DarLandmarkParts.p(q, z), to: DarLandmarkParts.p(q, roofHeight(DV2(q.x, q.y)) - 1.1), radius: 0.035, sides: 6)
                    }
                }
                let a = SIMD2(x - 5.5, y - 4.7), b = SIMD2(x + 5.5, y - 4.7)
                LandmarkMesh.beam(&ceilingFrames, from: DarLandmarkParts.p(a, roofHeight(DV2(a.x, a.y)) - 1.45), to: DarLandmarkParts.p(b, roofHeight(DV2(b.x, b.y)) - 1.45), radius: 0.14, sides: 8)
                for q in [a, b] {
                    LandmarkMesh.beam(&ceilingFrames, from: DarLandmarkParts.p(q, roofHeight(DV2(q.x, q.y)) - 1.45), to: DarLandmarkParts.p(q, roofHeight(DV2(q.x, q.y)) - 1.1), radius: 0.07, sides: 8)
                }
            }
            for y in [spineFront + 27, spineFront + 23] {
                let a = SIMD2(x - 3.5, y), b = SIMD2(x + 3.5, y)
                guard HarbourArchitectureParts.fits(DarLandmarkParts.rectangle(x: x, y: y, width: 8, depth: 1), inside: ring, clearance: 3) else { continue }
                for p in [a, SIMD2(x, y), b] {
                    LandmarkMesh.beam(&queues, from: DarLandmarkParts.p(p, 0.32), to: DarLandmarkParts.p(p, 1.36), radius: 0.055, sides: 8)
                    queues.revolve(centre: p, profile: [SIMD2(0, 0.33), SIMD2(0.22, 0.33), SIMD2(0.22, 0.39), SIMD2(0, 0.39)], segments: 12)
                }
                belts.quad(DarLandmarkParts.p(a, 1.17), DarLandmarkParts.p(b, 1.17), DarLandmarkParts.p(b, 1.31), DarLandmarkParts.p(a, 1.31))
            }
        }
        let signX = (hallMinX + hallMaxX) / 2
        for x in [signX - 7.5, signX + 7.5] {
            LandmarkMesh.beam(&queues, from: SIMD3(x, backEdge + 0.5, 0.32), to: SIMD3(x, backEdge + 0.5, 8.6), radius: 0.15, sides: 10)
        }
        LandmarkMesh.beam(&queues, from: SIMD3(signX - 7.5, backEdge + 0.5, 8.6), to: SIMD3(signX + 7.5, backEdge + 0.5, 8.6), radius: 0.12, sides: 8)
        for x in [signX - 5.0, signX + 5.0] {
            LandmarkMesh.beam(&queues, from: SIMD3(x, backEdge + 0.5, 8.1), to: SIMD3(x, backEdge + 0.5, 8.6), radius: 0.055, sides: 8)
        }
        root.addChildNode(rails.node(name: "terminal3UpperGalleryContinuousRails", material: DarLandmarkParts.silver))
        root.addChildNode(galleryGlass.node(name: "terminal3UpperGalleryGlass", material: AirportArchitectureParts.clearGlass(alpha: 0.09)))
        root.addChildNode(piers.node(name: "terminal3UpperFloorSupportingColumns", material: DarLandmarkParts.plaster))
        root.addChildNode(panels.node(name: "terminal3SuspendedAcousticCeilingPanels", material: DarLandmarkParts.plaster))
        root.addChildNode(ceilingFrames.node(name: "terminal3AlignedCeilingCrossMembers", material: DarLandmarkParts.silver))
        root.addChildNode(queues.node(name: "terminal3QueueStanchions", material: DarLandmarkParts.silver))
        root.addChildNode(belts.node(name: "terminal3BlueQueueBelts", material: AirportArchitectureParts.signBlue))
        AirportArchitectureParts.name("DEPARTURES · ALL GATES", centre: SIMD3((hallMinX + hallMaxX) / 2, backEdge + 0.5, 7.65), facing: SIMD2(0, 1), height: 0.7, root: root, material: AirportArchitectureParts.signBlue, maximumWidth: 16)
    }

    private static func circulation(at lower: SIMD2<Double>, polygon: [DV2], root: SCNNode) {
        let run = 17.0, rise = upperFloor - 0.32
        let envelope = DarLandmarkParts.rectangle(x: lower.x + 1.1, y: lower.y - run / 2, width: 8.4, depth: run + 1)
        guard HarbourArchitectureParts.fits(envelope, inside: polygon.map { SIMD2($0.x, $0.y) }, clearance: 2) else { return }
        var steps = BuildingMesh(), trusses = BuildingMesh(), rails = BuildingMesh(), glass = BuildingMesh()
        let stairWidth = 2.8
        for step in 0..<34 {
            let t = Double(step + 1) / 34
            AirportArchitectureParts.box(&steps, centre: SIMD2(lower.x - 1.25, lower.y - (Double(step) + 0.5) * run / 34), width: stairWidth, depth: run / 34, bottom: 0.32, top: 0.32 + rise * t)
        }
        for x in [lower.x + 1.55, lower.x + 3.65] {
            let a = SIMD3(x, lower.y, 0.32), b = SIMD3(x, lower.y - run, upperFloor)
            // Closed inclined truss; all tread and rail heights derive from the same endpoints.
            let side = SIMD3<Double>(0.72, 0, 0), down = SIMD3<Double>(0, 0, 0.38)
            trusses.quad(b - side, b + side, a + side, a - side)
            trusses.quad(a + side - down, b + side - down, b - side - down, a - side - down)
            trusses.quad(b - side - down, b - side, a - side, a - side - down)
            trusses.quad(b + side, b + side - down, a + side - down, a + side)
            trusses.quad(a - side, a + side, a + side - down, a - side - down)
            trusses.quad(b - side - down, b + side - down, b + side, b - side)
            for step in 0..<44 {
                let t = (Double(step) + 0.5) / 44
                let p = a + (b - a) * t
                let top = step == 43 ? upperFloor : p.z + 0.035
                AirportArchitectureParts.box(&steps, centre: SIMD2(p.x, p.y), width: 1.32, depth: run / 44, bottom: max(0.32, p.z - 0.07), top: top)
            }
            for offset in [-0.70, 0.70] {
                let p = a + SIMD3(offset, 0, 0), q = b + SIMD3(offset, 0, 0)
                glass.quad(p, q, q + SIMD3(0, 0, 1.08), p + SIMD3(0, 0, 1.08))
                glass.quad(p + SIMD3(0, 0, 1.08), q + SIMD3(0, 0, 1.08), q, p)
                LandmarkMesh.beam(&rails, from: p + SIMD3(0, 0, 1.14), to: q + SIMD3(0, 0, 1.14), radius: 0.075, sides: 10)
            }
        }
        for x in [lower.x - 2.47, lower.x] {
            let a = SIMD3(x, lower.y, 1.5), b = SIMD3(x, lower.y - run, upperFloor + 1.18)
            LandmarkMesh.beam(&rails, from: a, to: b, radius: 0.055, sides: 8)
            for step in stride(from: 0, through: 34, by: 4) {
                let t = Double(step) / 34, p = SIMD2(x, lower.y - run * t)
                LandmarkMesh.beam(&rails, from: DarLandmarkParts.p(p, 0.32 + rise * t), to: DarLandmarkParts.p(p, 1.5 + rise * t), radius: 0.045, sides: 8)
            }
        }
        root.addChildNode(steps.node(name: "terminal3StairAndEscalatorTreads", material: DarLandmarkParts.silver))
        root.addChildNode(trusses.node(name: "terminal3EscalatorClosedInclinedTrusses", material: DarLandmarkParts.dark))
        root.addChildNode(rails.node(name: "terminal3StairAndEscalatorHandrails", material: DarLandmarkParts.dark))
        root.addChildNode(glass.node(name: "terminal3EscalatorClearBalustrades", material: AirportArchitectureParts.clearGlass(alpha: 0.10)))
    }

    private static func lift(at centre: SIMD2<Double>, polygon: [DV2], root: SCNNode) {
        let ring = DarLandmarkParts.rectangle(x: centre.x, y: centre.y, width: 3.6, depth: 3.6)
        guard HarbourArchitectureParts.fits(ring, inside: polygon.map { SIMD2($0.x, $0.y) }, clearance: 1) else { return }
        var glass = BuildingMesh(), metal = BuildingMesh()
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            glass.quad(DarLandmarkParts.p(a, 0.32), DarLandmarkParts.p(b, 0.32), DarLandmarkParts.p(b, 10.4), DarLandmarkParts.p(a, 10.4))
            LandmarkMesh.beam(&metal, from: DarLandmarkParts.p(a, 0.32), to: DarLandmarkParts.p(a, 10.4), radius: 0.10, sides: 8)
            for z in [0.5, upperFloor, 10.4] { LandmarkMesh.beam(&metal, from: DarLandmarkParts.p(a, z), to: DarLandmarkParts.p(b, z), radius: 0.085, sides: 8) }
        }
        AirportArchitectureParts.box(&metal, centre: centre, width: 2.65, depth: 2.65, bottom: 0.33, top: 0.49)
        root.addChildNode(glass.node(name: "terminal3GlazedLiftShaft", material: AirportArchitectureParts.clearGlass(alpha: 0.18)))
        root.addChildNode(metal.node(name: "terminal3LiftStructuralFrame", material: DarLandmarkParts.dark))
    }
}
