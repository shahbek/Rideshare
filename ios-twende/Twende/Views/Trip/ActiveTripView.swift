import SwiftUI
import UIKit

/// B5–B9 — replaces Home while a request is live. The map is shared; the panel swaps per phase.
struct ActiveTripView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trip: Trip
    @State private var camera: MapCameraTarget = .automatic
    @State private var lastFramedPhase: TripPhase? = nil
    @State private var lastFollowAt: Date = .distantPast
    @State private var panelHeight: CGFloat = 340
    @State private var isPanelExpanded: Bool = false
    @State private var panelDrag: CGFloat = 0
    @GestureState private var isDraggingPanel: Bool = false
    @State private var reframeTask: Task<Void, Never>? = nil
    @State private var viewHeight: CGFloat = 844
    @State private var mapFrame: CGRect = .zero
    @State private var topControlsFrame: CGRect = .zero
    @State private var bottomControlsFrame: CGRect = .zero
    @State private var tripPanelFrame: CGRect = .zero
    @Environment(\.foldLayout) private var foldLayout

    private var driver: Driver? { env.trips.assignedDriver }
    private var canUseDriverEye: Bool {
        env.trips.driverPosition != nil && [.driverAssigned, .driverArrived, .inTrip].contains(trip.phase)
    }
    private var followsDriver: Bool { env.settings.driverEyeEnabled && canUseDriverEye }
    private var showsChrome: Bool { trip.phase != .searching && trip.phase != .noDrivers }

    var body: some View {
        ZStack {
            TripMapView(
                camera: $camera,
                pickup: trip.phase == .inTrip ? nil : trip.pickup.point,
                destination: trip.phase == .searching || trip.phase == .noDrivers ? nil : trip.destination.point,
                stops: trip.phase == .searching || trip.phase == .noDrivers ? [] : trip.stopList.map(\.point),
                routePoints: routePoints,
                driverPosition: env.trips.driverPosition,
                driverHeading: env.trips.driverHeading,
                driverTier: trip.tier,
                followsDriver: followsDriver,
                driverVisibleRect: driverVisibleRect,
                onDriverFollowInterrupted: { env.settings.driverEyeEnabled = false },
                isSearching: trip.phase == .searching,
                pickupEtaMinutes: trip.phase == .driverAssigned ? max(env.trips.driverEtaMinutes, 1) : nil,
                destinationEtaMinutes: trip.phase == .inTrip ? max(env.trips.remainingTripMinutes, 1) : nil,
                interactionModes: [.pan, .zoom],
                illuminatedDestination: trip.destination.point
            )
            .ignoresSafeArea()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mapFrame = $0 }

            VStack(spacing: 12) {
                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        if showsChrome {
                            MapCircleButton(systemImage: "square.and.arrow.up", accessibilityLabel: L(.shareTrip)) {
                                shareTrip()
                            }
                        }
                        Spacer()
                        if showsChrome {
                            MapCircleButton(systemImage: "shield.fill", accessibilityLabel: L(.sos), tint: TwendeColor.danger, icon3D: .siren) {
                                env.flow.activeSheet = .sos
                            }
                        }
                    }
                    if env.trips.needsRoadRoute {
                        roadRouteStatus
                    }
                    if !env.network.isOnline {
                        OfflineBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { topControlsFrame = $0 }
                Spacer()
                HStack(spacing: 12) {
                    if canUseDriverEye {
                        Toggle(L(.driverEye), isOn: Bindable(env.settings).driverEyeEnabled)
                            .font(TwendeFont.label)
                            .toggleStyle(.button)
                            .tint(TwendeColor.primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 48)
                            .background(TwendeColor.surface, in: .rect(cornerRadius: 8))
                            .accessibilityIdentifier("trip.driverEye")
                    }
                    Spacer(minLength: 0)
                    MapCircleButton(systemImage: "location.fill", accessibilityLabel: L(.recentre)) {
                        env.settings.driverEyeEnabled = false
                        frame(force: true)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bottomControlsFrame = $0 }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .animation(.spring(duration: 0.4), value: env.network.isOnline)
        }
        .mapPanel {
            BottomPanel(showsGrabber: showsChrome) {
                Group {
                    switch trip.phase {
                    case .searching:
                        SearchingPanel(trip: trip)
                    case .noDrivers:
                        NoDriversPanel(trip: trip)
                    case .driverAssigned, .driverArrived:
                        if let driver {
                            DriverEnRoutePanel(trip: trip, driver: driver, isExpanded: isPanelExpanded, dragTranslation: panelDrag)
                        }
                    case .inTrip:
                        if let driver {
                            InTripPanel(trip: trip, driver: driver, isExpanded: isPanelExpanded, dragTranslation: panelDrag)
                        }
                    default:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                routingAttribution
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tripPanelFrame = $0 }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .updating($isDraggingPanel) { _, active, _ in active = true }
                    .onChanged { value in
                        guard showsChrome, abs(value.translation.height) > abs(value.translation.width) else { return }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { panelDrag = value.translation.height }
                    }
                    .onEnded { value in
                        guard showsChrome, panelDrag != 0 else { return }
                        let expand = value.predictedEndTranslation.height < 0
                        if expand != isPanelExpanded { Haptics.selection() }
                        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)) {
                            isPanelExpanded = expand
                            panelDrag = 0
                        }
                    }
            )
            .onChange(of: isDraggingPanel) { _, active in
                if !active, panelDrag != 0 {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)) { panelDrag = 0 }
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                // Only accept settled heights: intermediate animation frames must not re-frame the camera.
                if abs(height - panelHeight) > 24 {
                    panelHeight = height
                }
            }
            .animation(.spring(duration: 0.45), value: trip.phase)
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.92), value: isPanelExpanded)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewHeight = max($0, 1) }
        .onChange(of: foldLayout) { _, _ in scheduleReframe() }
        .onChange(of: panelHeight) { _, _ in
            // The map's usable area changed; re-frame once the sheet has finished moving.
            scheduleReframe()
        }
        // Siri can read this ride off the screen: "where's my driver?", "what's my start code?", "cancel this".
        .primaryOnScreen(TripEntity(trip, env: env), activity: TwendeActivity.liveTrip, title: trip.destination.name)
        .onAppear {
            frame(force: true)
            if env.trips.needsRoadRoute { env.trips.refreshRoadRoutes() }
        }
        .onDisappear { reframeTask?.cancel() }
        .onChange(of: env.network.isOnline) { _, online in
            if online, env.trips.needsRoadRoute { env.trips.refreshRoadRoutes() }
        }
        .onChange(of: trip.phase) { _, _ in
            isPanelExpanded = false
            panelDrag = 0
            frame(force: true)
        }
        .onChange(of: env.trips.driverPosition) { _, _ in
            guard !followsDriver, trip.phase == .inTrip || trip.phase == .driverAssigned else { return }
            // Re-frame at most every 4s, and only when the vehicle has actually left the framed area, so the
            // camera glides instead of restarting its ease on every fix.
            let now = Date()
            guard now.timeIntervalSince(lastFollowAt) >= 4 else { return }
            lastFollowAt = now
            followDriver()
        }
    }

    private var routingAttribution: some View {
        HStack(spacing: 12) {
            Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            Link("OSRM · FOSSGIS", destination: URL(string: "https://routing.openstreetmap.de/about.html")!)
            Link("Fix the map", destination: URL(string: "https://www.openstreetmap.org/fixthemap")!)
        }
        .font(.caption2)
        .foregroundStyle(TwendeColor.ink)
        .frame(minHeight: 44)
    }

    private var roadRouteStatus: some View {
        VStack(spacing: 8) {
            Text(L(env.trips.isResolvingRoadRoute ? .roadRouteLoading : .roadRouteUnavailable))
                .font(TwendeFont.caption)
            if !env.trips.isResolvingRoadRoute {
                Button(L(.tryAgain)) { env.trips.refreshRoadRoutes() }
                    .frame(minHeight: 44)
            }
        }
        .padding(12)
        .background(TwendeColor.surface, in: .rect(cornerRadius: 8))
    }

    /// Route drawn on the map. In-trip it is the full route so the line stays still while the vehicle
    /// travels along it; trimming per fix made the map re-upload geometry four times a second.
    private var routePoints: [GeoPoint] {
        switch trip.phase {
        case .driverAssigned:
            return env.trips.approachRoute?.points ?? []
        default:
            return trip.route.points
        }
    }

    private func scheduleReframe() {
        reframeTask?.cancel()
        reframeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            frame(force: true)
        }
    }

    /// Available space is measured in one coordinate system, then converted to map-local points.
    /// The phone panel may already reduce the map's frame; intersection avoids double-counting it.
    private var driverVisibleRect: CGRect? {
        guard mapFrame.width > 0, mapFrame.height > 0 else { return nil }
        let left = mapFrame.minX + (foldLayout?.trailingMinX ?? 0) + 16
        let right = mapFrame.maxX - 16
        let top = max(mapFrame.minY, topControlsFrame.maxY) + 12
        var bottom = mapFrame.maxY - 16
        if bottomControlsFrame.height > 0 { bottom = min(bottom, bottomControlsFrame.minY - 12) }
        if foldLayout == nil, tripPanelFrame.height > 0 { bottom = min(bottom, tripPanelFrame.minY - 12) }
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left - mapFrame.minX, y: top - mapFrame.minY,
                      width: right - left, height: bottom - top)
    }

    private var bottomFraction: Double {
        min(max(panelHeight / viewHeight, 0.25), 0.75)
    }

    private func frame(force: Bool) {
        guard !followsDriver else { return }
        guard force || lastFramedPhase != trip.phase else { return }
        lastFramedPhase = trip.phase
        var points: [GeoPoint]
        switch trip.phase {
        case .searching, .noDrivers:
            points = [
                trip.pickup.point,
                trip.pickup.point.offset(eastMetres: 450, northMetres: 450),
                trip.pickup.point.offset(eastMetres: -450, northMetres: -450),
            ]
        case .driverAssigned:
            points = [trip.pickup.point] + (env.trips.approachRoute?.points ?? [])
            if let driverPosition = env.trips.driverPosition { points.append(driverPosition) }
        case .driverArrived:
            points = [
                trip.pickup.point,
                trip.pickup.point.offset(eastMetres: 300, northMetres: 300),
                trip.pickup.point.offset(eastMetres: -300, northMetres: -300),
            ]
        default:
            points = trip.route.points + trip.stopList.map(\.point) + [trip.destination.point]
            if let driverPosition = env.trips.driverPosition { points.append(driverPosition) }
        }
        let rect = MapCameraHelper.rect(fitting: points, bottomFraction: bottomFraction, paddingFraction: 0.3, fold: foldLayout)
        camera = .rect(rect)
    }

    private func followDriver() {
        guard let driverPosition = env.trips.driverPosition else { return }
        let target = trip.phase == .inTrip ? trip.destination.point : trip.pickup.point
        let rect = MapCameraHelper.rect(fitting: [driverPosition, target], bottomFraction: bottomFraction, paddingFraction: 0.35, fold: foldLayout)
        camera = .rect(rect)
    }

    private func shareTrip() {
        guard let driver else { return }
        let text = L(
            .shareTripMessage,
            driver.name,
            Format.plate(driver.vehicle.plate),
            trip.destination.name,
            "https://zuri.app/t/\(trip.id)"
        )
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        controller.popoverPresentationController?.sourceView = presenter.view
        presenter.present(controller, animated: true)
    }
}
