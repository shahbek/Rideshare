import AppIntents
import MapboxMaps
import SwiftUI

@main
struct TwendeApp: App {
    @State private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        TwendeFont.registerBundledFonts()
        // Public (pk.) Mapbox token provided by the project owner.
        MapboxOptions.accessToken = "pk.eyJ1Ijoic2hhaGJla21pcnUiLCJhIjoiY211YTBma2ZzMTloazJ3czdzeTQwZmxnZSJ9.-MJ4SGimPkMpq8itj76rVg"
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        // Siri and Shortcuts launch the app in the background to run an intent; no scene is connected then,
        // so view lifecycle hooks never fire. Registering here guarantees intents always find the store.
        IntentEnvironment.register(environment)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
                .onOpenURL { url in
                    DeepLinkRouter.handle(url, env: environment)
                }
                .task {
                    // The store is loaded synchronously in init, so the phrase parameters Siri learns
                    // (saved places, favourite drivers) are complete on the first refresh.
                    WidgetBridge.refreshShortcutParameters(force: true)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // The widget renders whatever was published last; make sure leaving the app always leaves a
            // fresh snapshot behind (pickup ETAs, wallet, the ride the passenger is on).
            // Keep this path tiny: work that outlives the background grace period gets the app killed.
            switch phase {
            case .background:
                environment.enterBackground()
                WidgetBridge.publishForBackground(environment)
            case .active:
                environment.enterForeground()
            default:
                break
            }
        }
    }
}
