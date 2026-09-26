import SwiftUI

/// Which point of the trip a pin marks. Pickup reads as a circle head, destination as a square, and each
/// intermediate stop as a numbered circle — the same grammar as the route connector in `RouteStopsView`.
nonisolated enum MapPinKind: Hashable, Sendable {
    case pickup
    case destination
    /// Zero-based index of an intermediate stop.
    case stop(Int)
}

/// Stroke-free map pin with contrast derived from the basemap. Labels can reposition independently;
/// the geometric head, stem and contact dot retain a stable map anchor.
///
/// Lift behaviour mirrors Uber's draggable pin: while the map moves, the head/stem/label rise off the
/// ground dot and the contact shadow widens and fades; on release everything settles back with one spring.
struct MapPin: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: MapPinKind
    var label: String? = nil
    var secondaryLabel: String? = nil
    var isLifted: Bool = false
    var isDarkMap: Bool = TwendeColor.isDarkMap
    var labelOffset: CGSize = CGSize(width: MapPin.headSize + MapPin.labelGap, height: 0)
    var labelMaxWidth: CGFloat = 260

    private var foreground: Color { isDarkMap ? .white : TwendeColor.ink }
    private var contrast: Color { isDarkMap ? TwendeColor.ink : .white }

    static let headSize: CGFloat = 22
    static let stemHeight: CGFloat = 14
    static let baseSize: CGFloat = 6
    static let liftDistance: CGFloat = 14
    static let labelGap: CGFloat = 6
    static var totalHeight: CGFloat { headSize + stemHeight + baseSize }

    private var lift: CGFloat { isLifted ? -Self.liftDistance : 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            groundShadow
            VStack(spacing: 0) {
                head
                Rectangle()
                    .fill(foreground)
                    .frame(width: 2, height: Self.stemHeight)
            }
            .overlay(alignment: .topLeading) {
                if let label {
                    MapPinBanner(text: label, secondaryLabel: secondaryLabel, isDarkMap: isDarkMap, maxWidth: labelMaxWidth)
                        .fixedSize()
                        .offset(labelOffset)
                }
            }
            .offset(y: lift - Self.baseSize / 2)
        }
        .frame(width: Self.headSize, height: Self.totalHeight, alignment: .bottom)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: isLifted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([label, secondaryLabel].compactMap { $0 }.joined(separator: ", ")))
    }

    /// What sits on the map. At rest it is the contrasting contact dot the stem stands on. Lifted, the dot stays as
    /// the anchor while a wider, softer shadow spreads beneath it — the further the pin rises, the larger,
    /// blurrier and paler its shadow, which is what sells the height.
    private var groundShadow: some View {
        ZStack {
            Ellipse()
                .fill(TwendeColor.ink.opacity(isLifted ? 0.16 : 0))
                .frame(width: isLifted ? 30 : Self.baseSize, height: isLifted ? 9 : 3)
                .blur(radius: isLifted ? 3 : 0)
            Ellipse()
                .fill(foreground.opacity(isLifted ? 0.48 : 1))
                .frame(width: isLifted ? 8 : Self.baseSize, height: isLifted ? 3 : Self.baseSize)

        }
        .frame(height: Self.baseSize)
    }

    private var head: some View {
        Group {
            switch kind {
            case .pickup, .stop:
                Circle().fill(foreground)
            case .destination:
                Rectangle().fill(foreground)
            }
        }
        .frame(width: Self.headSize, height: Self.headSize)
        .overlay {
            switch kind {
            case .stop(let index):
                Text("\(index + 1)")
                    .font(TwendeFont.figtree(12, weight: .bold).monospacedDigit())
                    .foregroundStyle(contrast)
            case .pickup, .destination:
                Circle()
                    .fill(contrast)
                    .frame(width: 6, height: 6)
            }
        }
        .shadow(color: .black.opacity(isLifted ? 0.18 : 0), radius: isLifted ? 4 : 0, y: isLifted ? 6 : 0)
    }

}

/// Passenger's pickup / current position pin, standing on the coordinate. Anchor annotations at `.bottom`.
struct PickupMarker: View {
    var label: String? = nil

    var body: some View {
        MapPin(kind: .pickup, label: label)
    }
}

