import SwiftUI

/// Top-up: pick the wallet on a large card, type the amount on a flat keypad, one gold button. After
/// the tap the sheet becomes the PIN-prompt waiting state until the payment server answers.
struct WalletTopUpSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var digits: String = ""
    @State private var source: PaymentMethod? = nil
    @State private var linkingWithOtherNumber: PaymentMethod? = nil
    @State private var isStarting: Bool = false
    @State private var startError: String? = nil
    @State private var activeReference: String? = nil

    private let rails: [PaymentMethod] = [.mixx, .mpesa, .airtel, .halopesa]

    private var amount: Int { Int(digits) ?? 0 }
    private var isSourceLinked: Bool { source.map { env.store.account(for: $0)?.isVerified == true } ?? false }

    private var validationText: String? {
        guard amount > 0 else { return nil }
        if amount < WalletRules.minimumTopUp { return L(.topUpMinimum, Format.tzs(WalletRules.minimumTopUp)) }
        if amount > env.store.walletTopUpHeadroom { return L(.topUpMaximum, Format.tzs(env.store.walletTopUpHeadroom)) }
        return nil
    }

    private var canConfirm: Bool {
        isSourceLinked && amount >= WalletRules.minimumTopUp && amount <= env.store.walletTopUpHeadroom && !isStarting
    }

    private var buttonTitle: String {
        guard let source else { return L(.topUpChooseWallet) }
        guard amount > 0 else { return L(.topUpEnterAmount) }
        return L(.topUpAddFrom, Format.tzs(amount), source.displayName)
    }

    var body: some View {
        Group {
            if let activeReference {
                MobileMoneyWaitingView(
                    reference: activeReference,
                    onDone: { dismiss() },
                    onRetry: { retry() },
                    onChangeAmount: { self.activeReference = nil }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                composer
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.spring(duration: 0.4), value: activeReference)
        .onAppear {
            if source == nil {
                source = rails.first { env.store.account(for: $0) != nil } ?? env.store.autoTopUp.method ?? .mixx
            }
        }
        .sheet(item: $linkingWithOtherNumber) { rail in
            LinkMobileMoneySheet(method: rail)
                .appSheet(detents: [.large])
        }
    }

    // MARK: Composer

    /// Fixed, non-scrolling layout: equal wallet tiles, one status line, the amount, a keypad that
    /// compresses to fit, and the gold button. Everything stays on one screen.
    private var composer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L(.topUpWallet))
                    .font(TwendeFont.display)
                    .foregroundStyle(TwendeColor.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                HStack(spacing: 8) {
                    ForEach(rails) { rail in
                        WalletRailTile(
                            method: rail,
                            isLinked: env.store.account(for: rail) != nil,
                            isSelected: source == rail
                        ) {
                            Haptics.selection()
                            source = rail
                        }
                    }
                }

                if let source {
                    WalletSourceStatus(
                        method: source,
                        account: env.store.account(for: source),
                        onLink: {
                            Haptics.tap()
                            linkingWithOtherNumber = source
                        }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Spacer(minLength: 8)
            amountDisplay
                .padding(.horizontal, 20)
            Spacer(minLength: 8)

            NumberPad(digits: $digits, limit: WalletRules.amountDigitLimit, isFlat: true, allowsLeadingZero: false, isCompressible: true)
                .padding(.horizontal, 20)
                .layoutPriority(-1)
                .onChange(of: digits) { _, _ in startError = nil }

            VStack(spacing: 8) {
                if let startError {
                    Text(startError)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    confirm()
                } label: {
                    HStack(spacing: 10) {
                        if isStarting { ProgressView().tint(.white) }
                        Text(buttonTitle)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: amount)
                    }
                }
                .buttonStyle(.twendePrimary)
                .disabled(!canConfirm)
                .accessibilityIdentifier("wallet.topUp.confirm")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
    }

    private var amountDisplay: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("TZS")
                    .font(TwendeFont.figtree(20, weight: .semibold))
                    .foregroundStyle(amount > 0 ? TwendeColor.ink : TwendeColor.inkTertiary)
                Text(amount > 0 ? Format.grouped(amount) : "0")
                    .font(TwendeFont.figtree(52, weight: .bold).monospacedDigit())
                    .foregroundStyle(amount > 0 ? TwendeColor.ink : TwendeColor.inkTertiary)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: amount)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("wallet.topUp.amount")

            Group {
                if let validationText {
                    Text(validationText)
                        .foregroundStyle(TwendeColor.amberText)
                } else if amount > 0 {
                    Text(L(.topUpNewBalance, Format.tzs(env.store.walletBalance + amount)))
                        .foregroundStyle(TwendeColor.inkSecondary)
                } else {
                    Text(L(.topUpMinimumHint, Format.tzs(WalletRules.minimumTopUp)))
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
            }
            .font(TwendeFont.caption)
            .contentTransition(.opacity)
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private func confirm() {
        guard let source, canConfirm else { return }
        Haptics.medium()
        start(amount: amount, method: source)
    }

    private func retry() {
        guard let payment = env.payments.payment(activeReference) else { activeReference = nil; return }
        start(amount: payment.amount, method: payment.method)
    }

    private func start(amount: Int, method: PaymentMethod) {
        isStarting = true
        startError = nil
        Task { @MainActor in
            do {
                let reference = try await env.payments.start(amount: amount, method: method, purpose: .topUp)
                isStarting = false
                activeReference = reference
            } catch {
                isStarting = false
                activeReference = nil
                startError = MobileMoneyCopy.startFailure(error)
                Haptics.error()
            }
        }
    }
}

/// One of four equal wallet tiles. Selection never changes size: only the ink edge and a soft brand
/// wash move, so the row stays perfectly even.
private struct WalletRailTile: View {
    let method: PaymentMethod
    let isLinked: Bool
    let isSelected: Bool
    let action: () -> Void

    private var brand: Color { Color(hex: method.brandHex) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MobileMoneyLogo(method: method, size: 40)
                Text(method.shortName)
                    .font(TwendeFont.label)
                    .foregroundStyle(TwendeColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? brand.opacity(0.08) : TwendeColor.surface)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? TwendeColor.ink : TwendeColor.border, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityLabel("\(method.displayName), \(isLinked ? L(.linked) : L(.notLinked))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("wallet.rail.\(method.rawValue)")
    }
}

/// One fixed-height line under the tiles for the selected wallet: the verified number with a
/// "Change" action, or a single "Link" action that opens the SMS-code flow.
private struct WalletSourceStatus: View {
    let method: PaymentMethod
    let account: MobileMoneyAccount?
    let onLink: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let account {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.isVerified ? (account.accountName ?? L(.linked)) : L(.notLinked))
                        .font(TwendeFont.label)
                        .foregroundStyle(account.isVerified ? TwendeColor.inkSecondary : TwendeColor.amberText)
                        .lineLimit(1)
                    Text(Format.phone(account.phone))
                        .font(TwendeFont.bodySemibold.monospacedDigit())
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(account.isVerified ? L(.change) : L(.walletNeedsVerify), action: onLink)
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.ink)
                    .underline()
                    .frame(minWidth: 48, minHeight: 48)
                    .accessibilityIdentifier("wallet.rail.\(method.rawValue).change")
            } else {
                Text(L(.notLinked))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Spacer(minLength: 8)
                Button(L(.linkShort), action: onLink)
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.ink)
                    .underline()
                    .frame(minWidth: 48, minHeight: 48)
                    .accessibilityIdentifier("wallet.rail.\(method.rawValue).link")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 8))
        .animation(.easeOut(duration: 0.15), value: account)
    }
}
