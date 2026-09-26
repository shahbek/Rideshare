import SwiftUI

/// C3a — one driver: stats, vehicle, notify toggle, request or remove.
struct DriverDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    let driverID: String

    private var driver: Driver? { env.drivers.driver(id: driverID) }

    var body: some View {
        if let driver {
            MenuScreen(title: driver.firstName, showsLargeTitle: false) {
                VStack(spacing: 14) {
                    TierGlyph(tier: driver.tier, width: 160)
                    PlateView(plate: driver.vehicle.plate, size: .hero)
                    Text(driver.firstName)
                        .font(TwendeFont.display)
                        .foregroundStyle(TwendeColor.ink)
                    RatingLabel(rating: driver.rating, trips: driver.trips)
                    DriverStatusChip(status: driver.status)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                HStack(spacing: 10) {
                    InfoTile(symbol: "calendar", title: L(.memberSinceShort), value: "\(driver.memberSince)")
                    InfoTile(symbol: "car.fill", title: L(.rideType), value: L(driver.tier.nameKey))
                    InfoTile(symbol: "location.fill", title: L(.awayFromYou), value: Format.distance(driver.position.distanceKm(to: env.flow.pickup.point) * RoutingService.roadFactor))
                }

                RowDivider(leading: 0)

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(driver.vehicle.description)
                            .font(TwendeFont.bodySemibold)
                            .foregroundStyle(TwendeColor.ink)
                        Text(L(.seats, driver.tier.seats))
                            .font(TwendeFont.caption)
                            .foregroundStyle(TwendeColor.inkSecondary)
                    }
                    Spacer()
                }

                if env.store.isFavourite(driver.id) {
                    RowDivider(leading: 0)
                    Toggle(isOn: Binding(
                        get: { env.store.notifiesWhenOnline(driver.id) },
                        set: { env.store.setNotifyWhenOnline(driver.id, enabled: $0) }
                    )) {
                        IconRow(icon: .bell, title: L(.notifyWhenOnline), subtitle: L(.notifyWhenOnlineBody, driver.firstName)) {
                            EmptyView()
                        }
                    }
                    .tint(TwendeColor.primary)
                }

                let pastTrips = env.store.history.filter { $0.driverID == driver.id && $0.phase == .rated }
                if !pastTrips.isEmpty {
                    RowDivider(leading: 0)
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(title: L(.tripsWithDriver, pastTrips.count))
                        ForEach(Array(pastTrips.prefix(3).enumerated()), id: \.element.id) { index, trip in
                            if index > 0 {
                                RowDivider(leading: 66)
                            }
                            Button {
                                Haptics.tap()
                                navigation.path.append(.tripDetail(trip.id))
                            } label: {
                                TripHistoryRow(trip: trip, driver: driver)
                            }
                            .buttonStyle(.pressableCard)
                        }
                    }
                }

                VStack(spacing: 4) {
                    if driver.status == .online {
                        Button(L(.requestDriver, driver.firstName)) {
                            Haptics.medium()
                            env.flow.requestDriver(driver)
                        }
                        .buttonStyle(.twendePrimary)
                    } else {
                        Button(L(.driverUnavailable, driver.firstName)) {}
                            .buttonStyle(.twendePrimary)
                            .disabled(true)
                    }
                    if env.store.isFavourite(driver.id) {
                        Button(L(.removeFromMyDrivers)) {
                            Haptics.warning()
                            env.store.removeFavourite(driver.id)
                            navigation.pop()
                        }
                        .buttonStyle(.twendeGhost)
                    } else {
                        Button {
                            Haptics.success()
                            env.store.addFavourite(driver.id)
                        } label: {
                            Label(L(.addToMyDriversShort), systemImage: "star.fill")
                        }
                        .buttonStyle(.twendeSecondary)
                    }
                }
                .padding(.top, 8)
            }
            .primaryOnScreen(DriverEntity(driver), activity: TwendeActivity.driver, title: driver.firstName)
        }
    }
}
