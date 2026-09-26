import SceneKit
import simd

/// Metric dimensions of the Morocco LED billboard (east/north/up metres, map-scale exaggerated so the
/// screen reads at street zoom). Shared by the steel structure and the video screen layer.
nonisolated enum BillboardDimensions {
    static let screenWidth: Double = 13.0
    static let screenHeight: Double = 7.3
    static let screenBottom: Double = 9.0
    static let frameMargin: Double = 0.45
    static let frameDepth: Double = 0.9
    static let poleRadius: Double = 0.55

    /// Unit vector the front screen faces, from a compass bearing.
    static func normal(facingDegrees: Double) -> SIMD2<Double> {
        let radians = facingDegrees * .pi / 180
        return SIMD2(sin(radians), cos(radians))
    }

    /// Viewer's right when looking at the front face.
    static func right(for normal: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(-normal.y, normal.x)
    }
}

/// Steel pole, concrete plinth, catwalk and dark cabinet. The lit faces are drawn separately by
/// `BillboardRenderLayer` so they can show live video.
enum BillboardGeometry {
    private static let steel = BuildingSurfaces.make("billboard.steel", color: "#8C9399", roughness: 0.45, metalness: 0.6)
    private static let cabinet = BuildingSurfaces.make("billboard.cabinet", color: "#1F2326", roughness: 0.5, metalness: 0.3)
    private static let concrete = BuildingSurfaces.make("billboard.plinth", color: "#C9C4BA", roughness: 0.9, metalness: 0)

    static func make(facingDegrees: Double) -> SCNScene {
        let scene = SCNScene()
        let root = SCNNode()
        root.name = "moroccoBillboard"
        scene.rootNode.addChildNode(root)
        let n = BillboardDimensions.normal(facingDegrees: facingDegrees)
        let r = BillboardDimensions.right(for: n)
        let d = BillboardDimensions.self

        DarLandmarkParts.volume(box(centre: .zero, right: r, normal: n, width: 2.0, depth: 2.0), bottom: 0, top: 0.7, material: concrete, name: "billboardPlinth", root: root)

        var pole = BuildingMesh()
        LandmarkMesh.beam(&pole, from: SIMD3(0, 0, 0.6), to: SIMD3(0, 0, d.screenBottom + 1.2), radius: d.poleRadius, sides: 16)
        // Short outriggers from the pole into the cabinet keep the head from looking glued on.
        for side in [-1.0, 1.0] {
            let tip = r * (d.screenWidth * 0.3 * side)
            LandmarkMesh.beam(&pole, from: SIMD3(0, 0, d.screenBottom - 1.6), to: SIMD3(tip.x, tip.y, d.screenBottom + 0.3), radius: 0.2, sides: 8)
        }
        root.addChildNode(pole.node(name: "billboardPole", material: steel))

        let cabinetWidth = d.screenWidth + d.frameMargin * 2
        DarLandmarkParts.volume(
            box(centre: .zero, right: r, normal: n, width: cabinetWidth, depth: d.frameDepth),
            bottom: d.screenBottom - d.frameMargin,
            top: d.screenBottom + d.screenHeight + d.frameMargin,
            material: cabinet, name: "billboardCabinet", root: root
        )
        DarLandmarkParts.volume(
            box(centre: n * 0.9, right: r, normal: n, width: cabinetWidth, depth: 1.1),
            bottom: d.screenBottom - d.frameMargin - 0.25,
            top: d.screenBottom - d.frameMargin - 0.1,
            material: steel, name: "billboardCatwalk", root: root
        )
        return scene
    }

    /// Counter-clockwise rectangle oriented by the billboard axes.
    private static func box(centre: SIMD2<Double>, right: SIMD2<Double>, normal: SIMD2<Double>, width: Double, depth: Double) -> [SIMD2<Double>] {
        let u = right * (width / 2), v = normal * (depth / 2)
        var ring = [centre - u - v, centre + u - v, centre + u + v, centre - u + v]
        if BuildingFootprint.area(ring) < 0 { ring.reverse() }
        return ring
    }
}
