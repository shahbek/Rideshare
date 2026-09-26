import Foundation

/// A selectable basemap look. Each case maps onto the Mapbox Standard style's own `theme` and
/// `lightPreset` import configuration, so switching never swaps style URIs: the 3D buildings,
/// native POIs, custom landmarks, routes and vehicles all survive the change untouched.
nonisolated enum MapStyleOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case monochromeDay
    case monochromeDusk
    case night
    case dawn
    case colourDay
    case faded

    var id: String { rawValue }

    /// Mapbox Standard `theme` config value.
    var theme: String {
        switch self {
        case .monochromeDay, .monochromeDusk: "monochrome"
        case .night, .dawn, .colourDay: "default"
        case .faded: "faded"
        }
    }

    /// Mapbox Standard `lightPreset` config value.
    var lightPreset: String {
        switch self {
        case .monochromeDay, .colourDay, .faded: "day"
        case .monochromeDusk: "dusk"
        case .night: "night"
        case .dawn: "dawn"
        }
    }

    /// Pins, banners and the map canvas invert on the low-light presets so labels stay legible.
    var isDark: Bool { lightPreset == "night" || lightPreset == "dusk" }

    var titleKey: LKey {
        switch self {
        case .monochromeDay: .mapStyleMonochromeDay
        case .monochromeDusk: .mapStyleMonochromeDusk
        case .night: .mapStyleNight
        case .dawn: .mapStyleDawn
        case .colourDay: .mapStyleColourDay
        case .faded: .mapStyleFaded
        }
    }

    var subtitleKey: LKey {
        switch self {
        case .monochromeDay: .mapStyleMonochromeDayBody
        case .monochromeDusk: .mapStyleMonochromeDuskBody
        case .night: .mapStyleNightBody
        case .dawn: .mapStyleDawnBody
        case .colourDay: .mapStyleColourDayBody
        case .faded: .mapStyleFadedBody
        }
    }

    /// Swatch ramp for the settings preview: ground, built form, then the accent the preset warms toward.
    var swatch: [UInt32] {
        switch self {
        case .monochromeDay: [0xF2F2F0, 0xD8D8D4, 0xB4B4AE]
        case .monochromeDusk: [0x3C3B42, 0x565463, 0x8D7F86]
        case .night: [0x14161C, 0x262A34, 0x4E5570]
        case .dawn: [0x9FA6BC, 0xC9B9AE, 0xE8C79B]
        case .colourDay: [0xEDE7DC, 0xCFE0C6, 0xA8C3E0]
        case .faded: [0xF4F3EF, 0xE4E2DB, 0xCBD3CB]
        }
    }

    static let fallback: MapStyleOption = .monochromeDay
}
