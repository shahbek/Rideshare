import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Lock Screen + Dynamic Island presentation of the ride. One headline that says what matters now
/// ("4 min until pickup"), the car and plate on the right, the driver and start code underneath.
/// The only vehicle that turns is the large 3D car in the Dynamic Island: a low-angle turntable of the
/// app's own fleet render, swapped frame by frame to follow the car's compass heading.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(WidgetPalette.canvas)
                .activitySystemActionForegroundColor(WidgetPalette.ink)
                .widgetURL(WidgetLink.activeTrip)
        } dynamicIsland: { context in
            let state = context.state
            let attributes = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TurningVehicle(tier: attributes.tier, heading: compassHeading(state), width: 76)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandFigure(attributes: attributes, state: state)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBottom(attributes: attributes, state: state)
                }
            } compactLeading: {
                TurningVehicle(tier: attributes.tier, heading: compassHeading(state), width: 30)
            } compactTrailing: {
                CompactTrailing(attributes: attributes, state: state)
            } minimal: {
                TurningVehicle(tier: attributes.tier, heading: compassHeading(state), width: 24)
            }
            .keylineTint(WidgetPalette.gold)
            .widgetURL(WidgetLink.activeTrip)
        }
    }
}

/// While the car is moving it faces its real heading; otherwise it rests in a front three-quarter view.
private func compassHeading(_ state: RideActivityAttributes.ContentState) -> Double {
    switch state.stage {
    case .onTheWay, .arrived, .inTrip: state.heading
    default: 135
    }
}

private func isMoving(_ stage: RideActivityAttributes.Stage) -> Bool {
    stage == .searching || stage == .onTheWay || stage == .arrived || stage == .inTrip
}

private func hasDriver(_ stage: RideActivityAttributes.Stage) -> Bool {
    stage == .onTheWay || stage == .arrived || stage == .inTrip
}

// MARK: - Copy

/// A headline split into an emphasised lead ("4 min") and the rest (" until pickup").
private struct Headline {
    var lead: String
    var rest: String
}

private enum LiveCopy {
    static func headline(_ a: RideActivityAttributes, _ s: RideActivityAttributes.ContentState) -> Headline {
        let sw = a.language == .swahili
        let mins = WidgetCopy.minutes(max(s.minutes, 1), a.language)
        let name = s.driverName ?? (sw ? "Dereva" : "Driver")
        switch s.stage {
        case .searching: return Headline(lead: sw ? "Tunatafuta dereva" : "Finding your driver", rest: "")
        case .noDrivers: return Headline(lead: sw ? "Hakuna dereva karibu" : "No drivers nearby", rest: "")
        case .onTheWay: return Headline(lead: mins, rest: sw ? " hadi kukuchukua" : " until pickup")
        case .arrived: return Headline(lead: name, rest: sw ? " amefika" : " is here")
        case .inTrip: return Headline(lead: mins, rest: sw ? " hadi \(a.destinationName)" : " to \(a.destinationName)")
        case .completed: return Headline(lead: sw ? "Umefika" : "Arrived", rest: sw ? " \(a.destinationName)" : " at \(a.destinationName)")
        case .paid: return Headline(lead: WidgetCopy.tzs(s.fare), rest: sw ? " imelipwa" : " paid")
        case .cancelled: return Headline(lead: sw ? "Safari imesitishwa" : "Ride cancelled", rest: "")
        }
    }

    static func subline(_ a: RideActivityAttributes, _ s: RideActivityAttributes.ContentState) -> String {
        let sw = a.language == .swahili
        switch s.stage {
        case .searching: return "\(a.tierName) · \(a.destinationName)"
        case .noDrivers: return sw ? "Fungua Zuri kujaribu tena" : "Open Zuri to try again"
        case .onTheWay: return sw ? "Kutana \(a.pickupName)" : "Meet at \(a.pickupName)"
        case .arrived: return sw ? "Kutana \(a.pickupName)" : "Meet at \(a.pickupName)"
        case .inTrip:
            let eta = Date().addingTimeInterval(Double(s.minutes) * 60).formatted(date: .omitted, time: .shortened)
            let arrive = sw ? "Kufika \(eta)" : "Arrive \(eta)"
            if s.inTraffic { return (sw ? "Foleni · " : "Slow traffic · ") + arrive }
            if let stop = s.nextStop { return (sw ? "Kupitia \(stop) · " : "Via \(stop) · ") + arrive }
            return arrive
        case .completed: return "\(WidgetCopy.tzs(s.fare)) · \(a.paymentName)"
        case .paid: return sw ? "Asante kwa kusafiri na Zuri" : "Thanks for riding with Zuri"
        case .cancelled: return s.fare > 0 ? (sw ? "Ada \(WidgetCopy.tzs(s.fare))" : "Fee \(WidgetCopy.tzs(s.fare))") : (sw ? "Hakuna ada" : "No fee charged")
        }
    }
}

