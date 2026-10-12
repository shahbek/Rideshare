import Foundation
import simd

/// A household address computed offline for any point in Dar es Salaam.
nonisolated struct ZuriAddress: Hashable, Sendable {
    /// Metric house number: ≈ metres along the street ÷ 5, odd on the left and even on the right
    /// when travelling away from the city centre (the street origin is its end nearer Askari Monument).
    let number: Int?
    let street: String?
    /// Metres along the street from its origin to the door (explains the number).
    let metresAlong: Double?
    /// Metres from the point to the street centre line.
    let setback: Double?
    let neighbourhood: String?
    let ward: String?
    let district: String?
    /// Short locality-relative Plus Code (11 characters, ≈ 3 m), e.g. `67RG+XP7`.
    let code: String
    /// Full global Plus Code, e.g. `6G5X67RG+XP7`.
    let fullCode: String

    /// "147 Haile Selassie Road", or the Plus Code when no named street is close.
    var headline: String {
        if let street, let number { return "\(number) \(street)" }
        return code
    }

    /// "Masaki, Kinondoni" (ward/neighbourhood and municipal district, without repeats).
    var locality: String {
        var parts: [String] = []
        for part in [ward ?? neighbourhood, district] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
        }
        return parts.joined(separator: ", ")
    }

    /// Single-line postal form with the code, for sharing.
    var shareText: String {
        [headline, locality, "Dar es Salaam", "Tanzania", street == nil ? nil : code].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Zuri Anwani: deterministic, offline household addressing.
///
/// 1. **Street** — the nearest named street within 120 m (bundled OSM street chains).
/// 2. **Number** — metric numbering along that street: stable, gap-free for infill, and it tells a
///    driver roughly how far along the street the door is. Odd left / even right, 10 m per number per side.
/// 3. **Ward and district** — point-in-polygon against bundled administrative boundaries, falling back
///    to the nearest mapped neighbourhood.
/// 4. **Plus Code** — an 11-character Open Location Code that is unique to the door (≈ 3 m), works
///    without any street, and can be pasted into Google or Apple Maps.
nonisolated enum ZuriAddressService {
    static let searchRadius = 120.0
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ZuriAddress] = [:]

    static func address(for point: GeoPoint) -> ZuriAddress {
        let key = String(format: "%.5f,%.5f", point.latitude, point.longitude)
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let result = compute(point)
        cacheLock.lock()
        if cache.count > 2_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func compute(_ point: GeoPoint) -> ZuriAddress {
        let atlas = DarAtlas.shared
        let p = DarAtlas.local(point)
        var best: (street: DarAtlas.Street, segment: Int, t: Double, distance: Double)?
        for entry in atlas.candidates(near: p, radius: searchRadius) {
            let street = atlas.streets[Int(entry.x)], s = Int(entry.y)
            let a = street.points[s], b = street.points[s + 1], ab = b - a
            let lengthSquared = simd_length_squared(ab)
            let t = lengthSquared > 0 ? min(1, max(0, simd_dot(p - a, ab) / lengthSquared)) : 0
            let distance = simd_distance(p, a + ab * t)
            guard distance <= searchRadius else { continue }
            // Within 2 m, prefer the bigger street (the frontage people use for directions).
            if let current = best {
                let closer = distance < current.distance - 2
                let tie = abs(distance - current.distance) <= 2 && street.rank < current.street.rank
                if !(closer || tie) { continue }
            }
            best = (street, s, t, distance)
        }
        let areas = atlas.areas(containing: point)
        let neighbourhood = atlas.neighbourhood(near: point)
        let full = PlusCode.encode(point)
        let short = PlusCode.short(point)
        guard let best else {
            return ZuriAddress(number: nil, street: nil, metresAlong: nil, setback: nil, neighbourhood: neighbourhood,
                               ward: areas.ward, district: areas.district, code: short, fullCode: full)
        }
        let street = best.street
        let a = street.points[best.segment], b = street.points[best.segment + 1]
        var along = street.distances[best.segment] + simd_distance(a, b) * best.t
        var direction = simd_normalize(b - a + SIMD2(1e-9, 0))
        // Origin at the end nearer the city centre so numbers grow outward.
        if simd_length(street.points.last ?? .zero) < simd_length(street.points.first ?? .zero) {
            along = street.length - along
            direction = -direction
        }
        let projection = a + (b - a) * best.t
        let offset = p - projection
        let isLeft = direction.x * offset.y - direction.y * offset.x > 0
        var number = max(isLeft ? 1 : 2, Int((along / 5).rounded()))
        if isLeft && number % 2 == 0 { number += 1 }
        if !isLeft && number % 2 == 1 { number += 1 }
        return ZuriAddress(number: number, street: street.name, metresAlong: along, setback: best.distance,
                           neighbourhood: neighbourhood, ward: areas.ward, district: areas.district, code: short, fullCode: full)
    }
}
