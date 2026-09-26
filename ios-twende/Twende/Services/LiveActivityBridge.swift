import ActivityKit
import Foundation
import UIKit

/// Mirrors the active trip into a Live Activity on the Lock Screen and in the Dynamic Island.
/// The trip simulation ticks four times a second; updates are coalesced to meaningful changes
/// (stage, minutes, a real turn or visible progress) so ActivityKit's budget is never exhausted.
enum LiveActivityBridge {
    private typealias State = RideActivityAttributes.ContentState

    private static var lastState: State?
    private static var lastPush: Date = .distantPast
    private static var unwrappedHeading: Double?
    private static var lastRawHeading: Double = 0
    private static var exportedPortraits: Set<String> = []

    private static var current: Activity<RideActivityAttributes>? {
        Activity<RideActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Call whenever the trip changes. Starts, updates or ends the activity as needed.
    static func sync(_ env: AppEnvironment) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let trip = env.trips.activeTrip, let stage = stage(for: trip.phase) else {
            endForArchivedTrip(env)
            return
        }

        let heading = trackHeading(env.trips.driverHeading, stage: stage)
        var state = makeState(trip: trip, stage: stage, heading: heading, env: env)

        if let activity = current, activity.attributes.tripID == trip.id {
            guard shouldPush(state) else { return }
            state.turn = turn(from: lastState, to: state)
            push(state, to: activity, alert: alert(for: state, previous: lastState, trip: trip, env: env))
        } else {
            endAll()
            start(trip: trip, state: state, env: env)
        }
    }

    // MARK: Lifecycle