// MARK: - Vehicle art

/// The app's own 3D fleet, seen from a low angle and exported by the app as a turntable. Frame 0 drives
/// away from the viewer; each frame turns it clockwise, so heading 90° is the side profile facing right
/// and 180° is the front. Falls back to the bundled miniature before the app has exported the frames.
struct TurningVehicle: View {
    let tier: String
    let heading: Double
    var width: CGFloat = 60

    private var frame: Int {
        let count = WidgetSnapshotStore.vehicleTurntableFrames
        let step = 360 / Double(count)
        var normalized = heading.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        return Int((normalized / step).rounded()) % count
    }

    var body: some View {
        Group {
            if let url = WidgetSnapshotStore.vehicleTurntableURL(tier: tier, frame: frame),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .id(frame)
                    .transition(.opacity)
            } else {
                WidgetVehicle(tier: tier, width: width)
            }
        }
        .frame(width: width, height: width * 0.72)
        .animation(.easeInOut(duration: 0.35), value: frame)
        .accessibilityHidden(true)
    }
}

/// The assigned driver's photo, exported by the app; the neutral bust until it arrives.
private struct DriverPortrait: View {
    let driverID: String?
    var size: CGFloat = 32
    var dark: Bool = false

    var body: some View {
        Group {
            if let id = driverID, let url = WidgetSnapshotStore.driverPortraitURL(id: id),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image("mannequin_driver_bust").resizable().aspectRatio(contentMode: .fill)
                    .padding(size * 0.1)
                    .background(dark ? Color.white.opacity(0.12) : WidgetPalette.surfaceAlt)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(dark ? Color.white.opacity(0.18) : WidgetPalette.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - Route line

/// Straight-down render of the same 3D vehicle as the turntable, nose pointing right, exported by the app.
/// Used on the route line, where it never turns. Until the export exists it shows the 3D side profile.
private struct TopDownVehicle: View {
    let tier: String
    var length: CGFloat = 34

    var body: some View {
        Group {
            if let url = WidgetSnapshotStore.vehicleTopURL(tier: tier), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                TurningVehicle(tier: tier, heading: 90, width: length)
            }
        }
        .frame(width: length, height: length * 0.5)
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        .accessibilityHidden(true)
    }
}

/// Travelled part solid, the rest dashed, a ring at the leg's end. A small top-down car rides on the
/// line facing right and never rotates.
private struct RouteLine: View {
    let tier: String
    let progress: Double
    var dark: Bool = false
    var carWidth: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let end: CGFloat = 12
            let lineY = height / 2
            let usable = max(width - carWidth - end, 1)
            let x = usable * min(max(progress, 0), 1)
            let solid = dark ? WidgetPalette.gold : WidgetPalette.ink
            let rest = dark ? Color.white.opacity(0.28) : WidgetPalette.inkTertiary
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: x + carWidth / 2, y: lineY))
                    path.addLine(to: CGPoint(x: width - end, y: lineY))
                }
                .stroke(rest, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 6]))
                Capsule().fill(solid)
                    .frame(width: x + carWidth / 2, height: 4)
                    .offset(y: lineY - 2)
                Circle()
                    .strokeBorder(solid, lineWidth: 3)
                    .background(Circle().fill(dark ? .black : .white))
                    .frame(width: 12, height: 12)
                    .offset(x: width - 12, y: lineY - 6)
                TopDownVehicle(tier: tier, length: carWidth)
                    .offset(x: x, y: lineY - carWidth * 0.25)
            }
            .animation(.easeInOut(duration: 1.2), value: progress)
        }
        .frame(height: max(carWidth * 0.5, 14) + 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Lock Screen

private struct RideLockScreenView: View {
    let attributes: RideActivityAttributes
    let state: RideActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    headline
                    Text(LiveCopy.subline(attributes, state))
                        .font(WidgetType.caption)
                        .foregroundStyle(WidgetPalette.inkSecondary)
                        .lineLimit(1)
                    if hasDriver(state.stage), let name = state.driverName {
                        Text([name, state.vehicle].compactMap { $0 }.joined(separator: " · "))
                            .font(WidgetType.label)
                            .foregroundStyle(WidgetPalette.inkTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                vehicleCorner
            }
            if isMoving(state.stage) || state.pin != nil {
                HStack(alignment: .center, spacing: 14) {
                    if isMoving(state.stage) {
                        RouteLine(tier: attributes.tier, progress: state.stage == .searching ? 0 : state.progress)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if let pin = state.pin, hasDriver(state.stage) {
                        WidgetSplitFlap(text: pin, tileSize: CGSize(width: 18, height: 26), spacing: 3)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var headline: some View {
        let copy = LiveCopy.headline(attributes, state)
        return (Text(copy.lead).foregroundStyle(WidgetPalette.accentText)
            + Text(copy.rest).foregroundStyle(WidgetPalette.ink))
            .font(WidgetType.figtree(20, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText(countsDown: true))
    }

    /// The 3D car in a front three-quarter view with the driver's photo tucked against it, and the
    /// plate underneath once a driver is assigned.
    private var vehicleCorner: some View {
        VStack(alignment: .center, spacing: 5) {
            TurningVehicle(tier: attributes.tier, heading: 135, width: 66)
                .overlay(alignment: .bottomLeading) {
                    if hasDriver(state.stage) {
                        DriverPortrait(driverID: state.driverID, size: 26)
                            .padding(2)
                            .background(Circle().fill(WidgetPalette.canvas))
                            .offset(x: -12, y: 4)
                    }
                }
            if let plate = state.plate, hasDriver(state.stage) {
                WidgetPlate(plate: plate, small: true)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Dynamic Island

private struct IslandFigure: View {
    let attributes: RideActivityAttributes
    let state: RideActivityAttributes.ContentState

    var body: some View {
        switch state.stage {
        case .onTheWay, .inTrip:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(max(state.minutes, 1))")
                    .font(WidgetType.figtree(32, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                Text(attributes.language == .swahili ? "dak" : "min")
                    .font(WidgetType.figtree(14, weight: .semibold))
                    .foregroundStyle(WidgetPalette.gold)
            }
        case .arrived:
            Text(attributes.language == .swahili ? "Amefika" : "Here")
                .font(WidgetType.figtree(22, weight: .bold))
                .foregroundStyle(WidgetPalette.gold)
        case .completed, .paid:
            Text(WidgetCopy.tzs(state.fare))
                .font(WidgetType.figtree(18, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        default:
            EmptyView()
        }
    }
}

/// Route line, then one row: driver photo and plate on the left, start code on the right. Inset well
/// inside the island's rounded corners so nothing is clipped.
private struct IslandBottom: View {
    let attributes: RideActivityAttributes
    let state: RideActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            if isMoving(state.stage) {
                RouteLine(tier: attributes.tier, progress: state.stage == .searching ? 0 : state.progress, dark: true, carWidth: 30)
            }
            HStack(alignment: .center, spacing: 8) {
                if hasDriver(state.stage) {
                    DriverPortrait(driverID: state.driverID, size: 28, dark: true)
                        .padding(.leading, 6)
                    if let plate = state.plate {
                        WidgetPlate(plate: plate, small: true)
                            .fixedSize()
                    }
                } else {
                    Text(caption)
                        .font(WidgetType.figtree(14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let pin = state.pin {
                    WidgetSplitFlap(text: pin, tileSize: CGSize(width: 17, height: 24), spacing: 2.5)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    /// One short fact when there's no driver to show.
    private var caption: String {
        let sw = attributes.language == .swahili
        switch state.stage {
        case .searching: return sw ? "Tunatafuta dereva" : "Finding a driver"
        case .noDrivers: return sw ? "Hakuna dereva" : "No drivers nearby"
        case .cancelled: return sw ? "Imesitishwa" : "Cancelled"
        default: return attributes.destinationName
        }
    }
}

private struct CompactTrailing: View {
    let attributes: RideActivityAttributes
    let state: RideActivityAttributes.ContentState

    var body: some View {
        Group {
            switch state.stage {
            case .onTheWay, .inTrip:
                Text(WidgetCopy.minutes(max(state.minutes, 1), attributes.language))
                    .contentTransition(.numericText(countsDown: true))
            case .arrived:
                Text(state.pin ?? "")
            case .completed, .paid:
                Text(WidgetCopy.tzs(state.fare))
            case .searching:
                Text("···")
            case .noDrivers, .cancelled:
                Text("—")
            }
        }
        .font(WidgetType.figtree(14, weight: .bold).monospacedDigit())
        .foregroundStyle(WidgetPalette.gold)
        .lineLimit(1)
    }
}
