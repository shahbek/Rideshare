import SwiftUI
import UIKit

/// C8 — FAQ plus direct contact routes. Plain rows with inset hairlines; FAQ expands in place.
struct SupportView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    @State private var expanded: Set<Int> = []

    private let faq: [(LKey, LKey)] = [
        (.faqQ1, .faqA1),
        (.faqQ2, .faqA2),
        (.faqQ3, .faqA3),
        (.faqQ4, .faqA4),
        (.faqQ5, .faqA5),
        (.faqQ6, .faqA6),
    ]

    var body: some View {
        MenuScreen(title: L(.support)) {
            HStack(spacing: 10) {
                Button {
                    open("https://wa.me/255700000000")
                } label: {
                    Label(L(.chatWhatsApp), systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.twendePrimary)
                Button {
                    open("tel://+255700000000")
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TwendeColor.ink)
                        .frame(width: 56, height: 56)
                        .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 16))
                }
                .accessibilityLabel(L(.callSupport))
            }
            Text(L(.supportHours))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)

            if let latest = env.store.history.first {
                RowDivider(leading: 0)
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: L(.lastTrip))
                    Button {
                        Haptics.tap()
                        navigation.path.append(.tripDetail(latest.id))
                    } label: {
                        TripHistoryRow(trip: latest, driver: env.drivers.driver(id: latest.driverID))
                    }
                    .buttonStyle(.pressableCard)
                }
            }

            RowDivider(leading: 0)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.faq))
                    .padding(.bottom, 4)
                ForEach(Array(faq.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        RowDivider(leading: 0)
                    }
                    FAQRow(question: L(item.0), answer: L(item.1), isExpanded: expanded.contains(index)) {
                        Haptics.selection()
                        withAnimation(.spring(duration: 0.3)) {
                            if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
                        }
                    }
                }
            }

            RowDivider(leading: 0)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.legal))
                    .padding(.bottom, 4)
                MenuRow(icon: .receipt, title: L(.termsOfService), horizontalPadding: 0) {
                    open("https://zuri.app/terms")
                }
                RowDivider(leading: 56)
                MenuRow(icon: .lock, title: L(.privacyPolicy), horizontalPadding: 0) {
                    open("https://zuri.app/privacy")
                }
            }
        }
    }

    private func open(_ string: String) {
        Haptics.tap()
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }
}

private struct FAQRow: View {
    let question: String
    let answer: String
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Text(question)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TwendeColor.inkTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 14)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                Text(answer)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
    }
}
