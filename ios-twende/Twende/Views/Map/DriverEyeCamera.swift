import MapboxMaps
import UIKit

/// Third-person chase session, driven by the existing interpolated trip pose.
@MainActor
final class DriverEyeCamera {
    private(set) var isActive: Bool = false
    private var savedCamera: CameraOptions?
    private var savedBounds: CameraBoundsOptions?
    private var lastPoint: GeoPoint?
    private var lastHeading: Double?
    private var lastGround: Double?
    private var lastAltitude: Double?

    /// Directly behind the vehicle, with no lateral orbit or bird's-eye offset.
    func cameraPoint(for point: GeoPoint, heading: Double) -> GeoPoint {
        let radians = heading * .pi / 180
        let metresPerDegree = 111_320.0
        return GeoPoint(latitude: point.latitude - cos(radians) * 22 / metresPerDegree,
                        longitude: point.longitude - sin(radians) * 22 / (metresPerDegree * max(0.01, cos(point.latitude * .pi / 180))))
    }

    func update(point: GeoPoint, heading: Double, ground: Double?, on view: MapView) {
        guard UIApplication.shared.applicationState == .active,
              point.latitude.isFinite, point.longitude.isFinite, heading.isFinite else { return }
        if !isActive {
            let state = view.mapboxMap.cameraState
            savedCamera = CameraOptions(center: state.center, padding: state.padding, zoom: state.zoom, bearing: state.bearing, pitch: state.pitch)
            savedBounds = CameraBoundsOptions(cameraBounds: view.mapboxMap.cameraBounds)
            do { try view.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: 25.5, maxPitch: 85)) }
            catch { return }
            view.camera.cancelAnimations()
            view.mapboxMap.setCamera(to: CameraOptions(padding: .zero))
            isActive = true
        }
        let knownGround = ground.flatMap { $0.isFinite ? $0 : nil }
        let floor = knownGround ?? lastGround ?? 0
        let altitude = max(0.3, floor + 9)
        guard point != lastPoint || heading != lastHeading || altitude != lastAltitude else { return }
        lastPoint = point; lastHeading = heading; lastGround = knownGround ?? lastGround
        lastAltitude = altitude
        let camera = view.mapboxMap.freeCameraOptions
        camera.location = cameraPoint(for: point, heading: heading).coordinate
        camera.altitude = altitude
        camera.setPitchBearingForPitch(72, bearing: heading)
        view.mapboxMap.freeCameraOptions = camera
    }

    func stop(on view: MapView, restore: Bool) {
        guard isActive else { return }
        isActive = false
        view.camera.cancelAnimations()
        if let savedBounds { try? view.mapboxMap.setCameraBounds(with: savedBounds) }
        if restore, let savedCamera { view.mapboxMap.setCamera(to: savedCamera) }
        savedCamera = nil; savedBounds = nil; lastPoint = nil; lastHeading = nil; lastGround = nil; lastAltitude = nil
    }
}
