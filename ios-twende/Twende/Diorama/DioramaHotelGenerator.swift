import Foundation

/// Photo-led landmark rules. Heights remain mapped; facade proportions are photographic estimates.
/// No Standard building or generic residential shell is used for these footprints.
nonisolated struct DioramaHotelGenerator {
    static let delta: UInt64 = 681_375_591
    static let waterfront: UInt64 = 681_320_838
    static let gallery: UInt64 = 688_368_950
    static let yellowBlock: UInt64 = 142_262_988
    static let arcade: UInt64 = 142_262_989
    static let ids: Set<UInt64> = [delta, waterfront, gallery, yellowBlock, arcade]
    let terrain: DioramaTerrain
    var courtyardCentre: DV2? = nil

    func build(_ f: DioramaBuildingFeature, mesh: inout DioramaMesh, glow: inout DioramaMesh,
               lights: inout [DioramaLight]) -> DioramaBuilt {
        let base = terrain.buildingHeight(f)
        let old = mesh.baseZ, oldGlow = glow.baseZ
        mesh.baseZ = base; glow.baseZ = base
        defer { mesh.baseZ = old; glow.baseZ = oldGlow }
        let isDelta = f.id == Self.delta, isTeal = f.id == Self.waterfront, isArcade = f.id == Self.arcade
        let isHotel = f.id == Self.gallery, isYellow = f.id == Self.yellowBlock
        let floors = isDelta ? 7 : (isTeal ? 4 : (isArcade ? 1 : (isHotel ? 5 : 6)))
        let height = f.height ?? Double(floors) * 3.2
        let pitch = height / Double(floors)
        let color: DioramaSwatch = isYellow ? .paleYellow : (isTeal ? .hotelTeal : (isDelta ? .deltaStone : (isHotel ? .slipwayBlue : .whitewash)))
        let box = DioramaPolygon.minimumAreaRectangle(f.ring)
        // Authored landmark plan shared by slabs, walls, roofs and ground masks.
        let ring = f.ring
        mesh.extrude(ring, z0: -0.25, z1: 0, color)
        let balconyRing = isDelta ? scallopedOutline(f.ring) : ring
        for floor in 0...floors {
            let z = Double(floor) * pitch
            let outline = isHotel && floor == floors
                ? (DioramaPolygon.offset(ring, by: -0.65) ?? ring)
                : (isDelta && floor > 0 && floor < floors ? balconyRing : ring)
            mesh.extrude(outline, z0: z, z1: z + 0.19, .trimWhite, top: floor == floors ? .roofConcrete : .paving)
            mesh.polygon(outline, z: z, .trimWhite, facingUp: false)
        }
        // The fish mural faces west into the pedestrian court in the photograph. Garden 1128180504
        // is farther south: aiming at its centroid incorrectly selected the hotel's short end wall.
        let desired = isHotel ? DV2(-1, -0.22).normalized : (isDelta ? DV2(1, 0) : (isTeal ? DV2(-1, 0) : DV2(1, 0)))
        let front = f.ring.indices.max { i, j in
            func score(_ k: Int) -> Double {
                let e = f.ring[(k + 1) % f.ring.count] - f.ring[k]
                return e.length * max(0, e.normalized.right.dot(desired))
            }
            return score(i) < score(j)
        } ?? 0
        // Hotel Slipway's signed porte-cochère faces the car park on the eastern service loop,
        // opposite the west mural frontage.
        let signSide = isHotel ? DV2(1, 0.22).normalized : desired
        let signEdge = f.ring.indices.max { i, j in
            func score(_ k: Int) -> Double {
                let e = f.ring[(k + 1) % f.ring.count] - f.ring[k]
                return e.length * max(0, e.normalized.right.dot(signSide))
            }
            return score(i) < score(j)
        } ?? front
        let fa = f.ring[signEdge], fb = f.ring[(signEdge + 1) % f.ring.count]
        let entrance = (fa + fb) * 0.5, entranceOut = (fb - fa).normalized.right
        for i in f.ring.indices where !f.clipped[i] {
            let a = f.ring[i], b = f.ring[(i + 1) % f.ring.count]
            let length = a.distance(to: b), dir = (b - a).normalized, out = dir.right
            guard length > 2 else { mesh.mouldedWall(ring, edge: i, z0: 0.19, z1: height, color); continue }
            let count = max(1, Int(length / (isDelta ? 4.2 : (isHotel && i == front ? 2.6 : 3.6))))
            let bay = length / Double(count)
            let galleryDepth = length > 8 ? (isDelta ? 1.45 : 1.25) : 0.22
            for floor in 0..<floors {
                let z = Double(floor) * pitch + 0.19
                let muralBay = false
                let groundArch = isHotel && i == front && floor == 0
                let archSpring = muralBay ? height - 1.0 : z + 1.65
                for k in 0..<count {
                    let l = a + dir * (Double(k) * bay), r = l + dir * bay
                    let centre = (l + r) * 0.5
                    let recess = [l + dir * 0.3 - out * galleryDepth, r - dir * 0.3 - out * galleryDepth].allSatisfy { DioramaPolygon.contains(f.ring, $0) } ? galleryDepth : 0.1
                    let backL = l - out * recess, backR = r - out * recess
                    if k == 0 { mesh.wall(l, backL, z0: z, z1: z + pitch - 0.19, color) }
                    if k == count - 1 { mesh.wall(backR, r, z0: z, z1: z + pitch - 0.19, color) }
                    let sill = floor == 0 ? 0.12 : 0.55
                    if !isArcade { mesh.wall(backL, backR, z0: z, z1: z + sill, color) }
                    mesh.wall(backL, backR, z0: z + pitch - 0.5, z1: z + pitch - 0.19, color)
                    // Masonry jambs leave a genuine glazed recess, with timber/white sliding frames.
                    for q in [backL, backR - dir * 0.23] {
                        mesh.box(centre: q + dir * 0.115, z0: z, axis: dir, halfLength: 0.115, halfWidth: 0.16, height: pitch - 0.19, color)
                    }
                    let glassL = backL + dir * 0.23 - out * 0.05, glassR = backR - dir * 0.23 - out * 0.05
                    if !isArcade { mesh.wall(glassL, glassR, z0: z + sill, z1: z + pitch - 0.5, .glass) }
                    for u in (isArcade ? [] : [0.0, 0.5, 1.0]) {
                        let q = glassL + (glassR - glassL) * u + out * 0.035
                        mesh.box(centre: q, z0: z + sill, axis: dir, halfLength: 0.035, halfWidth: 0.04, height: pitch - 0.5 - sill, isTeal || isDelta ? .frame : .doorWood)
                    }
                    if !isArcade && (k + floor) % 3 != 0 {
                        glow.wall(glassL + out * 0.005, glassR + out * 0.005, z0: z + sill + 0.1, z1: z + pitch - 0.65, .windowGlow)
                    }
                    if recess > 0.5 {
                        mesh.box(centre: l + dir * 0.14 - out * (isDelta ? 0.76 : 0.14), z0: z, axis: dir, halfLength: 0.14, halfWidth: 0.14, height: muralBay || groundArch ? archSpring - z : pitch - 0.19, isDelta ? .deltaStone : .trimWhite)
                        if k == count - 1 && (muralBay || groundArch) {
                            mesh.box(centre: r - dir * 0.14 - out * 0.14, z0: z, axis: dir, halfLength: 0.14,
                                     halfWidth: 0.14, height: archSpring - z, .trimWhite)
                        }
                        if floor > 0 {
                            if isDelta {
                                scallop(l: l, dir: dir, out: out, width: bay, z: z, mesh: &mesh)
                            } else {
                                let rail = centre - out * 0.13
                                mesh.box(centre: rail, z0: z, axis: dir, halfLength: bay / 2, halfWidth: 0.09, height: isTeal ? 0.52 : 0.15, isTeal ? .hotelTeal : .doorWood)
                                for h in [0.55, 1.04] {
                                    mesh.box(centre: rail, z0: z + h, axis: dir, halfLength: bay / 2, halfWidth: 0.045, height: 0.065, isTeal ? .trimWhite : .carvedWood)
                                }
                                let spindles = max(2, Int(bay / (isTeal ? 0.7 : 0.19)))
                                for n in 1..<spindles {
                                    let q = l + dir * (Double(n) * bay / Double(spindles)) - out * 0.13
                                    mesh.box(centre: q, z0: z + 0.15, axis: dir, halfLength: 0.024, halfWidth: 0.035, height: 0.87, isTeal ? .trimWhite : .doorWood)
                                }
                            }
                        }
                        if !isTeal && !isDelta && !muralBay && !groundArch {
                            mesh.tube(from: DV3(centre - out * 0.12, z + pitch - 0.25), to: DV3(centre - out * 0.95, z + pitch - 0.95), r0: 0.07, r1: 0.07, sides: 4, .carvedWood)
                        }
                    }
                    if isTeal && floor == 0 && k % 2 == 0 {
                        let ac = centre - out * 0.3
                        mesh.box(centre: ac, z0: z + pitch - 0.7, axis: dir, halfLength: 0.4, halfWidth: 0.22, height: 0.42, .concrete)
                        mesh.verticalDisc(centre: DV3(ac + out * 0.23, z + pitch - 0.49), radius: 0.15, sides: 12, facing: out, .metalCharcoal)
                    }
                    if isArcade { archedSpandrel(a: l, dir: dir, out: out, width: bay, spring: z + 1.75, rise: 1, top: height, color: .whitewash, mesh: &mesh) }
                    if muralBay || groundArch {
                        archedSpandrel(a: l, dir: dir, out: out, width: bay,
                                       spring: archSpring, rise: muralBay ? 0.8 : min(1.1, pitch - 1.85),
                                       top: muralBay ? height + 1.15 : z + pitch - 0.19,
                                       color: muralBay ? .muralBlue : .whitewash, mesh: &mesh, pointed: muralBay)
                    }
                }
            }
            if !isHotel {
                mesh.extrude([a, b, b - out * 0.22, a - out * 0.22], z0: height + 0.19, z1: height + 0.8, color, top: .trimWhite)
            }
        }
        if isHotel { fishCornice(ring, height: height, mesh: &mesh) }
        // The fish-painted curved cornice is the upper silhouette, not a west-only wall mural.
        if isDelta {
            let roofBox = DioramaOrientedRect(centre: box.centre, axis: box.axis, halfLength: box.halfLength * 0.43, halfWidth: box.halfWidth * 0.55)
            if roofBox.corners.allSatisfy({ DioramaPolygon.contains(f.ring, $0) }) {
                mesh.box(centre: roofBox.centre, z0: height + 0.19, axis: box.axis, halfLength: roofBox.halfLength, halfWidth: roofBox.halfWidth, height: 2.4, .deltaStone)
                for t in stride(from: -roofBox.halfLength, through: roofBox.halfLength, by: 0.55) {
                    for s in [-1.0, 1.0] {
                        mesh.box(centre: box.centre + box.axis * t + box.across * (s * roofBox.halfWidth), z0: height + 0.4, axis: box.axis, halfLength: 0.035, halfWidth: 0.07, height: 2.1, .trimWhite)
                    }
                }
            }
        }
        if isDelta || isHotel {
            canopy(at: entrance, dir: (fb - fa).normalized, out: entranceOut, isDelta: isDelta, mesh: &mesh, glow: &glow)
            lights.append(DioramaLight(position: DV3(entrance + entranceOut * 3, base + 3.5), color: SIMD3<Float>(1, 0.83, 0.62), radius: 12, intensity: 1.1))
        }
        return DioramaBuilt(feature: f, kind: .apartments, floors: floors, height: height, box: box, flatRoof: true, wallColor: color, entrance: entrance, entranceOut: entranceOut)
    }

    /// Solid attached fascia, coved bed moulding, projecting corona and flat weathering cap.
    /// Only the underside is curved: the fish-painted frieze is a broad vertical masonry face.
    private func fishCornice(_ ring: [DV2], height: Double, mesh: inout DioramaMesh) {
        let profile: [(reach: Double, z: Double)] = [
            (0, -0.42), (0.04, -0.34), (0.09, -0.26), (0.15, -0.20),
            (0.22, -0.17), (0.24, -0.12), (0.24, 0.82),
            (0.30, 0.86), (0.41, 0.93), (0.54, 1.02),
            (0.62, 1.04), (0.62, 1.21), (0, 1.21)
        ]
        let offsets = profile.map { DioramaCoastline.offset(ring, by: $0.reach) }
        for k in 0..<(profile.count - 1) {
            for i in ring.indices {
                let j = (i + 1) % ring.count
                mesh.quad(DV3(offsets[k][i], height + profile[k].z),
                          DV3(offsets[k][j], height + profile[k].z),
                          DV3(offsets[k + 1][j], height + profile[k + 1].z),
                          DV3(offsets[k + 1][i], height + profile[k + 1].z), .muralBlue)
            }
        }
        for i in ring.indices {
            let j = (i + 1) % ring.count
            mesh.wall(ring[j], ring[i], z0: height - 0.42, z1: height + 1.21, .slipwayBlue)
        }
    }

    func pitchedGalleryRoof(_ ring: [DV2], box: DioramaOrientedRect, z: Double, mesh: inout DioramaMesh, infillDepth: Double = 1.07) {
        let c = box.corners, reach = max(0.01, box.halfLength - box.halfWidth)
        let r0 = box.centre - box.axis * reach, r1 = box.centre + box.axis * reach
        let rise = box.halfWidth * 0.32
        let faces: [[DV3]] = [
            [DV3(c[0], z), DV3(c[1], z), DV3(r1, z + rise), DV3(r0, z + rise)],
            [DV3(c[1], z), DV3(c[2], z), DV3(r1, z + rise)],
            [DV3(c[2], z), DV3(c[3], z), DV3(r0, z + rise), DV3(r1, z + rise)],
            [DV3(c[3], z), DV3(c[0], z), DV3(r0, z + rise)]
        ]
        // Clip each planar hip to the actual non-rectangular footprint, retaining all notches.
        for face in faces {
            let mask = DioramaPolygon.counterClockwise(face.map(\.xy))
            let n = (face[1] - face[0]).cross(face[2] - face[0]).normalized
            guard abs(n.z) > 0.01 else { continue }
            func lifted(_ p: DV2) -> DV3 {
                DV3(p, face[0].z - (n.x * (p.x - face[0].x) + n.y * (p.y - face[0].y)) / n.z)
            }
            for t in DioramaPolygon.triangulate(ring) {
                var piece = [ring[t.0], ring[t.1], ring[t.2]]
                for i in mask.indices { piece = DioramaGroundCutouts.halfPlane(piece, a: mask[i], b: mask[(i + 1) % mask.count], inside: true) }
                guard piece.count >= 3 else { continue }
                for i in 1..<(piece.count - 1) { mesh.triangle(lifted(piece[0]), lifted(piece[i]), lifted(piece[i + 1]), .roofConcrete, normal: n.z > 0 ? n : n * -1) }
            }
        }
        func roofZ(_ p: DV2) -> Double {
            let v = p - box.centre
            return z + max(0, min(box.halfLength - abs(v.dot(box.axis)), box.halfWidth - abs(v.dot(box.across)))) * 0.32
        }
        let edge = DioramaPolygon.densify(ring + [ring[0]], maxStep: 1)
        for (a, b) in zip(edge, edge.dropFirst()) {
            mesh.quad(DV3(a, z - infillDepth), DV3(b, z - infillDepth), DV3(b, roofZ(b)), DV3(a, roofZ(a)), .whitewash, normal: DV3((b - a).normalized.right, 0))
        }
    }

    private func scallopedOutline(_ ring: [DV2]) -> [DV2] {
        var outline: [DV2] = []
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], dir = (b - a).normalized
            outline.append(a)
            let length = a.distance(to: b)
            guard length > 8 else { continue }
            let count = max(1, Int(length / 4.2)), bay = length / Double(count)
            for k in 0..<count {
                for j in 0...16 {
                    if k > 0 && j == 0 { continue }
                    let t = Double(j) / 16
                    let p = a + dir * ((Double(k) + t) * bay) - dir.right * (0.65 - 0.55 * sin(.pi * t))
                    if DioramaPolygon.contains(ring, p) { outline.append(p) }
                }
            }
        }
        return outline
    }

    private func scallop(l: DV2, dir: DV2, out: DV2, width: Double, z: Double, mesh: inout DioramaMesh) {
        // Curved balcony front cut into the footprint, not blobs attached to a solid extrusion.
        let points = (0...16).map { i -> DV2 in
            let t = Double(i) / 16
            return l + dir * (width * t) - out * (0.65 - 0.55 * sin(.pi * t))
        }
        for i in 0..<16 {
            let a = points[i], b = points[i + 1]
            mesh.wall(a, b, z0: z - 0.02, z1: z + 0.2, .trimWhite)
            mesh.tube(from: DV3(a, z + 1), to: DV3(b, z + 1), r0: 0.045, r1: 0.045, sides: 5, .trimWhite)
            mesh.tube(from: DV3(a, z + 0.2), to: DV3(a, z + 1), r0: 0.025, r1: 0.025, sides: 4, .trimWhite)
        }
    }

    func archedSpandrel(a: DV2, dir: DV2, out: DV2, width: Double, spring: Double, rise: Double,
                         top: Double, color: DioramaSwatch, mesh: inout DioramaMesh, pointed: Bool = false) {
        let half = pointed ? width * 0.36 : max(0.1, width / 2 - 0.25)
        let centre = a + dir * (width / 2), pierWidth = width / 2 - half
        // Angular samples resolve the steep jambs; uniform x samples made these look stepped.
        // Indexed face/reveal ribbons share vertices, with smoothly interpolated soffit normals.
        let steps = 40, start = mesh.positions.count
        let faceUV = DioramaAtlas.uv(color, dark: false)
        let backUV = DioramaAtlas.uv(.whitewash, dark: false)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x: Double, h: Double, dx: Double, dz: Double
            if pointed {
                let left = t <= 0.5
                let angle = (left ? t * 2 : (1 - t) * 2) * .pi / 3
                x = (left ? -1 : 1) * half * (2 * cos(angle) - 1)
                h = spring + rise * sin(angle) / sin(.pi / 3)
                dx = 2 * half * sin(angle)
                dz = (left ? 1 : -1) * rise * cos(angle) / sin(.pi / 3)
            } else {
                let angle = t * .pi
                x = -half * cos(angle); h = spring + rise * sin(angle)
                dx = half * sin(angle); dz = rise * cos(angle)
            }
            let p = centre + dir * x, rear = p - out * 0.24
            let soffit = (DV3(dir * dz, -dx)).normalized
            mesh.vertex(DV3(p, h), DV3(out, 0), faceUV)
            mesh.vertex(DV3(p, top), DV3(out, 0), faceUV)
            mesh.vertex(DV3(rear, h), DV3(-out, 0), backUV)
            mesh.vertex(DV3(rear, top), DV3(-out, 0), backUV)
            mesh.vertex(DV3(p, h), soffit, backUV)
            mesh.vertex(DV3(rear, h), soffit, backUV)
        }
        for i in 0..<steps {
            for k in [0, 2, 4] {
                let p = UInt32(start + i * 6 + k), q = p + 6
                mesh.tri(p, q, q + 1); mesh.tri(p, q + 1, p + 1)
            }
        }
        for p in [a + dir * (pierWidth / 2), a + dir * (width - pierWidth / 2)] {
            mesh.box(centre: p - out * 0.12, z0: spring, axis: dir, halfLength: pierWidth / 2, halfWidth: 0.12, height: top - spring, color)
        }
        // The top cap covers only the open span; pier boxes already cap their own widths.
        mesh.quad(DV3(centre - dir * half, top), DV3(centre + dir * half, top),
                  DV3(centre + dir * half - out * 0.24, top), DV3(centre - dir * half - out * 0.24, top), color, normal: .up)
    }

    private func arch(a: DV2, dir: DV2, out: DV2, width: Double, z: Double, rise: Double, mesh: inout DioramaMesh) {
        for i in 0..<16 {
            let t0 = Double(i) / 16 * Double.pi, t1 = Double(i + 1) / 16 * Double.pi
            let c = a + dir * (width / 2) - out * 0.08
            let p = DV3(c + dir * (cos(t0) * (width / 2 - 0.25)), z + sin(t0) * rise)
            let q = DV3(c + dir * (cos(t1) * (width / 2 - 0.25)), z + sin(t1) * rise)
            mesh.tube(from: p, to: q, r0: 0.16, r1: 0.16, sides: 6, .cream)
        }
    }

    private func canopy(at p: DV2, dir: DV2, out: DV2, isDelta: Bool, mesh: inout DioramaMesh, glow: inout DioramaMesh) {
        let width = isDelta ? 5.4 : 4.2, depth = isDelta ? 5.0 : 4.0
        mesh.box(centre: p + out * (depth / 2), z0: 3.6, axis: dir, halfLength: width, halfWidth: depth / 2, height: 0.42, .cream, bevel: 0.12)
        for s in [-1.0, 1.0] {
            let foot = p + dir * (s * (width - 0.35)) + out * (depth - 0.4)
            mesh.box(centre: foot, z0: 0, axis: dir, halfLength: 0.22, halfWidth: 0.22, height: 3.6, .cream)
            glow.box(centre: foot - out * 0.3, z0: 3.56, halfLength: 0.3, halfWidth: 0.2, height: 0.03, .lampGlow)
        }
        let fascia = p + out * (depth + 0.03)
        mesh.facadeBox(a: fascia - dir * width, dir: dir, out: out, u: width, width: width * 2, z0: 3.75, z1: 4.65, depth: 0.1, isDelta ? .deltaStone : .capCharcoal)
        DioramaLettering.line(isDelta ? "DELTA HOTELS" : "HOTEL SLIPWAY", centre: DV3(fascia + out * 0.12, 3.91), up: .up, facing: DV3(out, 0), height: 0.57, swatch: .trimWhite, mesh: &mesh)
        DioramaLettering.line(isDelta ? "DELTA HOTELS" : "HOTEL SLIPWAY", centre: DV3(fascia + out * 0.13, 3.91), up: .up, facing: DV3(out, 0), height: 0.57, swatch: .lampGlow, mesh: &glow)
    }

}
