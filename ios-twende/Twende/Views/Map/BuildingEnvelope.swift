import Foundation

/// Shared vertical envelope. Never truncate a valid native building to a decorative height cap.
enum BuildingEnvelope {
    static func roof(height: Double?, relatedHeights: [Double] = []) -> Double {
        let valid = ([height ?? 12] + relatedHeights).filter { $0.isFinite && $0 > 0 }
        let native = valid.max() ?? 12
        return native + max(1.5, native * 0.025)
    }
}
