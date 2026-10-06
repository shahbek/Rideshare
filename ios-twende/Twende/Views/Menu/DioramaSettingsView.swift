import SwiftUI

/// The diorama remains available, but its controls no longer cover the Home map.
struct DioramaSettingsView: View {
    @Bindable private var state: DioramaState = .shared

    var body: some View {
        MenuScreen(title: L(.masakiDiorama)) {
            Toggle(L(.dioramaEnabled), isOn: $state.isEnabled)
                .font(TwendeFont.bodyMedium)
                .tint(TwendeColor.primary)
                .frame(minHeight: 48)
            Text(L(.dioramaControlsBody))
                .font(TwendeFont.caption)
                .foregroundStyle(TwendeColor.inkSecondary)
            RowDivider(leading: 0)
            DioramaDebugPanel(state: state)
        }
    }
}
