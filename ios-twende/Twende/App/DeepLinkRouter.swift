import Foundation

/// Routes `zuri://` links from the widget (and Siri "open" results) to the right screen.
enum DeepLinkRouter {
    @MainActor
    static func handle(_ url: URL, env: AppEnvironment) {
        guard url.scheme == WidgetLink.scheme, env.settings.isOnboarded else { return }
        let id = url.pathComponents.dropFirst().first.flatMap { $0.removingPercentEncoding }
        env.flow.closeMenu()
        env.flow.activeSheet = nil
        switch url.host {
        case "search":
            guard !env.trips.hasLiveTrip else { env.flow.selectedTab = .home; return }
            env.flow.beginSearch()
        case "place":
            guard let id, !env.trips.hasLiveTrip, let place = PlaceResolver.place(id: id, in: env) else { return }
            env.flow.choose(destination: place.place)
        case "trip":
            guard let id else { return }
            if env.trips.activeTrip?.id == id {
                env.flow.selectedTab = .home
            } else if env.store.trip(id: id) != nil {
                env.flow.openMenu(at: .tripDetail(id))
            }
        case "driver":
            guard let id, env.drivers.driver(id: id) != nil else { return }
            env.flow.openMenu(at: .driverDetail(id))
        case "wallet":
            env.flow.openMenu(at: .wallet)
        case "history":
            env.flow.selectedTab = .activity
        default:
            env.flow.selectedTab = .home
        }
    }
}
