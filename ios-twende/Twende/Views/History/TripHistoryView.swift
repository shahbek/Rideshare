import SwiftUI

/// C2 — past trips, newest first, grouped by month. Plain rows with inset hairlines.
struct TripHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    @Environment(\.foldLayout) private var foldLayout
    var isActivityRoot: Bool = false

    nonisolated private struct MonthGroup: Identifiable, Sendable {
        let id: String
        let title: String
        let trips: [Trip]
    }

    private var groups: [MonthGroup] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Format.timeZone
        var ordered: [MonthGroup] = []
        for trip in env.store.history {
            let components = calendar.dateComponents([.year, .month], from: trip.createdAt)
            let key = "\(components.year ?? 0)-\(components.month ?? 0)"
            if let index = ordered.firstIndex(where: { $0.id == key }) {
                ordered[index] = MonthGroup(id: key, title: ordered[index].title, trips: ordered[index].trips + [trip])
            } else {
                ordered.append(MonthGroup(id: key, title: Format.monthYear(trip.createdAt, language: env.settings.language), trips: [trip]))
            }
        }
        return ordered
    }

    var body: some View {
        MenuScreen(title: L(isActivityRoot ? .tabActivity : .tripHistory)) {
            if env.store.history.isEmpty {
                EmptyStateView(
                    icon: .logbook,
                    title: L(.noTripsTitle),
                    message: L(.noTripsBody)
                )
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title)
                            .sectionLabelStyle()
                            .padding(.bottom, 4)
                        ForEach(Array(group.trips.enumerated()), id: \.element.id) { index, trip in
                            if index > 0 {
                                RowDivider(leading: 66)
                            }
                            Button {
                                Haptics.tap()
                                navigation.open(.tripDetail(trip.id), split: isActivityRoot && foldLayout != nil)
                            } label: {
                                TripHistoryRow(trip: trip, driver: env.drivers.driver(id: trip.driverID))
                            }
                            .buttonStyle(.pressableCard)
                            .onScreenEntity(TripEntity(trip, env: env))
                        }
                    }
                }
            }
        }
    }
}

/// Vehicle, destination, date, fare. Sits flush on white; callers add hairlines between rows.
struct TripHistoryRow: View {
    let trip: Trip
    let driver: Driver?

    var body: some View {
        HStack(spacing: 14) {
            TierGlyph(tier: trip.tier, width: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(trip.destination.name)
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                    .lineLimit(1)
                Text(Format.dateTime(trip.createdAt))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                if trip.phase == .cancelled {
                    Label(L(.cancelledLabel), systemImage: "xmark.circle.fill")
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                } else if let driver {
                    Text(driver.vehicle.description)
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(trip.phase == .cancelled ? Format.tzs(trip.cancellation?.fee ?? 0) : Format.tzs(trip.totalDue))
                    .font(TwendeFont.fare)
                    .foregroundStyle(TwendeColor.ink)
                if let rating = trip.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(TwendeColor.ink)
                        Text("\(rating)")
                            .font(TwendeFont.label)
                            .foregroundStyle(TwendeColor.inkSecondary)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TwendeColor.inkTertiary)
        }
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .contentShape(Rectangle())
    }
}

/// Rendered 3D illustration + copy for empty lists.
struct EmptyStateView: View {
    let icon: Icon3D
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Icon3DView(icon: icon, size: 120)
                .padding(.bottom, 6)
            Text(title)
                .font(TwendeFont.title)
                .foregroundStyle(TwendeColor.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(TwendeFont.body)
                .foregroundStyle(TwendeColor.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.twendeSecondary)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 12)
    }
}
