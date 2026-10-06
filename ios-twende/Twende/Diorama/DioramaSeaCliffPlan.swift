import Foundation

/// Photo-space composition: u runs left-to-right in the aerial, v runs towards the cliff.
/// The map supplies the site anchor/orientation/scale, not the wall or roof outlines.
nonisolated struct DioramaSeaCliffPlan {
    struct Mass: Sendable {
        let box: DioramaOrientedRect
        let floors: Int
        let eave: Double
        let roofRise: Double
        let openGround: Bool
        let pavilion: Bool
    }
    let origin: DV2
    let axis = DV2(-0.43, 0.903).normalized
    let scale: Double
    var seaward: DV2 { axis.right }

    init(projection: DioramaProjection, mappedOutline: [DV2]) {
        origin = projection.local(longitude: 39.28415, latitude: -6.73958)
        let direction = DV2(-0.43, 0.903).normalized
        let stations = mappedOutline.map { $0.dot(direction) }
        let length = (stations.max() ?? 0) - (stations.min() ?? 0)
        scale = min(1.12, max(0.88, length / 118))
    }
    func point(_ u: Double, _ v: Double) -> DV2 { origin + axis * (u * scale) + seaward * (v * scale) }
    func box(_ u: Double, _ v: Double, _ length: Double, _ width: Double) -> DioramaOrientedRect {
        .init(centre: point(u, v), axis: axis, halfLength: length * scale / 2, halfWidth: width * scale / 2)
    }
    var masses: [Mass] {
        [
            .init(box: box(-3, 0, 86, 14), floors: 3, eave: 10.2, roofRise: 3.7, openGround: false, pavilion: false),
            .init(box: box(46, 5, 12, 24), floors: 2, eave: 7.2, roofRise: 3.1, openGround: false, pavilion: false),
            .init(box: box(-50, 15, 12, 30), floors: 2, eave: 6.8, roofRise: 3.8, openGround: true, pavilion: false),
            .init(box: box(-48, 40, 30, 20), floors: 2, eave: 6.8, roofRise: 4.2, openGround: true, pavilion: false),
            .init(box: box(-29, 34, 8, 16), floors: 1, eave: 4.4, roofRise: 3.0, openGround: true, pavilion: false),
            .init(box: box(1, 27, 21, 11), floors: 1, eave: 3.2, roofRise: 3.3, openGround: true, pavilion: true)
        ]
    }
    var footprints: [[DV2]] { masses.map { $0.box.corners } }
    var restaurantDeck: [DV2] { box(-47, 49, 35, 10).corners }
    var lawn: [DV2] { box(1, 47, 47, 27).corners }
}
