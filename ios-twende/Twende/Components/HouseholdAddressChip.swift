import SwiftUI
import UIKit

/// Zuri household address: the door's Plus Code plus how far along its street it sits.
/// Tap copies the full shareable address.
struct HouseholdAddressChip: View {
    let address: ZuriAddress
    @State private var didCopy: Bool = false

    var body: some View {
        Button {
            UIPasteboard.general.string = address.shareText
            Haptics.success()
            withAnimation(.snappy) { didCopy = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.snappy) { didCopy = false }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: didCopy ? "checkmark" : "number")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TwendeColor.accentText)
                    .frame(width: 28, height: 28)
                    .background(TwendeColor.primaryTint, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(didCopy ? L(.copied) : L(.householdCode))
                        .font(TwendeFont.figtree(11, weight: .medium))
                        .foregroundStyle(TwendeColor.inkSecondary)
                    Text(address.code)
                        .font(TwendeFont.figtree(15, weight: .bold).monospacedDigit())
                        .foregroundStyle(TwendeColor.ink)
                        .kerning(0.6)
                }
                if let street = address.street, let along = address.metresAlong {
                    Divider().frame(height: 26)
                    Text(L(.metresAlongStreet, Int(along.rounded()), street))
                        .font(TwendeFont.figtree(12, weight: .medium))
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TwendeColor.inkTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(L(.householdCode)) \(address.code). \(address.shareText)")
        .accessibilityHint(L(.copy))
    }
}
