import SwiftUI

/// Stamped yellow enamel: rolled lip, recessed field, fine reflective grain and raised ink characters.
/// All lighting stays inside the plate; no mounting hardware or external shadows.
struct PlateView: View {
    enum Size {
        case small
        case regular
        case hero
    }

    let plate: String
    var size: Size = .regular

    private static let enamel = Color(hex: 0xFFE24D)

    var body: some View {
        // Embossed characters: light catches the top edge, a soft shadow falls below the raised ink.
        ZStack {
            registration
                .foregroundStyle(TwendeColor.ink.opacity(0.28))
                .blur(radius: 0.6)
                .offset(y: size == .hero ? 1.4 : 0.9)
            registration
                .foregroundStyle(.white.opacity(0.65))
                .offset(y: size == .hero ? -0.8 : -0.5)
            registration
                .foregroundStyle(TwendeColor.ink)
        }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background { enamelSurface }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(L(.plateNumber)) \(Format.plate(plate))"))
    }

    private var registration: some View {
        Text(Format.plate(plate))
            .font(font)
            .kerning(kerning)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var enamelSurface: some View {
        let rim = RoundedRectangle(cornerRadius: cornerRadius)
        let field = RoundedRectangle(cornerRadius: max(2, cornerRadius - 2))
        let rimWidth: CGFloat = size == .hero ? 2 : 1.25
        let beadWidth: CGFloat = size == .hero ? 1.2 : 0.8
        return ZStack {
            // Flat matte enamel, lit from above: marginally brighter at the top, warmer at the bottom.
            rim.fill(
                LinearGradient(stops: [
                    .init(color: Self.enamel.mix(with: .white, by: 0.14), location: 0),
                    .init(color: Self.enamel, location: 0.45),
                    .init(color: Self.enamel.mix(with: TwendeColor.ink, by: 0.10), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            // Soft sheen across the upper third only — enamel is satin, not chrome.
            rim.fill(
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.20), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.35),
                    .init(color: .clear, location: 0.6)
                ], startPoint: .top, endPoint: .bottom)
            )
            ObjectSurfaceGrain().clipShape(rim)
            // Raised border bead: light on its upper edge, shadow on its lower edge.
            field.strokeBorder(.white.opacity(0.55), lineWidth: beadWidth)
                .offset(y: -beadWidth * 0.6)
                .clipShape(rim)
            field.strokeBorder(TwendeColor.ink.opacity(0.30), lineWidth: beadWidth)
                .offset(y: beadWidth * 0.6)
                .clipShape(rim)
            field.strokeBorder(Self.enamel, lineWidth: beadWidth * 0.5)
            // Rolled outer rim: bright top lip, darker underside.
            rim.strokeBorder(
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.75), location: 0),
                    .init(color: Self.enamel.mix(with: TwendeColor.ink, by: 0.18), location: 0.55),
                    .init(color: TwendeColor.ink.opacity(0.55), location: 1)
                ], startPoint: .top, endPoint: .bottom),
                lineWidth: rimWidth
            )
        }
        .allowsHitTesting(false)
    }

    private var font: Font {
        switch size {
        case .small: TwendeFont.plateSmall
        case .regular: TwendeFont.plate
        case .hero: TwendeFont.plateHero
        }
    }

    private var kerning: CGFloat {
        switch size {
        case .small: 0.6
        case .regular: 1
        case .hero: 1.6
        }
    }

    private var cornerRadius: CGFloat {
        size == .hero ? 6 : 4
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: 10
        case .regular: 12
        case .hero: 16
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .small: 5
        case .regular: 7
        case .hero: 10
        }
    }
}
