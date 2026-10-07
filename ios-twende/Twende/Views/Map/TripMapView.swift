@_spi(Experimental) import MapboxMaps
import SwiftUI
import UIKit

/// Which gestures the map accepts.
nonisolated struct MapInteraction: OptionSet, Sendable {
    let rawValue: Int
    static let pan = MapInteraction(rawValue: 1 << 0)
    static let zoom = MapInteraction(rawValue: 1 << 1)
    static let rotate = MapInteraction(rawValue: 1 << 2)
    static let tilt = MapInteraction(rawValue: 1 << 3)
    static let all: MapInteraction = [.pan, .zoom, .rotate, .tilt]
}

/// Mapbox Standard (3D buildings, night lighting and discoverable local places) shared by every map screen.
///
/// Every Twende element is a native map object: the route is a `GeoJSONSource` with three `LineLayer`s
/// (white casing, green→ink gradient core revealed with `line-trim-offset`, and a light pulse whose
/// gradient is re-timed at 30fps); search rings are ground-aligned native circle layers. Pins use
/// view annotations; vehicles are procedural miniatures with alpha shadows in zoom-scaled annotations.
struct TripMapView: UIViewRepresentable {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var camera: MapCameraTarget
    var pickup: GeoPoint? = nil
    var destination: GeoPoint? = nil
    /// Intermediate stops between pickup and destination, in visiting order.
    var stops: [GeoPoint] = []
    var routePoints: [GeoPoint] = []
    var driverPosition: GeoPoint? = nil
    var driverHeading: Double = 0
    var driverTier: RideTier = .economy
    var followsDriver: Bool = false
    var onDriverFollowInterrupted: (() -> Void)? = nil
    var nearbyDrivers: [Driver] = []
    var favouriteIDs: Set<String> = []
    var isSearching: Bool = false
    /// Minutes shown in the pickup pin's label chip while the driver approaches.
    var pickupEtaMinutes: Int? = nil
    /// Minutes shown in the destination pin's label chip during the ride.
    var destinationEtaMinutes: Int? = nil
    /// Booking can supply descriptive pickup and clock-time drop-off banners without changing live-trip labels.
    var pickupBannerText: String? = nil
    var destinationBannerText: String? = nil
    /// Whether the pins carry a text label at all (Home keeps the pickup pin bare).
    var showsPinLabels: Bool = true
    /// Uses Mapbox's real device location, never the demo pickup or the simulated driver.
    var showsUserLocation: Bool = true
    var interactionModes: MapInteraction = .all
    /// Fixed picker contact dot in this map's local coordinates (not the full screen's center).
    var selectionPoint: CGPoint? = nil
    var highlightsSelectionBuilding: Bool = false
    /// Defaults to the destination; can remain set even when its pin is hidden during matching.
    var illuminatedDestination: GeoPoint? = nil
    /// Called when the camera settles after a user gesture or programmatic move.
    var onCameraMoved: ((GeoPoint) -> Void)? = nil
    /// Called when the camera starts moving; `true` when the user is dragging.
    var onCameraWillMove: ((Bool) -> Void)? = nil
    /// Called with the ad ID when the passenger taps a map billboard. Nil disables billboard taps.
    var onBillboardTap: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> MapView {
        let options = MapInitOptions(
            cameraOptions: CameraOptions(center: DarEsSalaam.upanga.coordinate, zoom: 13, pitch: Coordinator.cameraPitch),
            styleURI: .standard
        )
        let mapView = MapView(frame: .zero, mapInitOptions: options)
        mapView.mapboxMap.prefetchZoomDelta = 0
        mapView.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        mapView.backgroundColor = UIColor(TwendeColor.mapCanvas)
        mapView.presentationTransactionMode = .sync
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden
        mapView.ornaments.options.logo.margins = CGPoint(x: 8, y: 4)
        mapView.ornaments.options.attributionButton.margins = CGPoint(x: 2, y: 4)
        mapView.gestures.options.pitchEnabled = false
        mapView.gestures.delegate = context.coordinator
        context.coordinator.mapView = mapView
        context.coordinator.observe(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        mapView.gestures.options.panEnabled = interactionModes.contains(.pan)
        mapView.gestures.options.pinchZoomEnabled = interactionModes.contains(.zoom)
        mapView.gestures.options.doubleTapToZoomInEnabled = interactionModes.contains(.zoom)
        mapView.gestures.options.quickZoomEnabled = interactionModes.contains(.zoom)
        mapView.gestures.options.rotateEnabled = interactionModes.contains(.rotate)

        coordinator.updateLocationPuck(visible: showsUserLocation && env.location.isAuthorized)
        coordinator.applyCameraIfNeeded(camera)
        coordinator.updateRoute(routePoints)
        coordinator.updateSonar(isSearching ? pickup : nil)
        coordinator.updatePin(
            .pickup,
            at: pickup,
            label: pickupBannerLabel
        )
        coordinator.updatePin(
            .destination,
            at: destination,
            label: destinationBannerLabel
        )
        coordinator.updateStops(stops, labelled: showsPinLabels)
        coordinator.updateDriver(position: driverPosition, heading: driverHeading, tier: driverTier)
        coordinator.updateNearby(nearbyDrivers)
        coordinator.applyMapStyleIfNeeded()
        coordinator.updateSelection()
        coordinator.updateDiorama()
        coordinator.updateDriverCamera()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    static func dismantleUIView(_ mapView: MapView, coordinator: Coordinator) {
        coordinator.cancelCameraSettlement()
        coordinator.stopRoutePulse()
        coordinator.removeSearchPulse()
        coordinator.removeBuildingHighlight()
        coordinator.removeVehicles()
        coordinator.removeLandmarks()
        coordinator.removeDiorama()
    }

    var pickupBannerLabel: String? {
        pinLabel(text: pickupBannerText, eta: pickupEtaMinutes, fallback: L(.pickupLabel))
    }

    var destinationBannerLabel: String? {
        pinLabel(text: destinationBannerText, eta: destinationEtaMinutes, fallback: L(.dropoffLabel))
    }

    private func pinLabel(text: String?, eta: Int?, fallback: String) -> String? {
        guard showsPinLabels else { return nil }
        if let text { return text }
        if let eta { return L(.minutesShort, eta) }
        return fallback
    }
}

extension TripMapView {
    /// Owns the native map objects and keeps them in step with the SwiftUI inputs.
    final class Coordinator: NSObject, GestureManagerDelegate {
        var parent: TripMapView
        weak var mapView: MapView?

        private let driverEyeCamera = DriverEyeCamera()
        private var driverFollowInterrupted: Bool = false
        private var lastDioramaFollowUpdate: Date = .distantPast
        private var appliedCamera: MapCameraTarget? = nil
        private var pendingCamera: MapCameraTarget? = nil
        private var hasPositionedCamera: Bool = false
        private var puckVisible: Bool = false
        private var activeGestures: Set<String> = []
        private var cameraSettlement: Task<Void, Never>? = nil
        private var lastReportedSelection: GeoPoint? = nil
        private var cancelables: Set<AnyCancelable> = []

        private var styleReady: Bool = false
        private var appliedStyle: MapStyleOption? = nil
        private var routeInstalled: Bool = false
        private var renderedRoutePoints: [GeoPoint] = []
        private var routeEnd: GeoPoint? = nil
        private var routePoints: [GeoPoint] = []
        private var routeAppeared: Date? = nil
        private var frameTimer: Timer? = nil
        private var routeMotionFinished: Bool = false

        private var pins: [MapPinKind: HostedMarker] = [:]
        private var banners: [MapPinKind: MapMarkerBanner] = [:]
        private let searchPulse = MapSearchPulse()
        private let buildingHighlight = MapBuildingHighlight()
        private let tanzaniteBridge = TanzaniteBridgeLandmark()
        private let airtelHouse = AirtelBuildingLandmark()
        private let cityLandmarks = DarCityLandmarks()
        private let billboards: [BillboardLandmark] = BillboardCatalogue.all.map { BillboardLandmark(ad: $0) }
        private let billboardTeasers: [BillboardTeaser] = BillboardCatalogue.all.map { BillboardTeaser(ad: $0) }
        /// Procedural Slipway diorama; created only while `DioramaState.shared.isEnabled`.
        private var diorama: DioramaTileManager? = nil
        /// True while the diorama tile is on screen and Standard's 3D terrain must stay off.
        private var dioramaOwnsGround: Bool = false
        private var dioramaRegenerate: Int = 0
        private var dioramaFly: Int = 0
        func removeLandmarks() {
            for teaser in billboardTeasers { teaser.remove() }
            if let map = mapView?.mapboxMap {
                tanzaniteBridge.remove(from: map)
                airtelHouse.remove(from: map)
                cityLandmarks.remove(from: map)
                for billboard in billboards { billboard.remove(from: map) }
            }
        }
        private var renderedSelectionPoint: CGPoint? = nil
        private var highlightsSelection: Bool = false
        private var renderedDestination: GeoPoint? = nil

        private static let routeSourceID = "twende-route"
        private static let casingLayerID = "twende-route-casing"
        private static let coreLayerID = "twende-route-core"
        private static let pulseLayerID = "twende-route-pulse"

        /// Tilt so the Standard style's 3D buildings and the vehicle models read as objects, not decals.
        static let cameraPitch: CGFloat = 45

        /// Native POIs use Mapbox's real place data and collision-aware ranking, not invented hotspots.
        /// Only `theme` and `lightPreset` follow the Settings picker; every other entry is fixed so the
        /// 3D scene, POI visibility and building selection colours are identical in all map styles.
        static func standardConfig(for style: MapStyleOption) -> [String: Any] {
            var config = baseConfig
            config["theme"] = style.theme
            config["lightPreset"] = style.lightPreset
            return config
        }

        static var standardConfig: [String: Any] { standardConfig(for: AppSettings.shared.mapStyle) }

        private static let baseConfig: [String: Any] = [
            "show3dObjects": true,
            "showPlaceLabels": true,
            "showRoadLabels": true,
            "showPointOfInterestLabels": true,
            "densityPointOfInterestLabels": 5,
            "colorModePointOfInterestLabels": "default",
            "backgroundPointOfInterestLabels": "none",
            "showLandmarkIcons": true,
            "showLandmarkIconLabels": true,
            "showTransitLabels": false,
            "colorBuildingSelect": "#D3B07E",
            "colorBuildingHighlight": "#D3B07E",
        ]

        private var vehicleMarkers: [String: ProceduralTukTukMarker] = [:]
        private var nearbyVehicles: [String: Vehicle] = [:]

        /// Driver interpolation: the simulator reports a new fix every 0.25s; the model glides between fixes.
        private struct Pose: Equatable { var point: GeoPoint; var heading: Double }
        private struct Vehicle: Equatable { var tier: RideTier; var pose: Pose }
        private var driverTier: RideTier = .economy
        private var driverFrom: Pose? = nil
        private var driverTo: Pose? = nil
        private var driverShown: Pose? = nil
        private var driverMoveStarted: Date = .distantPast
        private static let driverGlideDuration: TimeInterval = 0.3
        private static let driverModelID = "twende-driver"

        init(parent: TripMapView) {
            self.parent = parent
        }

        func observe(_ mapView: MapView) {
            mapView.mapboxMap.onMapLoaded.observe { [weak self] _ in
                self?.refreshBuildingHighlight(immediately: true)
                self?.diorama?.scheduleUpdate(delay: 1.1)
            }.store(in: &cancelables)
            mapView.mapboxMap.onMapIdle.observe { [weak self] _ in
                guard let self else { return }
                guard self.activeGestures.isEmpty else { return }
                self.reportSelectionCoordinate()
                self.refreshBuildingHighlight(immediately: true)
                if let map = self.mapView?.mapboxMap { self.airtelHouse.update(on: map, settled: true) }
                self.diorama?.scheduleUpdate(delay: 1.1)
            }.store(in: &cancelables)
            mapView.mapboxMap.onStyleLoaded.observe { [weak self] _ in
                guard let self else { return }
                self.styleReady = true
                self.configureStandardStyle()
                self.tanzaniteBridge.styleDidReload()
                self.airtelHouse.styleDidReload()
                self.cityLandmarks.styleDidReload()
                for billboard in self.billboards { billboard.styleDidReload() }
                if let map = self.mapView?.mapboxMap {
                    self.tanzaniteBridge.update(on: map)
                    self.airtelHouse.update(on: map)
                    self.cityLandmarks.update(on: map)
                    for billboard in self.billboards { billboard.update(on: map) }
                }
                if let mapView = self.mapView, self.parent.onBillboardTap != nil {
                    for teaser in self.billboardTeasers { teaser.update(on: mapView) }
                }
                // Layers added before the style finished loading are dropped; replay the route.
                self.routeInstalled = false
                self.renderedRoutePoints = []
                self.routeEnd = nil
                self.updateRoute(self.routePoints)
                self.searchPulse.styleDidReload()
                self.updateSonar(self.parent.isSearching ? self.parent.pickup : nil)
                self.buildingHighlight.styleDidReload()
                self.refreshBuildingHighlight(immediately: true)
                self.diorama?.styleDidReload()
                if let map = self.mapView?.mapboxMap { self.diorama?.install(on: map) }
            }.store(in: &cancelables)
            mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
                guard let self, let map = self.mapView?.mapboxMap else { return }
                for marker in self.vehicleMarkers.values {
                    marker.updateCamera(bearing: map.cameraState.bearing, pitch: map.cameraState.pitch, zoom: map.cameraState.zoom)
                }
                if let mapView = self.mapView {
                    for banner in self.banners.values { banner.layout(on: mapView) }
                }
                if !self.searchPulse.needsFrames { self.searchPulse.tick(on: map) }
                self.refreshBuildingHighlight()
                self.tanzaniteBridge.update(on: map)
                self.airtelHouse.update(on: map)
                self.cityLandmarks.update(on: map)
                for billboard in self.billboards { billboard.update(on: map) }
                if let mapView = self.mapView, self.parent.onBillboardTap != nil {
                    for teaser in self.billboardTeasers { teaser.update(on: mapView) }
                }
                self.diorama?.scheduleUpdate(delay: 0.3)
                self.scheduleCameraSettlement()
            }.store(in: &cancelables)
            mapView.gestures.onMapTap.observe { [weak self] context in
                guard let self, let handler = self.parent.onBillboardTap, let map = self.mapView?.mapboxMap else { return }
                if let mapView = self.mapView, let teaser = self.billboardTeasers.first(where: { $0.hitTest(context.point, in: mapView) }) {
                    Haptics.tap()
                    handler(teaser.ad.id)
                } else if let hit = self.billboards.first(where: { $0.hitTest(context.point, on: map) }) {
                    Haptics.tap()
                    handler(hit.ad.id)
                }
            }.store(in: &cancelables)
            mapView.mapboxMap.onMapLoadingError.observe { error in
                print("[TripMapView] map loading error: \(error.type) \(error.message)")
            }.store(in: &cancelables)
        }

        private func configureStandardStyle() {
            guard let map = mapView?.mapboxMap else { return }
            let style = AppSettings.shared.mapStyle
            appliedStyle = style
            for (key, value) in Self.standardConfig(for: style) {
                do {
                    try map.setStyleImportConfigProperty(for: "basemap", config: key, value: value)
                } catch {
                    print("[TripMapView] standard config \(key) failed: \(error)")
                }
            }
            applyTerrain()
        }

        private static let demSourceID = "zuri-terrain-dem"
        static let demTilesetURL = "mapbox://mapbox.mapbox-terrain-dem-v1"

        /// Real elevation under Standard's 3D buildings. DEM tiles stop at z14 and are cached in the
        /// shared TileStore (and included in offline areas). Keep the datum stable in Low Power;
        /// the diorama instead reduces reflections and stops its animation clock. While the Slipway
        /// diorama is shown it owns the ground, so the terrain stays off until it hides.
        func applyTerrain() {
            guard let map = mapView?.mapboxMap else { return }
            guard !dioramaOwnsGround else {
                map.removeTerrain()
                return
            }
            do {
                if !map.sourceExists(withId: Self.demSourceID) {
                    var dem = RasterDemSource(id: Self.demSourceID)
                    dem.url = Self.demTilesetURL
                    dem.tileSize = 514
                    dem.maxzoom = 14
                    try map.addSource(dem)
                }
                var terrain = Terrain(sourceId: Self.demSourceID)
                // Dar es Salaam is low and gentle; a mild lift makes the Msasani ridge and shore readable.
                terrain.exaggeration = .constant(1.6)
                try map.setTerrain(terrain)
            } catch {
                print("[TripMapView] terrain unavailable: \(error.localizedDescription)")
            }
        }

        /// Re-applies the basemap configuration when Settings changes it, and rebuilds the pin views so
        /// their contrast follows the new lighting. Custom landmark layers are untouched by a config change.
        func applyMapStyleIfNeeded() {
            let style = AppSettings.shared.mapStyle
            guard styleReady, appliedStyle != style else { return }
            configureStandardStyle()
            // The diorama owns lightPreset/show3dObjects while enabled; re-assert after a style change.
            if let map = mapView?.mapboxMap, let diorama {
                diorama.styleDidReload()
                diorama.install(on: map)
            }
            guard let mapView else { return }
            mapView.backgroundColor = UIColor(TwendeColor.mapCanvas)
            for (kind, hosted) in pins {
                let label = hosted.label
                hosted.remove()
                pins[kind] = nil
                banners.removeValue(forKey: kind)?.remove()
                updatePin(kind, at: hosted.point, label: label)
            }
        }

        func updateLocationPuck(visible: Bool) {
            guard visible != puckVisible, let mapView else { return }
            puckVisible = visible
            if visible {
                var puck = Puck2DConfiguration.makeDefault(showBearing: true)
                puck.showsAccuracyRing = true
                mapView.location.options.puckType = .puck2D(puck)
                mapView.location.options.puckBearing = .heading
                mapView.location.options.puckBearingEnabled = true
            } else {
                mapView.location.options.puckType = nil
            }
        }

        // MARK: Destination building selection

        func updateSelection() {
            let destination = parent.illuminatedDestination ?? parent.destination
            guard renderedSelectionPoint != parent.selectionPoint || highlightsSelection != parent.highlightsSelectionBuilding || renderedDestination != destination else { return }
            renderedDestination = destination
            renderedSelectionPoint = parent.selectionPoint
            highlightsSelection = parent.highlightsSelectionBuilding
            // Geometry arrives through SwiftUI; avoid publishing back into it during updateUIView.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.styleReady else { return }
                self.reportSelectionCoordinate()
                self.refreshBuildingHighlight(immediately: true)
            }
        }

        private func reportSelectionCoordinate(force: Bool = false) {
            guard activeGestures.isEmpty, let mapView else { return }
            let point = parent.selectionPoint
            let coordinate = point.map { mapView.mapboxMap.coordinate(for: $0) }
                ?? mapView.mapboxMap.cameraState.center
            let selectedPoint = GeoPoint(coordinate)
            guard force || selectedPoint != lastReportedSelection else { return }
            lastReportedSelection = selectedPoint
            parent.onCameraMoved?(selectedPoint)
        }

        /// Camera quietness, not tile/network idleness, controls the picker pin's landing.
        private func scheduleCameraSettlement() {
            cameraSettlement?.cancel()
            guard parent.onCameraMoved != nil else { return }
            cameraSettlement = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { return }
                guard let self, self.activeGestures.isEmpty else { return }
                self.finishCameraMotion()
            }
        }

