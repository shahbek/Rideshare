import SwiftUI

/// Optional onboarding step after the name: scan an ID or skip.
struct IdentityPrimerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isScanning: Bool = false

    var body: some View {
        OnboardingScaffold(
            step: 5,
            title: L(.idPrimerTitle),
            subtitle: L(.idPrimerSubtitle),
            backTo: .profile
        ) {
            IdentityBenefits()
        } footer: {
            Button(L(.idScanAction)) {
                Haptics.medium()
                isScanning = true
            }
            .buttonStyle(.twendePrimary)
            .accessibilityIdentifier("onboarding.identity.scan")
            Button(L(.idSkip)) {
                env.settings.onboardingStage = .location
            }
            .buttonStyle(.twendeGhost)
            .accessibilityIdentifier("onboarding.identity.skip")
        }
        .fullScreenCover(isPresented: $isScanning) {
            IDScanFlow { verified in
                isScanning = false
                if verified { env.settings.onboardingStage = .location }
            }
        }
    }
}

/// The three plain promises shown before scanning: any ID, stays on the phone, drivers see only a badge.
private struct IdentityBenefits: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Icon3DView(icon: .shield, size: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
            ForEach(Array([L(.idPrimerBullet1), L(.idPrimerBullet2), L(.idPrimerBullet3)].enumerated()), id: \.offset) { index, text in
                if index > 0 { RowDivider(leading: 0) }
                Text(text)
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }
        }
    }
}

/// Account → Verify with ID: status when verified, otherwise the same promises and a scan button.
struct IdentityVerificationView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isScanning: Bool = false
    @State private var isConfirmingRemoval: Bool = false

    var body: some View {
        MenuScreen(title: env.store.isIdentityVerified ? L(.idVerified) : L(.idVerify)) {
            if let record = env.store.identity {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16) {
                        ProfileAvatar(size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.fullName.localizedCapitalized)
                                .font(TwendeFont.title)
                                .foregroundStyle(TwendeColor.ink)
                            VerifiedBadge()
                        }
                    }
                    .padding(.bottom, 16)
                    detail(L(.idDocumentType), IdentityCopy.kindName(record.kind))
                    detail(L(.idDocumentNumber), masked(record.documentNumber))
                    if !record.nationality.isEmpty { detail(L(.idNationality), record.nationality) }
                    if let birth = record.dateOfBirth { detail(L(.idDateOfBirth), Format.date(birth)) }
                    if let expiry = record.expiryDate { detail(L(.idExpiry), Format.date(expiry)) }
                    RowDivider(leading: 0)
                    Text(L(.idStatusBody, Format.date(record.verifiedAt), IdentityCopy.kindName(record.kind)))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .padding(.vertical, 12)
                }
                Button(L(.idRescan)) { isScanning = true }
                    .buttonStyle(.twendeSecondary)
                Button(L(.idRemove)) { isConfirmingRemoval = true }
                    .buttonStyle(.twendeGhost)
            } else {
                IdentityBenefits()
                Button(L(.idScanAction)) {
                    Haptics.medium()
                    isScanning = true
                }
                .buttonStyle(.twendePrimary)
                .accessibilityIdentifier("account.identity.scan")
            }
        }
        .fullScreenCover(isPresented: $isScanning) {
            IDScanFlow { _ in isScanning = false }
        }
        .confirmationDialog(L(.idRemove), isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button(L(.idRemove), role: .destructive) { env.store.removeIdentity() }
            Button(L(.cancel), role: .cancel) {}
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            RowDivider(leading: 0)
            HStack {
                Text(title).font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
                Spacer()
                Text(value).font(TwendeFont.bodyMedium.monospacedDigit()).foregroundStyle(TwendeColor.ink)
            }
            .frame(minHeight: 52)
        }
    }

    /// Only the last four characters are shown after saving.
    private func masked(_ number: String) -> String {
        guard number.count > 4 else { return number }
        return String(repeating: "•", count: min(8, number.count - 4)) + number.suffix(4)
    }
}

/// Ink seal + "ID verified", used next to the name on Account and Profile.
struct VerifiedBadge: View {
    var body: some View {
        Label(L(.idVerified), systemImage: "checkmark.seal.fill")
            .font(TwendeFont.captionMedium)
            .foregroundStyle(TwendeColor.ink)
            .labelStyle(.titleAndIcon)
            .accessibilityIdentifier("profile.verified")
    }
}

/// Card photo when the passenger kept it, otherwise ink initials.
struct ProfileAvatar: View {
    @Environment(AppEnvironment.self) private var env
    var size: CGFloat = 60

    var body: some View {
        let photo = env.store.identity?.usesCardPhoto == true ? ProfilePhotoStore.load() : nil
        Group {
            if let photo {
                Color(TwendeColor.surfaceAlt)
                    .overlay {
                        Image(uiImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
            } else {
                Text(Format.initials(env.store.profile?.name ?? "Z"))
                    .font(TwendeFont.figtree(size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TwendeColor.ink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
