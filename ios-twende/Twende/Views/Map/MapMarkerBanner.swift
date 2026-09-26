import MapboxMaps
import SwiftUI

/// Separate native annotation: moving a banner never shifts its pin's ground anchor.
@MainActor
final class MapMarkerBanner {
    private let hosted: HostedMarker
    private weak var pin: HostedMarker?
    private var point: GeoPoint
    private var label: String
    private var maximumWidth: CGFloat

    init(label: String, point: GeoPoint, pin: HostedMarker, mapView: MapView) {
        self.pin = pin
        self.label = label
        self.point = point
        maximumWidth = min(260, max(80, mapView.bounds.width - 32))
        hosted = HostedMarker(rootView: AnyView(MapPinBanner(text: label, maxWidth: maximumWidth).fixedSize()), anchor: .topLeft)
        hosted.attach(to: mapView, at: point)
        layout(on: mapView)
    }

    func update(label: String, point: GeoPoint, on mapView: MapView) {
        self.point = point
        hosted.move(to: point)
        let width = min(260, max(80, mapView.bounds.width - 32))
        if self.label != label || maximumWidth != width {
            self.label = label
            maximumWidth = width
            hosted.update(rootView: AnyView(MapPinBanner(text: label, maxWidth: width).fixedSize()))
        }
        layout(on: mapView)
    }

    func layout(on mapView: MapView) {
        // Native frame includes partly offscreen pins. point(for:) instead returns (-1, -1) there.
        guard let anchor = pin?.contactPoint(in: mapView), anchor.x.isFinite, anchor.y.isFinite else {
            hosted.setVisible(false)
            return
        }
        let pin = CGRect(x: anchor.x - 11, y: anchor.y - 39, width: 22, height: 42)
        let visible = mapView.bounds.intersects(pin)
        hosted.setVisible(visible)
        guard visible else { return }
        var viewport = mapView.bounds.insetBy(dx: 12, dy: 12)
        let top = max(viewport.minY, mapView.safeAreaInsets.top + 8)
        viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(30, viewport.maxY - top))
        let frame = MapBannerLayout.frame(anchor: anchor, size: hosted.size, viewport: viewport)
        hosted.setOffset(x: frame.minX - anchor.x, y: anchor.y - frame.minY)
    }

    func remove() { hosted.remove() }
}
