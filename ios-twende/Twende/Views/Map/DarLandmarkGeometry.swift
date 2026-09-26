import SceneKit
import simd

/// Photo-guided compositions in a site-specific, right-handed frame; the underlying OSM footprint is never rotated.
enum DarLandmarkGeometry {
    static func make(_ site: DarLandmarkSite) -> SCNScene {
        let scene = SCNScene()
        guard let footprint = site.footprint, let ring = footprint.rings.first else { return scene }
        let local = ring.map { SIMD2(simd_dot($0, site.right), simd_dot($0, site.inward)) }
        let root = SCNNode(); root.name = site.id
        root.simdTransform = simd_float4x4(columns: (
            SIMD4(Float(site.right.x), Float(site.right.y), 0, 0),
            SIMD4(Float(site.inward.x), Float(site.inward.y), 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)
        ))
        scene.rootNode.addChildNode(root)
        if site.kind == "tower" { PSPFTowerGeometry.build(site, ring: local, root: root) }
        else { DarChurchGeometry.build(site, ring: local, root: root) }
        return scene
    }
}
