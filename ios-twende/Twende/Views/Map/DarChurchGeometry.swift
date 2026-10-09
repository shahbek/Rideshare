import SceneKit
import UIKit
import simd

/// Individual church compositions, fitted within their mapped outer walls rather than generic church boxes.
enum DarChurchGeometry {
    static func build(_ site: DarLandmarkSite, ring: [SIMD2<Double>], root: SCNNode) {
        typealias P = DarLandmarkParts
        let cathedral = site.kind == "cathedral"
        let minX = ring.map(\.x).min() ?? -15, maxX = ring.map(\.x).max() ?? 15
        let minY = ring.map(\.y).min() ?? -20, maxY = ring.map(\.y).max() ?? 20
        let width = maxX - minX, depth = maxY - minY
        let centre = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
        let footprint = BuildingFootprint(rings: [ring])
        P.volume(ring, bottom: 0, top: 7.8, material: P.plaster, name: "mappedChurchWalls", root: root)
        P.volume(ring, bottom: 7.8, top: 8.05, material: P.clay, name: "closedAisleRoof", root: root)
        let nave = fittedRectangle(in: footprint, preferred: centre + SIMD2(cathedral ? -width * 0.1 : 0, 0), width: width * 0.5, depth: depth * 0.82)
        let naveFront = (nave[0] + nave[1]) / 2
        let naveBack = (nave[2] + nave[3]) / 2
        let naveWidth = simd_distance(nave[0], nave[1])
        let eave = cathedral ? 16.0 : 10.5, ridge = cathedral ? 24.0 : 16.0
        P.volume(nave, bottom: 7.8, top: eave, material: P.plaster, name: "churchNave", root: root)
        P.gable(nave, eave: eave, ridge: ridge, root: root, name: "steepNaveTileRoof")
        // Lower aisle roofs stay strictly within the same mapped polygon.
        for side in [-1.0, 1.0] {
            let preferred = centre + SIMD2(side * width * 0.32, 2)
            let aisle = fittedRectangle(in: footprint, preferred: preferred, width: width * 0.24, depth: depth * 0.65)
            P.gable(aisle, eave: 8.06, ridge: cathedral ? 11.2 : 11.0, root: root, name: "aisleTileRoof")
        }
        for side in [-1.0, 1.0] {
            let x = side < 0 ? nave[0].x : nave[1].x
            for bay in 0..<6 {
                let y = naveFront.y + (naveBack.y - naveFront.y) * (Double(bay) + 0.5) / 6
                let window = P.faceNode(at: SIMD2(x + side * 0.04, y), outward: SIMD2(side, 0), height: cathedral ? 10.0 : 7.9)
                P.arch(width: 1.3, height: cathedral ? 4.2 : 2.4, root: window, name: "navePointedWindow", illuminated: true)
                root.addChildNode(window)
                let buttress = P.rectangle(x: x - side * 0.15, y: y, width: 0.7, depth: 0.6)
                P.volume(buttress, bottom: 0, top: eave + 0.2, material: P.trim, name: "naveButtress", root: root)
            }
        }
        let desiredTower = cathedral ? SIMD2(maxX - width * 0.18, minY + depth * 0.15) : SIMD2(centre.x, minY + depth * 0.13)
        let tower = fittedRectangle(in: footprint, preferred: desiredTower, width: cathedral ? 7.4 : 6.8, depth: cathedral ? 7.4 : 6.8)
        let towerCentre = tower.reduce(SIMD2<Double>.zero, +) / 4
        let towerWidth = simd_distance(tower[0], tower[1])
        let towerTop = cathedral ? 30.5 : 25.0
        P.volume(tower, bottom: 0, top: towerTop, material: P.plaster, name: cathedral ? "cathedralNortheastTower" : "azaniaWestClockTower", root: root)
        for z in cathedral ? [15.8, 22.0, 28.0, 30.4] : [12.0, 18.0, 22.0, 24.9] {
            P.volume(tower, bottom: z, top: z + 0.24, material: P.trim, name: "towerStringCourse", root: root)
        }
        for i in tower.indices {
            let a = tower[i], b = tower[(i + 1) % 4], d = simd_normalize(b - a), n = SIMD2(d.y, -d.x)
            let face = P.faceNode(at: (a + b) / 2 + n * 0.035, outward: n, height: cathedral ? 24.5 : 21.0)
            P.arch(width: towerWidth * 0.62, height: cathedral ? 4.5 : 3.0, root: face, name: "openBelfry")
            var grille = BuildingMesh()
            for j in 1..<7 {
                let z = Double(j) * (cathedral ? 0.55 : 0.35)
                P.beam(&grille, SIMD3(-towerWidth * 0.26, z, 0.1), SIMD3(towerWidth * 0.26, z, 0.1), radius: 0.055)
            }
            face.addChildNode(grille.node(name: "belfryLouvers", material: P.slate))
            root.addChildNode(face)
            let disc = P.faceNode(at: (a + b) / 2 + n * 0.05, outward: n, height: cathedral ? 20.0 : 16.4)
            P.disc(radius: towerWidth * 0.21, root: disc, name: cathedral ? "towerRoseWindow" : "azaniaClockFace", clock: !cathedral)
            root.addChildNode(disc)
            if !cathedral {
                var gable = BuildingMesh(), trim = BuildingMesh()
                let left = (a + b) / 2 - d * towerWidth * 0.5 + n * 0.11
                let right = (a + b) / 2 + d * towerWidth * 0.5 + n * 0.11
                let middle = (a + b) / 2 + n * 0.11
                gable.triangle(P.p(left, 14.7), P.p(right, 14.7), P.p(middle, 19.0))
                P.beam(&trim, P.p(left, 14.7), P.p(middle, 19.0), radius: 0.14)
                P.beam(&trim, P.p(middle, 19.0), P.p(right, 14.7), radius: 0.14)
                root.addChildNode(gable.node(name: "azaniaClockGable", material: P.plaster))
                root.addChildNode(trim.node(name: "clockGableTileEdge", material: P.clay))
                // Move the clock in front of the gable's face, not behind its masonry.
                disc.simdPosition += SIMD3(Float(n.x * 0.16), Float(n.y * 0.16), 0)
            }
        }
        if cathedral {
            let half = towerWidth / 2
            let octagon = (0..<8).map { i -> SIMD2<Double> in
                let a = Double(i) * .pi / 4 + .pi / 8
                return towerCentre + SIMD2(cos(a), sin(a)) * (half / cos(.pi / 8))
            }
            P.pyramid(octagon, base: 30.5, top: site.height - 1.6, material: P.slate, root: root, name: "cathedralOctagonalSpire")
            cathedralFront(nave: nave, width: naveWidth, root: root)
        } else {
            P.pyramid(tower, base: 25.0, top: site.height - 1.3, material: P.clay, root: root, name: "azaniaPyramidalBelfryRoof")
            let entry = P.faceNode(at: SIMD2(towerCentre.x, tower[0].y - 0.04), outward: SIMD2(0, -1), height: 0.3)
            P.arch(width: towerWidth * 0.5, height: 4.0, root: entry, name: "azaniaEntrance")
            root.addChildNode(entry)
        }
        var cross = BuildingMesh()
        P.beam(&cross, P.p(towerCentre, site.height - 1.6), P.p(towerCentre, site.height), radius: 0.08)
        P.beam(&cross, P.p(towerCentre + SIMD2(-0.5, 0), site.height - 0.65), P.p(towerCentre + SIMD2(0.5, 0), site.height - 0.65), radius: 0.07)
        root.addChildNode(cross.node(name: "churchFinial", material: P.slate))
        LandmarkLightingGeometry.church(ring: ring, root: root)
    }

