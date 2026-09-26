import SwiftUI

/// Auto top-up rule: "When my balance drops below X, add Y from wallet Z". Off by default; the phone's
/// PIN prompt still confirms each automatic top-up.
struct AutoTopUpSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var isEnabled: Bool = false
    @State private var thresholdText: String = ""
    @State private var amountText: String = ""
    @State private var method: PaymentMethod? = nil

    private var linked: [PaymentMethod] {
        PaymentMethod.allCases.filter { $0.isMobileMoney && env.store.account(for: $0) != nil }
    }

    private var threshold: Int { Int(thresholdText) ?? 0 }
    private var amount: Int { Int(amountText) ?? 0 }

    private var validation: String? {
        guard isEnabled else { return nil }
        if linked.isEmpty { return L(.autoTopUpNeedsWallet) }
        if threshold < WalletRules.minimumTopUp || amount < WalletRules.minimumTopUp { return L(.autoTopUpInvalid) }
        if amount > WalletRules.maximumTopUp { return L(.topUpMaximum, Format.tzs(WalletRules.maximumTopUp)) }
        return nil
    }

    private var canSave: Bool {
        !isEnabled || (validation == nil && method != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Icon3DView(icon: .clock, size: 32)
                        Text(L(.autoTopUpTitle))
                            .font(TwendeFont.display)
                            .foregroundStyle(TwendeColor.ink)
                    }
                    Text(L(.autoTopUpBody))
                        .font(TwendeFont.body)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: $isEnabled.animation(.spring(duration: 0.3))) {
                        Text(L(.autoTopUp))
                            .font(TwendeFont.bodyMedium)
                            .foregroundStyle(TwendeColor.ink)
                    }
                    .tint(TwendeColor.primary)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("autoTopUp.toggle")

                    if isEnabled {
                        VStack(alignment: .leading, spacing: 16) {
                            TwendeTextField(title: L(.autoTopUpThreshold), text: $thresholdText, placeholder: "5,000", keyboard: .numberPad, prefix: "TZS")
                            TwendeTextField(title: L(.autoTopUpAmount), text: $amountText, placeholder: "20,000", keyboard: .numberPad, prefix: "TZS")

                            VStack(alignment: .leading, spacing: 0) {
                                Text(L(.autoTopUpFrom)).sectionLabelStyle()
                                    .padding(.bottom, 4)
                                if linked.isEmpty {
                                    Text(L(.autoTopUpNeedsWallet))
                                        .font(TwendeFont.caption)
                                        .foregroundStyle(TwendeColor.inkSecondary)
                                        .padding(.vertical, 8)
                                }
                                ForEach(Array(linked.enumerated()), id: \.element.id) { index, rail in
                                    if index > 0 { RowDivider(leading: 54) }
                                    Button {
                                        Haptics.selection()
                                        method = rail
                                    } label: {
                                        HStack(spacing: 14) {
                                            PaymentTile(method: rail)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(rail.displayName)
                                                    .font(TwendeFont.bodyMedium)
                                                    .foregroundStyle(TwendeColor.ink)
                                                Text(env.store.account(for: rail).map { Format.phone($0.phone) } ?? "")
                                                    .font(TwendeFont.caption)
                                                    .foregroundStyle(TwendeColor.inkSecondary)
                                            }
                                            Spacer()
                                            RadioDot(isSelected: method == rail)
                                        }
                                        .frame(minHeight: 60)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.pressableCard)
                                    .accessibilityAddTraits(method == rail ? .isSelected : [])
                                }
                            }

                            if let validation {
                                Text(validation)
                                    .font(TwendeFont.caption)
                                    .foregroundStyle(TwendeColor.amberText)
                            } else if method != nil {
                                Text(L(.autoTopUpSummary, Format.tzs(threshold), Format.tzs(amount), method?.displayName ?? ""))
                                    .font(TwendeFont.caption)
                                    .foregroundStyle(TwendeColor.inkSecondary)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            Button(L(.autoTopUpSave)) {
                Haptics.success()
                env.store.setAutoTopUp(AutoTopUpRule(isEnabled: isEnabled, threshold: threshold, amount: amount, method: method))
                if isEnabled { env.payments.checkAutoTopUp() }
                dismiss()
            }
            .buttonStyle(.twendePrimary)
            .disabled(!canSave)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .accessibilityIdentifier("autoTopUp.save")
        }
        .onAppear {
            let rule = env.store.autoTopUp
            isEnabled = rule.isEnabled
            thresholdText = String(rule.threshold)
            amountText = String(rule.amount)
            method = rule.method.flatMap { env.store.account(for: $0) != nil ? $0 : nil } ?? linked.first
        }
        .onChange(of: thresholdText) { _, value in
            let cleaned = String(value.filter(\.isNumber).prefix(WalletRules.amountDigitLimit))
            if cleaned != value { thresholdText = cleaned }
        }
        .onChange(of: amountText) { _, value in
            let cleaned = String(value.filter(\.isNumber).prefix(WalletRules.amountDigitLimit))
            if cleaned != value { amountText = cleaned }
        }
    }
}
