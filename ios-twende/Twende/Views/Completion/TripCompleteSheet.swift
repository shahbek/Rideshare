import SwiftUI

/// B10 — fare, badge restated with the exact amount, tip, and payment confirmation.
struct TripCompleteSheet: View {
    @Environment(AppEnvironment.self) private var env
    let trip: Trip
    @State private var isToppingUp: Bool = false

    private var driver: Driver? { env.trips.assignedDriver }
    private let tipOptions: [Int] = [0, 500, 1_000, 2_000]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let driver {
                    driverLine(driver)
                }
                FareBreakdownList(quote: trip.quote, tip: trip.tip)
                ZeroCommissionBadge(mode: trip.paymentState == .confirmed ? .settled(trip.totalDue) : .due(trip.totalDue))
                if trip.phase == .completed {
                    tipSection
                }
                paymentSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) {
                primaryAction
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(TwendeColor.surface)
        }
        .interactiveDismissDisabled()
        // "Tip 1,000 shillings", "rate this five stars", "how much was this?" all resolve to this ride.
        .primaryOnScreen(TripEntity(trip, env: env), activity: TwendeActivity.rideEnd, title: trip.destination.name)
        .sheet(isPresented: $isToppingUp) {
            WalletTopUpSheet()
                .appSheet(detents: [.large])
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(TwendeColor.primary, in: .circle)
                Text(L(.tripCompleteTitle))
                    .font(TwendeFont.display)
                    .foregroundStyle(TwendeColor.ink)
            }
            HStack(spacing: 6) {
                Text(trip.destination.name)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Text("·")
                    .foregroundStyle(TwendeColor.inkTertiary)
                Text(Format.dateTime(trip.completedAt ?? Date()))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
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
            PlateView(plate: driver.vehicle.plate, size: .small)
        }
    }

    private var tipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L(.addTip))
            HStack(spacing: 8) {
                ForEach(tipOptions, id: \.self) { amount in
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(duration: 0.3)) { env.trips.setTip(amount) }
                    } label: {
                        Text(amount == 0 ? L(.noTip) : Format.grouped(amount))
                            .font(TwendeFont.captionMedium)
                            .monospacedDigit()
                            .foregroundStyle(trip.tip == amount ? .white : TwendeColor.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(trip.tip == amount ? TwendeColor.primary : TwendeColor.surfaceAlt, in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.pressableCard)
                }
            }
            Text(L(.tipNote))
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.inkSecondary)
        }
    }

    private var paymentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L(.payment))
            HStack(spacing: 12) {
                PaymentTile(method: trip.paymentMethod)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.paymentMethod.displayName)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                    paymentStatusLabel
                }
                Spacer()
                Text(Format.tzs(trip.totalDue))
                    .font(TwendeFont.fareLarge)
                    .foregroundStyle(TwendeColor.ink)
                    .contentTransition(.numericText())
            }
            .padding(14)
            .cardSurface(cornerRadius: 14)

            if trip.phase == .paymentPending, trip.paymentMethod.isMobileMoney {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L(.mmRidePromptBody, Format.tzs(trip.totalDue), trip.paymentMethod.displayName))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let payment = env.payments.latestPayment(forTrip: trip.id), payment.status == .pending {
                        PromptCountdown(expiry: payment.expiryDate)
                        if !payment.live {
                            SimulatedPinPrompt(payment: payment)
                        }
                    }
                }
                .transition(.opacity)
            }

            if trip.paymentState == .failed {
                Label(
                    trip.paymentMethod == .wallet
                        ? L(.walletShortBody, Format.tzs(env.store.walletBalance))
                        : (env.trips.mobileMoneyError ?? L(.paymentFailedBody)),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.amberText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var paymentStatusLabel: some View {
        switch trip.paymentState {
        case .notStarted:
            Text(notStartedHint)
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(TwendeColor.primary)
                Text(L(.paymentPendingBody))
            }
            .font(TwendeFont.caption)
            .foregroundStyle(TwendeColor.inkSecondary)
        case .confirmed:
            Label(trip.paymentMethod == .wallet ? L(.walletPaid) : L(.paymentConfirmed), systemImage: "checkmark.circle.fill")
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.badgeForeground)
        case .failed:
            Label(L(.paymentFailed), systemImage: "xmark.circle.fill")
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.danger)
        }
    }

    private var notStartedHint: String {
        switch trip.paymentMethod {
        case .cash: L(.payDriverInCash)
        case .wallet: L(.walletBalanceDetail, Format.tzs(env.store.walletBalance))
        default: L(.tapToPay)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch trip.phase {
        case .completed:
            if trip.paymentMethod == .cash {
                Button(L(.confirmCashPaid, Format.tzs(trip.totalDue))) {
                    Haptics.medium()
                    env.trips.confirmCashPayment()
                }
                .buttonStyle(.twendePrimary)
            } else if trip.paymentMethod == .wallet {
                if env.store.walletCanCover(trip.totalDue) {
                    Button(L(.payWithWallet, Format.tzs(trip.totalDue))) {
                        Haptics.medium()
                        env.trips.payWithWallet()
                    }
                    .buttonStyle(.twendePrimary)
                    if trip.paymentState == .failed {
                        Button(L(.payCashInstead)) {
                            env.trips.switchPaymentToCash()
                        }
                        .buttonStyle(.twendeGhost)
                    }
                } else {
                    // Balance short: top up in a nested sheet, or fall back to cash without leaving settlement.
                    Button(L(.walletShortTopUp)) {
                        Haptics.tap()
                        isToppingUp = true
                    }
                    .buttonStyle(.twendePrimary)
                    Button(L(.payCashInstead)) {
                        env.trips.switchPaymentToCash()
                    }
                    .buttonStyle(.twendeGhost)
                }
            } else {
                Button(trip.paymentState == .failed ? L(.retryPayment) : L(.payWithMethod, trip.paymentMethod.displayName)) {
                    Haptics.medium()
                    env.trips.payWithMobileMoney()
                }
                .buttonStyle(.twendePrimary)
                if trip.paymentState == .failed {
                    Button(L(.payCashInstead)) {
                        env.trips.switchPaymentToCash()
                    }
                    .buttonStyle(.twendeGhost)
                }
            }
        case .paymentPending:
            Button {
            } label: {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(L(.waitingForConfirmation))
                }
            }
            .buttonStyle(.twendePrimary)
            .disabled(true)
        case .paymentConfirmed:
            RatingPanel(trip: trip)
        default:
            EmptyView()
        }
    }
}

