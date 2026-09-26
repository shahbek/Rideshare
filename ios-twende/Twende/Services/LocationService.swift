import CoreLocation
import Observation

/// Wraps CLLocationManager. Falls back to the Upanga demo pickup when the device is outside Dar es Salaam.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var devicePosition: GeoPoint?
    private(set) var lastErrorMessage: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// Device position when inside the service zone, otherwise the Upanga demo pickup.
    var effectivePosition: GeoPoint {
        if let devicePosition, DarEsSalaam.isInServiceZone(devicePosition) {
            return devicePosition
        }
        return DarEsSalaam.upanga
    }

    var isOutsideServiceZone: Bool {
        guard let devicePosition else { return false }
        return !DarEsSalaam.isInServiceZone(devicePosition)
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.isAuthorized {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let point = GeoPoint(last.coordinate)
        Task { @MainActor in
            self.devicePosition = point
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.lastErrorMessage = message
        }
    }
}
