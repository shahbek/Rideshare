import SwiftUI

/// Destinations inherit the originating stack's MenuNavigation, preserving native back behavior.
struct MenuDestinationView: View {
    @Environment(AppEnvironment.self) private var env
    let route: MenuRoute

    var body: some View {
        switch route {
        case .profile: ProfileView()
        case .history: TripHistoryView()
        case .tripDetail(let id):
            if let trip = env.store.trip(id: id) {
                TripDetailView(trip: trip)
            } else {
                MenuScreen(title: L(.receipt)) {
                    EmptyStateView(icon: .receipt, title: L(.noTripsTitle), message: L(.noTripsBody))
                }
            }
        case .drivers: MyDriversView()
        case .driverDetail(let id):
            if let driver = env.drivers.driver(id: id) { DriverDetailView(driverID: driver.id) }
        case .payments: PaymentsView()
        case .wallet: WalletView()
        case .savedPlaces: SavedPlacesView()
        case .editSavedPlace(let id): EditSavedPlaceView(savedPlaceID: id)
        case .promotions: PromotionsView()
        case .safety: SafetyCentreView()
        case .support: SupportView()
        case .settings: SettingsView()
        case .offlineMaps: OfflineMapsView()
        case .siriGuide: SiriGuideView()
        case .identity: IdentityVerificationView()
        }
    }
}