        func cancelCameraSettlement() {
            cameraSettlement?.cancel()
            cameraSettlement = nil
        }

        private func finishCameraMotion() {
            guard activeGestures.isEmpty else { return }
            cancelCameraSettlement()
            reportSelectionCoordinate(force: true)
            refreshBuildingHighlight(immediately: true)
        }

        private func refreshBuildingHighlight(immediately: Bool = false) {
            guard styleReady, let mapView, let map = mapView.mapboxMap else { return }
            let isPicking = parent.highlightsSelectionBuilding
            let coordinate = isPicking
                ? parent.selectionPoint.map { GeoPoint(map.coordinate(for: $0)) }
                : (parent.illuminatedDestination ?? parent.destination)
            // A selected native footprint must not install a second generic shell over bespoke hotels.
            if DioramaState.shared.isEnabled, let coordinate,
               coordinate.latitude >= -6.757351500676301, coordinate.latitude <= -6.751896464843376,
               coordinate.longitude >= 39.2706298828125, coordinate.longitude <= 39.276123046875 {
                buildingHighlight.clear(on: map)
                return
            }
            let point = isPicking ? parent.selectionPoint : coordinate.map { map.point(for: $0.coordinate) }
            buildingHighlight.schedule(
                at: point.flatMap { mapView.bounds.contains($0) ? $0 : nil },
                coordinate: coordinate, isPicking: isPicking, on: map, immediately: immediately
            )
        }

