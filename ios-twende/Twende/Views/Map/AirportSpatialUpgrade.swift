import SceneKit

/// Additive offline migration reuses saved terminals/props; only the corrected skin and tower are authored.
@MainActor enum AirportSpatialUpgrade {
    static func applying(to original: DioramaTileArtifacts, data: AirportMapData, includeTower: Bool) throws -> DioramaTileArtifacts {
        let origin = data.site.anchor.coordinate, rect = data.groundRect(origin: origin)
        guard let image = AirportGroundGeometry.image(data, origin: origin, size: 64) else { throw DioramaTileArchive.ArchiveError.invalid }
        let scene = SCNScene()
        AirportGroundSkin.add(data, root: scene.rootNode)
        if includeTower { AirportControlTowerGeometry.add(data, root: scene.rootNode) }
        let added = DioramaLandmarkMesh.airport(scene, origin: origin, image: image, rect: rect)
        let vBase = UInt32(original.vertices.count), iBase = original.indices.count
        var ranges: [DioramaRenderLayer.Range] = []
        for source in original.ranges {
            guard source.category == .ground else { ranges.append(source); continue }
            // Category also contains real paving/decks. Remove only material-9 painted terrain.
            var start: Int?
            for offset in stride(from: source.start, to: source.start + source.count - 2, by: 3) {
                let id = original.indices[offset]
                let painted = original.vertices[Int(id)].appearance.y == 9
                if painted, let begin = start {
                    ranges.append(.init(category: source.category, start: begin, count: offset - begin, minimum: source.minimum, maximum: source.maximum, doubleSided: source.doubleSided, translucent: source.translucent))
                    start = nil
                }
                if !painted && start == nil { start = offset }
            }
            if let start {
                ranges.append(.init(category: source.category, start: start, count: source.start + source.count - start, minimum: source.minimum, maximum: source.maximum, doubleSided: source.doubleSided, translucent: source.translucent))
            }
        }
        ranges.append(contentsOf: added.ranges.map {
            DioramaRenderLayer.Range(category: $0.category, start: $0.start + iBase, count: $0.count, minimum: $0.minimum, maximum: $0.maximum, doubleSided: $0.doubleSided, translucent: $0.translucent)
        })
        return DioramaTileArtifacts(tile: original.tile, vertices: original.vertices + added.vertices,
            indices: original.indices + added.indices.map { $0 + vBase }, ranges: ranges, groups: original.groups, allInstances: original.allInstances,
            parts: [], lights: original.lights, lightGrid: original.lightGrid, waterHeight: 0, shorelineReport: [], generationSeconds: 0, groundImage: image, renderMaterialsPrepared: true)
    }
}
