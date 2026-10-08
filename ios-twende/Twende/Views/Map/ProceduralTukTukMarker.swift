import MapboxMaps
import SceneKit
import UIKit

/// The proven SceneKit/Mapbox annotation renderer, now backed by the complete procedural fleet.
/// The ground origin projects to the exact centre of the canvas at every heading and camera pitch.
final class ProceduralTukTukMarker {
    private let view: SCNView
    private let container: MapAnnotationContainer
    private let miniature: VehicleMiniatureScene
    private let annotation: ViewAnnotation
    private var point: GeoPoint
    private var heading: Double
    private var lastBearing: Double = .infinity
    private var lastPitch: Double = .infinity
    private var lastZoom: Double = .infinity
    private let isAssigned: Bool

    init(mapView: MapView, point: GeoPoint, heading: Double, isAssigned: Bool, tier: RideTier = .bajaji) {
        self.point = point
        self.heading = heading
        self.isAssigned = isAssigned
        miniature = VehicleMiniatureScene(tier: tier)
        let side = Self.canvasSide(at: mapView.mapboxMap.cameraState.zoom, isAssigned: isAssigned)
        let size = CGSize(width: side, height: side)
        view = SCNView(frame: CGRect(origin: .zero, size: size))
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.isPlaying = false
        view.scene = miniature.scene
        view.pointOfView = miniature.camera
        container = MapAnnotationContainer(content: view, size: size)
        container.layoutIfNeeded()
        annotation = ViewAnnotation(coordinate: point.coordinate, view: container)
        annotation.allowOverlap = true
        annotation.allowOverlapWithPuck = true
        annotation.allowZElevate = false
        annotation.ignoreCameraPadding = true
        annotation.priority = isAssigned ? 1 : 0
        annotation.variableAnchors = [ViewAnnotationAnchorConfig(anchor: .center)]
        updateCamera(bearing: mapView.mapboxMap.cameraState.bearing, pitch: mapView.mapboxMap.cameraState.pitch, zoom: mapView.mapboxMap.cameraState.zoom)
        mapView.viewAnnotations.add(annotation)
    }

    func setTier(_ tier: RideTier) {
        guard miniature.tier != tier else { return }
        miniature.setTier(tier)
        view.setNeedsDisplay()
    }

    func move(to point: GeoPoint, heading: Double, bearing: Double, pitch: Double, zoom: Double) {
        if self.point != point {
            self.point = point
            annotation.annotatedFeature = .geometry(Point(point.coordinate))
        }
        let headingChanged = self.heading != heading
        self.heading = heading
        updateCamera(bearing: bearing, pitch: pitch, zoom: zoom, force: headingChanged)
    }

    func updateCamera(bearing: Double, pitch: Double, zoom: Double, force: Bool = false) {
        guard force || bearing != lastBearing || pitch != lastPitch || zoom != lastZoom else { return }
        if zoom != lastZoom {
            lastZoom = zoom
            let side = Self.canvasSide(at: zoom, isAssigned: isAssigned)
            if abs(container.contentSize.width - side) > 0.25 {
                container.contentSize = CGSize(width: side, height: side)
                annotation.setNeedsUpdateSize()
            }
        }
        lastBearing = bearing
        lastPitch = pitch
        miniature.update(heading: heading, bearing: bearing, pitch: pitch)
        view.setNeedsDisplay()
    }

    func remove() { annotation.remove() }

    /// One continuous zoom curve for every tier, independent of UI illustrations.
    /// Stays large from high above: 72pt floor at city overview, 96pt at z15, capped at 130pt up close.
    /// The assigned (tracked) vehicle renders 1.35x larger so it reads at any zoom.
    nonisolated static func canvasSide(at zoom: Double, isAssigned: Bool = false) -> CGFloat {
        guard zoom.isFinite else { return isAssigned ? 130 : 96 }
        let base = min(130, max(72, 96 * pow(2, (zoom - 15) * 0.3)))
        return CGFloat(isAssigned ? min(170, max(96, base * 1.35)) : base)
    }
}
