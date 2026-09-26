import SwiftUI

/// B3 — confirm where the driver should meet you, with an optional note.
struct ConfirmPickupView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraTarget = .automatic
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TripMapView(
                camera: $camera,
                pickup: env.flow.pickup.point,
                destination: env.flow.destination?.point,
                stops: env.flow.stops.map(\.point),
                routePoints: env.flow.route?.points ?? [],
                interactionModes: [.pan, .zoom]
            )
            .ignoresSafeArea()

            MapCircleButton(systemImage: "arrow.left", accessibilityLabel: L(.back)) {
                dismiss()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomPanel(showsGrabber: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L(.confirmPickupTitle))
                        .font(TwendeFont.title)
                        .foregroundStyle(TwendeColor.ink)

                    RouteStopsView(
                        pickup: env.flow.pickup.name,
                        destination: env.flow.destination?.name ?? "",
                        stops: env.flow.stops.map(\.name),
                        pickupDetail: env.flow.pickup.address,
                        destinationDetail: env.flow.destination?.address,
                        pickupAccessory: L(.change),
                        onPickupTap: { env.flow.beginSetOnMap(for: .pickup) },
                        onRemoveStop: { index in
                            withAnimation(.spring(duration: 0.3)) { env.flow.removeStop(at: index) }
                        }
                    )

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { routeActions }
                        VStack(alignment: .leading, spacing: 4) { routeActions }
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(TwendeColor.inkSecondary)
                        TextField(L(.pickupNotePlaceholder), text: Bindable(env.flow).pickupNote)
                            .font(TwendeFont.body)
                            .foregroundStyle(TwendeColor.ink)
                            .focused($isNoteFocused)
                            .submitLabel(.done)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isNoteFocused ? TwendeColor.ink : .clear, lineWidth: 2)
                    )

                    Button(L(.confirmPickup)) {
                        Haptics.medium()
                        isNoteFocused = false
                        env.flow.confirmPickup()
                    }
                    .buttonStyle(.twendePrimary)
                    .accessibilityIdentifier("booking.confirmPickup")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .primaryOnScreen(env.flow.destination.map { PlaceEntity($0) }, activity: TwendeActivity.pickup, title: env.flow.destination?.name ?? "")
        .onAppear { frame() }
        .onChange(of: env.flow.pickup) { _, _ in frame() }
        .onChange(of: env.flow.waypoints) { _, _ in frame() }
        .onChange(of: env.flow.route?.points.count) { _, _ in frame() }
    }

    @ViewBuilder
    private var routeActions: some View {
        Button {
            isNoteFocused = false
            env.flow.searchQuery = ""
            env.flow.searchTarget = .destination
            env.flow.path = [.search]
            Haptics.tap()
        } label: {
            Label(L(.reorderRoute), systemImage: "arrow.up.arrow.down")
                .font(TwendeFont.captionMedium)
                .frame(minHeight: 44)
                .fixedSize()
        }
        .buttonStyle(.twendeGhost)
        .accessibilityIdentifier("route.reorder")

        if env.flow.canAddStop {
            Button {
                Haptics.tap()
                env.flow.beginAddStop()
            } label: {
                Label(env.flow.stops.isEmpty ? L(.addStop) : L(.addAnotherStop), systemImage: "plus")
                    .font(TwendeFont.captionMedium)
                    .frame(minHeight: 44)
                    .fixedSize()
            }
            .buttonStyle(.twendeGhost)
        }
    }

    private func frame() {
        var points = env.flow.waypoints
        if let route = env.flow.route { points.append(contentsOf: route.points) }
        let rect = MapCameraHelper.rect(fitting: points, bottomFraction: 0.42, paddingFraction: 0.3)
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .rect(rect)
        }
    }
}
