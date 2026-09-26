import XCTest
@testable import Twende

@MainActor
final class MapStyleSelectionTests: XCTestCase {
    private func makeSettings() throws -> AppSettings {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "twende.tests.mapStyle.\(UUID().uuidString)"))
        return AppSettings(defaults: suite)
    }

    func testEveryStyleIsADistinctStandardConfigurationNotAStyleSwap() {
        XCTAssertEqual(MapStyleOption.allCases.count, 6)
        var seen: Set<String> = []
        for style in MapStyleOption.allCases {
            XCTAssertTrue(seen.insert("\(style.theme)|\(style.lightPreset)").inserted, "\(style.rawValue) duplicates another look")
            XCTAssertTrue(["monochrome", "default", "faded"].contains(style.theme), style.rawValue)
            XCTAssertTrue(["day", "dusk", "night", "dawn"].contains(style.lightPreset), style.rawValue)
            XCTAssertEqual(style.swatch.count, 3, style.rawValue)
            XCTAssertNotEqual(L(style.titleKey), L(style.subtitleKey))
            for language in AppLanguage.allCases {
                XCTAssertFalse(Strings.text(for: style.titleKey, language: language).isEmpty)
                XCTAssertFalse(Strings.text(for: style.subtitleKey, language: language).isEmpty)
            }
        }
    }

    func testStyleOnlyChangesLightingAndKeepsBuildingsPoisAndSelectionColours() {
        let baseline = TripMapView.Coordinator.standardConfig(for: .monochromeDay)
        for style in MapStyleOption.allCases {
            let config = TripMapView.Coordinator.standardConfig(for: style)
            XCTAssertEqual(config["theme"] as? String, style.theme)
            XCTAssertEqual(config["lightPreset"] as? String, style.lightPreset)
            for (key, value) in baseline where key != "theme" && key != "lightPreset" {
                XCTAssertEqual(String(describing: config[key] ?? "nil"), String(describing: value), "\(style.rawValue) changed \(key)")
            }
            XCTAssertEqual(config["show3dObjects"] as? Bool, true, style.rawValue)
            XCTAssertEqual(config["showPointOfInterestLabels"] as? Bool, true, style.rawValue)
            XCTAssertEqual(config["densityPointOfInterestLabels"] as? Int, 5, style.rawValue)
            XCTAssertEqual(config["showLandmarkIcons"] as? Bool, true, style.rawValue)
            XCTAssertEqual(config["colorBuildingSelect"] as? String, "#D3B07E", style.rawValue)
        }
    }

    func testDarkPresetsInvertMarkerContrastAndCanvas() {
        for style in MapStyleOption.allCases {
            XCTAssertEqual(style.isDark, style.lightPreset == "night" || style.lightPreset == "dusk", style.rawValue)
        }
        XCTAssertTrue(MapStyleOption.night.isDark)
        XCTAssertTrue(MapStyleOption.monochromeDusk.isDark)
        XCTAssertFalse(MapStyleOption.dawn.isDark)
        XCTAssertFalse(MapStyleOption.colourDay.isDark)
        // Marker contrast reads the live selection, so the banner flips with the chosen style.
        let original = AppSettings.shared.mapStyle
        defer { AppSettings.shared.mapStyle = original }
        AppSettings.shared.mapStyle = .night
        XCTAssertTrue(TwendeColor.isDarkMap)
        XCTAssertEqual(TwendeColor.mapLightPreset, "night")
        XCTAssertEqual(TwendeColor.mapCanvas, TwendeColor.ink)
        AppSettings.shared.mapStyle = .monochromeDay
        XCTAssertFalse(TwendeColor.isDarkMap)
        XCTAssertEqual(TwendeColor.mapCanvas, TwendeColor.surfaceAlt)
    }

    func testSelectionPersistsAndDefaultsToApprovedMonochromeDay() throws {
        let settings = try makeSettings()
        XCTAssertEqual(settings.mapStyle, .monochromeDay)
        settings.mapStyle = .dawn
        XCTAssertEqual(settings.mapStyle, .dawn)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "twende.tests.mapStyle.reload"))
        defaults.removePersistentDomain(forName: "twende.tests.mapStyle.reload")
        let first = AppSettings(defaults: defaults)
        first.mapStyle = .night
        XCTAssertEqual(AppSettings(defaults: defaults).mapStyle, .night, "Cold start must reopen in the chosen light")
        defaults.set("mapbox-satellite", forKey: "twende.settings.mapStyle")
        XCTAssertEqual(AppSettings(defaults: defaults).mapStyle, .monochromeDay, "Unknown stored values fall back")
        defaults.removePersistentDomain(forName: "twende.tests.mapStyle.reload")
    }
}
