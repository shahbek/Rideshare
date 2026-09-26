import SwiftUI

/// Service family shown on Home, Marti-style: the passenger picks what kind of vehicle before typing a destination.
nonisolated enum ServiceFamily: String, CaseIterable, Identifiable, Sendable {
    case ride
    case bajaji
    case boda

    var id: String { rawValue }

    var nameKey: LKey {
        switch self {
        case .ride: .serviceRide
        case .bajaji: .serviceBajaji
        case .boda: .serviceBoda
        }
    }

    /// Tier pre-selected on the ride options screen for this family.
    var defaultTier: RideTier {
        switch self {
        case .ride: .economy
        case .bajaji: .bajaji
        case .boda: .boda
        }
    }

    var glyphTier: RideTier { defaultTier }

    static func family(for tier: RideTier) -> ServiceFamily {
        switch tier {
        case .economy, .comfort, .premium: .ride
        case .bajaji: .bajaji
        case .boda: .boda
        }
    }
}

/// Airbnb category tabs: rendered 3D vehicle above a label; a 3pt rounded ink indicator slides along the
/// hairline track and sits centred on it under the selected tab;
/// unselected tabs are dimmed. Sits at the top of the Home sheet.
struct ServiceSwitcher: View {
    @Binding var selection: ServiceFamily
    let etaMinutes: (ServiceFamily) -> Int?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ServiceFamily.allCases) { family in
                let isSelected = family == selection
                Button {
                    Haptics.selection()
                    withAnimation(.spring(duration: 0.32, bounce: 0.1)) {
                        selection = family
                    }
                } label: {
                    VStack(spacing: 4) {
                        Icon3DView(icon: family.glyphTier.icon3D, size: 56)
                            .scaleEffect(isSelected ? 1 : 0.94)
                            .opacity(isSelected ? 1 : 0.6)
                        Text(L(family.nameKey))
                            .font(TwendeFont.figtree(13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? TwendeColor.ink : TwendeColor.inkSecondary)
                        if let eta = etaMinutes(family) {
                            Text(L(.minutesShort, eta))
                                .font(TwendeFont.figtree(12, weight: .medium).monospacedDigit())
                                .foregroundStyle(TwendeColor.inkSecondary)
                                .contentTransition(.numericText())
                        } else {
                            Text(" ")
                                .font(TwendeFont.figtree(12, weight: .medium))
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressableCard)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) {
            // Hairline track spanning the row; the 3pt ink indicator is centred on it, under the selected tab.
            GeometryReader { proxy in
                let tabWidth = proxy.size.width / CGFloat(ServiceFamily.allCases.count)
                let index = CGFloat(ServiceFamily.allCases.firstIndex(of: selection) ?? 0)
                let indicatorWidth = tabWidth - 20
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(TwendeColor.border)
                        .frame(height: 1)
                        .frame(maxHeight: .infinity)
                    Capsule()
                        .fill(TwendeColor.ink)
                        .frame(width: indicatorWidth, height: 3)
                        .offset(x: index * tabWidth + 10)
                        .animation(.spring(duration: 0.32, bounce: 0.1), value: selection)
                }
            }
            .frame(height: 3)
            .offset(y: 1)
        }
    }
}
