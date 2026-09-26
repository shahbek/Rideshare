import SwiftUI

/// Circular icon button. Floating (white + shadow) over the map, or grey-filled inside white screens.
struct MapCircleButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var tint: Color = TwendeColor.ink
    var isFloating: Bool = true
    var size: CGFloat = 48
    var usesLiquidGlass: Bool = false
    /// Optional 3D render shown instead of the line symbol (e.g. the SOS beacon).
    var icon3D: Icon3D? = nil
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            face
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel(accessibilityLabel)
    }

    private var icon: some View {
        Group {
            if let icon3D {
                Icon3DView(icon: icon3D, size: size * 0.72)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }

    @ViewBuilder
    private var face: some View {
        if usesLiquidGlass {
            if #available(iOS 26.0, *) {
                icon.glassEffect(.regular.interactive(), in: .circle)
            } else {
                icon.background(.ultraThinMaterial, in: .circle)
            }
        } else {
            icon.background {
                if isFloating {
                    Circle()
                        .fill(TwendeColor.surface)
                        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                } else {
                    Circle().fill(TwendeColor.surfaceAlt)
                }
            }
        }
    }
}

/// White capsule opening "My drivers": rendered star icon plus the online count. No portraits.
struct FavouritesCapsule: View {
    let drivers: [Driver]
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                Icon3DView(icon: .favourite, size: 26)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TwendeColor.ink)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: 44)
            .background {
                Capsule()
                    .fill(TwendeColor.surface)
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            }
        }
        .buttonStyle(.pressableCard)
    }
}

/// Small floating pill used for map-level hints such as the demo pickup notice.
struct MapHintPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(TwendeFont.label)
        }
        .foregroundStyle(TwendeColor.inkSecondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background {
            Capsule()
                .fill(TwendeColor.surface)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
    }
}
