import SwiftUI

/// Expanding green rings used around the pickup while matching a driver.
struct PulseView: View {
    var color: Color = TwendeColor.primary
    var size: CGFloat = 120

    @State private var isAnimating: Bool = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(isAnimating ? 2.0 : 0.5)
                    .opacity(isAnimating ? 0 : 0.9)
                    .animation(
                        .easeOut(duration: 2.2)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.7),
                        value: isAnimating
                    )
            }
        }
        .frame(width: size * 2, height: size * 2)
        .onAppear { isAnimating = true }
        .accessibilityHidden(true)
    }
}

/// Thin green bar sliding back and forth while the app waits on something.
struct IndeterminateBar: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(TwendeColor.primaryTint)
                Capsule()
                    .fill(TwendeColor.primary)
                    .frame(width: proxy.size.width * 0.35)
                    .offset(x: phase * proxy.size.width * 0.65)
            }
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }
}

/// White alert card shown when connectivity drops (G1).
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TwendeColor.amberText)
                .frame(width: 34, height: 34)
                .background(TwendeColor.amberTint, in: .circle)
            Text(L(.offlineBanner))
                .font(TwendeFont.captionMedium)
                .foregroundStyle(TwendeColor.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(TwendeColor.surface)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }
}
