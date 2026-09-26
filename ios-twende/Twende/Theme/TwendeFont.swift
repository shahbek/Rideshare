import CoreText
import SwiftUI

/// Type scale set in Figtree, a geometric grotesque in the Airbnb Cereal family. Regular body, semibold
/// labels, bold titles; digits in fares and counters are tabular.
enum TwendeFont {
    private static let regular = "Figtree-Regular"
    private static let medium = "Figtree-Medium"
    private static let semibold = "Figtree-SemiBold"
    private static let bold = "Figtree-Bold"

    static let display = Font.custom(bold, size: 28)
    static let displayLarge = Font.custom(bold, size: 34)
    static let title = Font.custom(bold, size: 22)
    static let headline = Font.custom(semibold, size: 17)
    static let body = Font.custom(regular, size: 16)
    static let bodyMedium = Font.custom(medium, size: 16)
    static let bodySemibold = Font.custom(semibold, size: 16)
    static let caption = Font.custom(regular, size: 14)
    static let captionMedium = Font.custom(medium, size: 14)
    static let label = Font.custom(medium, size: 13)
    static let fare = Font.custom(bold, size: 17).monospacedDigit()
    static let fareLarge = Font.custom(bold, size: 28).monospacedDigit()
    static let fareHero = Font.custom(bold, size: 40).monospacedDigit()
    static let counter = Font.custom(semibold, size: 20).monospacedDigit()
    static let plate = Font.custom(bold, size: 17).monospacedDigit()
    static let plateHero = Font.custom(bold, size: 26).monospacedDigit()
    static let plateSmall = Font.custom(semibold, size: 13).monospacedDigit()

    /// Arbitrary size in one of the four bundled weights.
    static func figtree(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .bold, .heavy, .black: Font.custom(bold, size: size)
        case .semibold: Font.custom(semibold, size: size)
        case .medium: Font.custom(medium, size: size)
        default: Font.custom(regular, size: size)
        }
    }

    /// Registers the bundled Figtree files with CoreText once per launch. Safe to call repeatedly.
    static func registerBundledFonts() {
        let names = ["Figtree-Regular", "Figtree-Medium", "Figtree-SemiBold", "Figtree-Bold"]
        let urls: [URL] = names.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
        }
        guard !urls.isEmpty else {
            print("[TwendeFont] no bundled Figtree files found; falling back to system font")
            return
        }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, done in
            let count = CFArrayGetCount(errors)
            if count > 0 {
                print("[TwendeFont] \(count) font registration issue(s) (already registered is harmless)")
            }
            return true
        }
    }
}
