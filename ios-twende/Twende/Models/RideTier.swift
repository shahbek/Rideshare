import Foundation

/// Five distinct ride options. Existing raw values remain stable for saved trips.
nonisolated enum RideTier: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case economy
    case comfort
    case premium
    case bajaji
    case boda

    var id: String { rawValue }

    var nameKey: LKey {
        switch self {
        case .economy: .tierEconomy
        case .comfort: .tierComfort
        case .premium: .tierPremium
        case .bajaji: .tierBajaji
        case .boda: .tierBoda
        }
    }

    var descriptionKey: LKey {
        switch self {
        case .economy: .tierEconomyDescription
        case .comfort: .tierComfortDescription
        case .premium: .tierPremiumDescription
        case .bajaji: .tierBajajiDescription
        case .boda: .tierBodaDescription
        }
    }

    /// Rendered 3D vehicle used everywhere the tier is shown.
    var icon3D: Icon3D {
        switch self {
        case .economy: .cityCar
        case .comfort: .sedan
        case .premium: .minivan
        case .bajaji: .bajaji
        case .boda: .boda
        }
    }

    /// Legacy side-view illustration.
    var imageName: String {
        switch self {
        case .economy: "hatchback_taxi_car"
        case .comfort, .premium: "sedan_car_side"
        case .bajaji: "bajaji_rickshaw_side"
        case .boda: "boda_boda_taxi"
        }
    }

    /// Archived imported models for debug probes only; Premium is procedural and has no bundle asset.
    var modelResourceName: String {
        switch self {
        case .economy: "vehicle_economy"
        case .comfort: "vehicle_comfort"
        case .premium: "vehicle_premium"
        case .bajaji: "vehicle_bajaji"
        case .boda: "vehicle_boda"
        }
    }

    /// Orientation metadata reported for each bundled model.
    var modelFrontAxis: ModelFrontAxis { .negativeX }

    /// Bundled glTF binary used by the Mapbox model layer (same asset as the USDZ).
    var mapModelURL: URL? {
        Bundle.main.url(forResource: modelResourceName, withExtension: "glb")
    }

    /// Real-world length of the bundled model in metres (model units are metres).
    var modelLengthMetres: Double {
        switch self {
        case .economy: 3.41
        case .comfort: 4.06
        case .premium: 4.8
        case .bajaji: 2.78
        case .boda: 1.90
        }
    }

    /// On-screen length every vehicle is drawn at, in points, before `markerScale`.
    static let mapModelLengthPoints: Double = 50

    /// Mapbox `model-scale` for a `viewport` scale-mode layer (screen pixels per model unit): every tier
    /// reads ~50pt long at any zoom, irrespective of its real-world dimensions.
    var viewportModelScale: Double {
        Self.mapModelLengthPoints * Double(markerScale) / modelLengthMetres
    }

    /// Equal prominence for every tier, including legacy sprite presentations.
    var markerScale: CGFloat { 2.8 }

    /// Flat top-down illustration; fallback while the 3D sprite is still rendering.
    var topDownImageName: String {
        switch self {
        case .economy: "hatchback_car_top_view"
        case .comfort, .premium: "car_sedan_top_view"
        case .bajaji: "rickshaw_tuk_tuk_topdown"
        case .boda: "motorcycle_taxi_top_view"
        }
    }

    var symbol: String {
        switch self {
        case .economy, .comfort: "car.fill"
        case .premium: "car.side.fill"
        case .bajaji: "car.side.fill"
        case .boda: "bicycle"
        }
    }

    var seats: Int {
        switch self {
        case .economy: 4
        case .comfort: 4
        case .premium: 6
        case .bajaji: 3
        case .boda: 1
        }
    }

    /// Demo tariff bands in TZS; Premium uses its own minivan rate, not an official quoted tariff.
    var tariff: Tariff {
        switch self {
        case .economy: Tariff(base: 3_000, perKm: 1_000, perMinute: 117, minimum: 3_500)
        case .comfort: Tariff(base: 4_000, perKm: 1_250, perMinute: 166, minimum: 5_000)
        case .premium: Tariff(base: 5_500, perKm: 1_600, perMinute: 200, minimum: 7_000)
        case .bajaji: Tariff(base: 2_000, perKm: 625, perMinute: 71, minimum: 2_500)
        case .boda: Tariff(base: 1_500, perKm: 375, perMinute: 25, minimum: 2_000)
        }
    }

    /// Cancellation fee once the driver is committed, TZS.
    var lateCancellationFee: Int {
        switch self {
        case .economy, .comfort, .premium: 1_000
        case .bajaji, .boda: 500
        }
    }
}

nonisolated struct Tariff: Hashable, Sendable {
    var base: Int
    var perKm: Int
    var perMinute: Int
    var minimum: Int
}
