import SwiftUI

/// Inline visit list. Drag handles reorder, tapping a row changes that visit in place and the trailing ×
/// clears it. UUIDs identify visits, so repeated addresses can be reordered independently.
struct InlineRouteEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entries: [RouteOrderEntry] = []
    var onInteraction: () -> Void = {}

    private var editingIndex: Int? {
        if case .replace(let index) = env.flow.searchTarget { return index }
        return nil
    }

    var body: some View {
        List {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(index: index, entry: entry)
                    .moveDisabled(isLocked(index))
            }
            .onMove { source, destination in
                // A live ride's car position always stays first.
                if env.flow.isEditingLiveRoute && (source.contains(0) || destination == 0) { return }
                onInteraction()
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                    entries.move(fromOffsets: source, toOffset: destination)
                    commit()
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: CGFloat(min(max(entries.count, 1), 4)) * 56)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityIdentifier("route.inline")
        .onChange(of: env.flow.orderedPlaces, initial: true) { _, places in
            guard entries.map(\.place) != places else { return }
            entries = places.map { RouteOrderEntry(place: $0) }
        }
    }

    private func row(index: Int, entry: RouteOrderEntry) -> some View {
        let isEditing = editingIndex == index
        return HStack(spacing: 10) {
            RouteMarker(kind: markerKind(index))
                .frame(width: 18)
                .accessibilityHidden(true)
            // Buttons inside an editing List never fire; tap gestures on plain content do.
            VStack(alignment: .leading, spacing: 2) {
                Text(role(index)).font(TwendeFont.figtree(11, weight: .medium))
                    .foregroundStyle(isEditing ? TwendeColor.accentText : TwendeColor.inkSecondary)
                Text(isEditing ? L(.changingThisStop) : entry.place.name).font(TwendeFont.bodyMedium)
                    .foregroundStyle(isEditing ? TwendeColor.inkSecondary : TwendeColor.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { beginEdit(index) }
            .accessibilityAddTraits(isLocked(index) ? [] : .isButton)
            .accessibilityHint(isLocked(index) ? "" : L(.tapToChange))

            if env.flow.canClearVisit(at: index) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TwendeColor.ink)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(TwendeColor.border, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { clear(index) }
                    .accessibilityLabel(isStop(index) ? L(.removeStop) : L(.clear))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("route.remove.\(index)")
            }
        }
        .frame(height: 52)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 0))
        .listRowBackground(isEditing ? TwendeColor.primaryTint : TwendeColor.surfaceAlt)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(role(index)), \(entry.place.name)")
        .accessibilityIdentifier("route.order.\(index)")
        .accessibilityAction(named: Text(L(.moveEarlier))) { shift(index, by: -1) }
        .accessibilityAction(named: Text(L(.moveLater))) { shift(index, by: 1) }
    }

    private func markerKind(_ index: Int) -> RouteMarker.Kind {
        if index == 0 { return .start }
        return isDestination(index) ? .end : .stop(index)
    }

    private func isDestination(_ index: Int) -> Bool {
        env.flow.destination != nil && index == entries.count - 1
    }

    private func isStop(_ index: Int) -> Bool {
        index > 0 && !isDestination(index)
    }

    private func isLocked(_ index: Int) -> Bool {
        env.flow.isEditingLiveRoute && index == 0
    }

    private func beginEdit(_ index: Int) {
        guard !isLocked(index) else { return }
        onInteraction()
        Haptics.tap()
        if editingIndex == index {
            env.flow.cancelAddStop()
        } else {
            env.flow.beginReplace(at: index)
        }
    }

    private func clear(_ index: Int) {
        onInteraction()
        Haptics.tap()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            env.flow.clearVisit(at: index)
        }
    }

    private func role(_ index: Int) -> String {
        if index == 0 { return env.flow.isEditingLiveRoute ? L(.yourRideNow) : L(.pickupLabel) }
        return isDestination(index) ? L(.dropoffLabel) : L(.stopLabel, index)
    }

    private func shift(_ index: Int, by delta: Int) {
        guard entries.indices.contains(index + delta), !isLocked(index), !isLocked(index + delta) else { return }
        onInteraction()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            entries.swapAt(index, index + delta)
            commit()
        }
    }

    private func commit() {
        if env.flow.reorderRoute(entries.map(\.place)) { Haptics.selection() }
    }
}

/// Route glyphs shared by the planner and summaries: a black ring with a white centre for the start,
/// numbered ink discs for stops, and an ink square for the drop-off.
struct RouteMarker: View {
    enum Kind: Equatable {
        case start
        case stop(Int)
        case end
    }

    let kind: Kind
    var size: CGFloat = 14

    var body: some View {
        switch kind {
        case .start:
            Circle()
                .fill(TwendeColor.surface)
                .overlay(Circle().strokeBorder(TwendeColor.ink, lineWidth: size * 0.3))
                .frame(width: size, height: size)
        case .stop(let number):
            Circle()
                .fill(TwendeColor.ink)
                .frame(width: size, height: size)
                .overlay {
                    Text("\(number)")
                        .font(TwendeFont.figtree(size * 0.64, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
        case .end:
            RoundedRectangle(cornerRadius: 2)
                .fill(TwendeColor.ink)
                .frame(width: size * 0.78, height: size * 0.78)
        }
    }
}

private struct RouteOrderEntry: Identifiable {
    let id: UUID = UUID()
    let place: Place
}
