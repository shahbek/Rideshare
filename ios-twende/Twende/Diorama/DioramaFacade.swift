import Foundation

/// A facade drawn by the fragment shader on a single wall quad (`DioramaMesh.facadeWall`).
///
/// The wall carries no opening geometry. Per vertex it encodes, in channels the 32-byte vertex
/// already has (no format change):
///  - material code (appearance.y): `32 + style·32 + storeyIndex − 0.375 + 0.75·f`, where `f` runs
///    0 → 1 along the wall. The shader recovers the wall length from the ratio of the screen
///    derivatives of `f` and of the along-wall world coordinate, so openings are centred on every
///    wall and corners know how far away they are. Values are exact in binary16.
///  - height attribute (appearance.z): `100 + height above the building base + 1000 · ground-floor
///    decimetres` (0 decimetres: the ground floor is one ordinary storey).
///  - category code fraction (appearance.w): `0.0625 · flags` (1 sharp start, 2 sharp end, 4 front).
nonisolated struct DioramaFacade: Sendable {
    /// Must match the style switch in the shader's `dioramaFacade`.
    enum Style: Int, Sendable {
        /// Blank render: end walls, short returns, parapets.
        case plain = 0
        /// Wide squat casements under a cast eyebrow hood; paired-leaf front door.
        case villa
        /// Punched openings in rendered masonry with sills and slab lines (Kisutu, tiled, modernist).
        case masonry
        /// Shopfront glazing across the ground-floor front, punched windows above.
        case commercial
        /// Deep recessed galleries behind solid balustrades (coastal apartments).
        case gallery
        /// Continuous horizontal window bands with slim mullions.
        case ribbon
        /// Full-height glazing on a mullion grid with spandrel bands (vertex colour tints the glass).
        case curtain
    }

    static let minimumStorey = 2.6
    static let storeyStep = 0.05

    var style: Style
    var storey: Double
    /// Height of a taller ground floor above the building base; 0 when it is one ordinary storey.
    var groundFloor: Double = 0

    /// Storey heights the code can express exactly (2.60 … 4.15 m in 5 cm steps). Generators snap
    /// their storey to this so the shader's floor lines land on the modelled slabs and roof.
    static func snapStorey(_ value: Double) -> Double {
        let clamped = min(max(value, minimumStorey), minimumStorey + storeyStep * 31)
        return minimumStorey + (((clamped - minimumStorey) / storeyStep).rounded()) * storeyStep
    }

    /// Ground floors are expressed in whole decimetres up to 9.9 m.
    static func snapGround(_ value: Double) -> Double {
        min(max((value * 10).rounded() / 10, 0), 9.9)
    }

    private var storeyIndex: Int {
        Int(((min(max(storey, Self.minimumStorey), Self.minimumStorey + Self.storeyStep * 31) - Self.minimumStorey) / Self.storeyStep).rounded())
    }

    func materialCode(along f: Float) -> Float {
        let code = Float(32 + style.rawValue * 32 + storeyIndex)
        return code - 0.375 + 0.75 * min(max(f, 0), 1)
    }

    func heightAttribute(_ z: Double) -> Float {
        let decimetres = Float(min(max(Int((groundFloor * 10).rounded()), 0), 99))
        return DioramaMesh.heightAttributeOffset + Float(z) + 1000 * decimetres
    }
}
