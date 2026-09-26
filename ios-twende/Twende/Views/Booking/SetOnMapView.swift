import SwiftUI

/// B2b — drag the map under a fixed pin to choose a pickup or destination.
struct SetOnMapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraTarget = .automatic
    @State private var isMoving: Bool = false
    @State private var mapFrame: CGRect = .zero
    @State private var pinAnchor: CGPoint? = nil
    @State private var resolved: Place? = nil

    private var target: SetOnMapTarget { env.flow.setOnMapTarget }
    private var isPickup: Bool { target == .pickup }

    private var pinKind: MapPinKind {
        switch target {
        case .pickup: .pickup
        case .destination: .destination
        case .stop: .stop(env.flow.stops.count)
        case .replace(let index): index == 0 ? .pickup : (isReplacingDestination(index) ? .destination : .stop(index - 1))
        }
    }

    private func isReplacingDestination(_ index: Int) -> Bool {
        env.flow.destination != nil && index == env.flow.orderedPlaces.count - 1
    }

    private var liftedLabel: String {
        switch target {
        case .pickup: L(.pickupLabel)
        case .destination: L(.dropoffLabel)
        case .stop: L(.stopLabel, env.flow.stops.count + 1)
        case .replace(let index): index == 0 ? L(.pickupLabel) : (isReplacingDestination(index) ? L(.dropoffLabel) : L(.stopLabel, index))
        }
    }

    private var title: String {
        switch target {
        case .pickup: L(.setPickupTitle)
        case .destination: L(.setDestinationTitle)
        case .stop: L(.setStopTitle)
        case .replace(let index): index == 0 ? L(.setPickupTitle) : (isReplacingDestination(index) ? L(.setDestinationTitle) : L(.setStopTitle))
        }
    }

    private var confirmTitle: String {
        switch target {
        case .pickup: L(.confirmPickupHere)
        case .destination: L(.confirmDestinationHere)
        case .stop: L(.confirmStopHere)
        case .replace(let index): index == 0 ? L(.confirmPickupHere) : (isReplacingDestination(index) ? L(.confirmDestinationHere) : L(.confirmStopHere))
        }
    }

    var body: some View {
        ZStack {
            TripMapView(
                camera: $camera,
                pickup: isPickup || target == .replace(0) ? nil : env.flow.pickup.point,
                stops: isPickup ? [] : env.flow.stops.map(\.point),
                selectionPoint: selectionPoint,
                highlightsSelectionBuilding: !isPickup,
                onCameraMoved: { point in
                    env.flow.mapCentre = point
                    isMoving = false
                },
                onCameraWillMove: { isGesture in
                    if isGesture && !isMoving {
                        isMoving = true
                    }
                }
            )
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .global)
            } action: { frame in
                mapFrame = frame
            }
            .ignoresSafeArea()

            CentrePin(
                kind: pinKind,
                label: isMoving ? liftedLabel : previewPlace.name,
                isLifted: isMoving,
                onAnchorChanged: { pinAnchor = $0 },
                viewport: mapFrame
            )

            VStack {
                HStack {
                    MapCircleButton(systemImage: "arrow.left", accessibilityLabel: L(.back)) {
                        dismiss()
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomPanel(showsGrabber: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title)
                        .font(TwendeFont.title)
                        .foregroundStyle(TwendeColor.ink)
                    HStack(spacing: 14) {
                        Icon3DView(icon: .pin, size: 40, lineOnly: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(previewPlace.name)
                                .font(TwendeFont.bodyMedium)
                                .foregroundStyle(TwendeColor.ink)
                            if isResolving {
                                Text(L(.findingAddress))
                                    .font(TwendeFont.caption)
                                    .foregroundStyle(TwendeColor.inkSecondary)
                            } else {
                                Text(previewPlace.address)
                                    .font(TwendeFont.caption)
                                    .foregroundStyle(TwendeColor.inkSecondary)
                                    .monospacedDigit()
                            }
                        }
                        Spacer()
                    }

                    if !previewPlace.isInServiceZone {
                        Label(L(.outOfZoneShort), systemImage: "exclamationmark.triangle.fill")
                            .font(TwendeFont.caption)
                            .foregroundStyle(TwendeColor.amberText)
                    }

                    Button(confirmTitle) {
                        Haptics.medium()
                        env.flow.confirmSetOnMap(resolved: resolved)
                    }
                    .buttonStyle(.twendePrimary)
                    .disabled(isMoving || isResolving || !previewPlace.isInServiceZone)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            camera = .region(MapCameraHelper.region(centre: env.flow.mapCentre, spanKm: 1.2))
        }
        .task(id: resolveKey) {
            // Only look up once the map settles, and never for every frame of a drag.
            guard !isMoving else { return }
            let point = env.flow.mapCentre
            if let hit = ReverseGeocoder.cached(for: point) { resolved = hit; return }
            resolved = nil
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let place = await ReverseGeocoder.place(for: point)
            guard !Task.isCancelled else { return }
            resolved = place
            lookupFinishedFor = resolveKey
        }
    }

    private var selectionPoint: CGPoint? {
        guard let pinAnchor, !mapFrame.isEmpty else { return nil }
        return CGPoint(x: pinAnchor.x - mapFrame.minX, y: pinAnchor.y - mapFrame.minY)
    }

    @State private var lookupFinishedFor: String? = nil

    private var resolveKey: String {
        String(format: "%.4f,%.4f,%d", env.flow.mapCentre.latitude, env.flow.mapCentre.longitude, isMoving ? 1 : 0)
    }

    private var isResolving: Bool {
        !isMoving && resolved == nil && lookupFinishedFor != resolveKey
    }

    /// Street address under the pin when Apple knows it, otherwise the nearest landmark.
    private var previewPlace: Place {
        resolved ?? DemoPlaces.label(for: env.flow.mapCentre)
    }
}
