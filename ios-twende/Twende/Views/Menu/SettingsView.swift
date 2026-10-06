import SwiftUI

/// C9 — language, notifications, log out and delete account. Plain rows with inset hairlines.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    @State private var isConfirmingLogout: Bool = false
    @State private var isConfirmingDelete: Bool = false

    var body: some View {
        MenuScreen(title: L(.settings)) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.language))
                    .padding(.bottom, 4)
                ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element.id) { index, language in
                    if index > 0 {
                        RowDivider(leading: 56)
                    }
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(duration: 0.3)) { env.settings.language = language }
                    } label: {
                        HStack(spacing: 16) {
                            Text(language.flag)
                                .font(.system(size: 22))
                                .frame(width: 40, height: 40)
                                .background(TwendeColor.surfaceAlt, in: .circle)
                            Text(language.nativeName)
                                .font(TwendeFont.bodyMedium)
                                .foregroundStyle(TwendeColor.ink)
                            Spacer()
                            Image(systemName: env.settings.language == language ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 24))
                                .foregroundStyle(env.settings.language == language ? TwendeColor.primary : TwendeColor.grabber)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .padding(.vertical, 10)
                        .frame(minHeight: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityAddTraits(env.settings.language == language ? .isSelected : [])
                }
            }

            RowDivider(leading: 0)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.mapStyle))
                Text(L(.mapStyleBody))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                ForEach(Array(MapStyleOption.allCases.enumerated()), id: \.element.id) { index, style in
                    if index > 0 {
                        RowDivider(leading: 56)
                    }
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(duration: 0.3)) { env.settings.mapStyle = style }
                    } label: {
                        MapStyleRow(style: style, isSelected: env.settings.mapStyle == style)
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityAddTraits(env.settings.mapStyle == style ? .isSelected : [])
                }
            }

            RowDivider(leading: 0)

            MenuRow(icon: .map, title: L(.offlineMaps), subtitle: L(.offlineBundled), horizontalPadding: 0) {
                Haptics.tap()
                navigation.path.append(.offlineMaps)
            }
            .accessibilityIdentifier("settings.offlineMaps")

            RowDivider(leading: 0)

            Toggle(isOn: Bindable(DioramaState.shared).isEnabled) {
                IconRow(icon: .house, title: "Masaki 3D diorama", subtitle: "Prepare all Masaki in Offline maps before viewing") { EmptyView() }
            }
            .tint(TwendeColor.primary)
            .accessibilityIdentifier("settings.diorama")

            RowDivider(leading: 0)

            MenuRow(
                icon: .phone,
                title: L(.siriGuide),
                subtitle: L(.siriGuideSubtitle),
                horizontalPadding: 0
            ) {
                Haptics.tap()
                navigation.path.append(.siriGuide)
            }
            .accessibilityIdentifier("settings.siriGuide")

            RowDivider(leading: 0)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.notifications))
                    .padding(.bottom, 4)
                Toggle(isOn: Bindable(env.settings).tripNotificationsEnabled) {
                    IconRow(icon: .cityCar, title: L(.tripUpdates)) { EmptyView() }
                }
                .tint(TwendeColor.primary)
                RowDivider(leading: 56)
                Toggle(isOn: Bindable(env.settings).promoNotificationsEnabled) {
                    IconRow(icon: .gift, title: L(.promoUpdates)) { EmptyView() }
                }
                .tint(TwendeColor.primary)
            }

            RowDivider(leading: 0)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L(.account))
                    .padding(.bottom, 4)
                MenuRow(
                    systemImage: "rectangle.portrait.and.arrow.right",
                    title: L(.logOut),
                    iconTint: TwendeColor.ink,
                    showsChevron: false,
                    horizontalPadding: 0
                ) {
                    isConfirmingLogout = true
                }
                RowDivider(leading: 56)
                MenuRow(
                    systemImage: "trash",
                    title: L(.deleteAccount),
                    subtitle: L(.deleteAccountSubtitle),
                    iconTint: TwendeColor.danger,
                    showsChevron: false,
                    horizontalPadding: 0
                ) {
                    isConfirmingDelete = true
                }
            }

            Text(verbatim: "Zuri v1.0 (1) · Dar es Salaam")
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
        .confirmationDialog(L(.logOutConfirmTitle), isPresented: $isConfirmingLogout, titleVisibility: .visible) {
            Button(L(.logOut), role: .destructive) {
                env.flow.closeMenu()
                env.flow.selectedTab = .home
                env.signOut()
            }
            Button(L(.cancel), role: .cancel) {}
        }
        .confirmationDialog(L(.deleteAccountConfirmTitle), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button(L(.deleteAccountConfirm), role: .destructive) {
                env.flow.closeMenu()
                env.flow.selectedTab = .home
                env.deleteAccount()
            }
            Button(L(.cancel), role: .cancel) {}
        } message: {
            Text(L(.deleteAccountConfirmBody))
        }
    }
}
