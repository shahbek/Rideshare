import SwiftUI

/// B9 — on the way to the destination with a time-in-traffic counter.
struct InTripPanel: View {
    @Environment(AppEnvironment.self) private var env
    let trip: Trip
    let driver: Driver
    var isExpanded: Bool = false
    var dragTranslation: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(.headingTo, trip.destination.name))
                        .font(TwendeFont.title)
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if env.trips.isInTraffic {
                            Label(L(.inTraffic), systemImage: "car.2.fill")
                                .foregroundStyle(TwendeColor.amberText)
                        } else {
                            Label(L(.movingWell), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(TwendeColor.badgeForeground)
                        }
                        if trip.trafficMinutes > 0 {
                            Text("· \(L(.trafficMinutes, trip.trafficMinutes))")
                                .foregroundStyle(TwendeColor.inkSecondary)
                        }
                    }
                    .font(TwendeFont.caption)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(L(.minutesShort, env.trips.remainingTripMinutes))
                        .font(TwendeFont.fareLarge)
                        .foregroundStyle(TwendeColor.ink)
                        .contentTransition(.numericText())
                    Text(L(.remaining))
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
            }

            TripProgressBar(progress: env.trips.tripProgress)

            CollapsiblePanelContent(isExpanded: isExpanded, dragTranslation: dragTranslation) {
              VStack(spacing: 14) {
            HStack(spacing: 12) {
                TierGlyph(tier: driver.tier, width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(driver.firstName)
                        .font(TwendeFont.bodySemibold)
                        .foregroundStyle(TwendeColor.ink)
                    Text(driver.vehicle.description)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                Spacer()
                PlateView(plate: driver.vehicle.plate, size: .regular)
            }

            HStack {
                Text(L(.fareLabel))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Spacer()
                Text(Format.tzs(trip.fare))
                    .font(TwendeFont.fare)
                    .foregroundStyle(TwendeColor.ink)
                    .contentTransition(.numericText())
                Text("· \(trip.paymentMethod.displayName)")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }

            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    env.flow.beginLiveRouteEdit(trip: trip, from: env.trips.driverPosition ?? trip.pickup.point)
                } label: {
                    Label(L(.changeRoute), systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.twendeSecondary)
                .accessibilityIdentifier("trip.changeRoute")

                ChatButton()
            }
              }
            }
        }
        .clipped()
    }
}

/// Thin green progress track.
struct TripProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(TwendeColor.surfaceAlt)
                Capsule()
                    .fill(TwendeColor.primary)
                    .frame(width: max(proxy.size.width * min(max(progress, 0), 1), 6))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.25), value: progress)
        .accessibilityHidden(true)
    }
}
