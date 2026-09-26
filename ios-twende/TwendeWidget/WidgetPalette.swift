import SwiftUI
import WidgetKit

/// Widget-side copy of the product palette: white canvas, near-black ink, warm greys, one champagne accent.
/// Values mirror `TwendeColor` exactly so the widget is indistinguishable from an app panel.
enum WidgetPalette {
    static let canvas = Color.white
    static let surfaceAlt = Color(hex: 0xF7F7F7)
    static let border = Color(hex: 0xDDDDDD)
    static let ink = Color(hex: 0x222222)
    static let inkSecondary = Color(hex: 0x6A6A6A)
    static let inkTertiary = Color(hex: 0xB0B0B0)

    static let gold = Color(hex: 0xC5AA76)
    static let goldPressed = Color(hex: 0xAD905A)
    static let goldDeep = Color(hex: 0xB89261)
    static let goldMid = Color(hex: 0xD3B07E)
    static let goldLight = Color(hex: 0xE6C89E)
    static let goldHighlight = Color(hex: 0xEFD9B4)
    static let goldTint = Color(hex: 0xF7F1E5)
    static let accentText = Color(hex: 0x745523)

    static let enamel = Color(hex: 0xFFE24D)
    static let busy = Color(hex: 0xE07A00)
    static let offline = Color(hex: 0xC8C8C8)

