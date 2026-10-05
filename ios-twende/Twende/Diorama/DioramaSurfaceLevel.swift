import Foundation

/// Flat finishes (roads, pavements, lawns, paving, paint) are painted into the tile's ground image,
/// so there is no stacked-finish ladder above the terrain any more. The only vertical clearance left
/// is for paint laid on structural slabs (court lines, parking bays), which are real raised planes.
nonisolated enum DioramaSurfaceLevel {
    static let structuralPaintClearance: Double = 0.04
}
