import MapboxMaps
import UIKit

/// Owns only an explicitly enabled driver's-eye session. Uses the existing interpolated trip pose.
@MainActor
final class DriverEyeCamera {
    private(set) var isActive: Bool = false
    private var savedCamera: CameraOptions?
    private var savedBounds: CameraBoundsOptions?
    private var lastPoint: GeoPoint?
    private var lastHeading: Double?
    private var lastGround: Double?

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
        // Missing terrain is not assumed flat at eye level; use an elevated fallback until available.
        let floor = (knownGround ?? lastGround ?? 0) + (knownGround == nil ? 18 : 0)
        guard point != lastPoint || heading != lastHeading || floor != lastGround else { return }
        lastPoint = point; lastHeading = heading; lastGround = knownGround ?? lastGround
        let camera = view.mapboxMap.freeCameraOptions
        camera.location = point.coordinate
        camera.altitude = max(0.3, floor + 2.4)
        camera.setPitchBearingForPitch(82, bearing: heading)
        view.mapboxMap.freeCameraOptions = camera
    }

    func stop(on view: MapView, restore: Bool) {
        guard isActive else { return }
        isActive = false
        view.camera.cancelAnimations()
        if let savedBounds { try? view.mapboxMap.setCameraBounds(with: savedBounds) }
        if restore, let savedCamera { view.mapboxMap.setCamera(to: savedCamera) }
        savedCamera = nil; savedBounds = nil; lastPoint = nil; lastHeading = nil; lastGround = nil
    }
}
