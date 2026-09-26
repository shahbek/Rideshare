import SceneKit
import simd

/// Bounded, material-batched details on an existing facade grid. Dimensions are in metres.
struct BuildingFacadeDetails {
    var stone = BuildingMesh()
    var timber = BuildingMesh()
    var iron = BuildingMesh()
    private(set) var treatmentCount: Int = 0
    private(set) var types: Set<String> = []
    let limit: Int

    mutating func bay(_ treatment: BuildingDetailGrammar.Treatment, start: SIMD2<Double>, tangent: SIMD2<Double>, outward: SIMD2<Double>, left: Double, right: Double, sill: Double, lintel: Double, floorTop: Double, bayLeft: Double, bayRight: Double) {
        guard treatment != .none, treatmentCount < limit, right > left, lintel > sill else { return }
        let centre = (left + right) / 2
        func p(_ x: Double, _ z: Double, _ depth: Double) -> SIMD3<Double> {
            let xy = start + tangent * x + outward * depth
            return SIMD3(xy.x, xy.y, z)
        }
        func bar(_ x0: Double, _ x1: Double, _ bottom: Double, _ top: Double, _ back: Double, _ front: Double, mesh: inout BuildingMesh) {
            mesh.quad(p(x0, bottom, front), p(x1, bottom, front), p(x1, top, front), p(x0, top, front))
            mesh.quad(p(x0, top, back), p(x0, top, front), p(x1, top, front), p(x1, top, back), normal: SIMD3(0, 0, 1))
            mesh.quad(p(x0, bottom, back), p(x1, bottom, back), p(x1, bottom, front), p(x0, bottom, front), normal: SIMD3(0, 0, -1))
            mesh.quad(p(x0, bottom, back), p(x0, bottom, front), p(x0, top, front), p(x0, top, back))
            mesh.quad(p(x1, bottom, front), p(x1, bottom, back), p(x1, top, back), p(x1, top, front))
        }
        switch treatment {
        case .none: return
        case .triangularPediment, .segmentalPediment:
            let base = lintel + 0.09, rise = min(0.36, floorTop - base - 0.14)
            guard rise > 0.12 else { return }
            let x0 = max(bayLeft + 0.15, left - 0.18), x1 = min(bayRight - 0.15, right + 0.18)
            bar(x0, x1, base - 0.08, base, 0, 0.18, mesh: &stone)
            if treatment == .triangularPediment {
                stone.triangle(p(x0, base, 0.13), p(x1, base, 0.13), p(centre, base + rise, 0.13))
                stone.quad(p(x0, base, 0), p(x0, base, 0.13), p(centre, base + rise, 0.13), p(centre, base + rise, 0))
                stone.quad(p(centre, base + rise, 0), p(centre, base + rise, 0.13), p(x1, base, 0.13), p(x1, base, 0))
            } else {
                for i in 0..<16 {
                    let a = Double(i) * .pi / 16, b = Double(i + 1) * .pi / 16
                    let r = (x1 - x0) / 2
                    let a0 = p(centre + r * cos(a), base + rise * sin(a), 0.16)
                    let b0 = p(centre + r * cos(b), base + rise * sin(b), 0.16)
                    stone.triangle(p(centre, base, 0.16), a0, b0)
                    stone.quad(a0, b0, p(centre + r * cos(b), base + rise * sin(b), 0), p(centre + r * cos(a), base + rise * sin(a), 0))
                }
            }
        case .shutters:
            let width = min(0.42, min(left - bayLeft, bayRight - right) - 0.16)
            guard width > 0.18 else { return }
            for x in [left - width - 0.08, right + 0.08] {
                bar(x, x + width, sill, lintel, 0.025, 0.09, mesh: &timber)
                for slat in 1..<8 {
                    let z = sill + (lintel - sill) * Double(slat) / 8
                    timber.quad(p(x + 0.035, z - 0.035, 0.095), p(x + width - 0.035, z - 0.035, 0.095), p(x + width - 0.035, z + 0.035, 0.14), p(x + 0.035, z + 0.035, 0.14))
                }
            }
        case .balcony:
            let x0 = max(bayLeft + 0.18, left - 0.20), x1 = min(bayRight - 0.18, right + 0.20)
            let floor = sill - 0.12
            let corners = [p(x0, 0, -0.02), p(x0, 0, 0.65), p(x1, 0, 0.65), p(x1, 0, -0.02)].map { SIMD2($0.x, $0.y) }
            let ring = BuildingContour.rounded(corners, tangentDistance: 0.22, segments: 4)
            let middle = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                stone.triangle(SIMD3(middle.x, middle.y, floor), SIMD3(a.x, a.y, floor), SIMD3(b.x, b.y, floor), normal: SIMD3(0, 0, 1))
                stone.triangle(SIMD3(middle.x, middle.y, floor - 0.14), SIMD3(b.x, b.y, floor - 0.14), SIMD3(a.x, a.y, floor - 0.14), normal: SIMD3(0, 0, -1))
            }
            stone.perimeter(rings: [ring], bottom: floor - 0.14, top: floor, projection: 0.04, profileSegments: 4)
            bar(x0 + 0.12, x1 - 0.12, floor + 0.78, floor + 0.84, 0.55, 0.61, mesh: &iron)
            for i in 0...7 {
                let x = x0 + 0.12 + (x1 - x0 - 0.24) * Double(i) / 7
                bar(x - 0.022, x + 0.022, floor, floor + 0.84, 0.55, 0.60, mesh: &iron)
            }
            for x in [x0 + 0.14, x1 - 0.14] {
                bar(x - 0.025, x + 0.025, floor + 0.78, floor + 0.84, 0.02, 0.58, mesh: &iron)
                stone.triangle(p(x - 0.07, floor - 0.45, 0), p(x - 0.07, floor - 0.14, 0.5), p(x - 0.07, floor - 0.14, 0))
                stone.triangle(p(x + 0.07, floor - 0.45, 0), p(x + 0.07, floor - 0.14, 0), p(x + 0.07, floor - 0.14, 0.5))
                stone.quad(p(x - 0.07, floor - 0.45, 0), p(x + 0.07, floor - 0.45, 0), p(x + 0.07, floor - 0.14, 0.5), p(x - 0.07, floor - 0.14, 0.5))
            }
        case .medallion:
            let radius = min(0.18, (floorTop - lintel - 0.16) / 2)
            guard radius > 0.06 else { return }
            let z = lintel + radius + 0.07
            for i in 0..<20 {
                let a = Double(i) * .pi / 10, b = Double(i + 1) * .pi / 10
                stone.quad(p(centre + cos(a) * radius, z + sin(a) * radius, 0.12), p(centre + cos(b) * radius, z + sin(b) * radius, 0.12), p(centre + cos(b) * radius * 0.65, z + sin(b) * radius * 0.65, 0.18), p(centre + cos(a) * radius * 0.65, z + sin(a) * radius * 0.65, 0.18))
                stone.triangle(p(centre, z, 0.18), p(centre + cos(a) * radius * 0.65, z + sin(a) * radius * 0.65, 0.18), p(centre + cos(b) * radius * 0.65, z + sin(b) * radius * 0.65, 0.18))
            }
        case .briseSoleil:
            for slat in 0..<3 {
                let z = lintel - Double(slat) * 0.20
                bar(left - 0.08, right + 0.08, z, z + 0.07, 0.02, 0.36, mesh: &timber)
            }
        }
        treatmentCount += 1
        types.insert(treatment.rawValue)
    }

    func addNodes(to root: SCNNode, identity: BuildingIdentity) {
        for (name, mesh, material) in [("facadeStoneDetails", stone, identity.material("trim")), ("facadeShuttersAndScreens", timber, identity.material("shutter")), ("facadeIronwork", iron, identity.material("iron"))] where !mesh.positions.isEmpty {
            root.addChildNode(mesh.node(name: name, material: material))
        }
    }
}
