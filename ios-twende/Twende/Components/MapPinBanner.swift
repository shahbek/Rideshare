import SwiftUI

/// Square, stroke-free banner. Contrast follows the map style, not the phone's interface theme.
struct MapPinBanner: View {
    let text: String
    var secondaryLabel: String? = nil
    var isDarkMap: Bool = TwendeColor.isDarkMap
    var maxWidth: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(TwendeFont.figtree(13, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
            if let secondaryLabel {
                Text(secondaryLabel)
                    .font(TwendeFont.figtree(11, weight: .medium))
                    .opacity(0.7)
            }
        }
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: MapPin.headSize)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .foregroundStyle(isDarkMap ? TwendeColor.ink : .white)
        .background(isDarkMap ? .white : TwendeColor.ink)
        .accessibilityElement(children: .combine)
    }
}
