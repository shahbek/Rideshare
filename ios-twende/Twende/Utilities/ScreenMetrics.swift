import UIKit

/// Screen size lookups for layouts that must reserve space for bottom panels.
enum ScreenMetrics {
    static var height: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? 844
    }
}
