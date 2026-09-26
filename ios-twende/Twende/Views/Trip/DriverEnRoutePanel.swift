import SwiftUI
import UIKit

/// B7/B8 — driver on the way / arrived. Two heights: collapsed shows only what you need to find the car
/// (ETA, vehicle + plate, PIN, quick contact); swiping up reveals the stops and cancel.
struct DriverEnRoutePanel: View {
    @Environment(AppEnvironment.self) private var env
    let trip: Trip
    let driver: Driver
    var isExpanded: Bool = false
    var dragTranslation: CGFloat = 0

    private var hasArrived: Bool { trip.phase == .driverArrived }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(hasArrived ? L(.driverArrivedTitle, driver.firstName) : L(.arrivingIn, env.trips.driverEtaMinutes))
                    .font(TwendeFont.title)
                    .foregroundStyle(TwendeColor.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                RatingLabel(rating: driver.rating, trips: driver.trips)
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 2) {
                    DriverAvatar(driver: driver, size: 48, showsStatus: false, showsPortrait: true)
                        .accessibilityIdentifier("trip.driver.portrait")
                    TierGlyph(tier: driver.tier, width: 64)
                }
                .onScreenEntity(DriverEntity(driver))
                VStack(alignment: .leading, spacing: 4) {
                    Text(driver.firstName)
                        .font(TwendeFont.bodySemibold)
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(1)
                    Text(driver.vehicle.description)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .lineLimit(2)
                    PlateView(plate: driver.vehicle.plate, size: .regular)
                }
                Spacer(minLength: 0)
            }

            if hasArrived {
                Label(L(.meetAtPickup, trip.pickup.name), systemImage: "figure.walk")
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.ink)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(alignment: .center, spacing: 12) {
                if let pin = trip.ridePIN {
                    RidePINCard(pin: pin, driverName: driver.firstName, hasArrived: hasArrived, compact: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    ContactButton(systemImage: "phone.fill", title: L(.call), compact: true) {
                        call(driver.phone)
                    }
                    ChatButton()
                    ContactButton(
                        systemImage: env.store.isFavourite(driver.id) ? "star.fill" : "star",
                        title: env.store.isFavourite(driver.id) ? L(.favourite) : L(.addFavourite),
                        compact: true
                    ) {
                        Haptics.selection()
                        env.store.toggleFavourite(driver.id)
                    }
                }
            }

            CollapsiblePanelContent(isExpanded: isExpanded, dragTranslation: dragTranslation) {
              VStack(spacing: 14) {
                if trip.ridePIN != nil {
                    Text(hasArrived ? L(.ridePINArrivedBody, driver.firstName) : L(.ridePINBody, driver.firstName))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                RowDivider(leading: 0)

                RouteStopsView(
                    pickup: trip.pickup.name,
                    destination: trip.destination.name,
                    stops: trip.stopList.map(\.name),
                    pickupDetail: trip.pickupNote.isEmpty ? nil : trip.pickupNote
                )

                Button(L(.cancelRide)) {
                    Haptics.tap()
                    env.flow.activeSheet = .cancelReason
                }
                .buttonStyle(.twendeGhost)
              }
            }
        }
        .clipped()
    }

    private func call(_ phone: String) {
        Haptics.tap()
        guard let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })") else { return }
        UIApplication.shared.open(url)
    }
}

/// The ride start code: four green split-flap digits sitting directly on the panel, with a small caption
/// above and the instruction below. The digits flip in when the driver is assigned.
struct RidePINCard: View {
    let pin: String
    let driverName: String
    let hasArrived: Bool
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L(.ridePINTitle).uppercased())
                    .font(TwendeFont.figtree(11, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TwendeColor.inkTertiary)
            }
            SplitFlapBoard(text: pin, tileSize: CGSize(width: 36, height: 50), spacing: 5)
            if !compact {
                Text(hasArrived ? L(.ridePINArrivedBody, driverName) : L(.ridePINBody, driverName))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L(.ridePINAccessibility, pin.map(String.init).joined(separator: " "))))
    }
}

/// Grey circular icon with a label underneath.
struct ContactButton: View {
    let systemImage: String
    let title: String
    var tint: Color = TwendeColor.ink
    /// Icon-only 44pt circle (label becomes the accessibility name).
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 17 : 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: compact ? 44 : 56, height: compact ? 44 : 56)
                    .background(TwendeColor.surface, in: .circle)
                    .overlay(Circle().strokeBorder(TwendeColor.border, lineWidth: 1))
                if !compact {
                    Text(title)
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: compact ? 44 : 76)
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel(Text(title))
    }
}
