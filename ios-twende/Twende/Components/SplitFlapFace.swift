import SwiftUI

/// Both halves clip the same full-height glyph, keeping its baseline and proportions exactly aligned.
/// A space renders as an unprinted leaf in plain brushed silver instead of gold.
struct SplitFlapFace: View {
    let character: Character
    let size: CGSize
    let top: Bool
    /// A turning leaf receives less light as it approaches edge-on; stationary halves stay unchanged.
    var lightLoss: Double = 0

    var body: some View {
        let radius = size.width * 0.34
        let halfHeight = size.height / 2
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0,
            bottomLeadingRadius: top ? 0 : radius,
            bottomTrailingRadius: top ? 0 : radius,
            topTrailingRadius: top ? radius : 0
        )
        let isBlank = character == " "
        let base = isBlank
            ? (top ? TwendeColor.silverTop : TwendeColor.silverBottom)
            : (top ? TwendeColor.primary : TwendeColor.primaryPressed)
        ZStack {
            shape.fill(
                base
                    .shadow(.inner(color: TwendeColor.ink.opacity(0.58), radius: 3.5, x: 0.7, y: top ? -2 : 2.5))
                    .shadow(.inner(color: .white.opacity(0.50), radius: 1, x: -0.5, y: top ? 1.2 : -1.2))
            )
            shape.fill(LinearGradient(
                colors: [.white.opacity(top ? 0.24 : 0.10), .clear, TwendeColor.ink.opacity(top ? 0.24 : 0.14)],
                startPoint: .top, endPoint: .bottom
            ))
            if isBlank {
                shape.fill(LinearGradient(
                    colors: [.clear, TwendeColor.silverSheen.opacity(top ? 0.55 : 0.25), .clear],
                    startPoint: UnitPoint(x: 0, y: 0.2), endPoint: UnitPoint(x: 1, y: 0.8)
                ))
            }
            ObjectSurfaceGrain()
            Text(isBlank ? "" : String(character))
                .font(TwendeFont.figtree(size.height * 0.64, weight: .bold).monospacedDigit())
                .foregroundStyle(
                    TwendeColor.primaryOnAccent.shadow(.inner(color: .black.opacity(0.25), radius: 0.8, y: 0.9))
                )
                .frame(width: size.width, height: size.height)
                .offset(y: top ? halfHeight / 2 : -halfHeight / 2)
        }
        .frame(width: size.width, height: halfHeight)
        .overlay(alignment: top ? .bottom : .top) {
            LinearGradient(
                colors: top ? [.clear, TwendeColor.ink.opacity(0.65)] : [TwendeColor.ink.opacity(0.48), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: top ? 5 : 4)
        }
        .overlay {
            shape.inset(by: 0.65).strokeBorder(
                LinearGradient(colors: [.white.opacity(top ? 0.42 : 0.18), .clear, TwendeColor.ink.opacity(0.48)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1
            )
        }
        .overlay { TwendeColor.ink.opacity(lightLoss) }
        .clipShape(shape)
    }
}
