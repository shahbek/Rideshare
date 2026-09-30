import SwiftUI

/// Root switch: onboarding until the passenger is signed in, then the map shell.
struct ContentView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            if env.settings.isOnboarded {
                MainShellView()
                    .transition(.opacity)
            } else {
                OnboardingFlowView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: env.settings.isOnboarded)
        .readsFoldLayout()
        .preferredColorScheme(.light)
        .tint(TwendeColor.primary)
        .task {
            // Defer optional catalogue renders until a real root view is mounted.
            env.sprites.start()
        }
        .onAppear {
            #if DEBUG
            print("[TwendeStartup] root_mounted onboarded=\(env.settings.isOnboarded)")
            #endif
            if env.settings.isOnboarded {
                env.startServices()
            }
        }
    }
}

/// Native tabs with independent navigation; booking and live rides retain their focused map flow.
struct MainShellView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var activityNavigation: MenuNavigation = MenuNavigation()
    @State private var accountNavigation: MenuNavigation = MenuNavigation()

    private var isFocusedRideFlow: Bool {
        !env.flow.path.isEmpty || env.trips.hasLiveTrip || env.trips.isSettling
    }

    var body: some View {
        TabView(selection: Bindable(env.flow).selectedTab) {
            Tab(L(.tabHome), systemImage: "house", value: MainTab.home) {
                homeStack
                    .toolbar(isFocusedRideFlow ? .hidden : .visible, for: .tabBar)
            }
            Tab(L(.tabActivity), systemImage: "clock.arrow.circlepath", value: MainTab.activity) {
                MenuSplitStack(placeholder: .logbook) {
                    TripHistoryView(isActivityRoot: true)
                }
                .environment(activityNavigation)
            }
            Tab(L(.account), systemImage: "person.crop.circle", value: MainTab.account) {
                SideMenuView(isModal: false)
                    .environment(accountNavigation)
            }
        }
        .tint(TwendeColor.ink)
        .onChange(of: env.flow.selectedTab) { _, _ in Haptics.selection() }
        .onChange(of: isFocusedRideFlow) { _, focused in
            if focused { env.flow.selectedTab = .home }
        }
        .onAppear {
            if isFocusedRideFlow { env.flow.selectedTab = .home }
            syncChat()
        }
        .toast(Bindable(env.flow).toast)
        .fullScreenCover(isPresented: Bindable(env.flow).isMenuPresented) {
            SideMenuView()
                .environment(env.flow.menuNavigation)
        }
        .sheet(item: Bindable(env.flow).activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .sheet(isPresented: settlingBinding) {
            if let trip = env.trips.activeTrip {
                TripCompleteSheet(trip: trip)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(DeviceMetrics.displayCornerRadius)
                    .presentationBackground(TwendeColor.surface)
                    .interactiveDismissDisabled()
            }
        }
        .onChange(of: chatTripKey) { _, _ in syncChat() }
        .onChange(of: env.trips.isSettling) { _, settling in
            // Never stack the completion sheet on top of another sheet.
            if settling { env.flow.activeSheet = nil }
        }
        .onChange(of: env.trips.lastCancellation) { _, cancellation in
            guard let cancellation else { return }
            let text = cancellation.fee > 0
                ? L(.cancelledWithFee, Format.tzs(cancellation.fee))
                : L(.cancelledNoFee)
            env.flow.showToast(text, symbol: "xmark.circle.fill", tint: .neutral)
            env.trips.acknowledgeCancellation()
        }
        .onChange(of: env.trips.justArchivedTripID) { _, id in
            guard let id, let trip = env.store.trip(id: id), trip.phase == .rated else {
                if id != nil { env.trips.acknowledgeArchive() }
                return
            }
            if trip.rating != nil {
                env.flow.showToast(L(.thanksForRating), symbol: "star.fill")
            }
            env.trips.acknowledgeArchive()
        }
        .modifier(SystemSurfacesSync(env: env))
        .onChange(of: env.drivers.recentlyOnlineDriverID) { _, id in
            guard let id, let driver = env.drivers.driver(id: id) else { return }
            if env.store.notifiesWhenOnline(id) {
                env.flow.showToast(L(.driverNowOnline, driver.firstName), symbol: "bell.badge.fill")
            }
            env.drivers.clearRecentlyOnline()
        }
    }

    private var homeStack: some View {
        NavigationStack(path: Bindable(env.flow).path) {
            Group {
                if let trip = env.trips.activeTrip, trip.phase.isLive {
                    ActiveTripView(trip: trip)
                        .transition(.opacity)
                } else {
                    HomeView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: env.trips.hasLiveTrip)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: BookingRoute.self) { route in
                Group {
                    switch route {
                    case .search: DestinationSearchView()
                    case .setOnMap: SetOnMapView()
                    case .confirmPickup: ConfirmPickupView()
                    case .rideOptions: RideOptionsView()
                    }
                }
                .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    /// Chat opens once a driver is assigned and closes when the ride ends.
    private var chatTripKey: String? {
        guard let trip = env.trips.activeTrip, trip.phase.isLive, trip.driverID != nil else { return nil }
        return trip.id
    }

    private func syncChat() {
        if let id = chatTripKey, let driver = env.trips.assignedDriver {
            env.chat.attach(tripID: id, driverName: driver.firstName)
        } else {
            env.chat.detach()
            if env.flow.activeSheet == .chat { env.flow.activeSheet = nil }
        }
    }

    private var settlingBinding: Binding<Bool> {
        Binding(
            get: { env.trips.isSettling && env.flow.activeSheet == nil },
            set: { _ in }
        )
    }

    @ViewBuilder
    private func sheetContent(for sheet: MainSheet) -> some View {
        switch sheet {
        case .zeroCommission:
            ZeroCommissionSheet().appSheet(detents: [.medium, .large])
        case .fareBreakdown:
            FareBreakdownSheet().appSheet(detents: [.medium, .large])
        case .paymentPicker:
            PaymentPickerSheet().appSheet(detents: [.medium, .large])
        case .promoCode:
            PromoCodeSheet().appSheet(detents: [.medium])
        case .cancelReason:
            CancelReasonSheet().appSheet(detents: [.large])
        case .sos:
            SOSSheet().appSheet(detents: [.medium, .large])
        case .chat:
            RideChatSheet().appSheet(detents: [.medium, .large])
        case .outOfZone:
            OutOfZoneSheet().appSheet(detents: [.medium])
        case .quickRequest(let driverID):
            if let driver = env.drivers.driver(id: driverID) {
                QuickRequestSheet(driver: driver).appSheet(detents: [.medium, .large])
            }
        case .billboard(let adID):
            if let ad = BillboardCatalogue.ad(id: adID) {
                BillboardAdSheet(ad: ad).appSheet(detents: [.medium, .large])
            }
        }
    }
}

/// Keeps the Home Screen widget and Siri suggestions in step with the ride, wallet, places and favourites.
private struct SystemSurfacesSync: ViewModifier {
    let env: AppEnvironment

    func body(content: Content) -> some View {
        content
            .onChange(of: env.trips.activeTrip) { _, _ in
                WidgetBridge.publish(env)
                SiriContextPublisher.publish(env)
                LiveActivityBridge.sync(env)
            }
            .onChange(of: env.trips.driverHeading) { _, _ in LiveActivityBridge.sync(env) }
            .onChange(of: env.trips.driverEtaMinutes) { _, _ in LiveActivityBridge.sync(env) }
            .onChange(of: env.trips.remainingTripMinutes) { _, _ in LiveActivityBridge.sync(env) }
            .onChange(of: env.store.data.walletBalance) { _, _ in WidgetBridge.publish(env) }
            .onChange(of: env.store.data.savedPlaces) { _, _ in WidgetBridge.publish(env) }
            .onChange(of: env.store.data.recents) { _, _ in WidgetBridge.publish(env) }
            .onChange(of: env.store.data.history.count) { _, _ in WidgetBridge.publish(env) }
            .onChange(of: env.store.data.favouriteDriverIDs) { _, _ in WidgetBridge.publish(env) }
            .onChange(of: env.store.data.profile?.name) { _, _ in WidgetBridge.publish(env) }
            .onChange(of: env.settings.language) { _, _ in WidgetBridge.publishNow(env) }
            .onChange(of: env.drivers.recentlyOnlineDriverID) { _, _ in WidgetBridge.publish(env) }
            .onChange(of: env.flow.pickup) { _, _ in WidgetBridge.publish(env) }
            .onChange(of: driverAvailability) { _, _ in WidgetBridge.publish(env) }
            .onAppear {
                WidgetBridge.publishNow(env)
                SiriContextPublisher.publish(env)
                LiveActivityBridge.sync(env)
            }
    }

    /// Online drivers per service family near the pickup — the widget shows these pickup times, so a
    /// fleet status change (a favourite coming online, a driver leaving the radius) republishes.
    private var driverAvailability: [Int] {
        ServiceFamily.allCases.map { family in
            env.drivers.candidates(tier: family.defaultTier, near: env.flow.pickup.point, favouriteIDs: []).count
        }
    }
}

#Preview {
    ContentView()
        .environment(AppEnvironment())
}
