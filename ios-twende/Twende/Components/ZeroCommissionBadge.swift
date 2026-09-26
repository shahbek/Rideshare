import SwiftUI

/// Mandatory trust badge: before a ride it promises 100% to the driver, after it restates the exact amount.
struct ZeroCommissionBadge: View {
    enum Mode: Equatable {
        /// Before the ride: "Driver receives 100%".
        case promise
        /// Fare known, payment not yet confirmed: "Driver receives TZS X · 100%".
        case due(Int)
        /// Payment confirmed: "Driver received TZS X · 100%".
        case settled(Int)
    }

    let mode: Mode
    var onInfo: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Icon3DView(icon: .handshake, size: 40, hero: true)
            Text(text)
                .font(TwendeFont.captionMedium)
                .foregroundStyle(TwendeColor.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 0)
            if let onInfo {
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L(.zeroCommissionTitle))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, onInfo == nil ? 14 : 4)
        .padding(.vertical, onInfo == nil ? 10 : 4)
        .frame(minHeight: 56)
        .background(TwendeColor.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TwendeColor.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch mode {
        case .promise:
            L(.badgeDriverReceives100)
        case .due(let amount):
            L(.badgeDriverReceivesAmount, Format.tzs(amount))
        case .settled(let amount):
            L(.badgeDriverReceived, Format.tzs(amount))
        }
    }
}
