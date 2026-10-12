import Foundation

/// Shared architectural datums are resolved before mesh generation. Facades, slabs and supports
/// consume the same bay grid; optional roof equipment uses a contained clearance zone, never a fence.
nonisolated struct DarArchitecturePlan {
    struct Elevation {
        let index: Int
        let a: DV2
        let b: DV2
        let bays: Int
        var length: Double { a.distance(to: b) }
        var dir: DV2 { (b - a).normalized }
        var out: DV2 { dir.right }
        var pitch: Double { length / Double(bays) }
        var mid: DV2 { (a + b) * 0.5 }
    }

    let source: [DV2]
    let envelope: [DV2]
    let glazing: [DV2]
    let elevations: [Elevation]
    let entrance: Int
    let levels: Int
    let height: Double
    let groundFloor: Double
    let storey: Double
    let recess: Double
    let serviceZone: DioramaOrientedRect?

    init?(footprint: [DV2], site: DarSkylineSite) {
        guard footprint.count >= 3, site.height.isFinite, site.height >= 6, site.levels >= 2 else { return nil }
        let clean = DioramaPolygon.clean(footprint, flags: Array(repeating: false, count: footprint.count)).points
        let source = DioramaPolygon.counterClockwise(clean)
        guard source.count >= 3, DioramaPolygon.area(source) > 60 else { return nil }
        self.source = source
        let bounds = DioramaPolygon.minimumAreaRectangle(source)
        let design = DarBuildingDesign(site: site)
        let radius = min(design.cornerRadius, max(0.25, bounds.halfWidth * 0.14))
        let round = DioramaPolygon.rounded(source, flags: Array(repeating: false, count: source.count), radius: radius).points
        let compact = Self.compactContour(round)
        let ring = Self.fits(compact, inside: source, clearance: -0.03) ? compact : source
        envelope = ring
        levels = min(site.levels, 60)
        height = site.height
        groundFloor = min(design.groundFloor, height / Double(levels) * 1.3)
        storey = (height - groundFloor) / Double(levels - 1)
        let wantedRecess = design.recess
        if let inner = Self.inset(ring, distance: wantedRecess) {
            glazing = inner; recess = wantedRecess
        } else if let inner = Self.inset(ring, distance: 0.2) {
            glazing = inner; recess = 0.2
        } else {
            glazing = ring; recess = 0
        }
        let perimeter = zip(ring, ring.dropFirst() + [ring[0]]).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        // Bound facade cells rather than dropping decorations halfway around a building.
        let pitch = max(design.bayWidth, perimeter * Double(levels) / 440)
        elevations = ring.indices.map { i in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return Elevation(index: i, a: a, b: b, bays: max(1, Int(a.distance(to: b) / pitch)))
        }
        entrance = elevations.max(by: { $0.length < $1.length })?.index ?? 0
        serviceZone = Self.containedCourt(in: ring)
    }

    func floor(_ index: Int) -> Double { index == 0 ? 0.32 : groundFloor + Double(index - 1) * storey }

    static func inset(_ ring: [DV2], distance: Double, minimumArea: Double = 12) -> [DV2]? {
        guard let inner = DioramaPolygon.offset(ring, by: -distance), inner.count == ring.count,
              DioramaPolygon.area(inner) > minimumArea, fits(inner, inside: ring, clearance: min(0.02, distance * 0.5)) else { return nil }
        return inner
    }

    /// Check edges as well as corners: a rectangle can bridge the notch of an L/U footprint.
    static func fits(_ candidate: [DV2], inside ring: [DV2], clearance: Double) -> Bool {
        guard candidate.count >= 3 else { return false }
        for i in candidate.indices {
            let a = candidate[i], b = candidate[(i + 1) % candidate.count]
            let steps = max(2, Int(ceil(a.distance(to: b) / 0.5)))
            for step in 0...steps {
                let p = a + (b - a) * (Double(step) / Double(steps))
                let distance = DioramaPolygon.distanceToRing(ring, p)
                if !DioramaPolygon.contains(ring, p) && distance > max(0.035, -clearance) { return false }
                if clearance > 0 && distance < clearance { return false }
            }
        }
        return true
    }

    /// Eliminate redundant samples on already-curved OSM outlines before repeating floor profiles.
    /// Every removed original sample must stay within 6 cm of the replacement chord; concave
    /// corners and genuine angular junctions are preserved.
    private static func compactContour(_ ring: [DV2]) -> [DV2] {
        var kept = Array(ring.indices)
        var changed = true
        while changed && kept.count > 4 {
            changed = false
            for position in kept.indices {
                let previous = kept[(position + kept.count - 1) % kept.count]
                let current = kept[position], next = kept[(position + 1) % kept.count]
                let incoming = ring[current] - ring[previous], outgoing = ring[next] - ring[current]
                guard incoming.cross(outgoing) >= 0, incoming.normalized.dot(outgoing.normalized) > 0.8 else { continue }
                var sample = (previous + 1) % ring.count, valid = true
                while sample != next {
                    if DioramaPolygon.distanceToSegment(ring[sample], ring[previous], ring[next]) > 0.06 { valid = false; break }
                    sample = (sample + 1) % ring.count
                }
                if valid { kept.remove(at: position); changed = true; break }
            }
        }
        return kept.map { ring[$0] }
    }

    private static func containedCourt(in ring: [DV2]) -> DioramaOrientedRect? {
        let box = DioramaPolygon.minimumAreaRectangle(ring)
        for scale in [0.46, 0.34, 0.24] {
            for u in [-0.28, 0.0, 0.28] {
                for v in [0.0, -0.22, 0.22] {
                    let court = DioramaOrientedRect(centre: box.centre + box.axis * (box.halfLength * u) + box.across * (box.halfWidth * v),
                        axis: box.axis, halfLength: min(5.5, box.halfLength * scale), halfWidth: min(3.2, box.halfWidth * scale))
                    if court.halfLength > 2, court.halfWidth > 1.6,
                       fits(court.corners, inside: ring, clearance: 1.0) { return court }
                }
            }
        }
        return nil
    }
}
