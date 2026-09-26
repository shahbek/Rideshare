import SwiftUI
import UIKit

/// C6 — active promotions and referrals. WhatsApp is the first share option.
/// Referral block on top; codes as plain rows with inset hairlines.
struct PromotionsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var copiedCode: String? = nil

    private var referralCode: String {
        env.store.profile?.referralCode ?? "TW-0000"
    }

    private var referralMessage: String {
        L(.referralMessage, referralCode, "https://zuri.app/r/\(referralCode)")
    }

    var body: some View {
        MenuScreen(title: L(.promotions)) {
            referralSection

            RowDivider(leading: 0)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.yourCodes))
                    .padding(.bottom, 4)
                ForEach(Array(PromoCatalog.all.enumerated()), id: \.element.id) { index, promo in
                    if index > 0 {
                        RowDivider(leading: 0)
                    }
                    PromoRow(
                        promo: promo,
                        isRedeemed: env.store.redeemedPromoCodes.contains(promo.code),
                        isCopied: copiedCode == promo.code
                    ) {
                        UIPasteboard.general.string = promo.code
                        Haptics.success()
                        copiedCode = promo.code
                    }
                }
            }

            RowDivider(leading: 0)

            Text(L(.promoTerms))
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var referralSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L(.referralTitle))
                    .font(TwendeFont.title)
                    .foregroundStyle(TwendeColor.ink)
                Text(L(.referralBody))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                UIPasteboard.general.string = referralCode
                Haptics.success()
                copiedCode = referralCode
            } label: {
                HStack {
                    Text(referralCode)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(TwendeColor.ink)
                        .kerning(2)
                    Spacer()
                    Label(copiedCode == referralCode ? L(.copied) : L(.copy), systemImage: copiedCode == referralCode ? "checkmark" : "doc.on.doc")
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.badgeForeground)
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableCard)
            .accessibilityLabel(Text("\(referralCode), \(L(.copy))"))

            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    shareOnWhatsApp()
                } label: {
                    Label(L(.shareWhatsApp), systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.twendePrimary)
                ShareLink(item: referralMessage) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TwendeColor.ink)
                        .frame(width: 56, height: 56)
                        .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 16))
                }
                .accessibilityLabel(L(.shareOther))
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func shareOnWhatsApp() {
        let encoded = referralMessage.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "whatsapp://send?text=\(encoded)"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let web = URL(string: "https://wa.me/?text=\(encoded)") {
            UIApplication.shared.open(web)
        }
    }
}

private struct PromoRow: View {
    let promo: Promotion
    let isRedeemed: Bool
    let isCopied: Bool
    let copy: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(promo.code)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(TwendeColor.ink)
                    if isRedeemed {
                        Text(L(.used))
                            .font(TwendeFont.label)
                            .foregroundStyle(TwendeColor.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(TwendeColor.surfaceAlt, in: .capsule)
                    }
                }
                Text(L(promo.title))
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                Text(L(promo.detail))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L(.expiresOn, Format.date(promo.expires)))
                    .font(TwendeFont.label)
                    .foregroundStyle(TwendeColor.inkTertiary)
            }
            Spacer()
            Button(action: copy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isRedeemed ? TwendeColor.inkTertiary : TwendeColor.badgeForeground)
                    .frame(width: 44, height: 44)
                    .background(isRedeemed ? TwendeColor.surfaceAlt : TwendeColor.badgeTint, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(isRedeemed)
            .accessibilityLabel(L(.copy))
        }
        .padding(.vertical, 14)
        .opacity(isRedeemed ? 0.6 : 1)
    }
}
