import SwiftUI

extension Color {
    /// Mixes the colour toward black by `amount` (0…1) for pressed states without a separate palette entry.
    func darkened(_ amount: Double) -> Color {
        guard amount > 0 else { return self }
        return mix(with: .black, by: amount)
    }

    /// Creates a colour from a 24-bit RGB hex literal such as `0xC5AA76`.
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

/// Airbnb-school palette: pure white surfaces, near-black ink, warm neutral greys, one champagne-gold accent.
/// Amber is reserved for warnings, red for SOS only. Ratings are ink, never yellow.
enum TwendeColor {
    static let primary = Color(hex: 0xC5AA76)
    static let primaryPressed = Color(hex: 0xAD905A)
    static let primaryTint = Color(hex: 0xF7F1E5)
    static let primaryHighlight = Color(hex: 0xEAD8AE)
    static let accentText = Color(hex: 0x745523)
    static let primaryOnAccent = Color(hex: 0x222222)

    /// Brushed-gold sheen ramp (sampled from polished champagne metal): deep edge → mid → light band → highlight.
    static let goldDeep = Color(hex: 0xB89261)
    static let goldMid = Color(hex: 0xD3B07E)
    static let goldLight = Color(hex: 0xE6C89E)
    static let goldHighlight = Color(hex: 0xEFD9B4)
    /// Blank split-flap leaves: cool silverfish metal, sampled so the top catches more light than the bottom.
    static let silverTop = Color(hex: 0xD5D9DD)
    static let silverBottom = Color(hex: 0xBCC2C8)
    static let silverSheen = Color(hex: 0xF1F3F5)
    static let badgeTint = primaryTint
    static let badgeForeground = Color(hex: 0x745523)

    static let surface = Color.white
    static let surfaceAlt = Color(hex: 0xF7F7F7)
    static let surfacePressed = Color(hex: 0xEBEBEB)
    static let border = Color(hex: 0xDDDDDD)
    static let grabber = Color(hex: 0xDDDDDD)

    static let ink = Color(hex: 0x222222)
    static let inkSecondary = Color(hex: 0x6A6A6A)
    static let inkTertiary = Color(hex: 0xB0B0B0)

    static let amber = Color(hex: 0xC13515)
    static let amberTint = Color(hex: 0xFFF8F6)
    static let amberText = Color(hex: 0xC13515)
    static let danger = Color(hex: 0xC13515)
    static let dangerTint = Color(hex: 0xFFF8F6)

    /// Marker contrast and the map canvas follow the chosen basemap preset, independently of the
    /// white app panels, which stay light in every map style.
    static var mapLightPreset: String { AppSettings.shared.mapStyle.lightPreset }
    static var isDarkMap: Bool { AppSettings.shared.mapStyle.isDark }
    static var mapCanvas: Color { isDarkMap ? ink : surfaceAlt }
    static let route = Color(hex: 0x222222)

    static let statusOnline = primary
    static let statusBusy = Color(hex: 0xE07A00)
    static let statusOffline = Color(hex: 0xC8C8C8)
}
