import SwiftUI

/// Wide-window layout for iPhone Duo's unfolded inner display (and any wide regular-width window).
/// Present only when the window is regular width and wider than tall; `nil` means the normal phone layout.
nonisolated struct FoldLayout: Equatable, Sendable {
    /// Full window width.
    var width: CGFloat
    /// Width of the pane left of the fold, fold margin excluded — controls placed inside never touch the hinge.
    var leadingWidth: CGFloat
    /// Where the pane right of the fold begins.
    var trailingMinX: CGFloat

    var gap: CGFloat { max(trailingMinX - leadingWidth, 0) }

    /// Share of the width the map should treat as covered (panel pane plus the fold band).
    var mapLeadingFraction: Double { width > 0 ? Double(trailingMinX / width) : 0 }

    /// How far right of the window centre the map pane's centre is, as a share of the width.
    var mapPaneShift: Double { width > 0 ? Double((trailingMinX + width) / 2 / width) - 0.5 : 0 }

    /// Horizontal offset from the window centre to the map pane's centre, in points.
    var mapPaneOffset: CGFloat { (trailingMinX + width) / 2 - width / 2 }
}

extension EnvironmentValues {
    @Entry var foldLayout: FoldLayout? = nil
}

/// Raw window geometry plus the hinge's reserved region when the SDK reports one.
nonisolated struct FoldGeometry: Equatable, Sendable {
    var size: CGSize
    var fold: CGRect?
}

extension FoldGeometry {
    @MainActor
    static func read(_ proxy: GeometryProxy) -> FoldGeometry {
        var fold: CGRect? = nil
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            // Inactive when flat, but its frame is the same; ask for it so the split never jumps.
            fold = proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame
        }
        #endif
        return FoldGeometry(size: proxy.size, fold: fold)
    }

    /// Wide layout for this geometry, or `nil` when the window should use the phone layout.
    func layout(isRegularWidth: Bool) -> FoldLayout? {
        guard isRegularWidth, size.width >= 700, size.width > size.height else { return nil }
        if let fold, fold.height > fold.width, fold.minX > 240, fold.maxX < size.width - 240 {
            return FoldLayout(width: size.width, leadingWidth: fold.minX, trailingMinX: fold.maxX)
        }
        // No hinge reported (older SDK or a non-foldable wide window): assume a centred 40 pt fold band.
        let half = size.width / 2
        return FoldLayout(width: size.width, leadingWidth: half - 20, trailingMinX: half + 20)
    }
}

/// Publishes `foldLayout` to the whole tree. Apply once at the root.
private struct FoldLayoutReader: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var geometry: FoldGeometry = FoldGeometry(size: .zero, fold: nil)

    func body(content: Content) -> some View {
        content
            .environment(\.foldLayout, geometry.layout(isRegularWidth: horizontalSizeClass == .regular))
            .onGeometryChange(for: FoldGeometry.self) { proxy in
                FoldGeometry.read(proxy)
            } action: { value in
                geometry = value
            }
    }
}

/// Keeps a bottom panel to the left of the fold on the wide display; a no-op on the phone layout.
private struct FoldPanelModifier: ViewModifier {
    @Environment(\.foldLayout) private var foldLayout

    func body(content: Content) -> some View {
        content
            .frame(width: foldLayout?.leadingWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Map-screen bottom panel: a bottom inset on the phone, or a panel pinned bottom-left of the fold on the
/// open inner display so the right pane is all map.
private struct MapPanelModifier<Panel: View>: ViewModifier {
    @Environment(\.foldLayout) private var foldLayout
    let panel: () -> Panel

    func body(content: Content) -> some View {
        if let foldLayout {
            content.overlay(alignment: .bottomLeading) {
                panel().frame(width: foldLayout.leadingWidth)
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { panel() }
        }
    }
}

extension View {
    /// Attaches a map screen's bottom panel, fold-aware.
    func mapPanel<Panel: View>(@ViewBuilder _ panel: @escaping () -> Panel) -> some View {
        modifier(MapPanelModifier(panel: panel))
    }

    /// Reads window size and the hinge, and publishes `\.foldLayout`.
    func readsFoldLayout() -> some View { modifier(FoldLayoutReader()) }

    /// Constrains a map panel to the pane left of the fold when the inner display is open.
    func foldPanel() -> some View { modifier(FoldPanelModifier()) }
}
