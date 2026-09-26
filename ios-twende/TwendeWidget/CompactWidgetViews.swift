import SwiftUI
import WidgetKit

/// 2×2: the live ride (vehicle, ETA, plate) or the gold "Where to?" launcher over the Home/Work chips.
struct SmallLauncherView: View {
    let entry: TwendeEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var lang: WidgetLanguage { snapshot.language }

    var body: some View {
        if let trip = snapshot.activeTrip {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    WidgetVehicle(tier: trip.tier, width: 60)
                    Spacer(minLength: 0)
                    if let plate = trip.plate, trip.phase != "inTrip" {
                        WidgetPlate(plate: plate, small: true)
                    }
                }
                Spacer(minLength: 0)
                Text(ActiveTripCopy.headline(trip, lang))
                    .font(WidgetType.label)
                    .foregroundStyle(WidgetPalette.inkSecondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ActiveTripCopy.bigNumber(trip))
                        .font(WidgetType.figtree(30, weight: .bold).monospacedDigit())
                        .foregroundStyle(WidgetPalette.ink)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(ActiveTripCopy.unit(trip, lang))
                        .font(WidgetType.caption)
                        .foregroundStyle(WidgetPalette.inkSecondary)
                        .lineLimit(1)
                }
                RouteProgressBar(progress: trip.progress)
            }
            .padding(14)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let nearest = snapshot.nearestService, let eta = nearest.etaMinutes {
                    // The soonest pickup near the passenger right now takes the title slot; the gold bar
                    // already carries the "search a destination" call to action.
                    NearestServiceLine(service: nearest, etaMinutes: eta, lang: lang)
                } else {
                    Text(WidgetCopy.text(.whereTo, lang))
                        .font(WidgetType.title)
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    ForEach(QuickPlaces.slots(snapshot, lang, limit: 2)) { slot in
                        Link(destination: slot.url) {
                            WidgetIcon3D(object: slot.object, size: 28)
                                .frame(width: 40, height: 40)
                                .background(WidgetPalette.canvas, in: .circle)
                                .overlay(Circle().strokeBorder(WidgetPalette.border, lineWidth: 1))
                        }
                    }
                    Spacer(minLength: 0)
                }
                Link(destination: WidgetLink.search) {
                    GoldBar(title: WidgetCopy.text(.searchDestination, lang), height: 44)
                }
            }
            .padding(12)
        }
    }
}

/// One line for the soonest pickup: the family's vehicle, its name and the minutes, as on the Home tabs.
struct NearestServiceLine: View {
    let service: WidgetServiceEta
    let etaMinutes: Int
    let lang: WidgetLanguage

