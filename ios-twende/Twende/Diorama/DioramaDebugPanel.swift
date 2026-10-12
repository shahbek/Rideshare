import SwiftUI

/// Live cost readout plus layer and effect switches. Works for every scenery source (bundled
/// harbour, downloads), so it is never hidden behind a download.
struct DioramaPerformancePanel: View {
    @Bindable var state: DioramaState
    @State private var flags: DioramaDebugSwitches.Flags = DioramaDebugSwitches.shared.flags

    private let columns: [GridItem] = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(liveStats)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TwendeColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TwendeColor.ink.opacity(0.05), in: .rect(cornerRadius: 12))
            }
            Text("Turn one switch off at a time and watch GPU frame time. Resets on restart.")
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)

            Text("Layers").font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
            LazyVGrid(columns: columns, spacing: 8) {
                layer("Buildings", .buildings)
                layer("Roads", .roads)
                layer("Objects", .props)
                layer("Trees", .vegetation)
                layer("Walls", .walls)
                layer("Ground", .ground)
                layer("Water", .water)
            }

            Text("Effects").font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
            LazyVGrid(columns: columns, spacing: 8) {
                flag("3D labels", \.labels)
                flag("Lights", \.pointLights)
                flag("Ground painting", \.groundPaint)
                flag("Facade shader", \.facadeShader)
                flag("Sun shadows", \.shadows)
                flag("Glow", \.bloom)
            }
        }
    }

    private func layer(_ title: String, _ category: DioramaCategory) -> some View {
        Toggle(isOn: Binding(get: { state.visibleCategories.contains(category) }, set: { _ in
            Haptics.tap()
            state.toggle(category)
        })) {
            Text(title).font(TwendeFont.label).frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .tint(TwendeColor.primary)
    }

    private func flag(_ title: String, _ key: WritableKeyPath<DioramaDebugSwitches.Flags, Bool>) -> some View {
        Toggle(isOn: Binding(get: { flags[keyPath: key] }, set: { value in
            Haptics.tap()
            flags[keyPath: key] = value
            DioramaDebugSwitches.shared.flags = flags
            NotificationCenter.default.post(name: DioramaState.renderSettingsChanged, object: state)
        })) {
            Text(title).font(TwendeFont.label).frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .tint(TwendeColor.primary)
    }

    /// Live totals across every scenery layer on screen, so each switch's effect is measurable.
    private var liveStats: String {
        let hosts = DioramaDebugSwitches.shared.liveHosts()
        guard !hosts.isEmpty else { return "Open the map over 3D scenery to see live counts." }
        var byCategory: [DioramaCategory: Int] = [:]
        for host in hosts { for (c, n) in host.triangles { byCategory[c, default: 0] += n } }
        let total = byCategory.values.reduce(0, +)
        let shadow = hosts.reduce(0) { $0 + $1.shadowTriangles }
        let draws = hosts.reduce(0) { $0 + $1.drawCalls }
        let gpu = hosts.compactMap(\.gpuMS).max()
        func fmt(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.2fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)" }
        var lines = ["On screen: \(fmt(total)) tris · \(draws) draws · \(hosts.count) layers"]
        lines.append("GPU frame: " + (gpu.map { String(format: "%.1f ms", $0) } ?? "–") + (gpu.map { $0 > 16.7 ? "  (over 60 fps budget)" : "" } ?? ""))
        for (c, n) in byCategory.sorted(by: { $0.value > $1.value }) where n > 0 {
            let pct = total > 0 ? Double(n) * 100 / Double(total) : 0
            lines.append(String(format: "%@ %@  %4.0f%%", c.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0), fmt(n).padding(toLength: 7, withPad: " ", startingAt: 0), pct))
        }
        lines.append("Shadow pass: " + (shadow > 0 ? "up to \(fmt(shadow)) tris re-drawn" : "off"))
        lines.append("Labels: \(hosts.reduce(0) { $0 + $1.labels }) · lights: \(hosts.reduce(0) { $0 + $1.lights })")
        return lines.joined(separator: "\n")
    }
}

/// Developer tools and reports, collapsed by default.
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
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Tools and reports").font(TwendeFont.bodyMedium)
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
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        button("Wireframe", $state.showsWireframe)
                        button("Basemap only", $state.isBasemapOnly)
                        button("Tile bounds", $state.showsDebugOverlay)
                        Toggle(isOn: Binding(get: { state.visibleCategories.contains(.shorelineDebug) },
                                             set: { _ in state.toggle(.shorelineDebug) })) {
                            Text("Shoreline types").font(TwendeFont.label).frame(maxWidth: .infinity)
                        }
                        .toggleStyle(.button).tint(TwendeColor.primary)
                    }
                    if state.visibleCategories.contains(.shorelineDebug) {
                        Text("Yellow: beach · red: seawall · orange: rocks · blue: deck · green: natural")
                            .font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
                    }
                    HStack(spacing: 8) {
                        Button("Reload tile") { Haptics.tap(); state.regenerateRequest += 1 }
                            .buttonStyle(.twendeSecondary)
                        Button("Fly to Slipway") {
                            Haptics.tap(); state.inspectionTarget = nil; state.cameraFlyRequest += 1
                        }
                        .buttonStyle(.twendeSecondary)
                        Button("Beach") {
                            Haptics.tap(); state.inspectionTarget = .beach; state.cameraFlyRequest += 1
                        }
                        .buttonStyle(.twendeSecondary)
                    }
                    DisclosureGroup("Shoreline report") {
                        Text(state.loadedTiles.values.flatMap(\.shorelineReport).joined(separator: "\n"))
                            .font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(TwendeFont.label)
                    DisclosureGroup("Performance report") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summary + "\n\n" + optimizationSummary)
                                .font(TwendeFont.label).foregroundStyle(TwendeColor.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            ShareLink(item: summary + "\n\n" + optimizationSummary) {
                                Label("Share report", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .font(TwendeFont.label)
                }
                .padding(.vertical, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { Text(title).font(TwendeFont.label).frame(maxWidth: .infinity) }
            .toggleStyle(.button).tint(TwendeColor.primary)
    }

    private var optimizationSummary: String {
        ([state.frameReport, state.passReport] + state.loadedTiles.sorted { $0.key.key < $1.key.key }.flatMap { _, artifacts in
            ["Measured packed-buffer savings (not fewer drawn triangles):"] + artifacts.optimizationReport
                + ["Generation stages:"] + artifacts.stageTimings
        }).joined(separator: "\n")
    }

    private var summary: String {
        var lines = [state.status]
        for (tile, artifacts) in state.loadedTiles.sorted(by: { ($0.key.x, $0.key.y) < ($1.key.x, $1.key.y) }) {
            lines.append("v\(DioramaConfig.slipway.generatorVersion) · \(tile)")
            lines.append("\(artifacts.totalTriangles.formatted()) unique tris · \(artifacts.totalInstances.formatted()) instances")
            lines.append("\(artifacts.totalBytes / 1024) KB · geometry \(String(format: "%.2f", artifacts.generationSeconds))s")
        }
        return lines.joined(separator: "\n")
    }
}
