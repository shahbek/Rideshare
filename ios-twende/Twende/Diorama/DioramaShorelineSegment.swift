import Foundation

/// Continuous classified coast, ordered with water on its left. Joins are shared before classification.
nonisolated struct DioramaShorelineSegment: Sendable {
    let id: UInt64
    let points: [DV2]
    let outward: [DV2]
    let kind: DioramaShoreline.Kind
    let source: DioramaShoreline.Source
    let evidence: String
    let hasRevetment: Bool
    var length: Double { DioramaPolygon.length(points) }
}
