import SwiftUI

/// A1 — brand moment. Auto-advances after a beat.
struct SplashView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isRevealed: Bool = false

    var body: some View {
        ZStack {
            TwendeColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                Icon3DView(icon: .cityCar, size: 168)
                    .padding(.bottom, 20)
                Text("Zuri")
                    .font(TwendeFont.figtree(40, weight: .bold))
                    .foregroundStyle(TwendeColor.primary)
                    .kerning(-1)
                Spacer()
                VStack(spacing: 4) {
                    Text(L(.splashTagline))
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.ink)
                    Text(L(.splashFooter))
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkTertiary)
                }
                .padding(.bottom, 24)
            }
            .opacity(isRevealed ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { isRevealed = true }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            guard env.settings.onboardingStage == .splash else { return }
            env.settings.onboardingStage = .language
        }
    }
}
