import SwiftUI

/// Settings row for one basemap look: a three-band swatch standing in for ground, built form and the
/// accent the preset warms toward, plus the same checkmark grammar as the language rows.
struct MapStyleRow: View {
    let style: MapStyleOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 16) {
            swatch
            VStack(alignment: .leading, spacing: 2) {
                Text(L(style.titleKey))
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                Text(L(style.subtitleKey))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24))
                .foregroundStyle(isSelected ? TwendeColor.primary : TwendeColor.grabber)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }

    private var swatch: some View {
        VStack(spacing: 0) {
            ForEach(Array(style.swatch.enumerated()), id: \.offset) { _, hex in
                Rectangle().fill(Color(hex: hex))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(isSelected ? TwendeColor.primary : TwendeColor.border, lineWidth: isSelected ? 2 : 1))
    }
}
