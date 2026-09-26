import SwiftUI

/// C5 — home, work and other saved places. Plain rows with inset hairlines.
struct SavedPlacesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation

    private var otherPlaces: [SavedPlace] {
        env.store.savedPlaces.filter { $0.kind == .other }
    }

    var body: some View {
        MenuScreen(title: L(.savedPlaces)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach([SavedPlaceKind.home, .work], id: \.self) { kind in
                    if let saved = env.store.savedPlace(kind: kind) {
                        savedRow(saved)
                    } else {
                        let addKey: LKey = kind == .home ? .addHome : .addWork
                        MenuRow(
                            icon: kind.icon3D,
                            title: L(addKey),
                            subtitle: L(.tapToSet),
                            horizontalPadding: 0
                        ) {
                            navigation.path.append(.editSavedPlace(nil))
                        }
                    }
                    RowDivider(leading: 56)
                }
                ForEach(otherPlaces) { saved in
                    savedRow(saved)
                    RowDivider(leading: 56)
                }
                AddRow(title: L(.addPlace)) {
                    navigation.path.append(.editSavedPlace(nil))
                }
            }
        }
    }

    private func savedRow(_ saved: SavedPlace) -> some View {
        MenuRow(
            icon: saved.kind.icon3D,
            title: saved.label,
            subtitle: "\(saved.place.name) · \(saved.place.address)",
            horizontalPadding: 0
        ) {
            navigation.path.append(.editSavedPlace(saved.id))
        }
        .onScreenEntity(PlaceEntity(saved.place, savedLabel: saved.label))
        .contextMenu {
            Button(role: .destructive) {
                env.store.removeSavedPlace(id: saved.id)
            } label: {
                Label(L(.delete), systemImage: "trash")
            }
        }
    }
}

/// C5a — create or edit a saved place: kind, label and a searchable location.
struct EditSavedPlaceView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(MenuNavigation.self) private var navigation
    let savedPlaceID: String?

    @State private var kind: SavedPlaceKind = .home
    @State private var label: String = ""
    @State private var query: String = ""
    @State private var selectedPlace: Place? = nil
    @State private var search: PlaceSearchService = PlaceSearchService()
    @State private var didLoad: Bool = false

    private var existing: SavedPlace? {
        savedPlaceID.flatMap { env.store.savedPlace(id: $0) }
    }

    private var canSave: Bool {
        selectedPlace != nil && !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        MenuScreen(title: existing == nil ? L(.addPlace) : L(.editPlace), showsLargeTitle: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.placeType)).sectionLabelStyle()
                HStack(spacing: 8) {
                    ForEach(SavedPlaceKind.allCases, id: \.self) { option in
                        ChipButton(title: L(option.key), icon: option.icon3D, isSelected: kind == option) {
                            kind = option
                            if label.isEmpty || label == L(.homeLabel) || label == L(.workLabel) {
                                label = option == .other ? "" : L(option.key)
                            }
                        }
                    }
                }
            }

            TwendeTextField(title: L(.placeLabel), text: $label, placeholder: L(.placeLabelPlaceholder))

            VStack(alignment: .leading, spacing: 8) {
                Text(L(.location)).sectionLabelStyle()
                if let selectedPlace {
                    HStack(spacing: 16) {
                        Image(systemName: "mappin")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(TwendeColor.ink)
                            .frame(width: 40, height: 40)
                            .background(TwendeColor.surfaceAlt, in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedPlace.name)
                                .font(TwendeFont.bodyMedium)
                                .foregroundStyle(TwendeColor.ink)
                            Text(selectedPlace.address)
                                .font(TwendeFont.caption)
                                .foregroundStyle(TwendeColor.inkSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(L(.change)) {
                            self.selectedPlace = nil
                        }
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.badgeForeground)
                        .frame(minHeight: 44)
                    }
                    .frame(minHeight: 60)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(TwendeColor.inkSecondary)
                        TextField(L(.searchPlace), text: $query)
                            .font(TwendeFont.body)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(TwendeColor.primary, lineWidth: 1.5))
                    VStack(spacing: 0) {
                        ForEach(Array(search.results.filter(\.isInServiceZone).enumerated()), id: \.element.id) { index, place in
                            if index > 0 {
                                RowDivider(leading: 56)
                            }
                            PlaceRow(place: place, horizontalPadding: 0) {
                                selectedPlace = place
                                query = ""
                            }
                        }
                    }
                }
            }

            Button(L(.savePlace)) {
                guard let selectedPlace else { return }
                Haptics.success()
                env.store.upsertSavedPlace(id: existing?.id, kind: kind, label: label.trimmingCharacters(in: .whitespaces), place: selectedPlace)
                navigation.pop()
            }
            .buttonStyle(.twendePrimary)
            .disabled(!canSave)

            if let existing {
                Button(L(.deletePlace)) {
                    Haptics.warning()
                    env.store.removeSavedPlace(id: existing.id)
                    navigation.pop()
                }
                .buttonStyle(.twendeGhost)
            }
        }
        .task(id: query) { await search.search(query) }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let existing {
                kind = existing.kind
                label = existing.label
                selectedPlace = existing.place
            } else {
                kind = env.store.savedPlace(kind: .home) == nil ? .home : (env.store.savedPlace(kind: .work) == nil ? .work : .other)
                label = kind == .other ? "" : L(kind.key)
            }
        }
    }
}

extension SavedPlaceKind {
    var key: LKey {
        switch self {
        case .home: .homeLabel
        case .work: .workLabel
        case .other: .otherLabel
        }
    }
}