    var body: some View {
        HStack(spacing: 8) {
            WidgetVehicle(tier: service.tier, width: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(service.name)
                    .font(WidgetType.label)
                    .foregroundStyle(WidgetPalette.inkSecondary)
                    .lineLimit(1)
                Text(WidgetCopy.minutes(etaMinutes, lang))
                    .font(WidgetType.figtree(17, weight: .bold).monospacedDigit())
                    .foregroundStyle(WidgetPalette.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 4×2: the pickup panel in miniature (vehicle + driver + plate + PIN) or the launcher beside Home/Work rows.
struct MediumLauncherView: View {
    let entry: TwendeEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var lang: WidgetLanguage { snapshot.language }

    var body: some View {
        if let trip = snapshot.activeTrip {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ActiveTripCopy.headline(trip, lang))
                        .font(WidgetType.figtree(20, weight: .bold))
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if trip.phase == "driverAssigned" || trip.phase == "inTrip" {
                        Text("\(ActiveTripCopy.bigNumber(trip)) \(ActiveTripCopy.unit(trip, lang))")
                            .font(WidgetType.figtree(20, weight: .bold).monospacedDigit())
                            .foregroundStyle(WidgetPalette.ink)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center, spacing: 12) {
                    WidgetVehicle(tier: trip.tier, width: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trip.driverFirstName ?? trip.tierName)
                            .font(WidgetType.bodySemibold)
                            .foregroundStyle(WidgetPalette.ink)
                            .lineLimit(1)
                        if let vehicle = trip.vehicle {
                            Text(vehicle)
                                .font(WidgetType.caption)
                                .foregroundStyle(WidgetPalette.inkSecondary)
                                .lineLimit(1)
                        }
                        if let plate = trip.plate {
                            WidgetPlate(plate: plate, small: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if let pin = trip.ridePIN, trip.phase == "driverAssigned" || trip.phase == "driverArrived" {
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(WidgetCopy.text(.startCode, lang).uppercased())
                                .font(WidgetType.figtree(10, weight: .semibold))
                                .kerning(1)
                                .foregroundStyle(WidgetPalette.inkSecondary)
                            WidgetSplitFlap(text: pin, tileSize: CGSize(width: 24, height: 34), spacing: 3)
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(WidgetCopy.text(.to, lang))
                                .font(WidgetType.label)
                                .foregroundStyle(WidgetPalette.inkSecondary)
                            Text(trip.destination)
                                .font(WidgetType.captionMedium)
                                .foregroundStyle(WidgetPalette.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                        .frame(maxWidth: 110)
                    }
                }
                RouteProgressBar(progress: trip.progress)
            }
            .padding(14)
        } else {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(WidgetCopy.text(.whereTo, lang))
                        .font(WidgetType.title)
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                    if let nearest = snapshot.nearestService, let eta = nearest.etaMinutes {
                        NearestServiceLine(service: nearest, etaMinutes: eta, lang: lang)
                    }
                    Spacer(minLength: 0)
                    Link(destination: WidgetLink.search) {
                        GoldBar(title: WidgetCopy.text(.searchDestination, lang), height: 48)
                    }
                }
                .frame(maxWidth: .infinity)
                Rectangle().fill(WidgetPalette.border).frame(width: 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(QuickPlaces.slots(snapshot, lang, limit: 2).enumerated()), id: \.element.id) { index, slot in
                        if index > 0 { WidgetHairline(leading: 0) }
                        Link(destination: slot.url) {
                            HStack(spacing: 10) {
                                WidgetIcon3D(object: slot.object, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(slot.title)
                                        .font(WidgetType.captionMedium)
                                        .foregroundStyle(WidgetPalette.ink)
                                        .lineLimit(1)
                                    if !slot.detail.isEmpty {
                                        Text(slot.detail)
                                            .font(WidgetType.label)
                                            .foregroundStyle(WidgetPalette.inkSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                }
                .frame(width: 128)
            }
            .padding(14)
        }
    }
}

/// Ride / Bajaji / Boda pickup times in one row — the Home service switcher, flattened. A family with no
/// driver in range shows "none" rather than a made-up number.
struct ServiceEtaStrip: View {
    let etas: [WidgetServiceEta]
    let lang: WidgetLanguage
    var vehicleWidth: CGFloat = 36

    var body: some View {
        HStack(spacing: 14) {
            ForEach(etas) { eta in
                Link(destination: WidgetLink.search) {
                    HStack(spacing: 6) {
                        WidgetVehicle(tier: eta.tier, width: vehicleWidth)
                            .opacity(eta.etaMinutes == nil ? 0.45 : 1)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(eta.name)
                                .font(WidgetType.label)
                                .foregroundStyle(WidgetPalette.ink)
                                .lineLimit(1)
                            Text(eta.etaMinutes.map { WidgetCopy.minutes($0, lang) } ?? WidgetCopy.text(.noDriversShort, lang))
                                .font(WidgetType.figtree(12, weight: .medium).monospacedDigit())
                                .foregroundStyle(WidgetPalette.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Words for the live ride, shared by every family.
enum ActiveTripCopy {
    static func headline(_ trip: WidgetActiveTrip, _ lang: WidgetLanguage) -> String {
        switch trip.phase {
        case "searching": WidgetCopy.text(.searching, lang)
        case "noDrivers": WidgetCopy.text(.noDrivers, lang)
        case "driverArrived": WidgetCopy.text(.driverArrived, lang)
        case "inTrip": WidgetCopy.text(.onTheWay, lang)
        case "completed", "paymentPending", "paymentConfirmed": WidgetCopy.text(.tripComplete, lang)
        default: WidgetCopy.text(.arrivingIn, lang)
        }
    }

    static func bigNumber(_ trip: WidgetActiveTrip) -> String {
        switch trip.phase {
        case "searching", "noDrivers": "…"
        case "driverArrived": "✓"
        case "completed", "paymentPending", "paymentConfirmed": WidgetCopy.tzs(trip.fare).replacingOccurrences(of: "TZS ", with: "")
        default: "\(max(trip.etaMinutes, 1))"
        }
    }

    static func unit(_ trip: WidgetActiveTrip, _ lang: WidgetLanguage) -> String {
        switch trip.phase {
        case "searching", "noDrivers", "driverArrived": ""
        case "completed", "paymentPending", "paymentConfirmed": "TZS"
        case "inTrip": "\(WidgetCopy.text(.min, lang)) \(WidgetCopy.text(.remaining, lang))"
        default: WidgetCopy.text(.min, lang)
        }
    }
}

/// Home / Work / extra saved chips, falling back to "Add home" when a slot is empty.
enum QuickPlaces {
    struct Slot: Identifiable {
        let id: String
        let title: String
        let detail: String
        let object: WidgetIcon3D.Object
        let url: URL
    }

    static func slots(_ snapshot: WidgetSnapshot, _ lang: WidgetLanguage, limit: Int = 2) -> [Slot] {
        var slots: [Slot] = []
        for kind in ["home", "work"] {
            if let saved = snapshot.savedPlaces.first(where: { $0.kind == kind }) {
                slots.append(Slot(id: saved.id, title: saved.label, detail: saved.detail, object: WidgetIcon3D.forPlaceKind(kind), url: WidgetLink.place(saved.id)))
            } else {
                let title = kind == "home" ? WidgetCopy.text(.addHome, lang) : WidgetCopy.text(.addWork, lang)
                slots.append(Slot(id: "add-\(kind)", title: title, detail: "", object: WidgetIcon3D.forPlaceKind(kind), url: WidgetLink.search))
            }
        }
        for saved in snapshot.savedPlaces where saved.kind == "other" {
            slots.append(Slot(id: saved.id, title: saved.label, detail: saved.detail, object: .signpost, url: WidgetLink.place(saved.id)))
        }
        return Array(slots.prefix(limit))
    }
}
