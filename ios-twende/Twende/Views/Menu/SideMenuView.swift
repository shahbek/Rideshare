import SwiftUI

/// Account tab and contextual account modal share the same plain, hairline-divided content.
struct SideMenuView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    var isModal: Bool = true

    var body: some View {
        NavigationStack(path: Bindable(navigation).path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    profileHeader
                    RowDivider(leading: 0)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    if isModal {
                        MenuRow(icon: .logbook, title: L(.tripHistory)) {
                            navigation.path.append(.history)
                        }
                    }
                    MenuRow(
                        icon: .favourite,
                        title: L(.myDrivers),
                        badge: L(.onlineCount, env.drivers.onlineCount(ids: env.store.favouriteDriverIDs))
                    ) {
                        navigation.path.append(.drivers)
                    }
                    MenuRow(icon: .wallet, title: L(.wallet), value: Format.tzs(env.store.walletBalance)) {
                        navigation.path.append(.wallet)
                    }
                    .accessibilityIdentifier("account.wallet")
                    MenuRow(icon: .cash, title: L(.payments), value: env.store.defaultPaymentMethod.displayName) {
                        navigation.path.append(.payments)
                    }
                    MenuRow(icon: .signpost, title: L(.savedPlaces)) {
                        navigation.path.append(.savedPlaces)
                    }
                    MenuRow(
                        icon: .shield,
                        title: env.store.isIdentityVerified ? L(.idVerified) : L(.idVerify),
                        subtitle: env.store.isIdentityVerified ? nil : L(.idVerifySubtitle)
                    ) {
                        navigation.path.append(.identity)
                    }
                    .accessibilityIdentifier("account.identity")

                    RowDivider(leading: 0)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                    MenuRow(icon: .gift, title: L(.promotions)) {
                        navigation.path.append(.promotions)
                    }
                    MenuRow(icon: .shield, title: L(.safetyCentre)) {
                        navigation.path.append(.safety)
                    }
                    MenuRow(icon: .chat, title: L(.support)) {
                        navigation.path.append(.support)
                    }
                    MenuRow(icon: .gear, title: L(.settings), value: env.settings.language.nativeName) {
                        navigation.path.append(.settings)
                    }

                    Text("Zuri · v1.0 · \(L(.madeInDar))")
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                }
                .padding(.bottom, 32)
            }
            .background(TwendeColor.surface.ignoresSafeArea())
            .navigationTitle(isModal ? "" : L(.account))
            .navigationBarTitleDisplayMode(isModal ? .inline : .large)
            .toolbarBackground(TwendeColor.surface, for: .navigationBar)
            .toolbar {
                if isModal {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            env.flow.closeMenu()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(TwendeColor.ink)
                                .frame(width: 44, height: 44)
                                .background(TwendeColor.surfaceAlt, in: .circle)
                        }
                        .accessibilityLabel(L(.close))
                    }
                }
            }
            .navigationDestination(for: MenuRoute.self) { route in
                MenuDestinationView(route: route)
            }
        }
        .tint(TwendeColor.primary)
    }

    private var profileHeader: some View {
        Button {
            navigation.path.append(.profile)
        } label: {
            HStack(spacing: 16) {
                ProfileAvatar(size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(env.store.profile?.name ?? "")
                        .font(TwendeFont.display)
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if env.store.isIdentityVerified {
                        VerifiedBadge()
                    }
                    HStack(spacing: 6) {
                        Text(Format.phone(env.store.profile?.phone ?? ""))
                        Text("·")
                        Text(L(.tripsTaken, env.store.history.filter { $0.phase == .rated }.count))
                    }
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TwendeColor.inkTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
    }

}

/// Scrollable white page with a large title. Used by every menu destination.
struct MenuScreen<Content: View>: View {
    let title: String
    var showsLargeTitle: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TwendeColor.surface.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(showsLargeTitle ? .large : .inline)
        .toolbarBackground(TwendeColor.surface, for: .navigationBar)
    }
}
