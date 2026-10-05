import Foundation

/// Ordered finish offsets above the shared terrain mesh. Ownership masks remove incompatible
/// overlaps; these offsets prevent depth fighting between legitimate stacked finishes.
nonisolated enum DioramaSurfaceLevel: Double, Sendable {
    case ground = 0
    case lawn = 0.025
    case footway = 0.08
    case paving = 0.11
    case road = 0.12
    case roadPaint = 0.17

    static let structuralPaintClearance: Double = 0.04
}
