import SwiftUI

/// Drives A1–A7. The stage is persisted so a cold start resumes at the right step.
struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            TwendeColor.surface.ignoresSafeArea()
            switch env.settings.onboardingStage {
            case .splash:
                SplashView()
                    .transition(.opacity)
            case .language:
                LanguageView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .signIn:
                SignInView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .phone:
                PhoneEntryView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .otp:
                OTPView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .profile:
                ProfileSetupView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .identity:
                IdentityPrimerView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .location:
                LocationPrimerView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .notifications:
                NotificationPrimerView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .done:
                Color.clear
            }
        }
        .animation(.spring(duration: 0.45), value: env.settings.onboardingStage)
    }
}

/// Shared scaffold: back affordance, title, content and a single dominant action. No progress chrome, so content starts right under the back button.
struct OnboardingScaffold<Content: View, Footer: View>: View {
    @Environment(AppEnvironment.self) private var env

    let step: Int
    let title: String
    let subtitle: String
    var backTo: OnboardingStage? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    private let totalSteps = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let backTo {
                HStack {
                    Button {
                        Haptics.tap()
                        env.settings.onboardingStage = backTo
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(TwendeColor.ink)
                            .frame(width: 48, height: 48)
                            .background(TwendeColor.surfaceAlt, in: .circle)
                    }
                    .accessibilityLabel(L(.back))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(TwendeFont.display)
                            .foregroundStyle(TwendeColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(TwendeFont.body)
                            .foregroundStyle(TwendeColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content()
                }
                .padding(.horizontal, 20)
                .padding(.top, backTo == nil ? 24 : 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 4) {
                footer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }
}
