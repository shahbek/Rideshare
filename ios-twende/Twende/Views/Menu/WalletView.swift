import SwiftUI

/// Prepaid Zuri wallet: balance, one gold Top up action, the auto top-up rule, then plain activity rows.
struct WalletView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isToppingUp: Bool = false
    @State private var isEditingAutoTopUp: Bool = false

    private var pendingTopUps: [PendingMobileMoney] {
        env.store.pendingMobileMoney.filter { $0.purpose != .ride }
    }

    var body: some View {
        MenuScreen(title: L(.wallet)) {
            balanceHero

            AutoTopUpRow { isEditingAutoTopUp = true }

            RowDivider(leading: 0)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.walletHistory))
                    .padding(.bottom, 4)
                ForEach(pendingTopUps) { pending in
                    PendingTopUpRow(pending: pending)
                    RowDivider(leading: 56)
                }
                if env.store.walletTransactions.isEmpty && pendingTopUps.isEmpty {
                    Text(L(.walletNoHistory))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(env.store.walletTransactions.enumerated()), id: \.element.id) { index, transaction in
                        if index > 0 {
                            RowDivider(leading: 56)
                        }
                        WalletTransactionRow(transaction: transaction)
                    }
                }
            }

            Text(L(.walletExplainer))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .sheet(isPresented: $isToppingUp) {
            WalletTopUpSheet()
                .appSheet(detents: [.large])
        }
        .sheet(isPresented: $isEditingAutoTopUp) {
            AutoTopUpSheet()
                .appSheet(detents: [.large])
        }
    }

    private var balanceHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(.walletBalance))
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.inkSecondary)
                    Text(Format.tzs(env.store.walletBalance))
                        .font(TwendeFont.fareHero)
                        .foregroundStyle(TwendeColor.ink)
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.4), value: env.store.walletBalance)
                        .accessibilityIdentifier("wallet.balance")
                }
                Spacer(minLength: 0)
                Icon3DView(icon: .wallet, size: 72)
            }
            Button {
                Haptics.tap()
                isToppingUp = true
            } label: {
                Text(L(.topUp))
            }
            .buttonStyle(.twendePrimary)
            .accessibilityIdentifier("wallet.topUp")
        }
        .padding(.top, 4)
    }
}

/// "Auto top-up · Off" or the active rule in one plain row; opens the rule editor.
struct AutoTopUpRow: View {
    @Environment(AppEnvironment.self) private var env
    let action: () -> Void

    private var summary: String {
        let rule = env.store.autoTopUp
        guard rule.isEnabled, let method = rule.method else { return L(.autoTopUpOff) }
        return L(.autoTopUpSummary, Format.tzs(rule.threshold), Format.tzs(rule.amount), method.displayName)
    }

    var body: some View {
        MenuRow(icon: .clock, title: L(.autoTopUp), subtitle: summary, horizontalPadding: 0, action: action)
            .accessibilityIdentifier("wallet.autoTopUp")
    }
}

/// A top-up the server has not settled yet. It never counts toward the balance.
private struct PendingTopUpRow: View {
    let pending: PendingMobileMoney

    var body: some View {
        HStack(spacing: 16) {
            Icon3DView(icon: .phone, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(.walletTopUpTitle, pending.method.displayName))
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                    .lineLimit(1)
                Text(L(.mmWaitingRow))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            Spacer(minLength: 8)
            Text(Format.tzs(pending.amount))
                .font(TwendeFont.fare)
                .foregroundStyle(TwendeColor.inkTertiary)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }
}

/// Plain activity row: 3D icon for the movement kind, title/date, signed amount on the right.
private struct WalletTransactionRow: View {
    let transaction: WalletTransaction

    private var icon: Icon3D {
        switch transaction.kind {
        case .topUp: .coins
        case .ridePayment: .cityCar
        case .refund: .receipt
        }
    }

    private var title: String {
        switch transaction.kind {
        case .topUp:
            let source = transaction.source?.displayName ?? L(.wallet)
            return transaction.isAutomatic == true ? L(.walletAutoTopUpTitle, source) : L(.walletTopUpTitle, source)
        case .ridePayment: return L(.walletRidePayment, transaction.detail ?? "")
        case .refund: return L(.walletRefund)
        }
    }

    private var subtitle: String {
        guard let reference = transaction.reference else { return Format.dateTime(transaction.at) }
        return "\(Format.dateTime(transaction.at)) · \(reference)"
    }

    var body: some View {
        HStack(spacing: 16) {
            Icon3DView(icon: icon, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(transaction.isCredit ? "+ \(Format.tzs(transaction.amount))" : Format.signedTZS(transaction.amount))
                .font(TwendeFont.fare)
                .foregroundStyle(transaction.isCredit ? TwendeColor.badgeForeground : TwendeColor.ink)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }
}