        func removeBuildingHighlight() {
            styleReady = false
            guard let mapView else { return }
            buildingHighlight.clear(on: mapView.mapboxMap)
        }

        // MARK: Diorama

        /// Starts or stops the diorama with the shared state, and services debug-panel requests.
        func updateDiorama() {
            let state = DioramaState.shared
            guard let mapView else { return }
            if state.isEnabled, diorama == nil {
                let manager = DioramaTileManager()
                manager.setBasemapTerrainEnabled = { [weak self] enabled in
                    guard let self else { return }
                    self.dioramaOwnsGround = !enabled
                    self.applyTerrain()
                }
                diorama = manager
                if styleReady { manager.install(on: mapView.mapboxMap) }
                if !parent.followsDriver { mapView.camera.fly(to: manager.introCamera(), duration: 1.6) }
                dioramaFly = state.cameraFlyRequest
                dioramaRegenerate = state.regenerateRequest
            } else if !state.isEnabled, let manager = diorama {
                manager.retract { [weak self, weak manager] in
                    guard let self, let manager, self.diorama === manager else { return }
                    manager.remove()
                    self.diorama = nil
                    self.dioramaOwnsGround = false
                    self.applyTerrain()
                }
                return
            }
            guard let diorama else { return }
            if state.isEnabled { diorama.cancelRetraction() }
            if state.regenerateRequest != dioramaRegenerate {
                dioramaRegenerate = state.regenerateRequest
                diorama.regenerate()
            }
            if state.cameraFlyRequest != dioramaFly {
                dioramaFly = state.cameraFlyRequest
                if !parent.followsDriver { mapView.camera.fly(to: diorama.introCamera(), duration: 1.2) }
            }
            diorama.scheduleUpdate(delay: 0.05)
        }

