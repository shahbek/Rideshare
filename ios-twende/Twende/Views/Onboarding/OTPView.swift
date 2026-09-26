import SwiftUI

/// A4 — six-digit code, auto-submits when complete, 60 s resend timer.
struct OTPView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var code: String = ""
    @State private var secondsUntilResend: Int = 60
    @State private var resendToken: Int = 0
    @State private var isVerifying: Bool = false
    @State private var errorText: String? = nil
    @State private var shakes: CGFloat = 0

    var body: some View {
        OnboardingScaffold(
            step: 3,
            title: L(.otpTitle),
            subtitle: L(.otpSubtitle, Format.phone(nationalDigits: env.settings.pendingPhone)),
            backTo: .phone
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 2) {
                    ForEach(0..<6, id: \.self) { index in
                        OTPFlapSlot(
                            digit: digit(at: index),
                            isActive: index == code.count && !isVerifying,
                            hasError: errorText != nil,
                            // Clearing the code rolls the leaves back to silver left to right.
                            delay: code.isEmpty ? Double(index) * 0.06 : 0
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .modifier(ShakeEffect(travel: shakes))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L(.otpTitle))
                .accessibilityValue(code)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.circle.fill")
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.danger)
                }

                HStack(spacing: 6) {
                    if secondsUntilResend > 0 {
                        Text(L(.otpResendIn, Format.clock(seconds: secondsUntilResend)))
                            .font(TwendeFont.caption)
                            .foregroundStyle(TwendeColor.inkSecondary)
                            .contentTransition(.numericText())
                    } else {
                        Button(L(.otpResend)) {
                            Haptics.tap()
                            secondsUntilResend = 60
                            resendToken += 1
                        }
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.badgeForeground)
                    }
                }
                .frame(minHeight: 44)

                Text(L(.otpDemoHint))
                    .font(TwendeFont.label)
                    .foregroundStyle(TwendeColor.inkTertiary)

                // The in-app keypad keeps entry working wherever the system keyboard is unavailable.
                NumberPad(digits: $code, limit: 6) { verify() }
                    .padding(.top, 4)
                    .disabled(isVerifying)
            }
            .onChange(of: code) { _, _ in errorText = nil }
        } footer: {
            Button {
                verify()
            } label: {
                if isVerifying {
                    ProgressView().tint(.white)
                } else {
                    Text(L(.verify))
                }
            }
            .buttonStyle(.twendePrimary)
            .disabled(code.count < 6 || isVerifying)

            Button(L(.otpChangeNumber)) {
                env.settings.onboardingStage = .phone
            }
            .buttonStyle(.twendeGhost)
        }
        .task(id: resendToken) {
            while secondsUntilResend > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secondsUntilResend = max(secondsUntilResend - 1, 0)
            }
        }
    }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }

    private func verify() {
        guard code.count == 6, !isVerifying else { return }
        isVerifying = true
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            isVerifying = false
            if code == "000000" {
                errorText = L(.otpInvalid)
                Haptics.error()
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                code = ""
                return
            }
            Haptics.success()
            // A returning passenger signing in with the same number skips profile setup.
            let storedPhone = env.store.profile?.phone.filter(\.isNumber) ?? ""
            let isReturningUser = !storedPhone.isEmpty && storedPhone.hasSuffix(env.settings.pendingPhone)
            env.settings.onboardingStage = isReturningUser ? .location : .profile
        }
    }
}

/// One split-flap leaf of the code: blank brushed silver until typed, then it drops onto a gold digit.
/// The slot awaiting the next digit carries the design system's 2pt ink focus edge; nothing sits beneath it.
struct OTPFlapSlot: View {
    let digit: String
    let isActive: Bool
    let hasError: Bool
    let delay: Double

    private static let size = CGSize(width: 48, height: 66)

    private var edgeColor: Color {
        hasError ? TwendeColor.danger : TwendeColor.ink
    }

    var body: some View {
        SplitFlapTile(
            target: digit.first ?? " ",
            size: Self.size,
            startDelay: delay,
            initial: " "
        )
        .padding(3)
        .overlay {
            RoundedRectangle(cornerRadius: Self.size.width * 0.34 + 3)
                .strokeBorder(edgeColor, lineWidth: 2)
                .opacity(isActive || hasError ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: isActive)
        .animation(.easeOut(duration: 0.2), value: hasError)
    }
}

struct ShakeEffect: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(travel * .pi * 6), y: 0))
    }
}
