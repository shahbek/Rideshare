import Foundation

/// Photo-guided concrete profiles in metres. Width is across the road, depth is along the road.
/// Heights are illustrative; the mapped horizontal alignment is kept unchanged.
struct TanzanitePylonProfile {
    struct Section {
        let elevation: Double
        let offset: Double
        let width: Double
        let depth: Double
    }

    let deckElevation: Double
    let isCentral: Bool
    var topElevation: Double { isCentral ? 66 : deckElevation + 21 }
    static let samplingSteps: Int = 56

    func section(at elevation: Double) -> Section {
        let z = min(topElevation, max(0, elevation))
        let u = min(1, z / max(1, deckElevation))
        let smooth = u * u * (3 - 2 * u)
        let shoulder = isCentral ? 13.4 : 13.1
        let foot = isCentral ? 9.4 : 8.9
        let upper = max(0, min(1, (z - deckElevation) / (topElevation - deckElevation)))
        let t2 = upper * upper, t3 = t2 * upper
        let tip = isCentral ? 1.8 : 11.5
        // Hermite joins keep the curved lower leg tangent-continuous through the shoulder.
        let topSlope = isCentral ? -0.24 * (topElevation - deckElevation) : -0.04 * (topElevation - deckElevation)
        let offset = z <= deckElevation ? foot + (shoulder - foot) * smooth
            : (2 * t3 - 3 * t2 + 1) * shoulder + (-2 * t3 + 3 * t2) * tip + (t3 - t2) * topSlope
        let width = isCentral ? (z <= deckElevation ? 4.8 - 0.6 * smooth : 4.2 - 0.9 * upper)
            : (z <= deckElevation ? 3.8 - 0.2 * smooth : 3.6 - 0.4 * upper)
        let depth = isCentral ? (z <= deckElevation ? 6.0 - 0.2 * smooth : 5.8 - upper)
            : (z <= deckElevation ? 5.4 - 0.2 * smooth : 5.2 - 0.7 * upper)
        return Section(elevation: z, offset: offset, width: width, depth: depth)
    }

    var sections: [Section] {
        (0...Self.samplingSteps).map { section(at: Double($0) * topElevation / Double(Self.samplingSteps)) }
    }

    /// Attach at the wide longitudinal face, away from the chamfer and clear of traffic.
    func cableSection(index: Int) -> Section {
        let i = min(9, max(0, index))
        return section(at: deckElevation + 11.5 + Double(i) * 0.68)
    }
}
