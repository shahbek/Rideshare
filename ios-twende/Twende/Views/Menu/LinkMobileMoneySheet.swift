import SwiftUI

/// C4a — link a wallet only after proving ownership: type the number, Zuri identifies the network
/// (M-Pesa, Mixx, Airtel, HaloPesa), texts a 6-digit code, and the number links once the code matches.
struct LinkMobileMoneySheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable { case number, code }

    @State private var method: PaymentMethod
    @State private var digits: String = ""
    @State private var stage: Stage = .number
    @State private var detected: PaymentMethod? = nil
    @State private var accountName: String? = nil
    @State private var isLookingUp: Bool = false
    @State private var isSending: Bool = false
    @State private var isVerifying: Bool = false
    @State private var errorText: String? = nil
    @State private var challenge: PaymentGateway.OTPChallenge? = nil
    @State private var code: String = ""
    @State private var secondsUntilResend: Int = 0
    @State private var shakes: CGFloat = 0

    private let gateway = PaymentGateway()

    init(method: PaymentMethod) {
        _method = State(initialValue: method)
    }

    private var existing: MobileMoneyAccount? { env.store.account(for: method) }
    private var isMismatch: Bool { detected != nil && detected != method }
    private var canSend: Bool { digits.count == 9 && !isMismatch && !isSending && !isLookingUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Group {
                switch stage {
                case .number: numberStage.transition(.opacity.combined(with: .move(edge: .leading)))
                case .code: codeStage.transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(.spring(duration: 0.35), value: stage)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .onAppear(perform: prefill)
        .task(id: digits) { await lookup() }
        .task(id: challenge?.verificationId) { await runResendTimer() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            MobileMoneyLogo(method: method, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage == .code ? L(.walletEnterCode) : (existing == nil ? L(.linkWallet, method.displayName) : L(.changeNumberTitle, method.displayName)))
                    .font(TwendeFont.title)
                    .foregroundStyle(TwendeColor.ink)
                if stage == .number, let existing {
                    Text(L(.currentNumber, Format.phone(existing.phone)))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                } else if stage == .code {
                    Text(L(.walletCodeSentTo, Format.phone(nationalDigits: digits)))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
            }
        }
    }

    // MARK: Number

    private var numberStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            TwendeTextField(
                title: L(.walletNumber),
                text: $digits,
                placeholder: "7XX XXX XXX",
                keyboard: .numberPad,
                contentType: .telephoneNumber,
                prefix: "+255",
                autoFocus: true
            )
            .onChange(of: digits) { _, newValue in
                let cleaned = String(newValue.filter(\.isNumber).drop(while: { $0 == "0" }).prefix(9))
                if cleaned != newValue { digits = cleaned }
                errorText = nil
            }

            networkLine
                .frame(minHeight: 24, alignment: .leading)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L(.walletOwnershipNote))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: sendCode) {
                HStack(spacing: 10) {
                    if isSending { ProgressView().tint(.white) }
                    Text(L(.walletSendCode))
                }
            }
            .buttonStyle(.twendePrimary)
            .disabled(!canSend)
            .accessibilityIdentifier("wallet.link.sendCode")

            if existing != nil {
                Button(role: .destructive) {
                    Haptics.medium()
                    env.store.unlinkMobileMoney(method)
                    dismiss()
                } label: {
                    Text(L(.unlinkWallet))
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.danger)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("wallet.unlink")
            }
        }
    }

    /// Live network read-out: local prefix guess instantly, confirmed by the server a beat later.
    @ViewBuilder
    private var networkLine: some View {
        if digits.count >= 2 {
            if let detected, detected != method {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(.walletWrongNetwork, detected.displayName, method.displayName))
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.amberText)
                    Button {
                        Haptics.selection()
                        method = detected
                    } label: {
                        HStack(spacing: 8) {
                            MobileMoneyLogo(method: detected, size: 24)
                            Text(L(.walletSwitchTo, detected.displayName))
                                .font(TwendeFont.captionMedium)
                                .foregroundStyle(TwendeColor.ink)
                                .underline()
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("wallet.link.switchNetwork")
                }
            } else if let detected {
                HStack(spacing: 8) {
                    MobileMoneyLogo(method: detected, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L(.walletDetectedAs, detected.displayName))
                            .font(TwendeFont.captionMedium)
                            .foregroundStyle(TwendeColor.ink)
                        if let accountName {
                            Text(L(.walletDetectedName, accountName))
                                .font(TwendeFont.label)
                                .foregroundStyle(TwendeColor.inkSecondary)
                        }
                    }
                    if isLookingUp { ProgressView().controlSize(.mini) }
                }
                .transition(.opacity)
            } else if digits.count >= 2 {
                Text(L(.walletUnknownNetwork))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
        }
    }

    // MARK: Code

    private var codeStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { index in
                    OTPFlapSlot(
                        digit: digit(at: index),
                        isActive: index == code.count && !isVerifying,
                        hasError: errorText != nil,
                        delay: code.isEmpty ? Double(index) * 0.06 : 0
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(ShakeEffect(travel: shakes))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L(.walletEnterCode))
            .accessibilityValue(code)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let test = challenge?.testCode {
                Text(L(.walletTestCode, test))
                    .font(TwendeFont.label)
                    .foregroundStyle(TwendeColor.inkTertiary)
            }

            HStack {
                Button(L(.walletEditNumber)) {
                    Haptics.tap()
                    code = ""
                    errorText = nil
                    stage = .number
                }
                .font(TwendeFont.captionMedium)
                .foregroundStyle(TwendeColor.ink)
                .frame(minHeight: 44)
                Spacer()
                if secondsUntilResend > 0 {
                    Text(L(.walletResendIn, Format.clock(seconds: secondsUntilResend)))
                        .font(TwendeFont.caption.monospacedDigit())
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .contentTransition(.numericText())
                } else {
                    Button(L(.walletResendCode), action: sendCode)
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.ink)
                        .underline()
                        .frame(minHeight: 44)
                        .disabled(isSending)
                }
            }

            Spacer(minLength: 0)

            NumberPad(digits: $code, limit: 6, isFlat: true, isCompressible: true) { verifyCode() }
                .layoutPriority(-1)
                .disabled(isVerifying)
                .onChange(of: code) { _, newValue in
                    errorText = nil
                    if newValue.count == 6 { verifyCode() }
                }

            Button(action: verifyCode) {
                HStack(spacing: 10) {
                    if isVerifying { ProgressView().tint(.white) }
                    Text(L(.verify))
                }
            }
            .buttonStyle(.twendePrimary)
            .disabled(code.count < 6 || isVerifying)
            .accessibilityIdentifier("wallet.link.verify")
        }
    }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }

    // MARK: Actions

    private func prefill() {
        let source = existing?.phone ?? env.store.profile?.phone ?? ""
        var national = source.filter(\.isNumber)
        if national.hasPrefix("255") { national.removeFirst(3) }
        if national.hasPrefix("0") { national.removeFirst() }
        digits = String(national.prefix(9))
    }

    /// Instant prefix guess, then the server's answer (which also catches ported numbers).
    private func lookup() async {
        accountName = nil
        detected = PaymentMethod.guessNetwork(nationalDigits: digits)
        guard digits.count == 9 else { return }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        isLookingUp = true
        defer { isLookingUp = false }
        guard let result = try? await gateway.lookupWallet(phone: "255" + digits), !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            detected = PaymentMethod.mobileMoney(network: result.network) ?? detected
            accountName = result.accountName
        }
    }

    private func sendCode() {
        guard digits.count == 9, !isSending else { return }
        isSending = true
        errorText = nil
        Task { @MainActor in
            defer { isSending = false }
            do {
                let sent = try await gateway.sendWalletCode(phone: "255" + digits, method: method)
                Haptics.success()
                challenge = sent
                accountName = sent.accountName ?? accountName
                code = ""
                secondsUntilResend = sent.resendAfter
                stage = .code
            } catch {
                errorText = MobileMoneyCopy.startFailure(error)
                Haptics.error()
            }
        }
    }

    private func verifyCode() {
        guard let challenge, code.count == 6, !isVerifying else { return }
        isVerifying = true
        Task { @MainActor in
            defer { isVerifying = false }
            do {
                let result = try await gateway.verifyWalletCode(verificationId: challenge.verificationId, code: code)
                guard result.verified else { throw PaymentGatewayError.server }
                Haptics.success()
                env.store.linkMobileMoney(method, phone: "+255" + digits, accountName: result.accountName ?? accountName)
                dismiss()
            } catch {
                errorText = MobileMoneyCopy.startFailure(error)
                Haptics.error()
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                code = ""
            }
        }
    }

    private func runResendTimer() async {
        while secondsUntilResend > 0 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            secondsUntilResend = max(secondsUntilResend - 1, 0)
        }
    }
}
