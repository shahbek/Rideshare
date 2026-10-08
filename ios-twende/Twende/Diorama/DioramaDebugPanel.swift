import SwiftUI

/// Settings-only diorama controls. The containing MenuScreen owns scrolling and navigation.
struct DioramaDebugPanel: View {
    @Bindable var state: DioramaState
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.tap()
                withAnimation(.spring(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 15, weight: .semibold))
                    Text(L(.masakiDiorama))
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

            if !DioramaDownloadService.shared.canView {
                DioramaDownloadView().padding(.vertical, 14)
            } else if isExpanded {
                Group {
                  VStack(alignment: .leading, spacing: 12) {
                    RowDivider(leading: 0)
                    Text("Prepared offline detail with up to eight coarse neighbours (64 MiB packed budget). No network fetches or geometry generation during viewing. Idle water animation is off.")
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
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
                        Button("Reload saved tile") {
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
                    DisclosureGroup("Instancing savings and generation timings") {
                        Text(optimizationSummary)
                            .font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        ShareLink(item: summary + "\n\n" + optimizationSummary) {
                            Label("Share performance report", systemImage: "square.and.arrow.up")
                        }
                    }
                    .font(TwendeFont.label)
                    Text(summary)
                        .font(TwendeFont.label)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                  }
                  .padding(.vertical, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ title: String, _ category: DioramaCategory) -> some View {
        Toggle(isOn: Binding(get: { state.visibleCategories.contains(category) }, set: { _ in state.toggle(category) })) {
            Text(title).font(TwendeFont.label)
        }
        .toggleStyle(.button)
        .tint(TwendeColor.primary)
    }

    private var optimizationSummary: String {
        ([state.frameReport, state.passReport] + state.loadedTiles.sorted { $0.key.key < $1.key.key }.flatMap { _, artifacts in
            ["Measured packed-buffer savings (not fewer drawn triangles):"] + artifacts.optimizationReport
                + ["Generation stages:"] + artifacts.stageTimings
        }).joined(separator: "\n")
    }

    private var summary: String {
        var lines = [state.status, state.passReport]
        for (tile, artifacts) in state.loadedTiles.sorted(by: { ($0.key.x, $0.key.y) < ($1.key.x, $1.key.y) }) {
            lines.append("v\(DioramaConfig.slipway.generatorVersion) · \(tile)")
            lines.append("\(artifacts.totalTriangles.formatted()) unique tris · \(artifacts.totalInstances.formatted()) instances")
            lines.append("\(artifacts.totalBytes / 1024) KB · geometry \(String(format: "%.2f", artifacts.generationSeconds))s")
        }
        return lines.joined(separator: "\n")
    }
}
