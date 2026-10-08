import SwiftUI

/// B1 — map root. Marti-style: service switcher on top of the sheet, then the "Where to?" bar, then places.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var camera: MapCameraTarget = .region(MapCameraHelper.homeRegion(around: DarEsSalaam.upanga))
    @State private var detentIndex: Int = 0
    @State private var isExploringMap: Bool = false
    @State private var contentAtTop: Bool = true
    @Environment(\.foldLayout) private var foldLayout

    private var nearby: [Driver] {
        env.drivers.nearbyOnline(near: env.flow.pickup.point)
    }

    private func eta(for family: ServiceFamily) -> Int? {
        let tier = family.defaultTier
        guard env.drivers.hasDriversNearby(tier: tier, near: env.flow.pickup.point) else { return nil }
        return env.drivers.pickupEta(tier: tier, near: env.flow.pickup.point)
    }

    private var favourites: [Driver] {
        env.drivers.favourites(ids: env.store.favouriteDriverIDs)
    }

    var body: some View {
      GeometryReader { geometry in
        ZStack {
            TripMapView(
                camera: $camera,
                pickup: env.flow.pickup.point,
                nearbyDrivers: nearby,
                favouriteIDs: Set(env.store.favouriteDriverIDs),
                showsPinLabels: false,
                onCameraWillMove: { isGesture in if isGesture { isExploringMap = true } },
                onBillboardTap: { adID in env.flow.activeSheet = .billboard(adID) }
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                if !env.network.isOnline {
                    OfflineBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()


            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .animation(.spring(duration: 0.4), value: env.network.isOnline)

            // Two detents only: a detached card at rest, edge-to-edge when tall. The sheet never covers the map.
            DraggableSheet(
                detents: [0.52, 0.72],
                detentIndex: $detentIndex,
                contentAtTop: contentAtTop,
                floatingControl: AnyView(
                    HStack(spacing: 12) {
                        MapCircleButton(systemImage: "square.3.layers.3d.top.filled", accessibilityLabel: L(.birdsEye), usesLiquidGlass: true) {
                            isExploringMap = true
                            camera = .topDown(requestID: UUID())
                        }
                        .accessibilityHint(L(.birdsEyeHint))
                        .accessibilityIdentifier("home.birdsEye")
                        MapCircleButton(systemImage: "location.fill", accessibilityLabel: L(.recentre), usesLiquidGlass: true) {
                            recentre()
                        }
                        .accessibilityIdentifier("home.recentre")
                    }
                )
            ) {
                sheetHeader
            } content: {
                sheetBody(bottomInset: geometry.safeAreaInsets.bottom)
            }
            .foldPanel()
        }
        .onChange(of: foldLayout) { _, _ in if !isExploringMap { recentre() } }
        .onAppear {
            env.flow.refreshPickupFromLocation()
            recentre(animated: false)
        }
        .onChange(of: env.location.devicePosition) { _, _ in
            env.flow.refreshPickupFromLocation()
        }
      }
    }

    // MARK: Sheet

    private var sheetHeader: some View {
        ServiceSwitcher(selection: Bindable(env.flow).service, etaMinutes: eta(for:))
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .accessibilityIdentifier("home.services")
    }

    private var searchButton: some View {
            Button {
                Haptics.tap()
                env.flow.beginSearch()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(TwendeColor.ink)
                    Text(L(.whereTo))
                        .font(TwendeFont.headline)
                        .foregroundStyle(TwendeColor.ink)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background {
                    Capsule()
                        .fill(TwendeColor.surface)
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                }
                .overlay(Capsule().strokeBorder(TwendeColor.border, lineWidth: 1))
            }
            .buttonStyle(.pressableCard)
            .accessibilityHint(L(.searchDestinationHint))
            .accessibilityIdentifier("home.search")
            .padding(.horizontal, 16)
    }

    private func sheetBody(bottomInset: CGFloat) -> some View {
      ZStack(alignment: .top) {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                quickPlaces
                    .padding(.vertical, 16)

                if !favourites.isEmpty {
                    favouriteDriversSection
                }

                recentsSection
            }
            .padding(.top, 72)
            .padding(.bottom, 32)
        }
        .contentMargins(.bottom, bottomInset + 16, for: .scrollContent)
        .scrollDisabled(detentIndex == 0)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top <= 1
        } action: { _, atTop in
            contentAtTop = atTop
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("home.sheet.content")
        searchButton.padding(.top, 10)
      }
    }

    /// Home / Work chips plus any extra saved places, in one horizontal row.
    private var quickPlaces: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(SavedPlaceKind.allCases.filter { $0 != .other }, id: \.self) { kind in
                    if let saved = env.store.savedPlace(kind: kind) {
                        ChipButton(title: saved.label, icon: kind.icon3D, minimumHeight: 48) {
                            env.flow.choose(destination: saved.place)
                        }
                        .onScreenEntity(PlaceEntity(saved.place, savedLabel: saved.label))
                    } else {
                        let addKey: LKey = kind == .home ? .addHome : .addWork
                        ChipButton(title: L(addKey), icon: kind.icon3D, minimumHeight: 48) {
                            env.flow.openMenu(at: .editSavedPlace(nil))
                        }
                    }
                }
                ForEach(env.store.savedPlaces.filter { $0.kind == .other }) { saved in
                    ChipButton(title: saved.label, icon: saved.kind.icon3D, minimumHeight: 48) {
                        env.flow.choose(destination: saved.place)
                    }
                    .onScreenEntity(PlaceEntity(saved.place, savedLabel: saved.label))
                }
            }
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .environment(\.isScrollEnabled, true)
    }

    private var favouriteDriversSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L(.myDrivers), actionTitle: L(.seeAll)) {
                env.flow.openMenu(at: .drivers)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(favourites) { driver in
                        Button {
                            Haptics.tap()
                            if driver.status == .online {
                                env.flow.activeSheet = .quickRequest(driver.id)
                            } else {
                                env.flow.openMenu(at: .driverDetail(driver.id))
                            }
                        } label: {
                            VStack(spacing: 6) {
                                DriverAvatar(driver: driver, size: 58)
                                Text(driver.firstName)
                                    .font(TwendeFont.label)
                                    .foregroundStyle(driver.status == .offline ? TwendeColor.inkSecondary : TwendeColor.ink)
                                    .lineLimit(1)
                            }
                            .frame(width: 66)
                        }
                        .buttonStyle(.pressableCard)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .environment(\.isScrollEnabled, true)
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if env.store.recents.isEmpty {
                PlaceRow(place: DemoPlaces.mlimaniCity, icon: .shoppingBag) {
                    env.flow.choose(destination: DemoPlaces.mlimaniCity)
                }
                RowDivider(leading: 72)
                PlaceRow(place: DemoPlaces.airport, icon: .plane) {
                    env.flow.choose(destination: DemoPlaces.airport)
                }
            } else {
                ForEach(Array(env.store.recents.prefix(4).enumerated()), id: \.element.id) { index, recent in
                    if index > 0 {
                        RowDivider(leading: 72)
                    }
                    PlaceRow(place: recent.place, icon: .recent) {
                        env.flow.choose(destination: recent.place)
                    }
                }
            }
        }
    }

    private func recentre(animated: Bool = true) {
        isExploringMap = false
        let region = MapCameraHelper.homeRegion(around: env.flow.pickup.point, fold: foldLayout)
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }
}

/// Destination row: rendered 3D icon, name and address.
struct PlaceRow: View {
    let place: Place
    /// Defaults to the place's own category icon (school, gym, food…) or the red push pin.
    var icon: Icon3D? = nil
    var trailing: String? = nil
    /// Zero when the row sits inside an already-inset page such as `MenuScreen`.
    var horizontalPadding: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 16) {
                Icon3DView(icon: icon ?? place.icon3D, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(TwendeFont.bodyMedium)
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(1)
                    Text(place.address)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
    }
}