    private static func cathedralFront(nave: [SIMD2<Double>], width: Double, root: SCNNode) {
        typealias P = DarLandmarkParts
        let centre = (nave[0] + nave[1]) / 2
        let rose = P.faceNode(at: centre + SIMD2(0, -0.04), outward: SIMD2(0, -1), height: 12.0)
        P.disc(radius: min(2.0, width * 0.17), root: rose, name: "cathedralMainRoseWindow", clock: false)
        root.addChildNode(rose)
        for index in -1...1 {
            let x = centre.x + Double(index) * width * 0.29
            let entrance = P.faceNode(at: SIMD2(x, centre.y - 0.09), outward: SIMD2(0, -1), height: 0.25)
            P.arch(width: width * 0.24, height: 4.5, root: entrance, name: "cathedralTriplePortal")
            var gable = BuildingMesh(), trim = BuildingMesh()
            let half = width * 0.145
            gable.triangle(SIMD3(-half, 4.5, 0.03), SIMD3(half, 4.5, 0.03), SIMD3(0, 6.7, 0.03))
            P.beam(&trim, SIMD3(-half, 4.5, 0.09), SIMD3(0, 6.7, 0.09), radius: 0.16)
            P.beam(&trim, SIMD3(0, 6.7, 0.09), SIMD3(half, 4.5, 0.09), radius: 0.16)
            entrance.addChildNode(gable.node(name: "portalGable", material: P.plaster))
            entrance.addChildNode(trim.node(name: "portalGableRim", material: P.trim))
            root.addChildNode(entrance)
        }
        for index in -3...3 {
            let x = centre.x + Double(index) * width / 9
            let recess = P.faceNode(at: SIMD2(x, centre.y - 0.04), outward: SIMD2(0, -1), height: 16.3)
            P.arch(width: 0.42, height: 6.4 - Double(abs(index)) * 1.5, root: recess, name: "cathedralGableLancet", illuminated: true)
            root.addChildNode(recess)
        }
    }

