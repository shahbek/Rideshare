import SceneKit
import simd

/// Photo-led JNIA tower on OSM 438449950. Vertical dimensions are estimated, not surveyed.
enum AirportControlTowerGeometry {
    nonisolated static let sourceID = 438449950

    static func add(_ data: AirportMapData, root: SCNNode) {
        guard let feature = data.features.first(where: { $0.id == sourceID }), feature.isClosed else { return }
        let source = DioramaPolygon.counterClockwise(feature.local(origin: data.site.anchor.coordinate))
        guard source.count == 8 else { return }
        let centre = DioramaPolygon.centroid(source)
        func ring(_ scale: Double) -> [SIMD2<Double>] {
            source.map { let p = centre + ($0 - centre) * scale; return SIMD2(p.x, p.y) }
        }
        func loft(_ mesh: inout BuildingMesh, from lower: [SIMD2<Double>], at bottom: Double, to upper: [SIMD2<Double>], at top: Double) {
            for i in lower.indices {
                let j = (i + 1) % lower.count
                mesh.quad(DarLandmarkParts.p(lower[i], bottom), DarLandmarkParts.p(lower[j], bottom), DarLandmarkParts.p(upper[j], top), DarLandmarkParts.p(upper[i], top))
            }
        }
        var shaft = BuildingMesh(), cab = BuildingMesh(), frames = BuildingMesh(), rails = BuildingMesh()
        loft(&shaft, from: ring(0.48), at: 0.2, to: ring(0.48), at: 19.5)
        loft(&shaft, from: ring(0.48), at: 19.5, to: ring(0.76), at: 26.4)
        let lower = ring(0.79), upper = ring(0.94)
        loft(&cab, from: lower, at: 27.3, to: upper, at: 31.1)
        for i in source.indices {
            let j = (i + 1) % source.count
            // Three panes per octagonal face, with mullions following the outward-inclined cab.
            for t in [0.0, 1.0 / 3.0, 2.0 / 3.0] {
                let a = lower[i] + (lower[j] - lower[i]) * t
                let b = upper[i] + (upper[j] - upper[i]) * t
                LandmarkMesh.beam(&frames, from: DarLandmarkParts.p(a, 27.3), to: DarLandmarkParts.p(b, 31.1), radius: 0.075, sides: 6)
            }
            let a = ring(0.94)[i], b = ring(0.94)[j]
            for z in [26.9, 27.45] { LandmarkMesh.beam(&rails, from: DarLandmarkParts.p(a, z), to: DarLandmarkParts.p(b, z), radius: 0.045, sides: 6) }
            for t in [0.0, 0.25, 0.5, 0.75] {
                let p = a + (b - a) * t
                LandmarkMesh.beam(&rails, from: DarLandmarkParts.p(p, 26.5), to: DarLandmarkParts.p(p, 27.45), radius: 0.035, sides: 6)
            }
        }
        root.addChildNode(shaft.node(name: "mappedAirportBuilding-438449950", material: DarLandmarkParts.plaster))
        root.addChildNode(cab.node(name: "airportControlTowerSlopedGlazing", material: BuildingSurfaces.make("airport.towerGlass", color: "#30494E", roughness: 0.65)))
        root.addChildNode(frames.node(name: "airportControlTowerCabFrames", material: DarLandmarkParts.silver))
        root.addChildNode(rails.node(name: "airportControlTowerGalleryRails", material: DarLandmarkParts.silver))
        root.addChildNode(BuildingFootprint(rings: [ring(0.97)]).deck(at: 26.5, thickness: 0.35, material: DarLandmarkParts.plaster, name: "airportControlTowerGallery"))
        root.addChildNode(BuildingFootprint(rings: [ring(0.99)]).deck(at: 31.75, thickness: 0.65, material: DarLandmarkParts.plaster, name: "airportControlTowerRoof"))
        var antenna = BuildingMesh()
        let p = SIMD2(centre.x, centre.y)
        LandmarkMesh.beam(&antenna, from: DarLandmarkParts.p(p, 31.75), to: DarLandmarkParts.p(p, 36), radius: 0.055, sides: 6)
        for x in [-0.9, 0.9] {
            let q = p + SIMD2(x, 0)
            LandmarkMesh.beam(&antenna, from: DarLandmarkParts.p(q, 31.75), to: DarLandmarkParts.p(q, 33.6), radius: 0.035, sides: 6)
        }
        root.addChildNode(antenna.node(name: "airportControlTowerRadioMasts", material: DarLandmarkParts.silver))
    }
}
