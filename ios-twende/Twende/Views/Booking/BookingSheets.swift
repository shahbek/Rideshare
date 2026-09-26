import SwiftUI

/// B4a — why the driver keeps 100%.
struct ZeroCommissionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(TwendeColor.primary)
                    .frame(width: 52, height: 52)
                    .background(TwendeColor.primaryTint, in: .circle)
                Text(L(.zeroCommissionTitle))
                    .font(TwendeFont.display)
                    .foregroundStyle(TwendeColor.ink)
            }
            Text(L(.zeroCommissionBody))
                .font(TwendeFont.body)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ExplainerRow(symbol: "person.fill.checkmark", title: L(.zeroCommissionPoint1Title), detail: L(.zeroCommissionPoint1Body))
                ExplainerRow(symbol: "doc.text.fill", title: L(.zeroCommissionPoint2Title), detail: L(.zeroCommissionPoint2Body))
                ExplainerRow(symbol: "star.fill", title: L(.zeroCommissionPoint3Title), detail: L(.zeroCommissionPoint3Body))
            }

            HStack {
                Text(L(.exampleFare))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Spacer()
                Text("TZS 14,125 → TZS 14,125")
                    .font(TwendeFont.fare)
                    .foregroundStyle(TwendeColor.badgeForeground)
            }
            .padding(14)
            .background(TwendeColor.badgeTint, in: .rect(cornerRadius: 12))

            Spacer(minLength: 0)
            Button(L(.gotIt)) { dismiss() }
                .buttonStyle(.twendePrimary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

private struct ExplainerRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TwendeColor.badgeForeground)
                .frame(width: 36, height: 36)
                .background(TwendeColor.badgeTint, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                Text(detail)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// B4b — itemised fare for the selected tier.
struct FareBreakdownSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L(.fareBreakdownTitle))
                .font(TwendeFont.display)
                .foregroundStyle(TwendeColor.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            if let quote = env.flow.selectedQuote {
                FareBreakdownList(quote: quote, tip: 0)
                Text(L(.fareBreakdownNote))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(L(.close)) { dismiss() }
                .buttonStyle(.twendeSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

/// Reusable itemised list shared by B4b, B10 and the receipt.
struct FareBreakdownList: View {
    let quote: FareQuote
    var tip: Int = 0
    var showsTotal: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L(quote.tier.nameKey), systemImage: quote.tier.symbol)
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Spacer()
                Text("\(Format.distance(quote.distanceKm)) · \(L(.minutesShort, quote.durationMinutes))")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            RowDivider(leading: 0)
            BreakdownRow(title: L(.baseFare), value: Format.tzs(quote.breakdown.base))
            BreakdownRow(title: L(.distanceFare, Format.distance(quote.distanceKm)), value: Format.tzs(quote.breakdown.distance))
            BreakdownRow(title: L(.timeFare, quote.durationMinutes), value: Format.tzs(quote.breakdown.time))
            if quote.breakdown.discount > 0 {
                BreakdownRow(title: L(.promoDiscount), value: Format.signedTZS(-quote.breakdown.discount), tint: TwendeColor.badgeForeground)
            }
            if tip > 0 {
                BreakdownRow(title: L(.tip), value: Format.tzs(tip))
            }
            if showsTotal {
                RowDivider(leading: 0)
                BreakdownRow(title: L(.total), value: Format.tzs(quote.fare + tip), emphasis: true)
            }
        }
        .padding(16)
        .cardSurface()
    }
}

/// B4c — choose cash, the Twende wallet or a linked mobile-money rail for this ride.
struct PaymentPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private var fare: Int { env.flow.selectedQuote?.fare ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L(.payWith))
                .font(TwendeFont.display)
                .foregroundStyle(TwendeColor.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(spacing: 0) {
                ForEach(Array(env.store.availablePaymentMethods.enumerated()), id: \.element.id) { index, method in
                    if index > 0 {
                        RowDivider(leading: 54)
                    }
                    PaymentOptionRow(
                        method: method,
                        detail: detail(for: method),
                        isSelected: env.flow.paymentMethod == method,
                        isWarning: method == .wallet && !env.store.walletCanCover(fare)
                    ) {
                        Haptics.selection()
                        env.flow.paymentMethod = method
                        dismiss()
                    }
                }
            }
            HStack(spacing: 20) {
                Button {
                    dismiss()
                    env.flow.openMenuAfterSheet(at: .wallet)
                } label: {
                    Label(L(.topUpWallet), systemImage: "plus.circle.fill")
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.badgeForeground)
                        .frame(minHeight: 48)
                }
                Button {
                    dismiss()
                    env.flow.openMenuAfterSheet(at: .payments)
                } label: {
                    Label(L(.addMobileMoney), systemImage: "iphone")
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.badgeForeground)
                        .frame(minHeight: 48)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func detail(for method: PaymentMethod) -> String {
        switch method {
        case .cash:
            return L(.cashDetail)
        case .wallet:
            let balance = env.store.walletBalance
            if balance == 0 { return L(.walletEmptyDetail) }
            if !env.store.walletCanCover(fare) { return L(.walletInsufficient, Format.tzs(balance)) }
            return L(.walletBalanceDetail, Format.tzs(balance))
        default:
            if let account = env.store.account(for: method) { return Format.phone(account.phone) }
            return method.operatorName
        }
    }
}

