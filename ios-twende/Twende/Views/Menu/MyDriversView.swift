import SwiftUI

/// C3 — favourite drivers with live status, request-directly and add-by-phone. Plain rows with inset hairlines.
struct MyDriversView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    @State private var isAddingByPhone: Bool = false

    private var favourites: [Driver] {
        env.drivers.favourites(ids: env.store.favouriteDriverIDs)
    }

    var body: some View {
        MenuScreen(title: L(.myDrivers)) {
            Text(L(.myDriversExplainer))
                .font(TwendeFont.body)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if favourites.isEmpty {
                EmptyStateView(
                    icon: .favourite,
                    title: L(.noFavouritesTitle),
                    message: L(.noFavouritesLong),
                    actionTitle: L(.addByPhone)
                ) {
                    isAddingByPhone = true
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(favourites) { driver in
                        FavouriteDriverRow(driver: driver) {
                            navigation.path.append(.driverDetail(driver.id))
                        } request: {
                            env.flow.requestDriver(driver)
                        }
                        .onScreenEntity(DriverEntity(driver))
                        RowDivider(leading: 72)
                    }
                    AddRow(title: L(.addByPhone), systemImage: "phone.badge.plus") {
                        isAddingByPhone = true
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingByPhone) {
            AddDriverByPhoneSheet()
                .appSheet(detents: [.medium])
        }
    }
}

struct FavouriteDriverRow: View {
    @Environment(AppEnvironment.self) private var env
    let driver: Driver
    let open: () -> Void
    let request: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 16) {
                    TierGlyph(tier: driver.tier, width: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(driver.firstName)
                            .font(TwendeFont.bodySemibold)
                            .foregroundStyle(TwendeColor.ink)
                        RatingLabel(rating: driver.rating, trips: driver.trips)
                        HStack(spacing: 6) {
                            DriverStatusChip(status: driver.status)
                            Text(L(driver.tier.nameKey))
                                .font(TwendeFont.label)
                                .foregroundStyle(TwendeColor.inkSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableCard)

            if driver.status == .online {
                Button {
                    Haptics.medium()
                    request()
                } label: {
                    Text(L(.request))
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(TwendeColor.primary, in: .capsule)
                }
                .buttonStyle(.pressableCard)
            } else {
                Button {
                    Haptics.selection()
                    env.store.setNotifyWhenOnline(driver.id, enabled: !env.store.notifiesWhenOnline(driver.id))
                } label: {
                    Image(systemName: env.store.notifiesWhenOnline(driver.id) ? "bell.fill" : "bell")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(env.store.notifiesWhenOnline(driver.id) ? TwendeColor.badgeForeground : TwendeColor.inkSecondary)
                        .frame(width: 44, height: 44)
                        .background(env.store.notifiesWhenOnline(driver.id) ? TwendeColor.badgeTint : TwendeColor.surfaceAlt, in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(L(.notifyWhenOnline))
            }
        }
        .padding(.vertical, 12)
    }
}

/// C3b — link a driver you already know by their number.
struct AddDriverByPhoneSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var digits: String = ""
    @State private var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L(.addByPhone))
                .font(TwendeFont.display)
                .foregroundStyle(TwendeColor.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(L(.addByPhoneBody))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
            TwendeTextField(
                title: L(.phoneLabel),
                text: $digits,
                placeholder: "7XX XXX XXX",
                keyboard: .numberPad,
                contentType: .telephoneNumber,
                prefix: "+255"
            )
            .onChange(of: digits) { _, newValue in
                let cleaned = String(newValue.filter(\.isNumber).prefix(9))
                if cleaned != newValue { digits = cleaned }
                errorText = nil
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.danger)
            }
            Text(L(.addByPhoneHint))
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.inkTertiary)
            Spacer(minLength: 0)
            Button(L(.addDriver)) {
                if let driver = env.drivers.driver(phone: digits) {
                    Haptics.success()
                    env.store.addFavourite(driver.id)
                    dismiss()
                    env.flow.showToast(L(.driverAdded, driver.firstName), symbol: "star.fill")
                } else {
                    Haptics.error()
                    errorText = L(.driverNotFound)
                }
            }
            .buttonStyle(.twendePrimary)
            .disabled(digits.count < 9)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}