/// Destination pin. Anchor annotations at `.bottom`.
struct DestinationMarker: View {
    var label: String? = nil

    var body: some View {
        MapPin(kind: .destination, label: label)
    }
}

/// Fixed centre pin for the "set on map" screen: lifts while the map is dragged, shows the resolved place.
struct CentrePin: View {
    let kind: MapPinKind
    let label: String
    let isLifted: Bool
    /// Window-space location of the fixed contact dot, independent of the animated head and label.
    var onAnchorChanged: ((CGPoint) -> Void)? = nil
    var viewport: CGRect = .zero
    @State private var pinFrame: CGRect = .zero
    @State private var labelSize: CGSize = .zero

    private var maxLabelWidth: CGFloat { viewport.isEmpty ? 260 : min(260, viewport.width - 32) }
    private var bannerOffset: CGSize {
        guard !viewport.isEmpty, !pinFrame.isEmpty, labelSize.width > 0 else {
            return CGSize(width: MapPin.headSize + MapPin.labelGap, height: 0)
        }
        let ground = CGPoint(x: pinFrame.midX, y: pinFrame.maxY - MapPin.baseSize / 2)
        let rect = MapBannerLayout.frame(anchor: ground, size: labelSize, viewport: viewport.insetBy(dx: 12, dy: 12), lift: isLifted ? MapPin.liftDistance : 0)
        return CGSize(width: rect.minX - pinFrame.minX, height: rect.minY - pinFrame.minY + (isLifted ? MapPin.liftDistance : 0))
    }

    var body: some View {
        MapPin(kind: kind, label: label, isLifted: isLifted, labelOffset: bannerOffset, labelMaxWidth: maxLabelWidth)
            .background {
                MapPinBanner(text: label, maxWidth: maxLabelWidth)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { labelSize = $0 }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pinFrame = $0 }
            .onGeometryChange(for: CGPoint.self) { geometry in
                let frame = geometry.frame(in: .global)
                return CGPoint(x: frame.midX, y: frame.maxY - MapPin.baseSize / 2)
            } action: { point in
                onAnchorChanged?(point)
            }
            .offset(y: -MapPin.totalHeight / 2)
    }
}

/// Bare top-down vehicle straight on the canvas: the tier's bundled 3D model rendered from above, no disc,
/// no plate. Rotates to heading; appears once with a short settle and otherwise only moves.
struct VehicleMarker: View {
    private let sprites: VehicleSpriteStore = VehicleSpriteStore.shared
    let tier: RideTier
    var heading: Double = 0
    var size: CGFloat = 56

    @State private var hasAppeared: Bool = false

    private var footprint: CGFloat { size * tier.markerScale }

    var body: some View {
        Group {
            if let sprite = sprites.sprite(for: tier) {
                Image(uiImage: sprite)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if tier == .premium {
                ProgressView().tint(TwendeColor.inkSecondary)
            } else {
                Image(tier.topDownImageName)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: footprint, height: footprint)
        .rotationEffect(.degrees(heading))
        .animation(.linear(duration: 0.25), value: heading)
        .scaleEffect(hasAppeared ? 1 : 0.6)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { hasAppeared = true }
        }
        .accessibilityHidden(true)
    }
}

/// Top-down vehicle for static product illustrations; same renderer as the live markers.
struct TopDownVehicle: View {
    let tier: RideTier
    var height: CGFloat = 44
    var heading: Double = 0

    var body: some View {
        VehicleMarker(tier: tier, heading: heading, size: height)
    }
}

/// Assigned driver's vehicle on the map.
struct DriverVehicleMarker: View {
    let tier: RideTier
    let heading: Double

    var body: some View {
        VehicleMarker(tier: tier, heading: heading, size: 58)
    }
}

/// Other online drivers, smaller. Favourites get a thin green ring on the ground beneath the vehicle.
struct NearbyDriverMarker: View {
    let driver: Driver
    let isFavourite: Bool

    var body: some View {
        VehicleMarker(tier: driver.tier, heading: driver.heading, size: 40)
            .background {
                if isFavourite {
                    Circle()
                        .stroke(TwendeColor.primary, lineWidth: 2)
                        .frame(width: 46, height: 46)
                }
            }
    }
}
