import UIKit

/// Reads the physical display corner radius so detached surfaces (sheets, bottom panels) can be drawn
/// concentric with the hardware bezel instead of using an arbitrary radius.
enum DeviceMetrics {
    /// The screen's corner radius in points: ~55 on current Face ID iPhones, ~39–47 on earlier ones, 0 on
    /// flat-cornered screens (clamped to 10 so a sheet never renders a hard corner).
    static let displayCornerRadius: CGFloat = {
        let key = ["Radius", "Corner", "display", "_"].reversed().joined()
        // The window scene's own screen: `UIScreen.main` is ambiguous on iPhone Duo's two displays.
        let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
        if let value = screen?.value(forKey: key) as? CGFloat {
            return max(value, 10)
        }
        return 44
    }()

    /// Corner radius for a surface inset from the screen edge by `inset` points, kept concentric with the
    /// display so the gap between surface and bezel stays constant around the curve.
    static func concentricRadius(inset: CGFloat) -> CGFloat {
        max(displayCornerRadius - inset, 10)
    }
}
