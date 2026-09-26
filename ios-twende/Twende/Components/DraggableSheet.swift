import SwiftUI

/// White bottom sheet with two or more detents. At the resting detent it is a detached card floating
/// 12pt inside the screen edges, extending underneath the tabs; at the tall detent it runs edge-to-edge and
/// beneath the tab bar. The card morphs continuously between the two as the header is dragged, then
/// settles with a spring that inherits the finger's release velocity.
struct DraggableSheet<Header: View, SheetContent: View>: View {
    var detents: [CGFloat] = [0.52, 0.72]
    @Binding var detentIndex: Int
    var contentAtTop: Bool = true
    var floatingControl: AnyView? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> SheetContent

    @State private var dragTranslation: CGFloat = 0
    @State private var headerHeight: CGFloat = 180
    @State private var acceptsDrag: Bool? = nil
    @GestureState private var isTouchActive: Bool = false

    private let floatingInset: CGFloat = 12
    private let floatingGap: CGFloat = 12

    private var clampedIndex: Int { min(max(detentIndex, 0), detents.count - 1) }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.height
            let minHeight = total * detents[0]
            let maxHeight = total * detents[detents.count - 1]
            let restingHeight = total * detents[clampedIndex]
            let height = min(max(restingHeight - dragTranslation, minHeight), maxHeight)
            // 0 = detached card at the resting detent, 1 = edge-to-edge at the tall detent.
            let progress = maxHeight > minHeight ? (height - minHeight) / (maxHeight - minHeight) : 1
            let detachment = 1 - progress
            let sideInset = floatingInset * detachment
            let bottomGap = floatingGap * detachment
            let cardHeight = max(height - bottomGap, headerHeight)
            let floatingRadius = DeviceMetrics.concentricRadius(inset: floatingInset)
            let topRadius = floatingRadius + (sheetRadius - floatingRadius) * progress
            let bottomRadius = floatingRadius * detachment
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: topRadius,
                bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius,
                topTrailingRadius: topRadius
            )

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    SheetGrabber()
                    header()
                }
                .contentShape(Rectangle())
                .highPriorityGesture(drag(total: total, fromHeader: true))
                .accessibilityIdentifier("home.sheet.header")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

                // Scroll content supplies its own bottom margin; the surface itself stays behind the tabs.
                content()
                    .highPriorityGesture(drag(total: total, fromHeader: false), including: clampedIndex == 0 ? .all : .none)
                    .simultaneousGesture(drag(total: total, fromHeader: false), including: clampedIndex == 0 ? .none : .all)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(0, cardHeight - headerHeight), alignment: .top)
            }
            .frame(width: proxy.size.width - sideInset * 2, height: cardHeight, alignment: .top)
            .clipShape(shape)
            .background {
                shape
                    .fill(TwendeColor.surface)
                    .shadow(
                        color: .black.opacity(0.10 + 0.06 * detachment),
                        radius: 16 + 8 * detachment,
                        y: -2 + 8 * detachment
                    )
            }
            .overlay(alignment: .topTrailing) {
                if let floatingControl {
                    floatingControl
                        .padding(.horizontal, 16)
                        .offset(y: -60)
                }
            }
            .padding(.bottom, bottomGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // Extend the measuring container, not the already-sized scroll viewport.
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: isTouchActive) { _, active in
            if !active, acceptsDrag != nil {
                withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)) {
                    dragTranslation = 0
                    acceptsDrag = nil
                }
            }
        }
    }

    private func drag(total: CGFloat, fromHeader: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($isTouchActive) { _, active, transaction in
                transaction.animation = nil
                active = true
            }
            .onChanged { value in
                if acceptsDrag == nil {
                    let vertical = abs(value.translation.height) > abs(value.translation.width)
                    acceptsDrag = vertical && (fromHeader || clampedIndex == 0 || (contentAtTop && value.translation.height > 0))
                }
                guard acceptsDrag == true else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragTranslation = value.translation.height
                }
            }
            .onEnded { value in
                guard acceptsDrag == true else { acceptsDrag = nil; return }
                let height = min(max(total * detents[clampedIndex] - value.translation.height, total * detents[0]), total * detents[detents.count - 1])
                let projectedHeight = total * detents[clampedIndex] - value.predictedEndTranslation.height
                let nearest = detents.indices.min { lhs, rhs in
                    abs(total * detents[lhs] - projectedHeight) < abs(total * detents[rhs] - projectedHeight)
                } ?? clampedIndex
                // Carry the finger's speed into the spring so a flick keeps moving instead of restarting from rest.
                let distance = total * detents[nearest] - height
                let velocity = -value.velocity.height
                let relativeVelocity = abs(distance) > 1 ? min(max(velocity / distance, -30), 30) : 0
                Haptics.selection()
                withAnimation(reduceMotion ? nil : .interpolatingSpring(mass: 1, stiffness: 260, damping: 28, initialVelocity: relativeVelocity)) {
                    detentIndex = nearest
                    dragTranslation = 0
                    acceptsDrag = nil
                }
            }
    }
}

/// Keeps expanded content mounted and reveals it through an animated viewport, avoiding insertion jumps.
struct CollapsiblePanelContent<Content: View>: View {
    let isExpanded: Bool
    var dragTranslation: CGFloat = 0
    @ViewBuilder let content: () -> Content
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        let visibleHeight = min(naturalHeight, max(0, (isExpanded ? naturalHeight : 0) - dragTranslation))
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
            .frame(height: visibleHeight, alignment: .top)
            .opacity(min(1, visibleHeight / 48))
            .clipped()
            .allowsHitTesting(isExpanded && dragTranslation == 0)
            .accessibilityHidden(!isExpanded)
    }
}

/// Fixed white panel anchored to the bottom edge (used under `safeAreaInset`).
struct BottomPanel<Content: View>: View {
    var showsGrabber: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if showsGrabber {
                SheetGrabber()
            } else {
                Spacer().frame(height: 20)
            }
            content()
        }
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: sheetRadius, topTrailingRadius: sheetRadius)
                .fill(TwendeColor.surface)
                .shadow(color: .black.opacity(0.10), radius: 16, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Edge-to-edge sheets share the display's own corner radius so their curve is concentric with the bezel.
var sheetRadius: CGFloat { DeviceMetrics.displayCornerRadius }