    static func status(_ raw: String) -> Color {
        switch raw {
        case "online": gold
        case "busy": busy
        default: offline
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The app's Figtree scale, bundled with the extension (`UIAppFonts` in Info.plist).
enum WidgetType {
    private static let regular = "Figtree-Regular"
    private static let medium = "Figtree-Medium"
    private static let semibold = "Figtree-SemiBold"
    private static let bold = "Figtree-Bold"

    static let display = Font.custom(bold, size: 28)
    static let title = Font.custom(bold, size: 22)
    static let section = Font.custom(semibold, size: 18)
    static let headline = Font.custom(semibold, size: 17)
    static let body = Font.custom(regular, size: 16)
    static let bodyMedium = Font.custom(medium, size: 16)
    static let bodySemibold = Font.custom(semibold, size: 16)
    static let caption = Font.custom(regular, size: 14)
    static let captionMedium = Font.custom(medium, size: 14)
    static let label = Font.custom(medium, size: 13)
    static let fare = Font.custom(bold, size: 17).monospacedDigit()
    static let fareLarge = Font.custom(bold, size: 28).monospacedDigit()
    static let plate = Font.custom(bold, size: 17).monospacedDigit()
    static let plateSmall = Font.custom(semibold, size: 13).monospacedDigit()

    static func figtree(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .bold, .heavy, .black: Font.custom(bold, size: size)
        case .semibold: Font.custom(semibold, size: size)
        case .medium: Font.custom(medium, size: size)
        default: Font.custom(regular, size: size)
        }
    }
}

/// Static, deterministic micro-grain for enamel and brushed metal. Identical to the app's.
struct WidgetSurfaceGrain: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<320 {
                let x = CGFloat((index * 73 + 19) % 997) / 997 * size.width
                let y = CGFloat((index * 137 + 47) % 991) / 991 * size.height
                let rect = CGRect(x: x, y: y, width: 0.6, height: 0.6)
                context.fill(Path(ellipseIn: rect), with: .color(index.isMultiple(of: 2) ? .white.opacity(0.16) : .black.opacity(0.075)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 3D objects

/// The rendered miniature objects the app uses for iconography. Vehicles are read from the App Group
/// (the app exports its procedural renders); the other objects are bundled with the extension.
struct WidgetIcon3D: View {
    enum Object: String {
        case house = "modern_house_model"
        case briefcase = "briefcase_slim"
        case signpost = "signpost_dual_arrow"
        case pin = "location_pin_2"
        case clock = "vintage_stopwatch"
        case wallet = "bifold_wallet"
        case logbook = "leather_travel_logbook"
        case driver = "mannequin_driver_bust"
        case coins = "stacked_coins"
    }

    let object: Object
    var size: CGFloat = 40

    var body: some View {
        Image(object.rawValue)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func forPlaceKind(_ kind: String) -> Object {
        switch kind {
        case "home": .house
        case "work": .briefcase
        case "recent": .clock
        default: .signpost
        }
    }
}

/// A ride tier as the app draws it: the procedural fleet render when the app has exported one, otherwise
/// the archived monochrome miniature of the closest vehicle.
struct WidgetVehicle: View {
    let tier: String
    var width: CGFloat = 56

    private var fallbackAsset: String {
        switch tier {
        case "comfort", "premium": "sedan_car_miniature"
        case "bajaji": "rickshaw_miniature"
        case "boda": "boda_boda_motorcycle_2"
        default: "hatchback_car"
        }
    }

    var body: some View {
        Group {
            if let url = WidgetSnapshotStore.vehicleImageURL(tier: tier), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(fallbackAsset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .saturation(0)
            }
        }
        .frame(width: width, height: width * 0.78)
        .accessibilityHidden(true)
    }
}

// MARK: - Skeuomorphic pieces

/// The app's 56pt brushed-gold primary action: horizontal sheen, inner occlusion, grain and bevelled edge.
struct GoldBar: View {
    let title: String
    var systemImage: String? = "magnifyingglass"
    var height: CGFloat = 56

    private var stops: [Gradient.Stop] {
        [
            .init(color: WidgetPalette.goldDeep, location: 0),
            .init(color: WidgetPalette.goldMid, location: 0.18),
            .init(color: WidgetPalette.goldLight, location: 0.42),
            .init(color: WidgetPalette.goldMid, location: 0.58),
            .init(color: WidgetPalette.goldHighlight, location: 0.74),
            .init(color: WidgetPalette.goldDeep, location: 1)
        ]
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
            }
            Text(title)
                .font(WidgetType.bodySemibold)
                .lineLimit(1)
        }
        .foregroundStyle(Color.white.shadow(.drop(color: WidgetPalette.goldDeep.opacity(0.55), radius: 0.6, y: 0.6)))
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            ZStack {
                shape.fill(LinearGradient(stops: stops, startPoint: UnitPoint(x: 0, y: 0.35), endPoint: UnitPoint(x: 1, y: 0.65)))
                shape.fill(
                    Color.clear
                        .shadow(.inner(color: WidgetPalette.ink.opacity(0.58), radius: 3.5, x: 0.7, y: -2))
                        .shadow(.inner(color: .white.opacity(0.50), radius: 1, x: -0.5, y: 1.2))
                )
                shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear, WidgetPalette.ink.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                WidgetSurfaceGrain()
                shape.inset(by: 0.65).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.42), .clear, WidgetPalette.ink.opacity(0.48)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            }
        }
        .clipShape(shape)
        .widgetAccentable()
    }
}

/// Stamped yellow enamel registration plate with rolled lip, raised bead and embossed ink lettering.
struct WidgetPlate: View {
    let plate: String
    var small: Bool = false

    var body: some View {
        let radius: CGFloat = 4
        let rim = RoundedRectangle(cornerRadius: radius)
        let field = RoundedRectangle(cornerRadius: 2)
        let bead: CGFloat = 0.8
        ZStack {
            registration.foregroundStyle(WidgetPalette.ink.opacity(0.28)).blur(radius: 0.6).offset(y: 0.9)
            registration.foregroundStyle(.white.opacity(0.65)).offset(y: -0.5)
            registration.foregroundStyle(WidgetPalette.ink)
        }
        .padding(.horizontal, small ? 10 : 12)
        .padding(.vertical, small ? 5 : 7)
        .background {
            ZStack {
                rim.fill(LinearGradient(stops: [
                    .init(color: WidgetPalette.enamel.mix(with: .white, by: 0.14), location: 0),
                    .init(color: WidgetPalette.enamel, location: 0.45),
                    .init(color: WidgetPalette.enamel.mix(with: WidgetPalette.ink, by: 0.10), location: 1)
                ], startPoint: .top, endPoint: .bottom))
                rim.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.20), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.35),
                    .init(color: .clear, location: 0.6)
                ], startPoint: .top, endPoint: .bottom))
                WidgetSurfaceGrain().clipShape(rim)
                field.strokeBorder(.white.opacity(0.55), lineWidth: bead).offset(y: -bead * 0.6).clipShape(rim)
                field.strokeBorder(WidgetPalette.ink.opacity(0.30), lineWidth: bead).offset(y: bead * 0.6).clipShape(rim)
                field.strokeBorder(WidgetPalette.enamel, lineWidth: bead * 0.5)
                rim.strokeBorder(LinearGradient(stops: [
                    .init(color: .white.opacity(0.75), location: 0),
                    .init(color: WidgetPalette.enamel.mix(with: WidgetPalette.ink, by: 0.18), location: 0.55),
                    .init(color: WidgetPalette.ink.opacity(0.55), location: 1)
                ], startPoint: .top, endPoint: .bottom), lineWidth: 1.25)
            }
        }
        .clipShape(rim)
    }

    private var registration: some View {
        Text(plate)
            .font(small ? WidgetType.plateSmall : WidgetType.plate)
            .kerning(small ? 0.6 : 1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// The ride start code as four static split-flap tiles: champagne upper leaf, deeper lower leaf,
/// hinge shadow in the middle and inset digits — the same object the app flips in.
struct WidgetSplitFlap: View {
    let text: String
    var tileSize: CGSize = CGSize(width: 30, height: 42)
    var spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                VStack(spacing: 1) {
                    half(character, top: true)
                    half(character, top: false)
                }
            }
        }
        .accessibilityLabel(Text(text.map(String.init).joined(separator: " ")))
    }

    private func half(_ character: Character, top: Bool) -> some View {
        let radius = tileSize.width * 0.34
        let halfHeight = tileSize.height / 2
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0,
            bottomLeadingRadius: top ? 0 : radius,
            bottomTrailingRadius: top ? 0 : radius,
            topTrailingRadius: top ? radius : 0
        )
        return ZStack {
            shape.fill(
                (top ? WidgetPalette.gold : WidgetPalette.goldPressed)
                    .shadow(.inner(color: WidgetPalette.ink.opacity(0.58), radius: 3.5, x: 0.7, y: top ? -2 : 2.5))
                    .shadow(.inner(color: .white.opacity(0.50), radius: 1, x: -0.5, y: top ? 1.2 : -1.2))
            )
            shape.fill(LinearGradient(
                colors: [.white.opacity(top ? 0.24 : 0.10), .clear, WidgetPalette.ink.opacity(top ? 0.24 : 0.14)],
                startPoint: .top, endPoint: .bottom
            ))
            WidgetSurfaceGrain()
            Text(String(character))
                .font(WidgetType.figtree(tileSize.height * 0.64, weight: .bold).monospacedDigit())
                .foregroundStyle(WidgetPalette.ink.shadow(.inner(color: .black.opacity(0.25), radius: 0.8, y: 0.9)))
                .frame(width: tileSize.width, height: tileSize.height)
                .offset(y: top ? halfHeight / 2 : -halfHeight / 2)
        }
        .frame(width: tileSize.width, height: halfHeight)
        .overlay(alignment: top ? .bottom : .top) {
            LinearGradient(
                colors: top ? [.clear, WidgetPalette.ink.opacity(0.65)] : [WidgetPalette.ink.opacity(0.48), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: top ? 5 : 4)
        }
        .overlay {
            shape.inset(by: 0.65).strokeBorder(
                LinearGradient(colors: [.white.opacity(top ? 0.42 : 0.18), .clear, WidgetPalette.ink.opacity(0.48)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
        }
        .clipShape(shape)
    }
}

// MARK: - Flat UI pieces (rows, chips, hairlines)

struct WidgetHairline: View {
    var leading: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(WidgetPalette.border)
            .frame(height: 1)
            .padding(.leading, leading)
    }
}

/// 18pt semibold sentence-case section heading with an optional underlined action, as in the app.
struct WidgetSectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var actionURL: URL? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(WidgetType.section)
                .foregroundStyle(WidgetPalette.ink)
            Spacer()
            if let actionTitle, let actionURL {
                Link(destination: actionURL) {
                    Text(actionTitle)
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(WidgetPalette.ink)
                        .underline()
                }
            }
        }
    }
}

