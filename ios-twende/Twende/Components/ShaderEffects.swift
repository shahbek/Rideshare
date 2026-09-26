import SwiftUI

/// Indeterminate progress: a 4pt bar with a soft band of light sweeping along it.
struct ShimmerBar: View {
    var height: CGFloat = 4

    private let start: Date = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let sweep = (t * 0.55).truncatingRemainder(dividingBy: 1) * 1.6 - 0.3
            GeometryReader { proxy in
                Capsule()
                    .fill(TwendeColor.primaryTint)
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: TwendeColor.primary.opacity(0), location: 0),
                                .init(color: TwendeColor.primary, location: 0.5),
                                .init(color: TwendeColor.primary.opacity(0), location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.44)
                        .offset(x: proxy.size.width * (sweep - 0.22))
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One specular streak that crosses the view when `isActive` flips on. Attached to the primary CTA so a press
/// reads as light catching a surface rather than a colour swap.
struct SheenModifier: ViewModifier {
    let isActive: Bool
    @State private var progress: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    if progress >= 0 && progress <= 1 {
                        LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.28)
                        .rotationEffect(.degrees(20))
                        .offset(x: proxy.size.width * (progress * 1.5 - 0.39))
                        .blendMode(.plusLighter)
                    }
                }
                .allowsHitTesting(false)
                .clipped()
            }
            .onChange(of: isActive) { _, active in
                guard active else { return }
                progress = 0
                withAnimation(.easeOut(duration: 0.55)) { progress = 1 }
            }
    }
}

extension View {
    /// Plays a single light sheen across the view whenever `isActive` becomes true.
    func sheen(isActive: Bool) -> some View {
        modifier(SheenModifier(isActive: isActive))
    }
}