/// B11 — stars, reason chips under 4★, favourite prompt on 5★, skip.
struct RatingPanel: View {
    @Environment(AppEnvironment.self) private var env
    let trip: Trip
    @State private var stars: Int = 0
    @State private var reasons: Set<RatingReason> = []
    @State private var addFavourite: Bool = true

    private var driver: Driver? { env.trips.assignedDriver }
    private var isAlreadyFavourite: Bool {
        driver.map { env.store.isFavourite($0.id) } ?? true
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(driver.map { L(.rateDriver, $0.firstName) } ?? L(.rateTrip))
                .font(TwendeFont.title)
                .foregroundStyle(TwendeColor.ink)
            StarPicker(rating: $stars)

            if stars > 0 && stars < 4 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(.whatWentWrong)).sectionLabelStyle()
                    FlowChips(items: RatingReason.allCases) { reason in
                        ChipButton(title: L(reason.key), isSelected: reasons.contains(reason)) {
                            if reasons.contains(reason) { reasons.remove(reason) } else { reasons.insert(reason) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if stars == 5, !isAlreadyFavourite, let driver {
                Toggle(isOn: $addFavourite) {
                    Label(L(.addToMyDrivers, driver.firstName), systemImage: "star.fill")
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                }
                .tint(TwendeColor.primary)
                .padding(14)
                .cardSurface(cornerRadius: 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button(L(.submitRating)) {
                Haptics.success()
                env.trips.rate(stars: stars, reasons: Array(reasons), addFavourite: stars == 5 && addFavourite && !isAlreadyFavourite)
            }
            .buttonStyle(.twendePrimary)
            .disabled(stars == 0)

            Button(L(.skip)) {
                env.trips.skipRating()
            }
            .buttonStyle(.twendeGhost)
        }
        .animation(.spring(duration: 0.35), value: stars)
    }
}

/// Wraps chips onto multiple lines.
struct FlowChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
