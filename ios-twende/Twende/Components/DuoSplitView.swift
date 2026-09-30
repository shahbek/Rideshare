import SwiftUI

/// Two panes either side of the fold. Uses `ArrangementView` on the iOS 27.1 SDK; older SDKs (and the
/// App Store build) get an equivalent split driven by `\.foldLayout`, with a hairline in the fold band.
/// Only used when `foldLayout` is non-nil — callers keep their single-column layout otherwise.
struct DuoSplitView<Primary: View, Secondary: View>: View {
    @Environment(\.foldLayout) private var foldLayout
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    var body: some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary()
            } secondary: {
                secondary()
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        HStack(spacing: 0) {
            primary()
                .frame(width: foldLayout?.leadingWidth)
                .frame(maxHeight: .infinity)
            ZStack {
                TwendeColor.surface
                TwendeColor.border.frame(width: 1)
            }
            .frame(width: foldLayout?.gap ?? 40)
            .ignoresSafeArea()
            secondary()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Empty detail pane shown before anything is picked in a two-pane list.
struct DuoDetailPlaceholder: View {
    let icon: Icon3D

    var body: some View {
        ZStack {
            TwendeColor.surfaceAlt.ignoresSafeArea()
            Icon3DView(icon: icon, size: 120)
                .opacity(0.9)
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityHidden(true)
    }
}
