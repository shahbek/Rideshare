import SwiftUI

/// 3D scenery settings, grouped as: Scenery, Look, Performance, Downloads, Developer.
struct DioramaSettingsView: View {
    @Bindable private var state: DioramaState = .shared

    var body: some View {
        MenuScreen(title: L(.masakiDiorama)) {
            VStack(alignment: .leading, spacing: 28) {
                section("Scenery") {
                    Toggle(L(.dioramaEnabled), isOn: $state.isEnabled)
                        .font(TwendeFont.bodyMedium)
                        .tint(TwendeColor.primary)
                        .frame(minHeight: 48)
                    Text(L(.dioramaControlsBody))
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                }
                section("Look") {
                    Picker("Time of day", selection: $state.timeOfDay) {
                        ForEach(DioramaTimeOfDay.allCases) { time in
                            Text(time.rawValue.capitalized).tag(time)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                section("Performance") {
                    DioramaProfilerView()
                    RowDivider(leading: 0)
                    DioramaPerformancePanel(state: state)
                }
                section("Downloads") {
                    DioramaDownloadView()
                    RowDivider(leading: 0)
                    AirportDownloadView()
                }
                section("Developer") {
                    DioramaDebugPanel(state: state)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
