import SwiftUI

/// Full-height state shown after a top-up is sent: "Check your phone", a live expiry countdown, then
/// Approved / failed with a clear next step. Updates itself from the payment coordinator.
struct MobileMoneyWaitingView: View {
    @Environment(AppEnvironment.self) private var env
    let reference: String
    let onDone: () -> Void
    let onRetry: () -> Void
    let onChangeAmount: () -> Void

    private var payment: MobileMoneyPayment? { env.payments.payment(reference) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch payment?.status {
                    case .success:
                        approved
                    case .failed:
                        failed
                    default:
                        waiting
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .animation(.spring(duration: 0.4), value: payment?.status)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .onChange(of: payment?.status) { _, status in
            if status == .failed { Haptics.error() }
        }
    }

    // MARK: States

    @ViewBuilder
    private var waiting: some View {
        if let payment {
            Icon3DView(icon: .phone, size: 96)
                .phaseAnimator([0.0, -4.0]) { view, offset in
                    view.offset(y: offset)
                } animation: { _ in .easeInOut(duration: 1.2) }
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.mmCheckPhoneTitle))
                    .font(TwendeFont.display)
                    .foregroundStyle(TwendeColor.ink)
                Text(L(.mmCheckPhoneBody, Format.tzs(payment.amount), payment.method.displayName))
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PromptCountdown(expiry: payment.expiryDate)
            if !payment.live {
                SimulatedPinPrompt(payment: payment)
            }
        } else {
            ProgressView().tint(TwendeColor.ink)
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    @ViewBuilder
    private var approved: some View {
        if let payment {
            Icon3DView(icon: .coins, size: 104)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.mmApprovedTitle, Format.tzs(payment.amount)))
                    .font(TwendeFont.display)
                    .foregroundStyle(TwendeColor.ink)
                Text(L(.mmApprovedBody, Format.tzs(env.store.walletBalance)))
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .contentTransition(.numericText())
            }
            ReceiptLine(title: L(.topUpFrom), value: payment.method.displayName)
            ReceiptLine(title: L(.mmReference), value: payment.orderReference)
        }
    }

    @ViewBuilder
    private var failed: some View {
        if let payment {
            Icon3DView(icon: .receipt, size: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(MobileMoneyCopy.failureTitle(payment.reason))
                    .font(TwendeFont.display)
                    .foregroundStyle(TwendeColor.ink)
                Text(MobileMoneyCopy.failureBody(payment.reason, method: payment.method))
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ReceiptLine(title: L(.mmReference), value: payment.orderReference)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch payment?.status {
        case .success:
            Button(L(.mmDone)) {
                Haptics.tap()
                onDone()
            }
            .buttonStyle(.twendePrimary)
            .accessibilityIdentifier("wallet.topUp.done")
        case .failed:
            VStack(spacing: 4) {
                Button(L(.tryAgain)) {
                    Haptics.medium()
                    onRetry()
                }
                .buttonStyle(.twendePrimary)
                Button(L(.mmChangeAmount)) { onChangeAmount() }
                    .buttonStyle(.twendeGhost)
            }
        default:
            Text(L(.mmKeepOpen))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
        }
    }
}

/// Two-column receipt line separated by a hairline.
private struct ReceiptLine: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            RowDivider(leading: 0)
            HStack {
                Text(title)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Spacer()
                Text(value)
                    .font(TwendeFont.captionMedium.monospacedDigit())
                    .foregroundStyle(TwendeColor.ink)
            }
            .frame(minHeight: 44)
        }
    }
}

/// "Prompt expires in 0:48" as plain text, ticking every second.
struct PromptCountdown: View {
    let expiry: Date?

    var body: some View {
        if let expiry {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(expiry.timeIntervalSince(context.date)))
                Text(L(.mmExpiresIn, Format.clock(seconds: remaining)))
                    .font(TwendeFont.captionMedium.monospacedDigit())
                    .foregroundStyle(remaining <= 10 ? TwendeColor.amberText : TwendeColor.inkSecondary)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
    }
}

/// Test-mode stand-in for the network's USSD PIN prompt. It mirrors what Mixx / M-Pesa / Airtel show on
/// the handset so the full flow — approve, wrong PIN, cancel, not enough money — can be exercised
/// before ClickPesa keys exist. Hidden automatically for live payments.
struct SimulatedPinPrompt: View {
    @Environment(AppEnvironment.self) private var env
    let payment: MobileMoneyPayment
    @State private var pin: String = ""
    @State private var isSending: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L(.mmTestMode))
                    .font(TwendeFont.label)
                    .foregroundStyle(TwendeColor.accentText)
                    .textCase(.uppercase)
                Text(L(.mmTestModeBody, payment.method.displayName))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The handset dialog itself: dark system-alert styling, not Zuri's design language.
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Text(payment.method.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(L(.mmPromptText, Format.tzs(payment.amount)))
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { index in
                            Text(index < pin.count ? "•" : "")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 40)
                                .background(.white.opacity(0.12), in: .rect(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(index == pin.count ? .white : .clear, lineWidth: 1.5)
                                )
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L(.mmPromptPin))
                }
                .padding(18)
                Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
                HStack(spacing: 0) {
                    Button(L(.mmPromptCancel)) { send("decline") }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 0.5, height: 48)
                    Button(L(.mmPromptSend)) { send("approve") }
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .disabled(pin.count < 4)
                        .opacity(pin.count < 4 ? 0.45 : 1)
                        .accessibilityIdentifier("mm.simulated.send")
                }
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: 0x64A8FF))
            }
            .background(Color(hex: 0x2C2C2E), in: .rect(cornerRadius: 14))
            .disabled(isSending)

            NumberPad(digits: $pin, limit: 4, isFlat: true)

            HStack {
                Text(L(.mmPromptHint))
                    .font(TwendeFont.label)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L(.mmSimulateInsufficient)) { send("insufficient") }
                    .font(TwendeFont.label)
                    .foregroundStyle(TwendeColor.ink)
                    .underline()
                    .frame(minHeight: 44)
            }
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TwendeColor.border, lineWidth: 1))
    }

    private func send(_ action: String) {
        guard !isSending else { return }
        isSending = true
        Haptics.tap()
        Task { @MainActor in
            await env.payments.simulate(reference: payment.orderReference, action: action, pin: action == "approve" ? pin : nil)
            isSending = false
            pin = ""
        }
    }
}
