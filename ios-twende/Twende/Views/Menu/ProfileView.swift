import SwiftUI

/// C1a — edit name and email; phone is the account identifier and read-only.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var didSave: Bool = false

    private var hasChanges: Bool {
        name != env.store.profile?.name || email != env.store.profile?.email
    }

    var body: some View {
        MenuScreen(title: L(.profile)) {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    ProfileAvatar(size: 96)
                    if env.store.isIdentityVerified {
                        VerifiedBadge()
                    }
                }
                .frame(maxWidth: .infinity)

                TwendeTextField(title: L(.fullName), text: $name, placeholder: L(.fullNamePlaceholder), contentType: .name)
                TwendeTextField(
                    title: L(.emailOptional),
                    text: $email,
                    placeholder: "jina@mfano.co.tz",
                    keyboard: .emailAddress,
                    contentType: .emailAddress,
                    autocapitalization: .never
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(L(.phoneLabel)).sectionLabelStyle()
                    HStack {
                        Text(Format.phone(env.store.profile?.phone ?? ""))
                            .font(TwendeFont.body)
                            .foregroundStyle(TwendeColor.inkSecondary)
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(TwendeColor.inkTertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 12))
                    Text(L(.phoneLockedHint))
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }

                if let joined = env.store.profile?.joinedAt {
                    HStack {
                        Label(L(.memberSince, Format.date(joined)), systemImage: "calendar")
                            .font(TwendeFont.caption)
                            .foregroundStyle(TwendeColor.inkSecondary)
                        Spacer()
                    }
                }

                Button(didSave ? L(.saved) : L(.saveChanges)) {
                    Haptics.success()
                    env.store.updateProfile(name: name.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces))
                    didSave = true
                }
                .buttonStyle(.twendePrimary)
                .disabled(!hasChanges || name.trimmingCharacters(in: .whitespaces).count < 2)
            }
        }
        .onAppear {
            name = env.store.profile?.name ?? ""
            email = env.store.profile?.email ?? ""
        }
        .onChange(of: name) { _, _ in didSave = false }
        .onChange(of: email) { _, _ in didSave = false }
    }
}
