@_spi(Experimental) import MapboxMaps
import SwiftUI
import UIKit

/// Native ground-aligned rings. Mapbox applies projection, pitch and camera perspective to these
/// circles; unlike view annotations they are not billboards facing the screen.
final class MapSearchPulse {
    private static let sourceID = "twende-search-origin"
    private static let layerIDs = (0..<3).map { "twende-search-ring-\($0)" }
    private var centre: GeoPoint? = nil
    private var startedAt: TimeInterval = 0
    private var isInstalled: Bool = false
    private var isStatic: Bool = false

    var needsFrames: Bool { isInstalled && !isStatic }

    func styleDidReload() {
        isInstalled = false
        centre = nil
    }

    func update(at point: GeoPoint?, on map: MapboxMap, reduceMotion: Bool) {
        guard let point else {
            remove(from: map)
            return
        }
        let modeChanged = isStatic != reduceMotion
        isStatic = reduceMotion
        do {
            if !isInstalled {
                var source = GeoJSONSource(id: Self.sourceID)
                source.data = .geometry(.point(Point(point.coordinate)))
                try map.addSource(source)
                for id in Self.layerIDs {
                    var ring = CircleLayer(id: id, source: Self.sourceID)
                    ring.slot = .middle
                    ring.circlePitchAlignment = .constant(.map)
                    ring.circlePitchScale = .constant(.map)
                    ring.circleColor = .constant(StyleColor(.clear))
                    ring.circleRadius = .constant(0)
                    ring.circleStrokeColor = .constant(StyleColor(UIColor(TwendeColor.primary)))
                    ring.circleStrokeWidth = .constant(2.5)
                    ring.circleStrokeOpacity = .constant(0)
                    ring.circleEmissiveStrength = .constant(1)
                    ring.circleRadiusTransition = StyleTransition(duration: 0, delay: 0)
                    ring.circleStrokeOpacityTransition = StyleTransition(duration: 0, delay: 0)
                    // Search never obscures a route if both are briefly present during a phase change.
                    let position: LayerPosition? = map.layerExists(withId: "twende-route-casing") ? .below("twende-route-casing") : nil
                    try map.addLayer(ring, layerPosition: position)
                }
                isInstalled = true
                centre = point
                startedAt = ProcessInfo.processInfo.systemUptime
                tick(on: map)
            } else if centre != point {
                centre = point
                map.updateGeoJSONSource(withId: Self.sourceID, geoJSON: .geometry(.point(Point(point.coordinate))))
            }
            if modeChanged { tick(on: map) }
        } catch {
            remove(from: map)
            print("[MapSearchPulse] Could not install ground rings")
        }
    }

    func tick(on map: MapboxMap) {
        guard isInstalled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        do {
            for (index, id) in Self.layerIDs.enumerated() {
                let phase = isStatic ? Double(index + 1) / 4 :
                    (elapsed / 2.8 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                let fadeIn = min(1, phase / 0.12)
                let opacity = isStatic ? 0.42 : 0.85 * fadeIn * pow(1 - phase, 1.4)
                // Zoom-dependent radius anchors the footprint to the ground, with a gentle upper limit
                // to keep matching readable even when the user zooms in very close.
                let zoomScale = min(2.5, max(0.35, pow(2, map.cameraState.zoom - 14)))
                let radius = (8 + 120 * phase) * zoomScale
                try map.setLayerProperty(for: id, property: "circle-radius", value: radius)
                try map.setLayerProperty(for: id, property: "circle-stroke-opacity", value: opacity)
            }
        } catch {
            remove(from: map)
            print("[MapSearchPulse] Ground-ring update stopped")
        }
    }

    func remove(from map: MapboxMap) {
        for id in Self.layerIDs.reversed() where map.layerExists(withId: id) {
            try? map.removeLayer(withId: id)
        }
        if map.sourceExists(withId: Self.sourceID) { try? map.removeSource(withId: Self.sourceID) }
        isInstalled = false
        centre = nil
    }
}
