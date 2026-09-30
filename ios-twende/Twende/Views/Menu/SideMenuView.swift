import SwiftUI

/// Account tab and contextual account modal share the same plain, hairline-divided content.
struct SideMenuView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    @Environment(\.foldLayout) private var foldLayout
    var isModal: Bool = true

    var body: some View {
        MenuSplitStack(placeholder: .gear) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    profileHeader
                    RowDivider(leading: 0)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    if isModal {
                        MenuRow(icon: .logbook, title: L(.tripHistory)) {
                            open(.history)
                        }
                    }
                    MenuRow(
                        icon: .favourite,
                        title: L(.myDrivers),
                        badge: L(.onlineCount, env.drivers.onlineCount(ids: env.store.favouriteDriverIDs))
                    ) {
                        open(.drivers)
                    }
                    MenuRow(icon: .wallet, title: L(.wallet), value: Format.tzs(env.store.walletBalance)) {
                        open(.wallet)
                    }
                    .accessibilityIdentifier("account.wallet")
                    MenuRow(icon: .cash, title: L(.payments), value: env.store.defaultPaymentMethod.displayName) {
                        open(.payments)
                    }
                    MenuRow(icon: .signpost, title: L(.savedPlaces)) {
                        open(.savedPlaces)
                    }
                    MenuRow(
                        icon: .shield,
                        title: env.store.isIdentityVerified ? L(.idVerified) : L(.idVerify),
                        subtitle: env.store.isIdentityVerified ? nil : L(.idVerifySubtitle)
                    ) {
                        open(.identity)
                    }
                    .accessibilityIdentifier("account.identity")

                    RowDivider(leading: 0)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                    MenuRow(icon: .gift, title: L(.promotions)) {
                        open(.promotions)
                    }
                    MenuRow(icon: .shield, title: L(.safetyCentre)) {
                        open(.safety)
                    }
                    MenuRow(icon: .chat, title: L(.support)) {
                        open(.support)
                    }
                    MenuRow(icon: .gear, title: L(.settings), value: env.settings.language.nativeName) {
                        open(.settings)
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
                    // Icon + title and a semantic placement so the item also works in iPhone Duo's vertical bar.
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L(.close), systemImage: "xmark") {
                            env.flow.closeMenu()
                        }
                        .tint(TwendeColor.ink)
                    }
                }
            }
        }
        .tint(TwendeColor.primary)
    }

    private func open(_ route: MenuRoute) {
        navigation.open(route, split: foldLayout != nil)
    }

    private var profileHeader: some View {
        Button {
            open(.profile)
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
