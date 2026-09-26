import SwiftUI

/// A5 — name required, email optional.
struct ProfileSetupView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var name: String = ""
    @State private var email: String = ""

    private var isValid: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2
    }

    var body: some View {
        OnboardingScaffold(
            step: 4,
            title: L(.profileTitle),
            subtitle: L(.profileSubtitle),
            backTo: .otp
        ) {
            VStack(spacing: 20) {
                TwendeTextField(
                    title: L(.fullName),
                    text: $name,
                    placeholder: L(.fullNamePlaceholder),
                    contentType: .name
                )
                TwendeTextField(
                    title: L(.emailOptional),
                    text: $email,
                    placeholder: "jina@mfano.co.tz",
                    keyboard: .emailAddress,
                    contentType: .emailAddress,
                    autocapitalization: .never
                )
                Text(L(.profilePrivacy))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Button(L(.continueAction)) {
                Haptics.medium()
                if env.store.profile != nil {
                    env.store.deleteAccount()
                }
                env.store.createProfile(
                    name: name.trimmingCharacters(in: .whitespaces),
                    phone: "+255" + env.settings.pendingPhone,
                    email: email.trimmingCharacters(in: .whitespaces)
                )
                env.backupNow()
                env.settings.onboardingStage = .identity
            }
            .buttonStyle(.twendePrimary)
            .disabled(!isValid)
        }
        .onAppear {
            // Prefill from the Google account; the passenger can still edit both.
            if name.isEmpty { name = env.auth.user?.name ?? "" }
            if email.isEmpty { email = env.auth.user?.email ?? "" }
        }
    }
}