    /// Sample both perimeter and interior so no rectangle spans an OSM notch or adjoining road.
    private static func fittedRectangle(in footprint: BuildingFootprint, preferred: SIMD2<Double>, width: Double, depth: Double) -> [SIMD2<Double>] {
        let ring = footprint.rings[0]
        let minX = ring.map(\.x).min() ?? 0, maxX = ring.map(\.x).max() ?? 0
        let minY = ring.map(\.y).min() ?? 0, maxY = ring.map(\.y).max() ?? 0
        let path = footprint.path
        for scale in [1.0, 0.9, 0.8, 0.65, 0.5, 0.35] {
            var best: (Double, [SIMD2<Double>])?
            for ix in 0...16 {
                for iy in 0...16 {
                    let centre = SIMD2(minX + (maxX - minX) * Double(ix) / 16, minY + (maxY - minY) * Double(iy) / 16)
                    let w = width * scale, d = depth * scale
                    let margin = 0.3
                    let fits = (0...8).allSatisfy { x in (0...8).allSatisfy { y in
                        path.contains(CGPoint(x: centre.x + (w + 2 * margin) * (Double(x) / 8 - 0.5), y: centre.y + (d + 2 * margin) * (Double(y) / 8 - 0.5)))
                    } }
                    // Interior sampling alone can miss Azania's narrow re-entrant notches. A boundary
                    // vertex inside the proposed rectangle proves it straddles the mapped perimeter.
                    let crossesNotch = ring.contains { abs($0.x - centre.x) < w / 2 + margin && abs($0.y - centre.y) < d / 2 + margin }
                    guard fits && !crossesNotch else { continue }
                    let score = simd_distance(centre, preferred)
                    if score < (best?.0 ?? .greatestFiniteMagnitude) { best = (score, DarLandmarkParts.rectangle(x: centre.x, y: centre.y, width: w, depth: d)) }
                }
            }
            if let best { return best.1 }
        }
        // The verified catalog's footprints all admit the bounded rectangles above.
        return DarLandmarkParts.rectangle(x: preferred.x, y: preferred.y, width: 0.2, depth: 0.2)
    }
}
