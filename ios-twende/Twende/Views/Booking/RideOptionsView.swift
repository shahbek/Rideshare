import SwiftUI

/// B4 — timed route banners, the selected transport fleet and a two-state panel with a fixed checkout footer.
struct RideOptionsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: MapCameraTarget = .automatic
    @State private var isPanelExpanded: Bool = true
    @State private var panelHeight: CGFloat = 480
    @State private var dragTranslation: CGFloat = 0
    @State private var expandedListHeight: CGFloat = 280
    @State private var headerHeight: CGFloat = 44
    @State private var footerHeight: CGFloat = 200
    @State private var mapHeight: CGFloat = 844
    @State private var reframeTask: Task<Void, Never>? = nil
    @Environment(\.foldLayout) private var foldLayout

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    TripMapView(
                        camera: $camera,
                        pickup: env.flow.pickup.point,
                        destination: env.flow.destination?.point,
                        stops: env.flow.stops.map(\.point),
                        routePoints: env.flow.route?.points ?? [],
                        nearbyDrivers: env.flow.rideOptionDrivers,
                        pickupBannerText: pickupBanner,
                        destinationBannerText: dropoffBanner(at: timeline.date),
                        interactionModes: [.pan, .zoom]
                    )
                }
                .ignoresSafeArea()

                HStack(alignment: .top) {
                    MapCircleButton(systemImage: "arrow.left", accessibilityLabel: L(.back)) {
                        dismiss()
                    }
                    Spacer()
                    if let route = env.flow.route, let destination = env.flow.destination {
                        routeChip(route: route, destination: destination)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .mapPanel {
                optionsPanel(availableHeight: geometry.size.height)
            }
            .onGeometryChange(for: CGFloat.self) { _ in
                geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            } action: { height in
                mapHeight = height
                scheduleReframe()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .primaryOnScreen(env.flow.destination.map { PlaceEntity($0) }, activity: TwendeActivity.booking, title: env.flow.destination?.name ?? "")
        .onAppear { scheduleReframe() }
        .onDisappear { reframeTask?.cancel() }
        .task {
            guard !env.settings.hasSeenZeroCommissionExplainer else { return }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard env.flow.activeSheet == nil else { return }
            env.settings.hasSeenZeroCommissionExplainer = true
            env.flow.activeSheet = .zeroCommission
        }
        .onChange(of: env.flow.route?.points) { _, _ in scheduleReframe() }
        .onChange(of: env.flow.waypoints) { _, _ in scheduleReframe() }
        .onChange(of: panelHeight) { _, _ in scheduleReframe() }
        .onChange(of: foldLayout) { _, _ in scheduleReframe() }
    }

    private var pickupBanner: String {
        guard let quote = env.flow.selectedQuote else { return L(.pickupLabel) }
        guard quote.hasDriversNearby else { return L(.pickupUnavailable) }
        let minutes = max(1, quote.pickupEtaMinutes)
        return minutes == 1 ? L(.pickupInOneMinute) : L(.pickupInMinutes, minutes)
    }

    private func dropoffBanner(at now: Date) -> String {
        guard let quote = env.flow.selectedQuote else { return L(.dropoffLabel) }
        guard let arrival = quote.estimatedDropoff(at: now) else { return L(.dropoffUnavailable) }
        return L(.dropoffAtTime, Format.time(arrival))
    }

    private func optionsPanel(availableHeight: CGFloat) -> some View {
        let listHeight = max(84, min(360, availableHeight * 0.72 - headerHeight - footerHeight))
        let restingHeight: CGFloat = isPanelExpanded ? listHeight : 84
        let visibleHeight = min(listHeight, max(84, restingHeight - dragTranslation))
        return VStack(spacing: 0) {
            panelHandle
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(env.flow.rideOptionQuotes.filter { isPanelExpanded || $0.tier == env.flow.selectedTier }) { quote in
                            tierRow(quote)
                                .id(quote.tier)
                                .transition(.opacity)
                        }
                        if isPanelExpanded, let preferred = env.flow.preferredDriver {
                            preferredNotice(preferred).padding(.horizontal, 16)
                                .transition(.opacity)
                        }
                    }
                    .padding(.vertical, isPanelExpanded ? 2 : 0)
                }
                .scrollDisabled(!isPanelExpanded)
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("rideOptions.list")
                .onChange(of: isPanelExpanded) { _, expanded in
                    if !expanded { proxy.scrollTo(env.flow.selectedTier, anchor: .top) }
                }
            }
            .frame(height: visibleHeight, alignment: .top)
            .clipped()
            checkoutFooter
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: sheetRadius, topTrailingRadius: sheetRadius)
                .fill(TwendeColor.surface)
                .shadow(color: .black.opacity(0.10), radius: 16, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(height - panelHeight) > 1 { panelHeight = height }
        }
        .onChange(of: listHeight, initial: true) { _, height in expandedListHeight = height }
    }

    private var panelHandle: some View {
        Button {
            setPanelExpanded(!isPanelExpanded)
        } label: {
            Color.clear
                .frame(height: 44)
                .overlay { SheetGrabber().allowsHitTesting(false) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(isPanelExpanded ? .collapseRideOptions : .expandRideOptions))
        .accessibilityIdentifier("rideOptions.toggle")
        .highPriorityGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width) {
                        dragTranslation = value.translation.height
                    }
                }
                .onEnded { value in
                    let start: CGFloat = isPanelExpanded ? expandedListHeight : 84
                    let projected = start - value.predictedEndTranslation.height
                    setPanelExpanded(projected > (expandedListHeight + 84) / 2)
                }
        )
    }

    private var checkoutFooter: some View {
        VStack(spacing: 8) {
            ZeroCommissionBadge(mode: .promise) { env.flow.activeSheet = .zeroCommission }
            paymentRow
            Button {
                Haptics.medium()
                env.flow.requestRide()
            } label: {
                HStack {
                    Text(requestTitle)
                    Spacer()
                    if let quote = env.flow.selectedQuote {
                        Text(Format.tzs(quote.fare))
                            .font(TwendeFont.fare)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 20)
            }
            .buttonStyle(.twendePrimary)
            .disabled(env.flow.selectedQuote == nil)
            .accessibilityIdentifier("rideOptions.request")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TwendeColor.surface)
    }

    private func setPanelExpanded(_ expanded: Bool) {
        if expanded != isPanelExpanded { Haptics.selection() }
        withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.92)) {
            isPanelExpanded = expanded
            dragTranslation = 0
        }
    }

    // MARK: Pieces

    private func routeChip(route: RouteResult, destination: Place) -> some View {
        Button {
            Haptics.tap()
            env.flow.activeSheet = .fareBreakdown
        } label: {
            HStack(spacing: 8) {
                if env.flow.isRefiningRoute {
                    ProgressView().controlSize(.mini).tint(TwendeColor.inkSecondary)
                } else {
                    Icon3DView(icon: .map, size: 24)
                }
                Text("\(Format.distance(route.distanceKm)) · \(L(.minutesShort, route.durationMinutes))")
                    .font(TwendeFont.figtree(14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(TwendeColor.ink)
                    .contentTransition(.numericText())
                if !env.flow.stops.isEmpty {
                    Text(env.flow.stops.count == 1 ? L(.viaOneStop) : L(.viaStops, env.flow.stops.count))
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background {
                Capsule()
                    .fill(TwendeColor.surface)
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            }
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel(L(.fareDetails))
    }

    private var tierList: some View {
        VStack(spacing: 8) {
            ForEach(env.flow.rideOptionQuotes) { quote in
                tierRow(quote)
            }
        }
    }

    private func tierRow(_ quote: FareQuote) -> some View {
        TierRow(
            quote: quote,
            isSelected: env.flow.selectedTier == quote.tier,
            isRecommended: quote.tier == .economy && env.flow.preferredDriverID == nil,
            isLocked: env.flow.preferredDriverID != nil && env.flow.preferredDriver?.tier != quote.tier
        ) {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) {
                env.flow.selectedTier = quote.tier
            }
        }
        .accessibilityIdentifier("rideOptions.tier.\(quote.tier.rawValue)")
        // Each priced row is an on-screen quote, so "book the comfort one" resolves to this exact fare.
        .onScreenEntity(FareQuoteEntity(quote, pickup: env.flow.pickup, destination: env.flow.destination ?? env.flow.pickup))
    }

    private var paymentRow: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.tap()
                env.flow.activeSheet = .paymentPicker
            } label: {
                HStack(spacing: 10) {
                    PaymentTile(method: env.flow.paymentMethod, size: 28)
                    Text(env.flow.paymentMethod.displayName)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TwendeColor.inkSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableCard)
            .accessibilityIdentifier("rideOptions.payment")

            Button {
                Haptics.tap()
                env.flow.activeSheet = .promoCode
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: env.flow.promo == nil ? "tag" : "tag.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(env.flow.promo?.code ?? L(.promoCode))
                        .font(TwendeFont.captionMedium)
                        .lineLimit(1)
                }
                .foregroundStyle(env.flow.promo == nil ? TwendeColor.ink : TwendeColor.badgeForeground)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(env.flow.promo == nil ? TwendeColor.surfaceAlt : TwendeColor.primaryTint, in: .capsule)
            }
            .buttonStyle(.pressableCard)
        }
    }

    private func preferredNotice(_ driver: Driver) -> some View {
        HStack(spacing: 10) {
            TierGlyph(tier: driver.tier, width: 32)
            Text(L(.willAskDriverFirst, driver.firstName))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
            Spacer()
        }
    }

    private var requestTitle: String {
        if let driver = env.flow.preferredDriver {
            return L(.requestDriver, driver.firstName)
        }
        return L(.letsGo)
    }

    private func scheduleReframe() {
        reframeTask?.cancel()
        reframeTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            frameRoute()
        }
    }

    private func frameRoute() {
        var points = env.flow.waypoints
        if let route = env.flow.route { points.append(contentsOf: route.points) }
        let fraction = min(max(panelHeight / max(mapHeight, 1), 0.15), 0.72)
        let rect = MapCameraHelper.rect(fitting: points, bottomFraction: fraction, paddingFraction: 0.3, fold: foldLayout)
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .rect(rect)
        }
    }
}