        func removeDiorama() {
            diorama?.remove()
            diorama = nil
            dioramaOwnsGround = false
            applyTerrain()
        }

        // MARK: Camera

        func applyCameraIfNeeded(_ target: MapCameraTarget) {
            guard !driverEyeCamera.isActive, !(parent.followsDriver && parent.driverPosition != nil) else { return }
            guard target != appliedCamera, target != .automatic, let mapView else { return }
            guard mapView.bounds.width > 0, mapView.bounds.height > 0 else {
                pendingCamera = target
                DispatchQueue.main.async { [weak self] in
                    guard let self, let pending = self.pendingCamera else { return }
                    self.pendingCamera = nil
                    self.applyCameraIfNeeded(pending)
                }
                return
            }
            appliedCamera = target
            let isFirstMove = !hasPositionedCamera
            hasPositionedCamera = true
            switch target {
            case .automatic:
                break
            case .region(let region):
                let widthPoints = Double(mapView.bounds.width)
                let metersPerPoint = region.spanKm * 1000 / widthPoints
                // Mapbox uses 512px tiles, hence the -1 relative to the Web-Mercator formula.
                let zoom = log2(156_543.03392 * cos(region.centre.latitude * .pi / 180) / metersPerPoint) - 1
                let options = CameraOptions(center: region.centre.coordinate, zoom: zoom, pitch: Self.cameraPitch)
                if isFirstMove {
                    mapView.mapboxMap.setCamera(to: options)
                } else {
                    mapView.camera.ease(to: options, duration: 0.6, curve: .easeInOut)
                }
            case .rect(let bounds):
                guard !bounds.points.isEmpty else { return }
                var coordinates = bounds.points.map(\.coordinate)
                if let first = bounds.points.first {
                    // Guarantee a sensible minimum extent so close points don't zoom to street level.
                    coordinates.append(first.offset(eastMetres: 500, northMetres: 500).coordinate)
                    coordinates.append(first.offset(eastMetres: -500, northMetres: -500).coordinate)
                }
                let width = mapView.bounds.width
                let height = mapView.bounds.height
                let pad = max(min(width, height) * bounds.paddingFraction * 0.5, 40)
                let insets = UIEdgeInsets(
                    top: pad + 72,
                    left: pad + width * min(max(bounds.leadingFraction, 0), 0.7),
                    bottom: pad + height * bounds.bottomFraction,
                    right: pad
                )
                guard let options = try? mapView.mapboxMap.camera(
                    for: coordinates,
                    camera: CameraOptions(bearing: 0, pitch: Self.cameraPitch),
                    coordinatesPadding: insets,
                    maxZoom: 17,
                    offset: nil
                ) else { return }
                if isFirstMove {
                    mapView.mapboxMap.setCamera(to: options)
                } else {
                    mapView.camera.ease(to: options, duration: 0.6, curve: .easeInOut)
                }
            }
        }

