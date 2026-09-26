import SwiftUI
import WidgetKit

/// Supplies the shared snapshot on a timeline. The app calls `WidgetCenter.reloadTimelines` whenever
/// the ride, wallet or places change, so the timeline itself only needs a slow safety refresh.
nonisolated struct TwendeTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TwendeEntry {
        TwendeEntry(date: .now, snapshot: .preview, isPlaceholder: true, isConnected: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TwendeEntry) -> Void) {
        if context.isPreview {
            completion(TwendeEntry(date: .now, snapshot: .preview, isPlaceholder: false, isConnected: true))
        } else {
            completion(TwendeTimelineProvider.currentEntry(at: .now))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TwendeEntry>) -> Void) {
        let now = Date.now
        completion(TwendeTimelineProvider.timeline(from: TwendeTimelineProvider.currentEntry(at: now), now: now))
    }

    private static func timeline(from current: TwendeEntry, now: Date) -> Timeline<TwendeEntry> {
        var entries: [TwendeEntry] = [current]
        let snapshot = current.snapshot
        // Count the ETA down between app refreshes so the number never looks stuck.
        if let trip = snapshot.activeTrip, trip.etaMinutes > 1, trip.phase == "driverAssigned" || trip.phase == "inTrip" {
            for minute in 1..<min(trip.etaMinutes, 15) {
                var next = snapshot
                next.activeTrip?.etaMinutes = trip.etaMinutes - minute
                entries.append(TwendeEntry(date: now.addingTimeInterval(Double(minute) * 60), snapshot: next, isPlaceholder: false, isConnected: current.isConnected))
            }
        } else if !snapshot.serviceEtas.isEmpty {
            // Pickup times are only meaningful for a short while after the app last measured them.
            var stale = snapshot
            stale.serviceEtas = []
            entries.append(TwendeEntry(date: now.addingTimeInterval(TwendeTimelineProvider.etaLifetime), snapshot: stale, isPlaceholder: false, isConnected: current.isConnected))
        }
        let refresh = snapshot.activeTrip == nil ? now.addingTimeInterval(30 * 60) : now.addingTimeInterval(5 * 60)
        return Timeline(entries: entries, policy: .after(refresh))
    }

    /// How long a published pickup estimate stays on the widget before it is hidden as out of date.
    static let etaLifetime: TimeInterval = 20 * 60

    /// Reads the App Group. No snapshot means the app has never run with this widget installed, or the
    /// build lacks the shared container — both render as the "open Zuri to connect" state.
    static func currentEntry(at date: Date) -> TwendeEntry {
        guard var snapshot = WidgetSnapshotStore.load() else {
            return TwendeEntry(date: date, snapshot: .empty(language: .device), isPlaceholder: false, isConnected: false)
        }
        if date.timeIntervalSince(snapshot.generatedAt) > etaLifetime {
            snapshot.serviceEtas = []
        }
        return TwendeEntry(date: date, snapshot: snapshot, isPlaceholder: false, isConnected: true)
    }
}

nonisolated struct TwendeEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let isPlaceholder: Bool
    /// False until the app has published a snapshot this widget can read.
    let isConnected: Bool
}

/// Home Screen widget: a compact ride launcher in the small and medium sizes, a live trip card in the large
/// size, and — new in iOS 27 — a full-height portrait dashboard that stands in for the app's Home screen.
struct TwendeWidget: Widget {
    let kind: String = TwendeAppGroup.widgetKind

    /// The portrait extra-large family is an iOS 27 SDK symbol; the iOS 26 SDK marks it unavailable on iOS.
    /// `IOS27_SDK` is set by the project only when building against an iOS 27 SDK, so both toolchains build.
    private var families: [WidgetFamily] {
        var all: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        #if IOS27_SDK
        if #available(iOS 27.0, *) {
            all.append(.systemExtraLargePortrait)
        }
        #endif
        return all
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TwendeTimelineProvider()) { entry in
            TwendeWidgetRootView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetPalette.canvas
                }
        }
        .configurationDisplayName("Zuri")
        .description("Pickup times, your wallet and payment method, and your ride as it happens.")
        .supportedFamilies(families)
        .contentMarginsDisabled()
    }
}

/// Picks the layout for the current family. iOS 27's portrait extra-large family gets the full dashboard.
struct TwendeWidgetRootView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TwendeEntry

    var body: some View {
        // Before the app has published (or when the install cannot share data), the same launcher renders from
        // an empty snapshot: search, Add home / Add work and the wallet all still open the app. No dead-end prompt.
        Group {
            if isPortraitExtraLarge {
                FullScreenDashboardView(entry: entry)
            } else {
                switch family {
                case .systemSmall: SmallLauncherView(entry: entry)
                case .systemMedium: MediumLauncherView(entry: entry)
                default: LargeTripCardView(entry: entry)
                }
            }
        }
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        .widgetURL(entry.snapshot.activeTrip == nil ? WidgetLink.home : WidgetLink.activeTrip)
    }

    private var isPortraitExtraLarge: Bool {
        #if IOS27_SDK
        if #available(iOS 27.0, *) {
            return family == .systemExtraLargePortrait
        }
        #endif
        return false
    }
}

