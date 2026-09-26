import SwiftUI

/// A3 — Tanzanian mobile number, +255 fixed, nine national digits.
struct PhoneEntryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var digits: String = ""

    private var isValid: Bool {
        digits.count == 9 && (digits.hasPrefix("6") || digits.hasPrefix("7"))
    }

    var body: some View {
        OnboardingScaffold(
            step: 2,
            title: L(.phoneTitle),
            subtitle: L(.phoneSubtitle),
            backTo: .signIn
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("🇹🇿")
                            .font(.system(size: 22))
                        Text("+255")
                            .font(TwendeFont.counter)
                            .foregroundStyle(TwendeColor.ink)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TwendeColor.inkTertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 56)
                    .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 8))
                    .padding(.trailing, 8)

                    Text(digits.isEmpty ? "7XX XXX XXX" : Format.phone(nationalDigits: digits, includeCode: false))
                        .font(TwendeFont.counter.monospacedDigit())
                        .foregroundStyle(digits.isEmpty ? TwendeColor.inkTertiary : TwendeColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: 56)
                        .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 8))
                        .accessibilityIdentifier("onboarding.phone")
                }
                Text(L(.phoneHint))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)

                // The in-app keypad keeps entry working wherever the system keyboard is unavailable.
                NumberPad(digits: $digits, limit: 9)
                    .padding(.top, 4)
            }
        } footer: {
            Button(L(.sendCode)) {
                Haptics.medium()
                env.settings.pendingPhone = digits
                env.settings.onboardingStage = .otp
            }
            .buttonStyle(.twendePrimary)
            .disabled(!isValid)
        }
        .onAppear { digits = env.settings.pendingPhone }
    }
}