        // MARK: Route

        /// Updates the route geometry. The draw-on animation only plays for a *new* route (different
        /// destination); trimming the travelled part of the same route just moves the source data.
        func updateRoute(_ points: [GeoPoint]) {
            routePoints = points
            guard styleReady else { return }
            // Reordering intermediate stops may leave both endpoints and the point count unchanged.
            guard points != renderedRoutePoints else { return }
            renderedRoutePoints = points

            guard let mapView else { return }
            let map: MapboxMap = mapView.mapboxMap

            guard points.count > 1 else {
                removeRoute(from: map)
                return
            }

            let line = LineString(points.map(\.coordinate))
            let isNewRoute = !routeInstalled || routeEnd != points[points.count - 1]
            routeEnd = points[points.count - 1]
            if isNewRoute {
                routeAppeared = Date()
            }

            if routeInstalled {
                map.updateGeoJSONSource(withId: Self.routeSourceID, geoJSON: .geometry(.lineString(line)))
            } else {
                var source = GeoJSONSource(id: Self.routeSourceID)
                source.data = .geometry(.lineString(line))
                source.lineMetrics = true
                try? map.addSource(source)

                var casing = LineLayer(id: Self.casingLayerID, source: Self.routeSourceID)
                casing.slot = .top
                casing.lineWidth = .constant(9)
                casing.lineColor = .constant(StyleColor(.white))
                casing.lineCap = .constant(.round)
                casing.lineJoin = .constant(.round)
                casing.lineEmissiveStrength = .constant(1)
                try? map.addLayer(casing)

                var core = LineLayer(id: Self.coreLayerID, source: Self.routeSourceID)
                core.slot = .top
                core.lineWidth = .constant(5)
                core.lineCap = .constant(.round)
                core.lineJoin = .constant(.round)
                core.lineEmissiveStrength = .constant(1)
                core.lineGradient = .expression(
                    Exp(.interpolate) {
                        Exp(.linear)
                        Exp(.lineProgress)
                        0.0
                        UIColor(TwendeColor.primary)
                        1.0
                        UIColor(TwendeColor.route)
                    }
                )
                try? map.addLayer(core)

                var pulse = LineLayer(id: Self.pulseLayerID, source: Self.routeSourceID)
                pulse.slot = .top
                pulse.lineWidth = .constant(5)
                pulse.lineCap = .constant(.round)
                pulse.lineJoin = .constant(.round)
                pulse.lineEmissiveStrength = .constant(1)
                pulse.lineGradient = .expression(
                    Exp(.interpolate) {
                        Exp(.linear)
                        Exp(.lineProgress)
                        0.0
                        UIColor.clear
                        1.0
                        UIColor.clear
                    }
                )
                try? map.addLayer(pulse)
                routeInstalled = map.layerExists(withId: Self.coreLayerID)
            }

            routeMotionFinished = false
            tickRoute()
            ensureFrameTimer()
        }