/// Airbnb chip: white, hairline, 24pt 3D object and 14pt medium label.
struct WidgetChip: View {
    let title: String
    let object: WidgetIcon3D.Object
    var height: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            WidgetIcon3D(object: object, size: 24)
            Text(title)
                .font(WidgetType.captionMedium)
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: height)
        .background(WidgetPalette.canvas, in: .capsule)
        .overlay(Capsule().strokeBorder(WidgetPalette.border, lineWidth: 1))
    }
}

/// Destination row: 40pt 3D object, name, address; identical to the app's `PlaceRow`.
struct WidgetPlaceRow: View {
    let title: String
    let detail: String
    let object: WidgetIcon3D.Object
    var trailing: String? = nil
    var height: CGFloat = 60

    var body: some View {
        HStack(spacing: 16) {
            WidgetIcon3D(object: object, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(WidgetType.bodyMedium)
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(WidgetType.caption)
                        .foregroundStyle(WidgetPalette.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(WidgetType.fare)
                    .foregroundStyle(WidgetPalette.ink)
            }
        }
        .frame(height: height)
    }
}

/// Neutral driver mark on a grey disc with a status dot, matching `DriverAvatar`.
struct WidgetDriverAvatar: View {
    let driver: WidgetDriver
    var size: CGFloat = 56

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(WidgetPalette.surfaceAlt)
                .frame(width: size, height: size)
                .overlay {
                    WidgetIcon3D(object: .driver, size: size * 0.78)
                        .offset(y: size * 0.06)
                }
                .clipShape(.circle)
                .saturation(driver.status == "offline" ? 0.2 : 1)
                .opacity(driver.status == "offline" ? 0.7 : 1)
            Circle()
                .fill(WidgetPalette.status(driver.status))
                .frame(width: max(size * 0.24, 12), height: max(size * 0.24, 12))
                .overlay(Circle().stroke(WidgetPalette.canvas, lineWidth: 2.5))
                .offset(x: 1, y: 1)
        }
        .frame(width: size + 2, height: size + 2)
    }
}

/// Ink route line with pickup dot and destination square, the map-pin grammar in miniature.
struct RouteProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.border).frame(height: 3)
                Capsule().fill(WidgetPalette.ink).frame(width: max(6, width * progress), height: 3)
                Circle().fill(WidgetPalette.ink).frame(width: 8, height: 8)
                Rectangle().fill(WidgetPalette.ink).frame(width: 8, height: 8).offset(x: width - 8)
                Circle()
                    .fill(WidgetPalette.canvas)
                    .overlay(Circle().stroke(WidgetPalette.ink, lineWidth: 2.5))
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, min(width - 12, width * progress - 6)))
            }
            .frame(height: 12)
        }
        .frame(height: 12)
    }
}