struct PaymentOptionRow: View {
    let method: PaymentMethod
    let detail: String
    let isSelected: Bool
    /// Tints the detail line amber, e.g. a wallet balance that cannot cover the fare.
    var isWarning: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                PaymentTile(method: method)
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.displayName)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                    Text(detail)
                        .font(TwendeFont.caption)
                        .foregroundStyle(isWarning ? TwendeColor.amberText : TwendeColor.inkSecondary)
                }
                Spacer()
                RadioDot(isSelected: isSelected)
            }
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// B4d — promo code entry.
struct PromoCodeSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var code: String = ""
    @State private var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L(.promoCode))
                .font(TwendeFont.display)
                .foregroundStyle(TwendeColor.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)

            if let promo = env.flow.promo {
                HStack(spacing: 12) {
                    Image(systemName: "tag.fill")
                        .foregroundStyle(TwendeColor.badgeForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(promo.code)
                            .font(TwendeFont.bodySemibold)
                            .foregroundStyle(TwendeColor.ink)
                        Text(L(promo.title))
                            .font(TwendeFont.caption)
                            .foregroundStyle(TwendeColor.inkSecondary)
                    }
                    Spacer()
                    Button(L(.remove)) {
                        env.flow.removePromo()
                        dismiss()
                    }
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.danger)
                }
                .padding(14)
                .background(TwendeColor.badgeTint, in: .rect(cornerRadius: 12))
            } else {
                TwendeTextField(
                    title: L(.enterCode),
                    text: $code,
                    placeholder: "KARIBU",
                    autocapitalization: .characters,
                    autoFocus: true
                )
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.circle.fill")
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.danger)
                }
                Text(L(.promoHint))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }

            Spacer(minLength: 0)
            if env.flow.promo == nil {
                Button(L(.applyCode)) {
                    if env.flow.applyPromo(code: code) {
                        Haptics.success()
                        dismiss()
                    } else {
                        Haptics.error()
                        errorText = L(.promoInvalid)
                    }
                }
                .buttonStyle(.twendePrimary)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button(L(.close)) { dismiss() }
                    .buttonStyle(.twendeSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

/// G4 — destination outside the Dar es Salaam zone.
struct OutOfZoneSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(TwendeColor.amberText)
                .frame(width: 64, height: 64)
                .background(TwendeColor.amberTint, in: .circle)
            Text(L(.outOfZoneTitle))
                .font(TwendeFont.display)
                .foregroundStyle(TwendeColor.ink)
            Text(L(.outOfZoneBody, env.flow.outOfZonePlace?.name ?? ""))
                .font(TwendeFont.body)
                .foregroundStyle(TwendeColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let place = env.flow.outOfZonePlace, !env.store.hasZoneNotification(place.name) {
                Button(L(.notifyMeZone)) {
                    Haptics.success()
                    env.store.notifyWhenZoneOpens(place.name)
                    dismiss()
                    env.flow.showToast(L(.notifyMeZoneConfirmed, place.name), symbol: "bell.fill")
                }
                .buttonStyle(.twendePrimary)
            } else {
                Label(L(.notifyMeZoneAlready), systemImage: "bell.fill")
                    .font(TwendeFont.captionMedium)
                    .foregroundStyle(TwendeColor.badgeForeground)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            Button(L(.chooseAnotherPlace)) { dismiss() }
                .buttonStyle(.twendeGhost)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
}

/// Quick request opened from a favourite's avatar on Home.
struct QuickRequestSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let driver: Driver

    private var etaMinutes: Int {
        RoutingService.pickupEtaMinutes(from: driver.position, to: env.flow.pickup.point)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                TierGlyph(tier: driver.tier, width: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(driver.firstName)
                        .font(TwendeFont.title)
                        .foregroundStyle(TwendeColor.ink)
                    RatingLabel(rating: driver.rating, trips: driver.trips)
                    DriverStatusChip(status: driver.status)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                InfoTile(symbol: "location.fill", title: L(.awayFromYou), value: Format.distance(driver.position.distanceKm(to: env.flow.pickup.point) * RoutingService.roadFactor))
                InfoTile(symbol: "clock.fill", title: L(.pickupEta), value: L(.minutesShort, etaMinutes))
            }
            HStack(spacing: 12) {
                TierGlyph(tier: driver.tier, width: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(driver.vehicle.description)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                    Text(L(driver.tier.nameKey))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                Spacer()
                PlateView(plate: driver.vehicle.plate, size: .small)
            }
            .padding(14)
            .cardSurface(cornerRadius: 12)
            Spacer(minLength: 0)
            Button(L(.requestDriver, driver.firstName)) {
                Haptics.medium()
                dismiss()
                env.flow.requestDriver(driver)
            }
            .buttonStyle(.twendePrimary)
            .disabled(driver.status != .online)
            Button(L(.viewProfile)) {
                dismiss()
                env.flow.openMenuAfterSheet(at: .driverDetail(driver.id))
            }
            .buttonStyle(.twendeGhost)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

/// Compact stat tile used on driver sheets.
struct InfoTile: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.inkSecondary)
            Text(value)
                .font(TwendeFont.headline)
                .foregroundStyle(TwendeColor.ink)
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
    }
}
