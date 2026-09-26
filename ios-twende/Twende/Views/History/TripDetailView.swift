import SwiftUI

/// C2a — receipt for a past trip with LATRA-style reference and PDF share.
/// Map, then plain sections separated by hairlines: route, driver, fare, payment, legal.
struct TripDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    let trip: Trip
    @State private var camera: MapCameraTarget = .automatic
    @State private var receiptURL: URL? = nil

    private var driver: Driver? { env.drivers.driver(id: trip.driverID) }
    private var isCancelled: Bool { trip.phase == .cancelled }

    var body: some View {
        MenuScreen(title: L(.receipt)) {
            VStack(alignment: .leading, spacing: 0) {
                TripMapView(
                    camera: $camera,
                    pickup: trip.pickup.point,
                    destination: trip.destination.point,
                    stops: trip.stopList.map(\.point),
                    routePoints: trip.route.points,
                    showsUserLocation: false,
                    interactionModes: []
                )
                .frame(height: 180)
                .clipShape(.rect(cornerRadius: 16))
                .onAppear {
                    camera = .rect(MapCameraHelper.rect(fitting: trip.route.points, paddingFraction: 0.35))
                }

                header
                    .padding(.top, 20)
                    .padding(.bottom, 18)

                RowDivider(leading: 0)

                RouteStopsView(
                    pickup: trip.pickup.name,
                    destination: trip.destination.name,
                    stops: trip.stopList.map(\.name),
                    pickupDetail: trip.pickup.address,
                    destinationDetail: trip.destination.address,
                    pickupAccessory: trip.startedAt.map(Format.time),
                    destinationAccessory: trip.completedAt.map(Format.time)
                )
                .padding(.vertical, 12)

                RowDivider(leading: 0)

                if let driver {
                    driverLine(driver)
                        .padding(.vertical, 14)
                    RowDivider(leading: 0)
                }

                if isCancelled, let cancellation = trip.cancellation {
                    VStack(alignment: .leading, spacing: 12) {
                        BreakdownRow(title: L(.cancellationReason), value: L(cancellation.reason.key))
                        BreakdownRow(title: L(.cancellationFee), value: Format.tzs(cancellation.fee), emphasis: true)
                    }
                    .padding(.vertical, 16)
                } else {
                    fareSection
                        .padding(.vertical, 16)
                    ZeroCommissionBadge(mode: .settled(trip.totalDue))
                        .padding(.bottom, 16)
                    RowDivider(leading: 0)
                    paymentLine
                        .padding(.vertical, 14)
                }

                RowDivider(leading: 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L(.latraNotice))
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Zuri Mobility Ltd · TIN 123-456-789 · Dar es Salaam")
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkTertiary)
                }
                .padding(.top, 16)
                .padding(.bottom, 24)

                actions
            }
        }
        // "Share this receipt", "book this again" — the receipt is the one item on screen.
        .primaryOnScreen(TripEntity(trip, env: env), activity: TwendeActivity.receipt, title: L(.receipt))
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(isCancelled ? Format.tzs(trip.cancellation?.fee ?? 0) : Format.tzs(trip.totalDue))
                    .font(TwendeFont.fareLarge)
                    .foregroundStyle(TwendeColor.ink)
                Spacer()
                if isCancelled {
                    Label(L(.cancelledLabel), systemImage: "xmark.circle.fill")
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                } else {
                    Label(L(.paymentConfirmed), systemImage: "checkmark.seal.fill")
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.badgeForeground)
                }
            }
            HStack(spacing: 6) {
                Text(Format.dateTime(trip.createdAt))
                Text("·").foregroundStyle(TwendeColor.inkTertiary)
                Text(trip.id).monospacedDigit()
            }
            .font(TwendeFont.caption)
            .foregroundStyle(TwendeColor.inkSecondary)
        }
    }

    private func driverLine(_ driver: Driver) -> some View {
        HStack(spacing: 12) {
            TierGlyph(tier: driver.tier, width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(driver.firstName)
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                Text(driver.vehicle.description)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            Spacer()
            if let rating = trip.rating {
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(star <= rating ? TwendeColor.ink : TwendeColor.border)
                    }
                }
                .accessibilityLabel(Text("\(rating)"))
            }
            PlateView(plate: driver.vehicle.plate, size: .small)
        }
    }

    private var fareSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L(trip.tier.nameKey), systemImage: trip.tier.symbol)
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Spacer()
                Text("\(Format.distance(trip.quote.distanceKm)) · \(L(.minutesShort, trip.quote.durationMinutes))")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            BreakdownRow(title: L(.baseFare), value: Format.tzs(trip.quote.breakdown.base))
            BreakdownRow(title: L(.distanceFare, Format.distance(trip.quote.distanceKm)), value: Format.tzs(trip.quote.breakdown.distance))
            BreakdownRow(title: L(.timeFare, trip.quote.durationMinutes), value: Format.tzs(trip.quote.breakdown.time))
            if trip.quote.breakdown.discount > 0 {
                BreakdownRow(title: L(.promoDiscount), value: Format.signedTZS(-trip.quote.breakdown.discount), tint: TwendeColor.badgeForeground)
            }
            if trip.tip > 0 {
                BreakdownRow(title: L(.tip), value: Format.tzs(trip.tip))
            }
            RowDivider(leading: 0)
            BreakdownRow(title: L(.total), value: Format.tzs(trip.totalDue), emphasis: true)
        }
    }

    private var paymentLine: some View {
        HStack(spacing: 12) {
            PaymentTile(method: trip.paymentMethod, size: 36)
            Text(trip.paymentMethod.displayName)
                .font(TwendeFont.bodyMedium)
                .foregroundStyle(TwendeColor.ink)
            Spacer()
            Text(Format.tzs(trip.totalDue))
                .font(TwendeFont.fare)
                .foregroundStyle(TwendeColor.ink)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(L(.rebook)) {
                Haptics.medium()
                env.flow.rebook(trip)
            }
            .buttonStyle(.twendePrimary)

            if !isCancelled {
                if let receiptURL {
                    ShareLink(item: receiptURL) {
                        Label(L(.shareReceipt), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.twendeSecondary)
                } else {
                    Button {
                        Haptics.tap()
                        receiptURL = ReceiptRenderer.render(trip: trip, driver: driver, language: env.settings.language)
                    } label: {
                        Label(L(.prepareReceipt), systemImage: "doc.text")
                    }
                    .buttonStyle(.twendeSecondary)
                }
            }

            Button(L(.reportIssue)) {
                navigation.path.append(.support)
            }
            .buttonStyle(.twendeGhost)
        }
    }
}
