import SwiftUI

/// B5 — matching a driver. Cancel is visible from the first second.
struct SearchingPanel: View {
    @Environment(AppEnvironment.self) private var env
    let trip: Trip

    private var preferredDriver: Driver? {
        env.drivers.driver(id: trip.preferredDriverID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text(preferredDriver.map { L(.askingDriver, $0.firstName) } ?? L(.findingDriver, L(trip.tier.nameKey)))
                    .font(TwendeFont.title)
                    .foregroundStyle(TwendeColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                ShimmerBar()
                HStack(spacing: 6) {
                    Text(Format.clock(seconds: env.trips.searchElapsedSeconds))
                        .font(TwendeFont.captionMedium.monospacedDigit())
                        .foregroundStyle(TwendeColor.ink)
                        .contentTransition(.numericText())
                    Text("· \(L(.usuallyUnder))")
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
            }

            if let preferredDriver {
                HStack(spacing: 12) {
                    TierGlyph(tier: preferredDriver.tier, width: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preferredDriver.firstName)
                            .font(TwendeFont.bodySemibold)
                            .foregroundStyle(TwendeColor.ink)
                        RatingLabel(rating: preferredDriver.rating, trips: preferredDriver.trips)
                    }
                    Spacer()
                    DriverStatusChip(status: preferredDriver.status)
                }
            }

            RowDivider(leading: 0)

            RouteStopsView(pickup: trip.pickup.name, destination: trip.destination.name, stops: trip.stopList.map(\.name))

            HStack(spacing: 12) {
                TierGlyph(tier: trip.tier, width: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(trip.tier.nameKey))
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                    Text(trip.paymentMethod.displayName)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                Spacer()
                Text(Format.tzs(trip.fare))
                    .font(TwendeFont.fare)
                    .foregroundStyle(TwendeColor.ink)
            }
            .frame(minHeight: 56)

            Button(L(.cancelRequest)) {
                Haptics.warning()
                env.trips.cancel(reason: .changedPlans)
            }
            .buttonStyle(.twendeSecondary)
        }
        .animation(.easeInOut(duration: 0.25), value: env.trips.searchElapsedSeconds)
    }
}

/// B5b — no driver accepted.
struct NoDriversPanel: View {
    @Environment(AppEnvironment.self) private var env
    let trip: Trip

    private var alternatives: [RideTier] {
        RideTier.allCases.filter { $0 != trip.tier && env.drivers.hasDriversNearby(tier: $0, near: trip.pickup.point) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TwendeColor.amberText)
                    .frame(width: 52, height: 52)
                    .background(TwendeColor.amberTint, in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(.noDriversTitle))
                        .font(TwendeFont.title)
                        .foregroundStyle(TwendeColor.ink)
                    Text(L(.noDriversBody, L(trip.tier.nameKey)))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !alternatives.isEmpty {
                Text(L(.tryAnotherRide)).sectionLabelStyle()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(alternatives) { tier in
                            Button {
                                Haptics.tap()
                                env.trips.retrySearch(with: tier)
                            } label: {
                                HStack(spacing: 8) {
                                    TierGlyph(tier: tier, width: 40)
                                    Text(L(tier.nameKey))
                                        .font(TwendeFont.captionMedium)
                                        .foregroundStyle(TwendeColor.ink)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 48)
                                .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 8))
                            }
                            .buttonStyle(.pressableCard)
                        }
                    }
                }
                .scrollClipDisabled()
            }

            Toggle(isOn: Binding(
                get: { env.store.notifyWhenDriversAvailable },
                set: { env.store.setNotifyWhenDriversAvailable($0) }
            )) {
                Label(L(.notifyWhenDrivers), systemImage: "bell.fill")
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
            }
            .tint(TwendeColor.primary)
            .frame(minHeight: 56)

            Button(L(.tryAgain)) {
                Haptics.medium()
                env.trips.retrySearch()
            }
            .buttonStyle(.twendePrimary)

            Button(L(.backToHome)) {
                env.trips.abandonSearch()
            }
            .buttonStyle(.twendeGhost)
        }
    }
}
