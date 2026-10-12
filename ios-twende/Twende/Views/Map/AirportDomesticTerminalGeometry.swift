import SceneKit
import simd

/// T2's photographed concrete forest canopy, using the reported 13m structural grid.
enum AirportDomesticTerminalGeometry {
    static func add(ring: [SIMD2<Double>], boardingRoots: [SIMD2<Double>], root: SCNNode) {
        let polygon = DioramaPolygon.counterClockwise(ring.map { DV2($0.x, $0.y) })
        let triangles = DioramaPolygon.triangulate(polygon)
        guard AirportArchitectureParts.completeTriangulation(polygon, triangles: triangles) else { return }
        let bounds = DioramaRect.bounding(polygon), pitch = 13.0, thickness = 0.58
        var roof = BuildingMesh(), soffit = BuildingMesh(), rim = BuildingMesh(), trunks = BuildingMesh(), ribs = BuildingMesh()
        func height(_ p: DV2, _ centre: DV2) -> Double {
            9.3 + 3.3 * max(abs(p.x - centre.x), abs(p.y - centre.y)) / (pitch / 2)
        }
        var coveredArea = 0.0
        for x in stride(from: bounds.minX, to: bounds.maxX, by: pitch) {
            for y in stride(from: bounds.minY, to: bounds.maxY, by: pitch) {
                let centre = DV2(x + pitch / 2, y + pitch / 2)
                let corners = [DV2(x, y), DV2(x + pitch, y), DV2(x + pitch, y + pitch), DV2(x, y + pitch)]
                for face in corners.indices {
                    let umbrella = [centre, corners[face], corners[(face + 1) % 4]]
                    for (a, b, c) in triangles {
                        let piece = clip(umbrella, inside: [polygon[a], polygon[b], polygon[c]])
                        guard piece.count >= 3, DioramaPolygon.area(piece) > 0.0000001 else { continue }
                        let faces = DioramaPolygon.triangulate(piece)
                        guard AirportArchitectureParts.completeTriangulation(piece, triangles: faces) else { return }
                        coveredArea += DioramaPolygon.area(piece)
                        for (i, j, k) in faces {
                            let ps = [piece[i], piece[j], piece[k]].map { SIMD3($0.x, $0.y, height($0, centre)) }
                            roof.triangle(ps[0], ps[1], ps[2])
                            let drop = SIMD3<Double>(0, 0, thickness)
                            soffit.triangle(ps[2] - drop, ps[1] - drop, ps[0] - drop)
                        }
                        // Close only the true campus-facing perimeter. Adjacent roof fans share edges.
                        for i in piece.indices {
                            let p = piece[i], q = piece[(i + 1) % piece.count], mid = (p + q) * 0.5
                            guard DioramaPolygon.distanceToRing(polygon, mid) < 0.00001 else { continue }
                            let za = height(p, centre), zb = height(q, centre)
                            rim.quad(SIMD3(p.x, p.y, za - thickness), SIMD3(q.x, q.y, zb - thickness), SIMD3(q.x, q.y, zb), SIMD3(p.x, p.y, za))
                        }
                    }
                }
                guard DioramaPolygon.contains(polygon, centre), DioramaPolygon.distanceToRing(polygon, centre) > 1.1 else { continue }
                AirportArchitectureParts.box(&trunks, centre: SIMD2(centre.x, centre.y), width: 0.95, depth: 0.95, bottom: 0.32, top: 8.86)
                // Flared capital and eight concrete branches all meet the same roof profile.
                trunks.revolve(centre: SIMD2(centre.x, centre.y), profile: [SIMD2(0.48, 8.2), SIMD2(0.8, 8.65), SIMD2(1.18, 8.85), SIMD2(0, 8.85)], segments: 12)
                for end in corners + [DV2(x + pitch / 2, y), DV2(x + pitch, y + pitch / 2), DV2(x + pitch / 2, y + pitch), DV2(x, y + pitch / 2)] {
                    var tip = centre
                    for step in 1...20 {
                        let candidate = centre + (end - centre) * (Double(step) / 20)
                        guard DioramaPolygon.contains(polygon, candidate), DioramaPolygon.distanceToRing(polygon, candidate) > 0.35 else { break }
                        tip = candidate
                    }
                    guard tip.distance(to: centre) > 0.5 else { continue }
                    LandmarkMesh.beam(&ribs, from: SIMD3(centre.x, centre.y, 8.55), to: SIMD3(tip.x, tip.y, height(tip, centre) - thickness + 0.05), radius: 0.27, sides: 8)
                }
            }
        }
        guard abs(coveredArea - DioramaPolygon.area(polygon)) < max(0.0001, DioramaPolygon.area(polygon) * 0.000001) else { return }
        root.addChildNode(roof.node(name: "terminal2UmbrellaRoof", material: DarLandmarkParts.plaster))
        root.addChildNode(soffit.node(name: "terminal2ConcreteUmbrellaSoffit", material: DarLandmarkParts.trim))
        root.addChildNode(rim.node(name: "terminal2ClosedCanopyEdges", material: DarLandmarkParts.plaster))
        root.addChildNode(trunks.node(name: "terminal2ConcreteTreeColumnsAndCapitals", material: DarLandmarkParts.plaster))
        root.addChildNode(ribs.node(name: "terminal2AlignedRadialConcreteRoofRibs", material: DarLandmarkParts.trim))
        let inset = HarbourArchitectureParts.inset(ring, by: 1.4)
        AirportArchitectureParts.glazing(inset.isEmpty ? ring : inset, bottom: 0.32, top: 8.7, openingCentres: boardingRoots, root: root)
        let galleryEdge = bounds.minY + bounds.height * 0.55
        let gallery = DioramaPolygon.clipPolygon(polygon, to: DioramaRect(minX: bounds.minX, minY: bounds.minY, maxX: bounds.maxX, maxY: galleryEdge))
        if gallery.count >= 3 {
            root.addChildNode(BuildingFootprint(rings: [gallery.map { SIMD2($0.x, $0.y) }]).deck(at: 5.35, thickness: 0.35, material: DarLandmarkParts.trim, name: "terminal2AirsideMezzanineAndBridgeLandings"))
            var rails = BuildingMesh()
            for i in gallery.indices {
                let a = gallery[i], b = gallery[(i + 1) % gallery.count]
                guard abs(a.y - galleryEdge) < 0.01, abs(b.y - galleryEdge) < 0.01 else { continue }
                LandmarkMesh.beam(&rails, from: SIMD3(a.x, a.y, 6.9), to: SIMD3(b.x, b.y, 6.9), radius: 0.085, sides: 8)
                let length = a.distance(to: b)
                for station in stride(from: 0.0, to: length, by: 3.0) {
                    let p = a + (b - a) * (station / length)
                    LandmarkMesh.beam(&rails, from: SIMD3(p.x, p.y, 5.7), to: SIMD3(p.x, p.y, 6.9), radius: 0.06, sides: 8)
                }
            }
            root.addChildNode(rails.node(name: "terminal2OpenMezzanineRails", material: DarLandmarkParts.silver))
        }
        // Select a genuine long frontage, rather than an interior row or a narrow roof finger.
        let fronts = ring.indices.filter { i in
            let d = ring[(i + 1) % ring.count] - ring[i]
            return simd_length(d) > 25 && d.x / simd_length(d) < -0.5
        }
        if let edge = fronts.max(by: { (ring[$0].y + ring[($0 + 1) % ring.count].y) < (ring[$1].y + ring[($1 + 1) % ring.count].y) }) {
            let a = ring[edge], b = ring[(edge + 1) % ring.count], along = simd_normalize(b - a), outward = SIMD2(along.y, -along.x)
            let centre = (a + b) / 2 - outward * 0.35
            AirportArchitectureParts.name("JULIUS NYERERE INTERNATIONAL AIRPORT TERMINAL 2", centre: DarLandmarkParts.p(centre, 13.0), facing: outward, height: 1.35, root: root, material: AirportArchitectureParts.roofSignBlue, maximumWidth: simd_distance(a, b) * 0.9, depth: 0.28)
            var posts = BuildingMesh()
            for fraction in [0.15, 0.5, 0.85] {
                let p = a + (b - a) * fraction - outward * 0.55
                LandmarkMesh.beam(&posts, from: DarLandmarkParts.p(p, 9.3), to: DarLandmarkParts.p(p, 13.5), radius: 0.10, sides: 6)
            }
            root.addChildNode(posts.node(name: "terminal2BlueRoofSignSupports", material: DarLandmarkParts.silver))
        }
    }

    /// Convex half-plane intersection preserves the pyramid planes instead of sampling a wavy grid.
    private static func clip(_ source: [DV2], inside triangle: [DV2]) -> [DV2] {
        var result = source
        for i in triangle.indices {
            let a = triangle[i], b = triangle[(i + 1) % triangle.count], edge = b - a
            var output: [DV2] = []
            guard result.count >= 3 else { return [] }
            for j in result.indices {
                let p = result[(j + result.count - 1) % result.count], q = result[j]
                let before = edge.cross(p - a), after = edge.cross(q - a)
                if (before >= 0) != (after >= 0) {
                    output.append(p + (q - p) * (before / (before - after)))
                }
                if after >= 0 { output.append(q) }
            }
            result = output
        }
        return result
    }
}
