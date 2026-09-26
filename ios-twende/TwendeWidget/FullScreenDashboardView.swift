import SwiftUI
import WidgetKit

/// iOS 27 `systemExtraLargePortrait`: a calm ride launcher. Only what a passenger checks before tapping —
/// how soon each service can come, the wallet, how the ride will be paid, and where to go — with flexible
/// spacing so the few blocks spread evenly over any height instead of crowding the top.
struct FullScreenDashboardView: View {
    let entry: TwendeEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var lang: WidgetLanguage { snapshot.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 16)

            if let trip = snapshot.activeTrip {
                LiveTripHero(trip: trip, lang: lang)
                Spacer(minLength: 16)
                RouteStops(pickup: trip.pickup, destination: trip.destination)
                Spacer(minLength: 16)
                WidgetHairline()
                PaymentLine(
                    method: WidgetCopy.payment(trip.paymentMethod ?? snapshot.paymentMethod, kind: trip.paymentMethod == nil ? snapshot.paymentKind : nil, lang),
                    kind: snapshot.paymentKind,
                    trailing: WidgetCopy.tzs(trip.fare),
                    lang: lang
                )
            } else {
                serviceList
                Spacer(minLength: 16)
                moneyRow
                Spacer(minLength: 20)
                Link(destination: WidgetLink.search) {
                    SearchCapsule(title: WidgetCopy.text(.whereTo, lang))
                }
                ChipRow(slots: QuickPlaces.slots(snapshot, lang, limit: 2))
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WidgetCopy.greeting(at: entry.date, lang))
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetPalette.inkSecondary)
                Text(snapshot.passengerFirstName.isEmpty ? "Zuri" : snapshot.passengerFirstName)
                    .font(WidgetType.display)
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            if snapshot.monthTrips > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(WidgetCopy.text(.thisMonth, lang))
                        .font(WidgetType.label)
                        .foregroundStyle(WidgetPalette.inkSecondary)
                    Text("\(snapshot.monthTrips) \(WidgetCopy.text(.trips, lang))")
                        .font(WidgetType.bodySemibold.monospacedDigit())
                        .foregroundStyle(WidgetPalette.ink)
                }
            }
        }
    }

    // MARK: - Services

    /// Live pickup times when the app measured them recently; otherwise the three services without a number,
    /// so the page never shows invented times.
    private var services: [WidgetServiceEta] {
        if !snapshot.serviceEtas.isEmpty { return snapshot.serviceEtas }
        return WidgetSnapshot.preview.serviceEtas.map {
            WidgetServiceEta(service: $0.service, name: $0.name, tier: $0.tier, etaMinutes: nil)
        }
    }

    private var hasLiveTimes: Bool { !snapshot.serviceEtas.isEmpty }

    private var serviceList: some View {
        VStack(spacing: 0) {
            ForEach(Array(services.enumerated()), id: \.element.id) { index, eta in
                if index > 0 { WidgetHairline(leading: 88) }
                Link(destination: WidgetLink.search) {
                    HStack(spacing: 16) {
                        WidgetVehicle(tier: eta.tier, width: 72)
                            .opacity(hasLiveTimes && eta.etaMinutes == nil ? 0.45 : 1)
                        Text(eta.name)
                            .font(WidgetType.headline)
                            .foregroundStyle(WidgetPalette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if hasLiveTimes {
                            Text(eta.etaMinutes.map { WidgetCopy.minutes($0, lang) } ?? WidgetCopy.text(.noDriversShort, lang))
                                .font(WidgetType.section.monospacedDigit())
                                .foregroundStyle(eta.etaMinutes == nil ? WidgetPalette.inkTertiary : WidgetPalette.ink)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WidgetPalette.inkTertiary)
                    }
                    .frame(height: 72)
                }
            }
        }
    }

    // MARK: - Wallet + payment

    private var moneyRow: some View {
        HStack(spacing: 10) {
            Link(destination: WidgetLink.wallet) {
                MoneyTile(
                    object: .wallet,
                    label: WidgetCopy.text(.wallet, lang),
                    value: snapshot.walletBalance > 0 ? WidgetCopy.tzs(snapshot.walletBalance) : WidgetCopy.text(.topUp, lang)
                )
            }
            Link(destination: WidgetLink.wallet) {
                MoneyTile(
                    object: snapshot.paymentKind == "cash" || snapshot.paymentKind == nil ? .coins : .wallet,
                    label: WidgetCopy.text(.payWith, lang),
                    value: WidgetCopy.payment(snapshot.paymentMethod, kind: snapshot.paymentKind, lang)
                )
            }
        }
    }
}

/// Flat hairline tile: 3D object, small grey label, bold value. Two sit side by side.
private struct MoneyTile: View {
    let object: WidgetIcon3D.Object
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            WidgetIcon3D(object: object, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(WidgetType.label)
                    .foregroundStyle(WidgetPalette.inkSecondary)
                    .lineLimit(1)
                Text(value)
                    .font(WidgetType.bodySemibold.monospacedDigit())
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
        .background(WidgetPalette.canvas, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WidgetPalette.border, lineWidth: 1))
    }
}

/// "Pay with M-Pesa ........ TZS 9,500" under the live ride.
private struct PaymentLine: View {
    let method: String
    let kind: String?
    let trailing: String
    let lang: WidgetLanguage

    var body: some View {
        HStack(spacing: 12) {
            WidgetIcon3D(object: kind == "cash" ? .coins : .wallet, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(WidgetCopy.text(.payWith, lang))
                    .font(WidgetType.label)
                    .foregroundStyle(WidgetPalette.inkSecondary)
                Text(method)
                    .font(WidgetType.bodySemibold)
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(WidgetType.fare)
                .foregroundStyle(WidgetPalette.ink)
        }
        .frame(height: 56)
    }
}
