@_spi(Experimental) import MapboxMaps
import SceneKit
import simd

/// Footprint-aware architectural grammar: base, aligned bays, recessed openings, entrance and roof crown.
/// Detail is real connected geometry with smooth colour fields; no noisy textures or decorative block piles.
enum BuildingArchitecture {
    static let windowBudget: Int = 320

    static func make(geometry: Geometry, origin: LocationCoordinate2D, base: Double, roof: Double, style requestedStyle: BuildingMaterialStyle? = nil, windowLimit: Int = windowBudget, roofStyle: BuildingRoof.Style? = nil, isFragmented: Bool = false, identity suppliedIdentity: BuildingIdentity? = nil) -> SCNNode {
        let root = SCNNode()
        root.name = "building"
        guard base.isFinite, roof.isFinite, base >= 0, roof > base else { return root }
        let polygons: [[[LocationCoordinate2D]]]
        switch geometry {
        case .polygon(let polygon): polygons = [polygon.coordinates]
        case .multiPolygon(let multi): polygons = Array(multi.coordinates.prefix(12))
        default: return root
        }
        let sourceIdentity = suppliedIdentity ?? BuildingIdentity(geometry: geometry)
        let footprints = polygons.compactMap { BuildingFootprint(coordinates: $0, origin: origin) }
        let usesVariation = requestedStyle == nil || suppliedIdentity != nil
        let primaryForm = footprints.max { abs(BuildingFootprint.area($0.rings[0])) < abs(BuildingFootprint.area($1.rings[0])) }.map {
            BuildingMorphology(footprint: $0, height: roof - base, identity: sourceIdentity, roofOverride: roofStyle)
        }
        let identity = usesVariation && !isFragmented ? (primaryForm?.identity ?? sourceIdentity) : sourceIdentity
        let wallMaterial = identity.material("wall"), glassMaterial = identity.material("glass")
        let detailGrammar = BuildingDetailGrammar(identity: identity)
        var facadeDetails = BuildingFacadeDetails(limit: windowLimit < 100 ? 8 : 24)
        var orders = BuildingMesh()
        var columnCount = 0
        let totalEdges = max(1, footprints.reduce(0) { $0 + $1.rings.reduce(0) { $0 + $1.count } })
        let style = requestedStyle ?? footprints.first.map { BuildingGrammar(footprint: $0, height: roof - base, roofOverride: roofStyle).material } ?? .royalStone
        let perEdge = max(0, min(windowBudget, windowLimit)) / totalEdges
        let trim = usesVariation ? identity.material("trim") : BuildingSurfaces.make("architectural edge", color: style.trim, roughness: 0.85)
        let revealMaterial = identity.material("recess")
        let baseMaterial = identity.material("base")
        var rhythm = BuildingFacadeRhythm(limit: windowLimit < 100 ? 16 : 40)
        var baseCourses = BuildingMesh()
        var walls = BuildingMesh(), glazing = BuildingMesh(), reveals = BuildingMesh()
        var frames = BuildingMesh(), bands = BuildingMesh(), entrances = BuildingMesh(), plinth = BuildingMesh()
        var lighting = BuildingMesh()
        let lightMaterial = BuildingSurfaces.make("architectural light", color: "#FFF0CF", roughness: 0.4)
        lightMaterial.emission.contents = UIColor.white
        for originalFootprint in footprints {
            let morphology = BuildingMorphology(footprint: originalFootprint, height: roof - base, identity: sourceIdentity, roofOverride: roofStyle)
            let shaped = usesVariation && !isFragmented
            if shaped && morphology.isTower && originalFootprint.rings.count == 1 {
                root.addChildNode(BuildingGlassTower.make(footprint: originalFootprint, base: base, roof: roof, identity: identity))
                continue
            }
            let tropical = shaped && roofStyle == nil && BuildingLifestyle.hasTropicalRoof(morphology) && originalFootprint.rectangle != nil
            let planted = shaped && morphology.roofStyle == .terrace && identity.variant(channel: 15, count: 3) == 0
            let inferredRoof = tropical ? BuildingRoof.Style.hip : shaped ? morphology.roofStyle : roofStyle
            let grammar = BuildingGrammar(footprint: originalFootprint, height: roof - base, roofOverride: isFragmented ? .terrace : inferredRoof)
            let footprint = isFragmented ? originalFootprint : BuildingContour.softened(originalFootprint)
            let roofNode = (tropical ? BuildingLifestyle.tropical(footprint: originalFootprint, eave: roof, base: base, identity: identity) : nil) ?? BuildingRoof.make(footprint: originalFootprint, eave: roof, style: grammar.roofStyle, trim: trim, softensEdges: !isFragmented, variant: identity.variant(channel: 2, count: 8))
            root.addChildNode(roofNode)
            let crownHeight = shaped ? morphology.crownHeight : grammar.crownHeight
            if planted, let garden = BuildingLifestyle.plantedRoof(footprint: originalFootprint, eave: roof, identity: identity) {
                roofNode.addChildNode(garden)
            } else if !isFragmented, crownHeight > 0, let rectangle = originalFootprint.rectangle {
                roofNode.addChildNode(BuildingCrown.make(rectangle: rectangle, eave: roof, height: crownHeight, isTower: shaped ? morphology.isTower : grammar.family == .tower, trim: trim, levels: shaped ? morphology.crownLevels : nil, variant: identity.variant(channel: 3, count: 4)))
            } else if !isFragmented, grammar.roofStyle == .terrace,
                      let atrium = BuildingCrown.atrium(footprint: originalFootprint, eave: roof, trim: trim) {
                roofNode.addChildNode(atrium)
            }
            if usesVariation {
                roofNode.enumerateChildNodes { node, _ in
                    guard let geometry = node.geometry else { return }
                    switch node.name {
                    case "continuousDome", "continuousVault", "sawtoothRoof": geometry.materials = [identity.material("metal")]
                    case "mansardRoof", "dormerCaps": geometry.materials = [identity.material("slate")]
                    case "dormerGlass", "clerestoryGlass": geometry.materials = [glassMaterial]
                    case "roundedCrownSurface":
                        if node.parent?.name != "roofAtrium" { geometry.materials = [wallMaterial] }
                    case "continuousRoof", "spanishBarrelTiles": geometry.materials = [identity.material(tropical ? "slate" : "tile")]
                    case "roofDeck", "crownRoof": geometry.materials = [identity.material("terrace")]
                    default: break
                    }
                }
                if !isFragmented && (!shaped || morphology.hasClassicalOrnaments) {
                    roofNode.addChildNode(BuildingRoofOrnaments.make(footprint: footprint, eave: roof, grammar: detailGrammar, isTerrace: grammar.roofStyle == .terrace, budget: max(4, (windowLimit < 100 ? 16 : 48) / max(1, footprints.count))))
                }
            }
            if shaped && (morphology.family == .rowHouse || (morphology.family == .mansion && identity.detailVariant % 2 == 0)),
               let bays = BuildingLifestyle.sanFranciscoBays(footprint: originalFootprint, base: base, eave: roof, identity: identity) {
                root.addChildNode(bays)
            }
            let height = roof - base
            let floorCount = max(1, Int(min(28, height / (shaped ? morphology.floorSpacing : 3.6))))
            let storey = height / Double(floorCount)
            let baseHeight = min(0.5, height * 0.08)
            plinth.perimeter(rings: footprint.rings, bottom: base, top: base + baseHeight, projection: 0.10)
            bands.perimeter(rings: footprint.rings, bottom: roof - min(0.20, height * 0.05), top: roof + 0.12, projection: 0.20)
            lighting.perimeter(rings: footprint.rings, bottom: roof - 0.13, top: roof - 0.07, projection: 0.22)
            if grammar.hasFloorBands {
                let bandStride = shaped ? morphology.bandStride : 1
                for floor in stride(from: 1, to: floorCount, by: bandStride) {
                    let z = base + Double(floor) * storey
                    bands.perimeter(rings: footprint.rings, bottom: z - 0.12, top: z + 0.06, projection: grammar.family == .tower ? 0.09 : 0.15)
                }
            }
            if shaped && height > 8 {
                baseCourses.perimeter(rings: footprint.rings, bottom: base + min(0.7, storey * 0.15), top: base + min(1.3, storey * 0.30), projection: 0.08, profileSegments: 4)
            }
            for (ringIndex, ring) in footprint.rings.enumerated() {
                let lengths = ring.indices.map { simd_distance(ring[$0], ring[($0 + 1) % ring.count]) }
                let vertexNormals = BuildingContour.outwardNormals(ring)
                let front = lengths.indices.max { a, b in
                    if abs(lengths[a] - lengths[b]) > 0.01 { return lengths[a] < lengths[b] }
                    let midA = (ring[a] + ring[(a + 1) % ring.count]) / 2
                    let midB = (ring[b] + ring[(b + 1) % ring.count]) / 2
                    return midA.y == midB.y ? midA.x > midB.x : midA.y > midB.y
                }
                for edge in ring.indices {
                    let start = ring[edge], end = ring[(edge + 1) % ring.count]
                    let length = lengths[edge]
                    guard length > 0.02 else { continue }
                    let tangent = (end - start) / length
                    let outward = SIMD2(tangent.y, -tangent.x)
                    let normal = SIMD3(outward.x, outward.y, 0.0)
                    func p(_ x: Double, _ z: Double, _ depth: Double = 0) -> SIMD3<Double> {
                        let xy = start + tangent * x + outward * depth
                        return SIMD3(xy.x, xy.y, z)
                    }
                    guard length >= 3, height >= 2.4, perEdge > 0 else {
                        let n0 = vertexNormals[edge], n1 = vertexNormals[(edge + 1) % ring.count]
                        if length < 1.5 && !isFragmented {
                            walls.smoothQuad(p(0, base), p(length, base), p(length, roof), p(0, roof), normals: [SIMD3(n0.x, n0.y, 0), SIMD3(n1.x, n1.y, 0), SIMD3(n1.x, n1.y, 0), SIMD3(n0.x, n0.y, 0)])
                        } else {
                            walls.quad(p(0, base), p(length, base), p(length, roof), p(0, roof), normal: normal)
                        }
                        continue
                    }
                    let rows = min(floorCount, perEdge)
                    let bays = max(1, min(12, min(perEdge / rows, Int(length / ((shaped ? morphology.bayWidth : grammar.bayWidth) * (usesVariation ? identity.rhythm : 1))))))
                    let bayWidth = length / Double(bays)
                    if shaped && morphology.usesVerticalRibs && ringIndex == 0 {
                        for bay in 1..<bays {
                            rhythm.addRib(start: start, tangent: tangent, outward: outward, position: Double(bay) * bayWidth, bottom: base + min(storey, 4.2), top: roof - 0.25, variant: identity.detailVariant)
                        }
                    }
                    // Unshown storeys remain continuous walls; budget never drops a roof or opens holes.
                    var cursor = base
                    for row in 0..<rows {
                        let floor = row * floorCount / rows
                        let low = base + Double(floor) * storey, high = low + storey
                        if low > cursor { walls.quad(p(0, cursor), p(length, cursor), p(length, low), p(0, low), normal: normal) }
                        for bay in 0..<bays {
                            let x0 = Double(bay) * bayWidth, x1 = x0 + bayWidth
                            let isEntry = ringIndex == 0 && edge == front && floor == 0 && bay == bays / 2 && base < 0.1 && !isFragmented
                            let wideBay = grammar.family == .tower || grammar.family == .pavilion
                            let openingWidth = min(isEntry ? 2.5 : (shaped && morphology.isTower) ? 3.8 : wideBay ? 3.3 : 2.4, bayWidth * (shaped ? morphology.windowRatio : wideBay ? 0.76 : 0.62))
                            let left = (x0 + x1 - openingWidth) / 2, right = left + openingWidth
                            let sill = isEntry ? low + 0.08 : low + min(1.05, storey * 0.25)
                            let lintel = low + min(storey - 0.48, isEntry ? 3.0 : 3.1)
                            let depth = grammar.recess
                            // Tile the wall around each opening. There is no opaque wall behind the pane.
                            walls.quad(p(x0, low), p(x1, low), p(x1, sill), p(x0, sill), normal: normal)
                            walls.quad(p(x0, lintel), p(x1, lintel), p(x1, high), p(x0, high), normal: normal)
                            walls.quad(p(x0, sill), p(left, sill), p(left, lintel), p(x0, lintel), normal: normal)
                            walls.quad(p(right, sill), p(x1, sill), p(x1, lintel), p(right, lintel), normal: normal)
                            reveals.quad(p(left, sill), p(left, lintel), p(left, lintel, -depth), p(left, sill, -depth))
                            reveals.quad(p(right, lintel), p(right, sill), p(right, sill, -depth), p(right, lintel, -depth))
                            reveals.quad(p(left, lintel), p(right, lintel), p(right, lintel, -depth), p(left, lintel, -depth))
                            bands.quad(p(left, sill, -depth), p(right, sill, -depth), p(right, sill), p(left, sill), normal: SIMD3(0, 0, 1))
                            glazing.quad(p(left, sill, -depth), p(right, sill, -depth), p(right, lintel, -depth), p(left, lintel, -depth), normal: normal)
                            if usesVariation && (!shaped || (!morphology.isTower && morphology.family != .cottage && morphology.family != .rowHouse)) && (identity.order == .roman || identity.order == .gallery || identity.order == .domed) {
                                BuildingOrders.arch(wall: &walls, trim: &bands, reveal: &reveals, start: start, tangent: tangent, normal: outward, left: left, right: right, top: lintel, bottom: sill, depth: depth)
                            }
                            let isGreek = identity.order == .doric || identity.order == .ionic || identity.order == .corinthian
                            if usesVariation, !isFragmented, (!shaped || morphology.hasClassicalOrnaments), columnCount < 32, bayWidth > 3,
                               (isGreek && floor == 0 && (edge == front || identity.order != .doric)) || (identity.order == .roman && floor < 3) || (identity.order == .gallery && floor == 0) {
                                let centre = start + tangent * (x0 + 0.35) + outward * 0.12
                                BuildingOrders.column(mesh: &orders, centre: centre, tangent: tangent, outward: outward, bottom: low, top: high - 0.12, order: isGreek ? identity.order : .doric)
                                columnCount += 1
                            }
                            if openingWidth > 1.6 {
                                let centre = (left + right) / 2, half = 0.045
                                frames.quad(p(centre - half, sill, -depth + 0.02), p(centre + half, sill, -depth + 0.02), p(centre + half, lintel, -depth + 0.02), p(centre - half, lintel, -depth + 0.02), normal: normal)
                            }
                            if usesVariation, !isFragmented {
                                let treatment = detailGrammar.treatment(floor: floor, bay: bay, width: bayWidth, storey: storey, isEntry: isEntry, isCourtyard: ringIndex > 0)
                                facadeDetails.bay(treatment, start: start, tangent: tangent, outward: outward, left: left, right: right, sill: sill, lintel: lintel, floorTop: high, bayLeft: x0, bayRight: x1)
                            }
                            if isEntry {
                                for x in [left - 0.20, right + 0.20] {
                                    lighting.quad(p(x - 0.06, low + 1.65, 0.10), p(x + 0.06, low + 1.65, 0.10), p(x + 0.06, low + 2.0, 0.10), p(x - 0.06, low + 2.0, 0.10), normal: normal)
                                }
                                let corners = [p(left - 0.35, 0, -0.08), p(left - 0.35, 0, 0.85), p(right + 0.35, 0, 0.85), p(right + 0.35, 0, -0.08)].map { SIMD2($0.x, $0.y) }
                                let canopyRing = BuildingContour.rounded(corners, tangentDistance: 0.30)
                                let canopy = BuildingFootprint(rings: [canopyRing])
                                let centre = canopyRing.reduce(SIMD2<Double>.zero, +) / Double(canopyRing.count)
                                for i in canopyRing.indices {
                                    let a = canopyRing[i], b = canopyRing[(i + 1) % canopyRing.count]
                                    entrances.triangle(SIMD3(centre.x, centre.y, lintel + 0.30), SIMD3(a.x, a.y, lintel + 0.30), SIMD3(b.x, b.y, lintel + 0.30), normal: SIMD3(0, 0, 1))
                                    entrances.triangle(SIMD3(centre.x, centre.y, lintel + 0.12), SIMD3(b.x, b.y, lintel + 0.12), SIMD3(a.x, a.y, lintel + 0.12), normal: SIMD3(0, 0, -1))
                                }
                                entrances.perimeter(rings: canopy.rings, bottom: lintel + 0.12, top: lintel + 0.30, projection: 0.10)
                            }
                        }
                        cursor = high
                    }
                    if cursor < roof { walls.quad(p(0, cursor), p(length, cursor), p(length, roof), p(0, roof), normal: normal) }
                }
            }
        }
        if usesVariation {
            facadeDetails.addNodes(to: root, identity: identity)
            rhythm.addNode(to: root, identity: identity)
            if !baseCourses.positions.isEmpty { root.addChildNode(baseCourses.node(name: "masonryBaseCourse", material: baseMaterial)) }
        }
        if usesVariation { root.addChildNode(lighting.node(name: "architecturalLighting", material: lightMaterial)) }
        if !orders.positions.isEmpty { root.addChildNode(orders.node(name: "order.\(identity.order)", material: trim)) }
        for (name, mesh, material) in [
            ("walls", walls, usesVariation ? wallMaterial : BuildingSurfaces.wall(style)), ("reflectiveWindows", glazing, usesVariation ? glassMaterial : BuildingSurfaces.glass),
            ("windowRecesses", reveals, revealMaterial), ("facadeMullions", frames, trim),
            ("continuousCornices", bands, trim), ("entranceCanopy", entrances, trim), ("buildingBase", plinth, baseMaterial)
        ] where !mesh.positions.isEmpty {
            root.addChildNode(mesh.node(name: name, material: material))
        }
        return root
    }

}