        private func removeRoute(from map: MapboxMap) {
            routeEnd = nil
            guard routeInstalled else { return }
            try? map.removeLayer(withId: Self.pulseLayerID)
            try? map.removeLayer(withId: Self.coreLayerID)
            try? map.removeLayer(withId: Self.casingLayerID)
            try? map.removeSource(withId: Self.routeSourceID)
            routeInstalled = false
        }

        /// One 30fps clock drives route/search pulses and driver glide; it stops itself when idle.
        private func ensureFrameTimer() {
            guard frameTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            frameTimer = timer
        }

        func stopRoutePulse() {
            frameTimer?.invalidate()
            frameTimer = nil
        }

        private func tickFrame() {
            guard UIApplication.shared.applicationState == .active else {
                finishRouteAppearance()
                stopRoutePulse()
                return
            }
            if routeInstalled && !routeMotionFinished { tickRoute() }
            if searchPulse.needsFrames, let map = mapView?.mapboxMap { searchPulse.tick(on: map) }
            let driverBusy = tickDriver()
            if (!routeInstalled || routeMotionFinished) && !driverBusy && !searchPulse.needsFrames {
                stopRoutePulse()
            }
        }

        private func finishRouteAppearance() {
            guard routeInstalled, let map = mapView?.mapboxMap else { return }
            try? map.setLayerProperty(for: Self.coreLayerID, property: "line-trim-offset", value: [0.0, 0.0])
            try? map.setLayerProperty(for: Self.casingLayerID, property: "line-trim-offset", value: [0.0, 0.0])
            try? map.setLayerProperty(for: Self.pulseLayerID, property: "line-gradient", value: Self.clearGradient)
            routeMotionFinished = true
        }

        /// Reveal for 0.9s, then one 2.8s sweep. Static routes must not keep the GPU awake.
        private func tickRoute() {
            guard routeInstalled, let map = mapView?.mapboxMap else { return }
            let now = Date()
            let elapsed = routeAppeared.map { now.timeIntervalSince($0) } ?? 1
            let reduced = parent.reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            if reduced || elapsed >= 3.7 {
                finishRouteAppearance()
                return
            }
            let raw = min(max(elapsed / 0.9, 0), 1)
            let reveal = 1 - pow(1 - raw, 3)

            if reveal < 1 {
                let trim: [Double] = [min(reveal, 0.999), 1.0]
                try? map.setLayerProperty(for: Self.coreLayerID, property: "line-trim-offset", value: trim)
                try? map.setLayerProperty(for: Self.casingLayerID, property: "line-trim-offset", value: trim)
                try? map.setLayerProperty(for: Self.pulseLayerID, property: "line-gradient", value: Self.clearGradient)
                return
            }
            try? map.setLayerProperty(for: Self.coreLayerID, property: "line-trim-offset", value: [0.0, 0.0])
            try? map.setLayerProperty(for: Self.casingLayerID, property: "line-trim-offset", value: [0.0, 0.0])

            let cycle = max(elapsed - 0.9, 0) / 2.8
            let tailLength = 0.12
            let head = min(max(cycle, 0.001), 0.999)
            let tail = max(head - tailLength, 0)
            guard head - tail > 0.005 else {
                try? map.setLayerProperty(for: Self.pulseLayerID, property: "line-gradient", value: Self.clearGradient)
                return
            }
            let gradient: [Any] = [
                "interpolate", ["linear"], ["line-progress"],
                max(tail - 0.001, 0), "rgba(197, 170, 118, 0)",
                tail, "rgba(197, 170, 118, 0)",
                head, "rgba(255, 255, 255, 0.95)",
                min(head + 0.001, 1), "rgba(255, 255, 255, 0)",
            ]
            try? map.setLayerProperty(for: Self.pulseLayerID, property: "line-gradient", value: gradient)
        }

        private static let clearGradient: [Any] = [
            "interpolate", ["linear"], ["line-progress"],
            0, "rgba(0, 0, 0, 0)",
            1, "rgba(0, 0, 0, 0)",
        ]

        // MARK: Markers

        func updateSonar(_ point: GeoPoint?) {
            guard styleReady, let map = mapView?.mapboxMap else { return }
            searchPulse.update(at: point, on: map, reduceMotion: parent.reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled)
            if searchPulse.needsFrames { ensureFrameTimer() }
        }

        func removeSearchPulse() {
            guard let map = mapView?.mapboxMap else { return }
            searchPulse.remove(from: map)
        }

