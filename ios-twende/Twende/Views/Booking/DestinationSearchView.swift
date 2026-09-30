import SwiftUI

/// Destination search and inline route editing share one screen; moves re-quote immediately.
struct DestinationSearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var search: PlaceSearchService = PlaceSearchService()
    @FocusState private var isFocused: Bool
    @Environment(\.foldLayout) private var foldLayout
    @State private var previewCamera: MapCameraTarget = .automatic

    private var isAddingStop: Bool { env.flow.searchTarget == .stop }
    private var replacingIndex: Int? {
        if case .replace(let index) = env.flow.searchTarget { return index }
        return nil
    }
    /// Filling something other than the destination field.
    private var isSubTarget: Bool { isAddingStop || replacingIndex != nil }

    private var headerTitle: String {
        env.flow.isEditingLiveRoute ? L(.changeRoute) : L(.planYourTrip)
    }

    private var fieldPlaceholder: String {
        guard let index = replacingIndex else { return isAddingStop ? L(.whereToNext) : L(.whereTo) }
        if index == 0 { return L(.searchPickup) }
        return index == env.flow.orderedPlaces.count - 1 && env.flow.destination != nil ? L(.whereTo) : L(.whereToNext)
    }

    private func pick(_ place: Place) {
        if let index = replacingIndex {
            env.flow.replace(at: index, with: place)
            isFocused = false
        } else if isAddingStop {
            env.flow.add(stop: place)
        } else {
            env.flow.choose(destination: place)
        }
    }

    private func goBack() {
        if isSubTarget {
            env.flow.cancelAddStop()
            isFocused = false
            return
        }
        if env.flow.isEditingLiveRoute { env.flow.endLiveRouteEdit() } else { dismiss() }
    }

    var body: some View {
        Group {
            if foldLayout != nil {
                // Open inner display: planner left of the fold, the route taking shape on the right.
                DuoSplitView { planner } secondary: { routePreview }
            } else {
                planner
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { isFocused = env.flow.destination == nil }
        .onChange(of: env.flow.searchTarget) { _, target in isFocused = target != .destination || env.flow.destination == nil }
        .task(id: env.flow.searchQuery) { await search.search(env.flow.searchQuery) }
    }

    private var routePreview: some View {
        TripMapView(
            camera: $previewCamera,
            pickup: env.flow.pickup.point,
            destination: env.flow.destination?.point,
            stops: env.flow.stops.map(\.point),
            routePoints: env.flow.route?.points ?? [],
            interactionModes: [.pan, .zoom]
        )
        .ignoresSafeArea()
        .onAppear { framePreview() }
        .onChange(of: env.flow.waypoints) { _, _ in framePreview() }
        .onChange(of: env.flow.route?.points.count) { _, _ in framePreview() }
    }

    private func framePreview() {
        var points = env.flow.waypoints
        if let route = env.flow.route { points.append(contentsOf: route.points) }
        guard !points.isEmpty else { return }
        previewCamera = points.count == 1
            ? .region(MapCameraHelper.region(centre: points[0], spanKm: 2))
            : .rect(MapCameraHelper.rect(fitting: points, paddingFraction: 0.3))
    }

    private var planner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MapCircleButton(systemImage: "arrow.left", accessibilityLabel: L(.back), isFloating: false, size: 44) { goBack() }
                Text(headerTitle)
                    .font(TwendeFont.title)
                    .foregroundStyle(TwendeColor.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            VStack(spacing: 10) {
                InlineRouteEditor { isFocused = false }
                if showsSearchField { searchField }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if let preferred = env.flow.preferredDriver {
                preferredDriverBanner(preferred)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if env.flow.searchQuery.isEmpty {
                        savedChips.padding(.bottom, 8)
                        setOnMapRow
                        RowDivider(leading: 72)
                        if !isSubTarget && env.flow.canAddStop {
                            addStopRow
                            RowDivider(leading: 72)
                        }
                        ForEach(env.store.recents) { recent in
                            PlaceRow(place: recent.place, icon: .recent) { pick(recent.place) }
                                .onScreenEntity(PlaceEntity(recent.place))
                            RowDivider(leading: 72)
                        }
                        SectionHeader(title: L(.popularPlaces))
                            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
                        ForEach(DemoPlaces.catalogue.prefix(6)) { place in
                            PlaceRow(place: place, trailing: distanceLabel(to: place)) { pick(place) }
                                .onScreenEntity(PlaceEntity(place))
                            RowDivider(leading: 72)
                        }
                    } else {
                        setOnMapRow
                        RowDivider(leading: 72)
                        if search.results.isEmpty && !search.isSearching { noResults }
                        ForEach(search.results) { place in
                            PlaceRow(place: place, trailing: distanceLabel(to: place)) { pick(place) }
                                .onScreenEntity(PlaceEntity(place))
                            RowDivider(leading: 72)
                        }
                        if search.isSearching {
                            HStack(spacing: 10) {
                                ProgressView().tint(TwendeColor.accentText)
                                Text(L(.searchingPlaces)).font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if env.flow.destination != nil && !isSubTarget {
                VStack(spacing: 8) {
                    if env.flow.isEditingLiveRoute, let quote = env.flow.selectedQuote {
                        HStack {
                            Text(L(.newFare)).font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
                            Spacer()
                            Text(Format.tzs(quote.breakdown.total)).font(TwendeFont.fare).foregroundStyle(TwendeColor.ink)
                                .contentTransition(.numericText())
                        }
                    }
                    Button(env.flow.isEditingLiveRoute ? L(.updateRoute) : L(.continueAction)) {
                        isFocused = false
                        if env.flow.isEditingLiveRoute {
                            Haptics.success()
                            env.flow.commitLiveRouteEdit()
                        } else {
                            env.flow.path = [.search, .confirmPickup]
                        }
                    }
                    .buttonStyle(.twendePrimary)
                    .accessibilityIdentifier("route.continue")
                }
                .padding(16)
                .background(TwendeColor.surface)
            }
        }
        .background(TwendeColor.surface.ignoresSafeArea())
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(TwendeColor.inkSecondary)
            TextField(fieldPlaceholder, text: Bindable(env.flow).searchQuery)
                .font(TwendeFont.bodyMedium)
                .foregroundStyle(TwendeColor.ink)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("booking.destination")
            if !env.flow.searchQuery.isEmpty {
                Button { env.flow.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TwendeColor.inkTertiary).frame(width: 44, height: 44)
                }
                .accessibilityLabel(L(.clear))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TwendeColor.ink, lineWidth: 2))
    }

    private func preferredDriverBanner(_ driver: Driver) -> some View {
        HStack(spacing: 12) {
            TierGlyph(tier: driver.tier, width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(.requestingDriver, driver.firstName)).font(TwendeFont.captionMedium).foregroundStyle(TwendeColor.ink)
                Text(L(.chooseDestinationFirst)).font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
            }
            Spacer()
            Button(L(.remove)) { env.flow.preferredDriverID = nil }
                .font(TwendeFont.captionMedium).foregroundStyle(TwendeColor.inkSecondary)
        }
        .padding(.vertical, 8)
    }

    private var savedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(env.store.savedPlaces) { saved in
                    ChipButton(title: saved.label, icon: saved.kind.icon3D) { pick(saved.place) }
                }
                if env.store.savedPlaces.isEmpty {
                    ChipButton(title: L(.addHome), icon: .house) { env.flow.openMenu(at: .editSavedPlace(nil)) }
                }
            }
        }
        .contentMargins(.horizontal, 16)
    }

    private var addStopRow: some View {
        Button {
            Haptics.tap()
            env.flow.beginAddStop()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TwendeColor.ink).frame(width: 40, height: 40)
                    .background(TwendeColor.surfaceAlt, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.flow.stops.isEmpty ? L(.addStop) : L(.addAnotherStop)).font(TwendeFont.bodyMedium).foregroundStyle(TwendeColor.ink)
                    Text(L(.maxStopsReached, BookingFlow.maxStops)).font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(TwendeColor.inkTertiary)
            }
            .padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityIdentifier("route.addStop")
    }

    private var setOnMapRow: some View {
        Button {
            Haptics.tap()
            if let index = replacingIndex {
                env.flow.beginSetOnMap(for: .replace(index))
            } else {
                env.flow.beginSetOnMap(for: isAddingStop ? .stop : .destination)
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "map").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TwendeColor.ink).frame(width: 40, height: 40)
                    .background(TwendeColor.surfaceAlt, in: .circle)
                Text(L(.setOnMap)).font(TwendeFont.bodyMedium).foregroundStyle(TwendeColor.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(TwendeColor.inkTertiary)
            }
            .padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
    }

    /// Once the route is complete the list itself is the editor; the field returns when a row is tapped,
    /// a stop is being added, or the passenger starts typing.
    private var showsSearchField: Bool {
        env.flow.destination == nil || isSubTarget || !env.flow.searchQuery.isEmpty || isFocused
    }

    private var noResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(.noResultsTitle)).font(TwendeFont.bodyMedium).foregroundStyle(TwendeColor.ink)
            Text(L(.noResultsBody)).font(TwendeFont.caption).foregroundStyle(TwendeColor.inkSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
    }

    private func distanceLabel(to place: Place) -> String {
        Format.distance(env.flow.pickup.point.distanceKm(to: place.point) * RoutingService.roadFactor)
    }
}
