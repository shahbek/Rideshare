import SwiftUI

/// Rendered 3D vehicle for a ride tier, sized for list rows and tiles.
struct TierGlyph: View {
    let tier: RideTier
    var width: CGFloat = 64

    var body: some View {
        Icon3DView(icon: tier.icon3D, size: width)
            .frame(width: width, height: width * 0.78)
    }
}
