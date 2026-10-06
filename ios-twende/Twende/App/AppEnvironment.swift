import Foundation
import Observation

/// Composition root. Created once by the app and injected through the SwiftUI environment.
@Observable
final class AppEnvironment {
    let settings: AppSettings = AppSettings.shared
    let store: PassengerStore = PassengerStore()
    let drivers: DriverService = DriverService()
    let location: LocationService = LocationService()
    let network: NetworkMonitor = NetworkMonitor()
    let sprites: VehicleSpriteStore = VehicleSpriteStore.shared
    let auth: AuthManager = AuthManager()
    let chat: RideChatService = RideChatService()
    @ObservationIgnored private let accounts = AccountService()
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    let offlineMaps: OfflineMapService
    let payments: MobileMoneyCoordinator
    let trips: TripCoordinator
    let flow: BookingFlow

    init() {
        offlineMaps = OfflineMapService(network: network)
        DioramaDownloadService.shared.configure(maps: offlineMaps)
        payments = MobileMoneyCoordinator(store: store)
        trips = TripCoordinator(drivers: drivers, store: store, network: network, payments: payments)
        flow = BookingFlow(drivers: drivers, store: store, location: location, trips: trips)
        let flow = flow
        payments.announce = { text in flow.showToast(text, symbol: "checkmark.circle.fill") }
        payments.resume()
        store.didChange = { [weak self] data in self?.scheduleBackup(data) }
    }

    // MARK: Account

    /// Debounced upload of the passenger's data to their signed-in account.
    private func scheduleBackup(_ data: PassengerData) {
        guard auth.isSignedIn, data.profile != nil else { return }
        backupTask?.cancel()
        let auth = auth
        let accounts = accounts
        backupTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let token = await auth.validAccessToken() else { return }
            do {
                try await accounts.save(data, token: token)
            } catch {
                print("[Account] backup failed; will retry on next change")
            }
        }
    }

    /// After Google sign-in: restores a saved account if one exists. Returns true for a returning passenger.
    func restoreAccount() async -> Bool {
        guard let token = await auth.validAccessToken() else { return false }
        do {
            guard let remote = try await accounts.fetch(token: token), remote.profile != nil else { return false }
            store.restore(from: remote)
            return true
        } catch {
            print("[Account] restore failed")
            return false
        }
    }

    /// Uploads immediately (e.g. right after the profile is created).
    func backupNow() {
        scheduleBackup(store.data)
    }

    /// Signs out of Google and returns to onboarding. Local data stays on the device.
    func signOut() {
        backupTask?.cancel()
        auth.signOut()
        settings.resetOnboarding()
    }

    /// Deletes the server copy, then local data, then signs out.
    func deleteAccount() {
        backupTask?.cancel()
        let auth = auth
        let accounts = accounts
        Task {
            if let token = await auth.validAccessToken() {
                try? await accounts.delete(token: token)
            }
            auth.signOut()
        }
        store.deleteAccount()
        settings.resetOnboarding()
    }

    /// Kicks off background simulation and location updates once the passenger is onboarded.
    func startServices() {
        hasStartedServices = true
        location.start()
        drivers.startLiveUpdates()
    }

    private var hasStartedServices: Bool = false

    /// Suspends timer-driven simulation so no work runs after the system backgrounds the app.
    func enterBackground() {
        DioramaDownloadService.shared.pause()
        offlineMaps.pause()
        drivers.pauseLiveUpdates()
    }

    /// Resumes whatever `startServices()` started once the scene is active again.
    func enterForeground() {
        payments.resume()
        guard hasStartedServices else { return }
        drivers.startLiveUpdates()
        payments.checkAutoTopUp()
    }
}
