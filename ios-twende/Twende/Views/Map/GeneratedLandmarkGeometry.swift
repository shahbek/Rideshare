import SceneKit
import simd

/// Loads only approved local assets, preserving native fallback on any geometry/calibration failure.
enum GeneratedLandmarkGeometry {
    static func make(_ site: DarLandmarkSite, asset: GeneratedLandmarkAsset) -> SCNScene? {
        guard asset.placementApproved,
              let up = GeneratedLandmarkAsset.axis(asset.localUpAxis),
              let frontName = asset.localFrontAxis,
              let front = GeneratedLandmarkAsset.axis(frontName),
              abs(simd_dot(up, front)) < 0.001,
              let footprint = site.footprint, let ring = footprint.rings.first,
              let url = Bundle.main.url(forResource: asset.resource, withExtension: "usdz"),
              let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 0, fileSize <= 24 * 1024 * 1024,
              let imported = try? SCNScene(url: url, options: [.checkConsistency: true]) else { return nil }
        let scene = SCNScene(), placement = SCNNode(), visual = SCNNode()
        placement.name = site.id; visual.name = "generatedLandmarkVisual"
        scene.rootNode.addChildNode(placement); placement.addChildNode(visual)
        for child in imported.rootNode.childNodes { visual.addChildNode(child.clone()) }
        let localRight = simd_normalize(simd_cross(up, front))
        let localBasis = simd_float3x3(columns: (localRight, up, front))
        let bearing = Float(asset.frontBearing * .pi / 180)
        let worldFront = SIMD3<Float>(sin(bearing), cos(bearing), 0)
        let worldUp = SIMD3<Float>(0, 0, 1)
        let worldRight = simd_normalize(simd_cross(worldUp, worldFront))
        let correction = simd_float3x3(columns: (worldRight, worldUp, worldFront)) * simd_transpose(localBasis)
        visual.simdTransform = simd_float4x4(columns: (
            SIMD4(correction.columns.0, 0), SIMD4(correction.columns.1, 0),
            SIMD4(correction.columns.2, 0), SIMD4(0, 0, 0, 1)))
        var triangles = 0, sourceVertices = 0, materials = 0
        visual.enumerateChildNodes { node, _ in
            node.light = nil; node.camera = nil
            guard let geometry = node.geometry else { return }
            triangles += geometry.elements.reduce(0) { $0 + $1.primitiveCount }
            sourceVertices += geometry.sources(for: .vertex).first?.vectorCount ?? 0
            materials += geometry.materials.count
            geometry.materials = geometry.materials.map { material in
                let copy = material.copy() as? SCNMaterial ?? material
                copy.name = "generated.landmark"
                copy.roughness.contents = 0.85
                copy.metalness.contents = 0
                copy.transparency = 1
                return copy
            }
        }
        guard triangles > 0, triangles <= 60_000, sourceVertices <= 300_000, materials <= 32 else { return nil }
        let vertices = BuildingRenderGeometry.vertices(from: scene)
        guard !vertices.isEmpty, vertices.count <= 180_000 else { return nil }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for vertex in vertices {
            let point = SIMD3(vertex.position.x, vertex.position.y, vertex.position.z)
            let normal = SIMD3(vertex.normal.x, vertex.normal.y, vertex.normal.z)
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                  normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else { return nil }
            low = simd_min(low, point); high = simd_max(high, point)
        }
        guard high.z - low.z > 0.001 else { return nil }
        let factor = Float(asset.targetHeight) / (high.z - low.z)
        let centre = SIMD3((low.x + high.x) / 2, (low.y + high.y) / 2, low.z)
        // Check actual transformed support bounds before removing the original building shell.
        let polygon = ring.map { DV2($0.x, $0.y) }
        for vertex in vertices {
            let point = (SIMD3(vertex.position.x, vertex.position.y, vertex.position.z) - centre) * factor
            let xy = DV2(Double(point.x), Double(point.y))
            guard DioramaPolygon.contains(polygon, xy)
                || DioramaPolygon.distanceToRing(polygon, xy) <= 0.75 else { return nil }
        }
        let scale = simd_float4x4(columns: (SIMD4(factor, 0, 0, 0), SIMD4(0, factor, 0, 0),
            SIMD4(0, 0, factor, 0), SIMD4(-centre * factor, 1)))
        placement.simdTransform = scale
        return scene
    }
}
