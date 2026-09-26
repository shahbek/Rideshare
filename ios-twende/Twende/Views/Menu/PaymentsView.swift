import SwiftUI

/// C4 — cash and the Twende wallet are always present; four mobile-money rails can be linked and any
/// method made default. Plain rows: available methods with a radio on the right, then unlinked rails.
struct PaymentsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var linking: PaymentMethod? = nil

    var body: some View {
        MenuScreen(title: L(.payments)) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.defaultMethod))
                    .padding(.bottom, 4)
                ForEach(Array(env.store.availablePaymentMethods.enumerated()), id: \.element.id) { index, method in
                    if index > 0 {
                        RowDivider(leading: 56)
                    }
                    PaymentMethodRow(
                        method: method,
                        detail: detail(for: method),
                        isSelected: env.store.defaultPaymentMethod == method
                    ) {
                        Haptics.selection()
                        env.store.setDefaultPayment(method)
                    }
                    .contextMenu {
                        if method.isMobileMoney {
                            Button(role: .destructive) {
                                env.store.unlinkMobileMoney(method)
                            } label: {
                                Label(L(.unlink), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            let unlinked = PaymentMethod.allCases.filter { $0.isMobileMoney && env.store.account(for: $0) == nil }
            if !unlinked.isEmpty {
                RowDivider(leading: 0)
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: L(.addMobileMoney))
                        .padding(.bottom, 4)
                    ForEach(Array(unlinked.enumerated()), id: \.element.id) { index, method in
                        if index > 0 {
                            RowDivider(leading: 56)
                        }
                        Button {
                            Haptics.tap()
                            linking = method
                        } label: {
                            HStack(spacing: 16) {
                                PaymentTile(method: method)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(method.displayName)
                                        .font(TwendeFont.bodyMedium)
                                        .foregroundStyle(TwendeColor.ink)
                                    Text(method.operatorName)
                                        .font(TwendeFont.caption)
                                        .foregroundStyle(TwendeColor.inkSecondary)
                                }
                                Spacer()
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(TwendeColor.badgeForeground)
                                    .frame(width: 32, height: 32)
                                    .background(TwendeColor.badgeTint, in: .circle)
                            }
                            .padding(.vertical, 10)
                            .frame(minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressableCard)
                    }
                }
            }

            RowDivider(leading: 0)

            Text(L(.paymentsNote))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $linking) { method in
            LinkMobileMoneySheet(method: method)
                .appSheet(detents: [.large])
        }
    }

    private func detail(for method: PaymentMethod) -> String {
        switch method {
        case .cash:
            return L(.cashDetail)
        case .wallet:
            return env.store.walletBalance == 0 ? L(.walletEmptyDetail) : L(.walletBalanceDetail, Format.tzs(env.store.walletBalance))
        default:
            if let account = env.store.account(for: method) { return Format.phone(account.phone) }
            return method.operatorName
        }
    }
}

/// Flush list row for a linked method with a trailing radio. Used on the Payments page.
private struct PaymentMethodRow: View {
    let method: PaymentMethod
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                PaymentTile(method: method)
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.displayName)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                    Text(detail)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isSelected ? TwendeColor.primary : TwendeColor.grabber)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