        func updatePin(_ kind: MapPinKind, at point: GeoPoint?, label: String?) {
            guard let mapView else { return }
            guard let point else {
                pins[kind]?.remove()
                pins[kind] = nil
                banners.removeValue(forKey: kind)?.remove()
                return
            }
            // Pin geometry never changes with banner width or placement. Each banner has its own anchor.
            let leading: CGFloat = 8
            let view = AnyView(
                MapPin(kind: kind)
                    .accessibilityLabel(label ?? "")
                    .padding(.leading, leading)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
            )
            if let hosted = pins[kind] {
                hosted.move(to: point)
                if hosted.label != label {
                    hosted.label = label
                    hosted.update(rootView: view)
                }
            } else {
                let hosted = HostedMarker(rootView: view, anchor: .bottomLeft)
                hosted.label = label
                // Negative offsetX moves the view left so the head's centre line lands on the coordinate.
                hosted.offsetX = -(leading + MapPin.headSize / 2)
                // The coordinate is the centre of the contact dot, not the bottom edge of its canvas.
                hosted.offsetY = -MapPin.baseSize / 2
                hosted.onFrameChanged = { [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    self.banners[kind]?.layout(on: mapView)
                }
                hosted.attach(to: mapView, at: point)
                pins[kind] = hosted
            }
            if let label {
                if let banner = banners[kind] {
                    banner.update(label: label, point: point, on: mapView)
                } else if let pin = pins[kind] {
                    banners[kind] = MapMarkerBanner(label: label, point: point, pin: pin, mapView: mapView)
                }
            } else {
                banners.removeValue(forKey: kind)?.remove()
            }
        }

        /// One numbered pin per intermediate stop; pins beyond the current count are removed.
        func updateStops(_ stops: [GeoPoint], labelled: Bool) {
            for (index, point) in stops.enumerated() {
                updatePin(.stop(index), at: point, label: labelled ? L(.stopLabel, index + 1) : nil)
            }
            let stale = pins.keys.filter { kind in
                if case .stop(let index) = kind { return index >= stops.count }
                return false
            }
            for kind in stale {
                pins[kind]?.remove()
                pins[kind] = nil
                banners.removeValue(forKey: kind)?.remove()
            }
        }

        // MARK: 3D vehicles

        /// Retains each native annotation across updates; all four tier models are built locally.
        private func syncVehicles() {
            guard let mapView else { return }
            var poses = nearbyVehicles.mapValues(\.pose)
            if let driverShown { poses[Self.driverModelID] = driverShown }
            let staleIDs = vehicleMarkers.keys.filter { poses[$0] == nil }
            for id in staleIDs {
                vehicleMarkers.removeValue(forKey: id)?.remove()
            }
            let state = mapView.mapboxMap.cameraState
            for (id, pose) in poses {
                let tier = id == Self.driverModelID ? driverTier : (nearbyVehicles[id]?.tier ?? .economy)
                if let marker = vehicleMarkers[id] {
                    marker.setTier(tier)
                    marker.move(to: pose.point, heading: pose.heading, bearing: state.bearing, pitch: state.pitch, zoom: state.zoom)
                } else {
                    vehicleMarkers[id] = ProceduralTukTukMarker(
                        mapView: mapView, point: pose.point, heading: pose.heading,
                        isAssigned: id == Self.driverModelID,
                        tier: tier
                    )
                }
            }
        }

        func removeVehicles() {
            if let mapView { driverEyeCamera.stop(on: mapView, restore: false) }
            for marker in vehicleMarkers.values { marker.remove() }
            vehicleMarkers.removeAll()
            for banner in banners.values { banner.remove() }
            banners.removeAll()
            for pin in pins.values { pin.remove() }
            pins.removeAll()
            cancelables.removeAll()
        }

        func updateDriver(position: GeoPoint?, heading: Double, tier: RideTier) {
            guard let position else {
                if driverShown != nil || driverTo != nil {
                    driverFrom = nil
                    driverTo = nil
                    driverShown = nil
                    syncVehicles()
                }
                return
            }
            if driverTier != tier {
                driverTier = tier
                syncVehicles()
            }
            if let target = driverTo, target.point == position, target.heading == heading { return }
            let start = driverShown ?? Pose(point: position, heading: heading)
            driverFrom = start
            driverTo = Pose(point: position, heading: heading)
            driverMoveStarted = Date()
            if driverShown == nil {
                driverShown = start
                syncVehicles()
            }
            ensureFrameTimer()
        }

        /// Advances the driver glide one frame. Returns `true` while still moving.
        private func tickDriver() -> Bool {
            guard let from = driverFrom, let to = driverTo else { return false }
            let t = min(Date().timeIntervalSince(driverMoveStarted) / Self.driverGlideDuration, 1)
            let delta = ((to.heading - from.heading + 540).truncatingRemainder(dividingBy: 360)) - 180
            let pose = Pose(
                point: GeoPoint(
                    latitude: from.point.latitude + (to.point.latitude - from.point.latitude) * t,
                    longitude: from.point.longitude + (to.point.longitude - from.point.longitude) * t
                ),
                heading: from.heading + delta * t
            )
            if pose != driverShown {
                driverShown = pose
                updateDriverCamera()
                syncVehicles()
            }
            if t >= 1 {
                driverFrom = nil
                return false
            }
            return true
        }

        func updateDriverCamera() {
            guard let mapView else { return }
            if !parent.followsDriver { driverFollowInterrupted = false }
            guard parent.followsDriver, !driverFollowInterrupted, activeGestures.isEmpty, let pose = driverShown else {
                if driverEyeCamera.isActive {
                    driverEyeCamera.stop(on: mapView, restore: true)
                    appliedCamera = parent.camera
                    syncVehicles()
                }
                return
            }
            let wasActive = driverEyeCamera.isActive
            let rear = driverEyeCamera.cameraPoint(for: pose.point, heading: pose.heading)
            let vehicleGround = diorama?.groundHeight(at: pose.point)
                ?? mapView.mapboxMap.elevation(at: pose.point.coordinate)
            let rearGround = diorama?.groundHeight(at: rear)
                ?? mapView.mapboxMap.elevation(at: rear.coordinate)
            let ground = [vehicleGround, rearGround].compactMap { $0 }.filter(\.isFinite).max()
            driverEyeCamera.update(point: pose.point, heading: pose.heading, ground: ground, on: mapView)
            if wasActive != driverEyeCamera.isActive { syncVehicles() }
            // Continuous driving must not perpetually postpone the normal camera-settle debounce.
            if Date().timeIntervalSince(lastDioramaFollowUpdate) >= 0.5 {
                lastDioramaFollowUpdate = Date()
                diorama?.update()
            }
        }

        func updateNearby(_ drivers: [Driver]) {
            var changedTiers: Set<RideTier> = []
            let ids = Set(drivers.map(\.id))
            for (id, vehicle) in nearbyVehicles where !ids.contains(id) {
                nearbyVehicles[id] = nil
                changedTiers.insert(vehicle.tier)
            }
            for item in drivers {
                let vehicle = Vehicle(tier: item.tier, pose: Pose(point: item.position, heading: item.heading))
                if let previous = nearbyVehicles[item.id] {
                    if previous != vehicle {
                        nearbyVehicles[item.id] = vehicle
                        changedTiers.insert(vehicle.tier)
                        if previous.tier != vehicle.tier { changedTiers.insert(previous.tier) }
                    }
                } else {
                    nearbyVehicles[item.id] = vehicle
                    changedTiers.insert(vehicle.tier)
                }
            }
            if !changedTiers.isEmpty { syncVehicles() }
        }

        // MARK: GestureManagerDelegate

        nonisolated func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
            MainActor.assumeIsolated {
                activeGestures.insert(String(describing: gestureType))
                if driverEyeCamera.isActive, let mapView {
                    driverFollowInterrupted = true
                    driverEyeCamera.stop(on: mapView, restore: false)
                    appliedCamera = parent.camera
                    syncVehicles()
                    parent.onDriverFollowInterrupted?()
                }
                cancelCameraSettlement()
                if parent.highlightsSelectionBuilding, let mapView {
                    buildingHighlight.clear(on: mapView.mapboxMap)
                }
                parent.onCameraWillMove?(true)
            }
        }

