import SwiftUI

extension View {
    /// Soft grey card. No borders anywhere in the app — depth comes from fill and spacing.
    func cardSurface(cornerRadius: CGFloat = 16, fill: Color = TwendeColor.surfaceAlt) -> some View {
        background(fill, in: .rect(cornerRadius: cornerRadius))
    }

    /// White surface with a soft drop shadow, for controls floating over the map.
    func floatingSurface(in shape: some Shape) -> some View {
        background {
            shape
                .fill(TwendeColor.surface)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        }
    }

    /// Sentence-case section heading in grey.
    func sectionLabelStyle() -> some View {
        self
            .font(TwendeFont.figtree(18, weight: .semibold))
            .foregroundStyle(TwendeColor.ink)
    }

    /// Standard white sheet: corners concentric with the device display, grabber.
    func appSheet(detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        self
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(DeviceMetrics.displayCornerRadius)
            .presentationBackground(TwendeColor.surface)
    }
}
