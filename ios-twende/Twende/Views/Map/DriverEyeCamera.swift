import MapboxMaps
import UIKit

/// Rear-facing chase tracking with vehicle heading and UI-aware projection.
@MainActor
final class DriverEyeCamera {
    private(set) var isActive: Bool = false
    private var savedCamera: CameraOptions?
    private var savedBounds: CameraBoundsOptions?
    private var lastHeading: Double?
    private var lastPoint: GeoPoint?
    private var lastPadding: UIEdgeInsets?
    private var lastSize: CGSize?
    private var lastForwardView: Bool?

    func update(point: GeoPoint, heading: Double, visibleRect: CGRect?, forwardView: Bool = false, on view: MapView) {
        guard UIApplication.shared.applicationState == .active,
              point.latitude.isFinite, point.longitude.isFinite, heading.isFinite,
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        if !isActive {
            let state = view.mapboxMap.cameraState
            savedCamera = CameraOptions(center: state.center, padding: state.padding, zoom: state.zoom, bearing: state.bearing, pitch: state.pitch)
            savedBounds = CameraBoundsOptions(cameraBounds: view.mapboxMap.cameraBounds)
            do { try view.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: 25.5, maxPitch: 85)) }
            catch { return }
            view.camera.cancelAnimations()
            isActive = true
        }
        let bounds = view.bounds
        let available = (visibleRect ?? bounds.inset(by: view.safeAreaInsets)).intersection(bounds)
        guard !available.isNull, available.width > 0, available.height > 0 else { return }
        let forwardInset = forwardView ? available.height * 0.24 : 0
        let padding = UIEdgeInsets(top: available.minY - bounds.minY + forwardInset,
                                   left: available.minX - bounds.minX,
                                   bottom: bounds.maxY - available.maxY,
                                   right: bounds.maxX - available.maxX)
        let bearing = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        guard point != lastPoint || bearing != lastHeading || padding != lastPadding || bounds.size != lastSize || forwardView != lastForwardView else { return }
        lastForwardView = forwardView
        lastHeading = bearing
        lastPoint = point
        lastPadding = padding
        lastSize = bounds.size
        // Center and padding let Mapbox solve the projection, rather than guessing
        // an eye location whose optical axis can miss the car or ignore UI occlusion.
        view.mapboxMap.setCamera(to: CameraOptions(center: point.coordinate, padding: padding,
                                                   zoom: forwardView ? 18.6 : 17.5, bearing: bearing, pitch: forwardView ? 69 : 45))
    }

    func stop(on view: MapView, restore: Bool) {
        guard isActive else { return }
        isActive = false
        view.camera.cancelAnimations()
        if let savedBounds { try? view.mapboxMap.setCameraBounds(with: savedBounds) }
        if restore, let savedCamera { view.mapboxMap.setCamera(to: savedCamera) }
        lastHeading = nil
        savedCamera = nil
        savedBounds = nil
        lastPoint = nil
        lastPadding = nil
        lastSize = nil
        lastForwardView = nil
    }
}
