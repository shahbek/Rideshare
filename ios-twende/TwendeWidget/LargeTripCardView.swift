import SwiftUI
import WidgetKit

/// 4×4: the app's Home sheet — pickup times, search bar, Home/Work chips, favourite drivers, recent
/// destinations — or, during a ride, the pickup panel followed by the route.
struct LargeTripCardView: View {
    let entry: TwendeEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var lang: WidgetLanguage { snapshot.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let trip = snapshot.activeTrip {
                LiveTripHero(trip: trip, lang: lang)
                WidgetHairline().padding(.vertical, 12)
                RouteStops(pickup: trip.pickup, destination: trip.destination)
            } else if snapshot.favouriteDrivers.isEmpty {
                // The 4×4 family is 345–382pt tall depending on the phone: pick the richest launcher that fits
                // rather than clipping the last row. Home/Work chips and pickup times outrank the driver row.
                ViewThatFits(in: .vertical) {
                    launcher(showsDrivers: false, recents: 3)
                    launcher(showsDrivers: false, recents: 2)
                    launcher(showsDrivers: false, recents: 1)
                }
            } else {
                ViewThatFits(in: .vertical) {
                    launcher(showsDrivers: true, recents: 2)
                    launcher(showsDrivers: true, recents: 1)
                    launcher(showsDrivers: false, recents: 2)
                    launcher(showsDrivers: false, recents: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// Home sheet in miniature. Contains no spacers so `ViewThatFits` measures its true height.
    private func launcher(showsDrivers: Bool, recents: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !snapshot.serviceEtas.isEmpty {
                ServiceEtaStrip(etas: snapshot.serviceEtas, lang: lang, vehicleWidth: 36)
                    .padding(.bottom, 12)
            }
            Link(destination: WidgetLink.search) {
                SearchCapsule(title: WidgetCopy.text(.whereTo, lang))
            }
            ChipRow(slots: QuickPlaces.slots(snapshot, lang, limit: 3))
                .padding(.top, 12)
            if showsDrivers {
                DriversRow(drivers: Array(snapshot.favouriteDrivers.prefix(4)), lang: lang)
                    .padding(.top, 14)
            }
            RecentsList(snapshot: snapshot, lang: lang, limit: recents)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The 56pt white search capsule from the Home sheet.
struct SearchCapsule: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(WidgetPalette.ink)
            Text(title)
                .font(WidgetType.headline)
                .foregroundStyle(WidgetPalette.ink)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background {
            Capsule()
                .fill(WidgetPalette.canvas)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
        .overlay(Capsule().strokeBorder(WidgetPalette.border, lineWidth: 1))
    }
}

struct ChipRow: View {
    let slots: [QuickPlaces.Slot]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(slots) { slot in
                Link(destination: slot.url) {
                    WidgetChip(title: slot.title, object: slot.object, height: 44)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Pickup panel in miniature: title line, vehicle beside driver + plate, start code.
struct LiveTripHero: View {
    let trip: WidgetActiveTrip
    let lang: WidgetLanguage

    private var showsPIN: Bool {
        trip.ridePIN != nil && (trip.phase == "driverAssigned" || trip.phase == "driverArrived")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ActiveTripCopy.headline(trip, lang))
                    .font(WidgetType.title)
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if trip.phase == "driverAssigned" || trip.phase == "inTrip" {
                    Text("\(ActiveTripCopy.bigNumber(trip)) \(ActiveTripCopy.unit(trip, lang))")
                        .font(WidgetType.title.monospacedDigit())
                        .foregroundStyle(WidgetPalette.ink)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 12) {
                WidgetVehicle(tier: trip.tier, width: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.driverFirstName ?? trip.tierName)
                        .font(WidgetType.bodySemibold)
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                    if let vehicle = trip.vehicle {
                        Text(vehicle)
                            .font(WidgetType.caption)
                            .foregroundStyle(WidgetPalette.inkSecondary)
                            .lineLimit(2)
                    }
                    if let plate = trip.plate {
                        WidgetPlate(plate: plate)
                    }
                }
                Spacer(minLength: 0)
            }
            if showsPIN, let pin = trip.ridePIN {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(WidgetCopy.text(.startCode, lang).uppercased())
                                .font(WidgetType.figtree(11, weight: .semibold))
                                .kerning(1.2)
                                .foregroundStyle(WidgetPalette.inkSecondary)
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(WidgetPalette.inkTertiary)
                        }
                        WidgetSplitFlap(text: pin, tileSize: CGSize(width: 34, height: 48), spacing: 5)
                    }
                    Spacer(minLength: 0)
                    Text(WidgetCopy.tzs(trip.fare))
                        .font(WidgetType.fare)
                        .foregroundStyle(WidgetPalette.ink)
                }
            } else {
                RouteProgressBar(progress: trip.progress)
            }
        }
    }
}

/// Pickup → destination with the app's connector: hollow ring, hairline stem, filled square.
struct RouteStops: View {
    let pickup: String
    let destination: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 0) {
                Circle().strokeBorder(WidgetPalette.ink, lineWidth: 2).frame(width: 10, height: 10)
                Rectangle().fill(WidgetPalette.border).frame(width: 2).frame(maxHeight: .infinity)
                Rectangle().fill(WidgetPalette.ink).frame(width: 10, height: 10)
            }
            .padding(.vertical, 12)
            VStack(spacing: 0) {
                Text(pickup)
                    .font(WidgetType.bodyMedium)
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 36)
                WidgetHairline()
                Text(destination)
                    .font(WidgetType.bodyMedium)
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 36)
            }
        }
        .frame(height: 73)
    }
}

/// Recent destinations as `PlaceRow`s with the 72pt inset hairlines.
struct RecentsList: View {
    let snapshot: WidgetSnapshot
    let lang: WidgetLanguage
    var limit: Int = 3
    var rowHeight: CGFloat = 56

    var body: some View {
        let places = Array(snapshot.recentPlaces.prefix(limit))
        VStack(alignment: .leading, spacing: 0) {
            if places.isEmpty {
                Text(WidgetCopy.text(.noRecents, lang))
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetPalette.inkTertiary)
                    .padding(.vertical, 12)
            }
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                if index > 0 { WidgetHairline(leading: 56) }
                Link(destination: WidgetLink.place(place.id)) {
                    WidgetPlaceRow(title: place.label, detail: place.detail, object: .clock, height: rowHeight)
                }
            }
        }
    }
}

/// Favourite drivers as 58pt avatars with first names, exactly like the Home sheet.
struct DriversRow: View {
    let drivers: [WidgetDriver]
    let lang: WidgetLanguage
    var avatarSize: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetSectionHeader(title: WidgetCopy.text(.myDrivers, lang))
            HStack(alignment: .top, spacing: 14) {
                ForEach(drivers) { driver in
                    Link(destination: WidgetLink.driver(driver.id)) {
                        VStack(spacing: 6) {
                            WidgetDriverAvatar(driver: driver, size: avatarSize)
                            Text(driver.firstName)
                                .font(WidgetType.label)
                                .foregroundStyle(driver.status == "offline" ? WidgetPalette.inkSecondary : WidgetPalette.ink)
                                .lineLimit(1)
                        }
                        .frame(width: avatarSize + 12)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