/// One ride tier: vehicle, name, seats + ETA, fare. Selection is a grey fill with a black edge — no green tint.
struct TierRow: View {
    let quote: FareQuote
    let isSelected: Bool
    var isRecommended: Bool = false
    var isLocked: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                TierGlyph(tier: quote.tier, width: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(quote.tier.nameKey))
                        .font(TwendeFont.bodySemibold)
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if isRecommended {
                        Text(L(.recommended))
                            .font(TwendeFont.figtree(11, weight: .medium))
                            .foregroundStyle(TwendeColor.badgeForeground)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    HStack(spacing: 6) {
                        if quote.hasDriversNearby {
                            Text(L(.minutesShort, quote.pickupEtaMinutes))
                        } else {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(L(.fewDriversNearby))
                        }
                        Text("·")
                        Image(systemName: "person.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(quote.tier.seats)")
                    }
                    .font(TwendeFont.figtree(12, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(quote.hasDriversNearby ? TwendeColor.inkSecondary : TwendeColor.amberText)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.tzs(quote.fare))
                        .font(TwendeFont.fare)
                        .foregroundStyle(TwendeColor.ink)
                        .contentTransition(.numericText())
                    if quote.breakdown.discount > 0 {
                        Text(Format.tzs(quote.breakdown.subtotal))
                            .font(TwendeFont.label)
                            .strikethrough()
                            .foregroundStyle(TwendeColor.inkTertiary)
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 84)
            .background(TwendeColor.surface, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? TwendeColor.ink : TwendeColor.border, lineWidth: isSelected ? 2 : 1)
            )
            .padding(.horizontal, 16)
            .opacity(isLocked ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .disabled(isLocked)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Payment glyph: rendered banknotes for cash, the wallet render for the Zuri balance, and the provider's
/// own logo on a white tile for every mobile-money rail so passengers recognise their network instantly.
struct PaymentTile: View {
    let method: PaymentMethod
    var size: CGFloat = 40

    var body: some View {
        switch method {
        case .cash: Icon3DView(icon: .cash, size: size)
        case .wallet: Icon3DView(icon: .wallet, size: size)
        default: MobileMoneyLogo(method: method, size: size)
        }
    }
}

/// A provider logo centred on a white rounded tile with a hairline edge.
struct MobileMoneyLogo: View {
    let method: PaymentMethod
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(Color.white)
            .overlay {
                if let asset = method.logoAsset {
                    Image(asset)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(size * 0.14)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(TwendeColor.border, lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityLabel(method.displayName)
    }
}
