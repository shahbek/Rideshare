import Foundation

/// Open Location Code ("Plus Code") encoder: the open, offline, worldwide grid that Google Maps,
/// Apple Maps search and Tanzania's own address pilots accept. 11 characters ≈ 3 × 3.5 m, so each
/// household door gets its own code even where streets have no name.
nonisolated enum PlusCode {
    private static let alphabet = Array("23456789CFGHJMPQRVWX")

    /// Full 11-character code, e.g. `6RX7QQ3R+7FX`.
    static func encode(_ point: GeoPoint) -> String {
        let lat = min(max(point.latitude, -90), 90 - 1e-10) + 90
        var lng = point.longitude.truncatingRemainder(dividingBy: 360)
        if lng < -180 { lng += 360 } else if lng >= 180 { lng -= 360 }
        lng += 180
        // Integer grid at the 11th-digit resolution: 1/40000° latitude, 1/32000° longitude.
        var latI = Int(floor(lat * 40_000))
        var lngI = Int(floor(lng * 32_000))
        let grid = alphabet[(latI % 5) * 4 + (lngI % 4)]
        latI /= 5; lngI /= 4
        var pairs: [Character] = []
        for _ in 0..<5 {
            pairs.insert(alphabet[lngI % 20], at: 0)
            pairs.insert(alphabet[latI % 20], at: 0)
            latI /= 20; lngI /= 20
        }
        var code = String(pairs)
        code.insert("+", at: code.index(code.startIndex, offsetBy: 8))
        return code + String(grid)
    }

    /// Locality-relative short code (`QQ3R+7FX`) when the point is close enough to `reference`
    /// for the standard 4-digit recovery (within 0.3°; a 0.25° safety margin is used).
    static func short(_ point: GeoPoint, reference: GeoPoint = DarEsSalaam.centre) -> String {
        let full = encode(point)
        guard abs(point.latitude - reference.latitude) < 0.25, abs(point.longitude - reference.longitude) < 0.25 else { return full }
        return String(full.dropFirst(4))
    }
}
