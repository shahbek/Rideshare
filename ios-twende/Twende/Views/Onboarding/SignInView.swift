import SwiftUI

/// Sign in with Google. A returning passenger's saved account is restored and they skip straight
/// to permissions; a new passenger continues to phone number and profile.
struct SignInView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isRestoring: Bool = false

    private var isBusy: Bool { env.auth.isSigningIn || isRestoring }

    var body: some View {
        OnboardingScaffold(
            step: 2,
            title: L(.signInTitle),
            subtitle: L(.signInSubtitle),
            backTo: .language
        ) {
            VStack(spacing: 20) {
                Icon3DView(icon: .shield, size: 140)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                HStack(alignment: .top, spacing: 12) {
                    Icon3DView(icon: .phone, size: 32)
                    Text(L(.signInPhoneInstead))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if let error = env.auth.errorMessage {
                    Text(error)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
        } footer: {
            Button {
                signIn()
            } label: {
                HStack(spacing: 12) {
                    if isBusy {
                        ProgressView().tint(TwendeColor.ink)
                    } else {
                        Image("logo_google")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                    }
                    Text(L(.signInGoogle))
                        .font(TwendeFont.bodySemibold)
                        .foregroundStyle(TwendeColor.ink)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(TwendeColor.surface, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TwendeColor.ink, lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableCard)
            .disabled(isBusy)
            .accessibilityIdentifier("onboarding.signIn.google")
            Text(L(.signInTerms))
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .animation(.easeOut(duration: 0.2), value: env.auth.errorMessage)
        .task {
            // Already signed in from an earlier launch: carry on without asking again.
            if env.auth.isSignedIn { await continueAfterSignIn() }
        }
    }

    private func signIn() {
        Haptics.medium()
        Task {
            guard await env.auth.signInWithGoogle() else {
                if env.auth.errorMessage != nil { Haptics.error() }
                return
            }
            Haptics.success()
            await continueAfterSignIn()
        }
    }

    private func continueAfterSignIn() async {
        isRestoring = true
        let returning = await env.restoreAccount()
        isRestoring = false
        if returning {
            env.flow.showToast(L(.accountSynced), symbol: "checkmark.circle.fill")
            env.settings.onboardingStage = .location
        } else {
            env.settings.onboardingStage = .phone
        }
    }
}