    private static func start(trip: Trip, state: State, env: AppEnvironment) {
        let attributes = RideActivityAttributes(
            tripID: trip.id,
            tier: trip.tier.rawValue,
            tierName: L(trip.tier.nameKey),
            pickupName: trip.pickup.name,
            destinationName: trip.destination.name,
            paymentName: paymentName(trip.paymentMethod, env: env),
            language: language(env)
        )
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(20 * 60)),
                pushType: nil
            )
            lastState = state
            lastPush = Date()
        } catch {
            print("[LiveActivity] could not start: \(error.localizedDescription)")
        }
    }

    private static func push(_ state: State, to activity: Activity<RideActivityAttributes>, alert: AlertConfiguration?) {
        lastState = state
        lastPush = Date()
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(20 * 60))
        Task {
            await activity.update(content, alertConfiguration: alert)
        }
    }

    /// The trip left `activeTrip` (rated or cancelled): show the outcome briefly, then dismiss.
    private static func endForArchivedTrip(_ env: AppEnvironment) {
        guard let activity = current else { return }
        let archived = env.store.trip(id: activity.attributes.tripID)
        var final = lastState ?? State(stage: .paid, minutes: 0, progress: 1, heading: 0, turn: 0, fare: archived?.totalDue ?? 0, inTraffic: false)
        final.stage = archived?.phase == .cancelled ? .cancelled : .paid
        final.minutes = 0
        final.turn = 0
        final.inTraffic = false
        if let archived { final.fare = archived.phase == .cancelled ? (archived.cancellation?.fee ?? 0) : archived.totalDue }
        let dismissAfter: TimeInterval = final.stage == .cancelled ? 30 : 90
        resetTracking()
        Task {
            await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(dismissAfter)))
        }
    }

    private static func endAll() {
        resetTracking()
        for activity in Activity<RideActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func resetTracking() {
        lastState = nil
        lastPush = .distantPast
        unwrappedHeading = nil
    }

    // MARK: State

    private static func stage(for phase: TripPhase) -> RideActivityAttributes.Stage? {
        switch phase {
        case .searching: .searching
        case .noDrivers: .noDrivers
        case .driverAssigned: .onTheWay
        case .driverArrived: .arrived
        case .inTrip: .inTrip
        case .completed, .paymentPending: .completed
        case .paymentConfirmed: .paid
        case .rated, .cancelled: nil
        }
    }

    private static func makeState(trip: Trip, stage: RideActivityAttributes.Stage, heading: Double, env: AppEnvironment) -> State {
        let driver = env.trips.assignedDriver
        let minutes: Int
        let progress: Double
        switch stage {
        case .onTheWay:
            minutes = env.trips.driverEtaMinutes
            progress = env.trips.approachProgress
        case .arrived:
            minutes = 0
            progress = 1
        case .inTrip:
            minutes = env.trips.remainingTripMinutes
            progress = env.trips.tripProgress
        case .completed, .paid:
            minutes = 0
            progress = 1
        default:
            minutes = 0
            progress = 0
        }
        return State(
            stage: stage,
            minutes: max(minutes, 0),
            progress: min(max(progress, 0), 1),
            heading: heading,
            turn: 0,
            driverName: driver?.firstName,
            driverID: portraitID(for: driver),
            vehicle: driver.map { "\($0.vehicle.colour) \($0.vehicle.make) \($0.vehicle.model)" },
            plate: driver?.vehicle.plate,
            pin: stage == .onTheWay || stage == .arrived ? trip.ridePIN : nil,
            fare: stage == .completed || stage == .paid ? trip.totalDue : trip.fare,
            inTraffic: stage == .inTrip && env.trips.isInTraffic,
            nextStop: stage == .inTrip ? trip.stopList.first?.name : nil
        )
    }

    /// Copies the driver's catalogue portrait into the App Group once, small enough for the Live Activity.
    private static func portraitID(for driver: Driver?) -> String? {
        guard let driver, let name = driver.portraitName else { return nil }
        if exportedPortraits.contains(driver.id) { return driver.id }
        guard let image = UIImage(named: name),
              let url = WidgetSnapshotStore.driverPortraitURL(id: driver.id),
              let data = WidgetBridge.downscaled(image, maxSide: 120).pngData() else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            exportedPortraits.insert(driver.id)
            return driver.id
        } catch {
            print("[LiveActivity] portrait export failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Keeps the heading continuous (359° → 2° becomes 359° → 362°) so the car never spins backwards.
    private static func trackHeading(_ raw: Double, stage: RideActivityAttributes.Stage) -> Double {
        guard stage == .onTheWay || stage == .inTrip || stage == .arrived else { return unwrappedHeading ?? raw }
        guard let previous = unwrappedHeading else {
            unwrappedHeading = raw
            lastRawHeading = raw
            return raw
        }
        let delta = shortestDelta(from: lastRawHeading, to: raw)
        lastRawHeading = raw
        let next = previous + delta
        unwrappedHeading = next
        return next
    }

    private static func shortestDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func turn(from previous: State?, to next: State) -> Double {
        guard let previous, previous.stage == next.stage else { return 0 }
        return min(max(next.heading - previous.heading, -32), 32)
    }

    private static func shouldPush(_ state: State) -> Bool {
        guard let last = lastState else { return true }
        let elapsed = Date().timeIntervalSince(lastPush)
        if last.stage != state.stage || last.driverName != state.driverName || last.driverID != state.driverID || last.pin != state.pin || last.fare != state.fare {
            return true
        }
        if elapsed < 1 { return false }
        if last.minutes != state.minutes || last.inTraffic != state.inTraffic || last.nextStop != state.nextStop { return true }
        if abs(last.heading - state.heading) >= 9 { return true }
        // A straight stretch after a turn: level the car again.
        if last.turn != 0 && abs(last.heading - state.heading) < 2 && elapsed >= 1.5 { return true }
        return elapsed >= 3 && abs(last.progress - state.progress) >= 0.03
    }

    private static func alert(for state: State, previous: State?, trip: Trip, env: AppEnvironment) -> AlertConfiguration? {
        guard let previous, previous.stage != state.stage else { return nil }
        let swahili = language(env) == .swahili
        let name = state.driverName ?? (swahili ? "Dereva" : "Your driver")
        switch state.stage {
        case .onTheWay:
            return AlertConfiguration(
                title: swahili ? "\(name) yuko njiani" : "\(name) is on the way",
                body: swahili ? "Anafika baada ya dakika \(state.minutes)" : "Arriving in \(state.minutes) min",
                sound: .default
            )
        case .arrived:
            return AlertConfiguration(
                title: swahili ? "\(name) amefika" : "\(name) is here",
                body: swahili ? "Namba ya kuanza: \(state.pin ?? "")" : "Start code \(state.pin ?? "")",
                sound: .default
            )
        case .completed:
            return AlertConfiguration(
                title: swahili ? "Umefika \(trip.destination.name)" : "You've arrived at \(trip.destination.name)",
                body: LocalizedStringResource(stringLiteral: WidgetCopy.tzs(state.fare)),
                sound: .default
            )
        default:
            return nil
        }
    }

    private static func language(_ env: AppEnvironment) -> WidgetLanguage {
        env.settings.language == .english ? .english : .swahili
    }

    private static func paymentName(_ method: PaymentMethod, env: AppEnvironment) -> String {
        method == .cash && language(env) == .swahili ? "Taslimu" : method.displayName
    }
}
