import Foundation

/// Footprint-fitted illustrative filling stations; no inferred brand or live fuel prices.
nonisolated struct DioramaFuelStation {
    let config: DioramaConfig
    let terrain: DioramaTerrain
    let roads: DioramaRoadIndex
    let library: DioramaPropLibrary

    func build(ring: [DV2], pieces: [[DV2]], top: Double, rng: inout DioramaRandom,
               props: inout DioramaMesh, glow: inout DioramaMesh, lights: inout [DioramaLight]) {
        let plot = DioramaPolygon.minimumAreaRectangle(ring)
        let surface = DioramaStreetSurface(pieces)
        func clear(_ box: DioramaOrientedRect) -> Bool {
            let samples = DioramaPolygon.densify(box.corners + [box.corners[0]], maxStep: 0.6) + [box.centre]
            return samples.allSatisfy { surface.contains($0) && !roads.isOnCarriageway($0, margin: 0.3) }
        }
        // Search the owned forecourt rather than dropping a canopy through an existing shop.
        var chosen: DioramaOrientedRect?
        for factor in [1.0, 0.82, 0.66] {
            for x in [0.0, -0.3, 0.3] {
                for y in [0.0, -0.3, 0.3] {
                    let candidate = DioramaOrientedRect(centre: plot.centre + plot.axis * (x * plot.halfLength) + plot.across * (y * plot.halfWidth),
                        axis: plot.axis, halfLength: min(plot.halfLength * 0.65, 10) * factor,
                        halfWidth: min(plot.halfWidth * 0.65, 6.5) * factor)
                    if chosen == nil, candidate.halfLength >= 3.6, candidate.halfWidth >= 2.7, clear(candidate) { chosen = candidate }
                }
            }
            if chosen != nil { break }
        }
        guard let canopy = chosen else { return }
        let a = canopy.axis, c = canopy.across, h = 5.1
        // Deep radiused fascia, softly rolled roof, recessed soffit and individual luminaires.
        Self.shell(canopy, z: top + h, height: 0.7, radius: 0.85, bevel: 0.16, .trimWhite, into: &props)
        let soffit = canopy.expanded(by: -0.3)
        Self.shell(soffit, z: top + h - 0.10, height: 0.12, radius: 0.65, bevel: 0.04, .roofConcrete, into: &props)
        for side in [-1.0, 1.0] {
            let edge = canopy.centre + c * (side * (canopy.halfWidth - 0.025))
            props.box(centre: edge, z0: top + h + 0.24, axis: a, halfLength: canopy.halfLength - 1.0, halfWidth: 0.04, height: 0.19, .signRed, bevel: 0.035)
            DioramaLettering.line("FUEL", centre: DV3(edge + c * (side * 0.05), top + h + 0.28), up: .up, facing: DV3(c * side, 0), height: 0.35, swatch: .trimWhite, mesh: &props)
        }
        let island = DioramaOrientedRect(centre: canopy.centre, axis: a, halfLength: canopy.halfLength - 1.25, halfWidth: 0.78)
        Self.shell(island, z: top, height: 0.22, radius: 0.7, bevel: 0.06, .kerb, into: &props)
        for side in [-1.0, 1.0] {
            let column = island.centre + a * (side * (island.halfLength - 0.65))
            Self.shell(.init(centre: column, axis: a, halfLength: 0.32, halfWidth: 0.28), z: top + 0.22, height: h - 0.22, radius: 0.18, bevel: 0.06, .trimWhite, into: &props)
            let bollard = island.centre + a * (side * (island.halfLength - 0.12))
            props.cylinder(centre: bollard, z0: top + 0.22, z1: top + 1.1, r0: 0.12, r1: 0.12, sides: 16, .signYellow)
            props.cylinder(centre: bollard, z0: top + 0.76, z1: top + 0.96, r0: 0.125, r1: 0.125, sides: 16, .metalCharcoal)
        }
        let count = max(1, min(3, Int((island.halfLength * 2 - 3) / 2.7)))
        for k in 0..<count {
            let u = (Double(k) - Double(count - 1) / 2) * 2.8
            let p = island.centre + a * u
            let base = top + 0.22
            Self.shell(.init(centre: p, axis: a, halfLength: 0.62, halfWidth: 0.38), z: base + 0.65, height: 1.20, radius: 0.18, bevel: 0.10, .trimWhite, into: &props)
            Self.shell(.init(centre: p, axis: a, halfLength: 0.62, halfWidth: 0.38), z: base, height: 0.65, radius: 0.16, bevel: 0.05, .signRed, into: &props)
            for side in [-1.0, 1.0] {
                let front = p + c * (side * 0.39)
                props.box(centre: front, z0: base + 1.13, axis: a, halfLength: 0.39, halfWidth: 0.025, height: 0.40, .glass, bevel: 0.03)
                props.box(centre: front + a * 0.22, z0: base + 0.91, axis: a, halfLength: 0.12, halfWidth: 0.035, height: 0.13, .metalCharcoal, bevel: 0.015)
                for row in [0.0, 0.12] {
                    props.box(centre: front + c * (side * 0.028), z0: base + 1.22 + row, axis: a, halfLength: 0.24, halfWidth: 0.008, height: 0.035, .mint)
                }
                // A hanging hose loop and docked nozzle, not an anonymous block appliance.
                let hose = (0...16).map { i -> DV3 in
                    let t = Double(i) / 16 * Double.pi
                    return DV3(p + a * (0.66 + 0.29 * sin(t)) + c * (side * (0.12 + 0.22 * Double(i) / 16)), base + 1.50 - 1.12 * sin(t))
                }
                for (v, w) in zip(hose, hose.dropFirst()) { props.tube(from: v, to: w, r0: 0.045, r1: 0.045, sides: 8, .tyre) }
                props.tube(from: DV3(p + a * 0.66 + c * (side * 0.34), base + 1.5), to: DV3(p + a * 0.48 + c * (side * 0.34), base + 1.25), r0: 0.07, r1: 0.065, sides: 8, side > 0 ? .signGreen : .signYellow)
                let light = p + c * (side * 1.6)
                glow.box(centre: light, z0: top + h - 0.13, axis: a, halfLength: 0.42, halfWidth: 0.28, height: 0.035, .lampGlow, bottom: true)
            }
        }
        if lights.count < config.maxLights {
            lights.append(DioramaLight(position: DV3(canopy.centre, top + h - 0.3), color: SIMD3(1, 0.95, 0.82), radius: 14, intensity: 1.1))
        }
        let car = DioramaOrientedRect(centre: island.centre + c * 2.35, axis: a, halfLength: 2.3, halfWidth: 1.05)
        if clear(car) { props.instance(rng.pick(library.cars), DioramaTransform(rotation: a.angle, translation: DV3(car.centre, top))) }
        if let road = roads.nearest(to: plot.centre, within: 60) {
            let toward = (road.point - plot.centre).normalized
            for distance in stride(from: max(plot.halfLength, plot.halfWidth) - 1.5, through: 3.0, by: -1) {
                let sign = DioramaOrientedRect(centre: plot.centre + toward * distance, axis: road.direction, halfLength: 1, halfWidth: 0.32)
                guard clear(sign), !canopy.expanded(by: 1).contains(sign.centre) else { continue }
                Self.shell(sign, z: top, height: 5.3, radius: 0.25, bevel: 0.15, .trimWhite, into: &props)
                for side in [-1.0, 1.0] {
                    let face = sign.centre + sign.across * (side * 0.33)
                    props.box(centre: face, z0: top + 3.9, axis: sign.axis, halfLength: 0.78, halfWidth: 0.035, height: 1.0, .signRed, bevel: 0.05)
                    DioramaLettering.line("FUEL", centre: DV3(face + sign.across * (side * 0.04), top + 4.25), up: .up, facing: DV3(sign.across * side, 0), height: 0.35, swatch: .trimWhite, mesh: &props)
                    for (index, text) in ["PETROL", "DIESEL"].enumerated() {
                        DioramaLettering.line(text, centre: DV3(face, top + 3.15 - Double(index) * 0.6), up: .up, facing: DV3(sign.across * side, 0), height: 0.22, swatch: .metalCharcoal, mesh: &props)
                    }
                }
                break
            }
        }
    }

    /// Closed rounded plan with a rolled upper edge and smooth wall normals.
    private static func shell(_ box: DioramaOrientedRect, z: Double, height: Double, radius: Double, bevel: Double,
                              _ swatch: DioramaSwatch, into mesh: inout DioramaMesh) {
        let ring = DioramaPolygon.rounded(box.corners, flags: [false, false, false, false], radius: min(radius, box.halfWidth * 0.8), segments: 10).points
        let b = min(bevel, height * 0.4)
        for i in ring.indices { mesh.mouldedWall(ring, edge: i, z0: z, z1: z + height - b, swatch) }
        mesh.polygon(ring, z: z, swatch, facingUp: false)
        guard let inner = DioramaPolygon.offset(ring, by: -b), inner.count == ring.count else {
            mesh.polygon(ring, z: z + height - b, swatch); return
        }
        for i in ring.indices {
            let j = (i + 1) % ring.count
            func normal(_ k: Int) -> DV3 {
                DV3(((ring[k] - ring[(k + ring.count - 1) % ring.count]).normalized.right + (ring[(k + 1) % ring.count] - ring[k]).normalized.right).normalized, 0)
            }
            for step in 0..<4 {
                func v(_ k: Int, _ step: Int) -> UInt32 {
                    let angle = Double(step) / 4 * Double.pi / 2
                    let p = ring[k] * cos(angle) + inner[k] * (1 - cos(angle))
                    return mesh.vertex(DV3(p, z + height - b + b * sin(angle)), (normal(k) * cos(angle) + DV3.up * sin(angle)).normalized, DioramaAtlas.uv(swatch, dark: false))
                }
                mesh.reserve(4)
                let a = v(i, step), c = v(j, step), d = v(j, step + 1), e = v(i, step + 1)
                mesh.face(a, c, d, outward: normal(i) + .up); mesh.face(a, d, e, outward: normal(i) + .up)
            }
        }
        mesh.polygon(inner, z: z + height, swatch)
    }
}
