import SwiftUI

/// Floating developer panel over the Home map: time of day, category toggles, regenerate and tile
/// bounds. Follows the app's flat white/ink/gold language.
struct DioramaDebugPanel: View {
    @Bindable var state: DioramaState
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.tap()
                withAnimation(.spring(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Slipway diorama")
                        .font(TwendeFont.headline)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                .foregroundStyle(TwendeColor.ink)
                .padding(.horizontal, 14)
                .frame(height: 48)
            }
            .buttonStyle(.pressableCard)

            if isExpanded {
                ScrollView {
                  VStack(alignment: .leading, spacing: 12) {
                    RowDivider(leading: 0)
                    Picker("Time of day", selection: $state.timeOfDay) {
                        ForEach(DioramaTimeOfDay.allCases) { time in
                            Text(time.rawValue.capitalized).tag(time)
                        }
                    }
                    .pickerStyle(.segmented)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        toggle("Buildings", .buildings)
                        toggle("Compound walls", .walls)
                        toggle("Vegetation", .vegetation)
                        toggle("Props", .props)
                        toggle("Ground", .ground)
                        toggle("Roads", .roads)
                        toggle("Water", .water)
                        toggle("Shoreline types", .shorelineDebug)
                        Toggle("Wireframe", isOn: $state.showsWireframe)
                            .font(TwendeFont.label).toggleStyle(.button).tint(TwendeColor.primary)
                        Toggle("Basemap only", isOn: $state.isBasemapOnly)
                            .font(TwendeFont.label).toggleStyle(.button).tint(TwendeColor.primary)
                        Toggle(isOn: $state.showsDebugOverlay) {
                            Text("Tile bounds").font(TwendeFont.label)
                        }
                        .toggleStyle(.button)
                        .tint(TwendeColor.primary)
                    }

                    HStack(spacing: 8) {
                        Button("Regenerate tile") {
                            Haptics.tap()
                            state.regenerateRequest += 1
                        }
                        .buttonStyle(.twendeSecondary)
                        Button("Fly to Slipway") {
                            Haptics.tap()
                            state.inspectionTarget = nil
                            state.cameraFlyRequest += 1
                        }
                        .buttonStyle(.twendeSecondary)
                    }

                    if state.visibleCategories.contains(.shorelineDebug) {
                        Text("Yellow: beach · red: seawall · orange: rocks · blue: deck · green: natural")
                            .font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
                    }
                    Button("Inspect beach section") {
                        state.inspectionTarget = .beach
                        state.cameraFlyRequest += 1
                    }
                    .buttonStyle(.twendeSecondary)
                    DisclosureGroup("Shoreline classification report") {
                        Text(state.loadedTiles.values.flatMap(\.shorelineReport).joined(separator: "\n"))
                            .font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(TwendeFont.label)
                    Text(summary)
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                  }
                  .padding(14)
                }
                .frame(maxHeight: 340)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 360)
        .background(TwendeColor.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TwendeColor.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    private func toggle(_ title: String, _ category: DioramaCategory) -> some View {
        Toggle(isOn: Binding(get: { state.visibleCategories.contains(category) }, set: { _ in state.toggle(category) })) {
            Text(title).font(TwendeFont.label)
        }
        .toggleStyle(.button)
        .tint(TwendeColor.primary)
    }

    private var summary: String {
        var lines = [state.status]
        for (tile, artifacts) in state.loadedTiles.sorted(by: { ($0.key.x, $0.key.y) < ($1.key.x, $1.key.y) }) {
            lines.append("\(tile): \(artifacts.totalTriangles.formatted()) tris · \(artifacts.totalBytes / 1024) KB")
        }
        return lines.joined(separator: "\n")
    }
}