        nonisolated func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {
            MainActor.assumeIsolated {
                activeGestures.remove(String(describing: gestureType))
                if willAnimate { scheduleCameraSettlement() }
                else { finishCameraMotion() }
            }
        }

        nonisolated func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {
            MainActor.assumeIsolated { finishCameraMotion() }
        }
    }
}

/// A Mapbox `ViewAnnotation` whose content is a live SwiftUI view.
final class HostedMarker {
    private let host: UIHostingController<AnyView>
    private let container: MapAnnotationContainer
    private var annotation: ViewAnnotation? = nil
    private var currentPoint: GeoPoint? = nil
    private let anchor: ViewAnnotationAnchor
    /// Additional X offset in points; positive moves the view right. Set before `attach`.
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    /// Cheap identity of the hosted content so callers can skip redundant updates.
    var label: String? = nil
    var onFrameChanged: (() -> Void)? = nil

    var size: CGSize { container.contentSize }

    /// Coordinate this marker is anchored to, so callers can rebuild it in place.
    var point: GeoPoint? { currentPoint }

    init(rootView: AnyView, anchor: ViewAnnotationAnchor) {
        self.anchor = anchor
        host = UIHostingController(rootView: rootView)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        let measured = host.sizeThatFits(in: CGSize(width: 400, height: 400))
        container = MapAnnotationContainer(content: host.view, size: measured)
        container.layoutIfNeeded()
    }

    func attach(to mapView: MapView, at point: GeoPoint) {
        let annotation = ViewAnnotation(coordinate: point.coordinate, view: container)
        annotation.allowOverlap = true
        annotation.allowOverlapWithPuck = true
        annotation.allowZElevate = false
        annotation.variableAnchors = [ViewAnnotationAnchorConfig(anchor: anchor, offsetX: offsetX, offsetY: offsetY)]
        annotation.ignoreCameraPadding = true
        annotation.onFrameChanged = { [weak self] _ in self?.onFrameChanged?() }
        annotation.onVisibilityChanged = { [weak self] _ in self?.onFrameChanged?() }
        mapView.viewAnnotations.add(annotation)
        self.annotation = annotation
        currentPoint = point
    }

    /// Repositions the annotation; a no-op when the coordinate is unchanged so SwiftUI re-renders never
    /// nudge a settled pin.
    func move(to point: GeoPoint) {
        guard point != currentPoint else { return }
        currentPoint = point
        annotation?.annotatedFeature = .geometry(Point(point.coordinate))
    }

    func update(rootView: AnyView) {
        host.rootView = rootView
        resize()
        annotation?.setNeedsUpdateSize()
    }

    /// Coordinate recovered from the native pin frame, including partially clipped annotations.
    func contactPoint(in mapView: MapView) -> CGPoint? {
        guard anchor == .bottomLeft, container.superview != nil, !container.isHidden else { return nil }
        return container.convert(CGPoint(x: -offsetX, y: container.bounds.height + offsetY), to: mapView)
    }

    func setOffset(x: CGFloat, y: CGFloat) {
        guard abs(offsetX - x) > 0.1 || abs(offsetY - y) > 0.1 else { return }
        offsetX = x
        offsetY = y
        annotation?.variableAnchors = [ViewAnnotationAnchorConfig(anchor: anchor, offsetX: x, offsetY: y)]
    }

    func setVisible(_ visible: Bool) {
        if annotation?.visible != visible { annotation?.visible = visible }
    }

    /// On-screen frame of the hosted view, or nil when it isn't placed.
    func frame(in mapView: MapView) -> CGRect? {
        guard container.superview != nil, !container.isHidden, annotation?.visible != false else { return nil }
        return container.convert(container.bounds, to: mapView)
    }

    func remove() {
        annotation?.remove()
        annotation = nil
    }

    private func resize() {
        let size = host.sizeThatFits(in: CGSize(width: 400, height: 400))
        container.contentSize = CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}
