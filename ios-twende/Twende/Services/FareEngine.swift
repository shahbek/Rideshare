import Foundation

/// Deterministic fare calculation within LATRA-style bands. Zero commission: the driver receives the full fare.
nonisolated enum FareEngine {
    static func quote(
        tier: RideTier,
        route: RouteResult,
        pickupEtaMinutes: Int,
        hasDriversNearby: Bool,
        promo: Promotion?
    ) -> FareQuote {
        let tariff = tier.tariff
        let distance = roundToFive(route.distanceKm * Double(tariff.perKm))
        let time = route.durationMinutes * tariff.perMinute
        var breakdown = FareBreakdown(base: tariff.base, distance: distance, time: time, discount: 0)
        if breakdown.subtotal < tariff.minimum {
            breakdown.base += tariff.minimum - breakdown.subtotal
        }
        if let promo {
            breakdown.discount = promo.discount(on: breakdown.subtotal)
        }
        return FareQuote(
            tier: tier,
            distanceKm: route.distanceKm,
            durationMinutes: route.durationMinutes,
            pickupEtaMinutes: pickupEtaMinutes,
            breakdown: breakdown,
            hasDriversNearby: hasDriversNearby
        )
    }

    private static func roundToFive(_ value: Double) -> Int {
        Int((value / 5).rounded()) * 5
    }
}

/// Promotions available in the demo. Codes are matched case-insensitively.
nonisolated enum PromoCatalog {
    static var all: [Promotion] {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let endOfMonth = calendar.date(byAdding: .day, value: 21, to: now) ?? now
        let laterThisYear = calendar.date(byAdding: .day, value: 75, to: now) ?? now
        return [
            Promotion(
                code: "KARIBU",
                title: .promoKaribuTitle,
                detail: .promoKaribuDetail,
                percentOff: 20,
                maxDiscount: 3_000,
                expires: endOfMonth
            ),
            Promotion(
                code: "ZURI10",
                title: .promoTwende10Title,
                detail: .promoTwende10Detail,
                percentOff: 10,
                maxDiscount: 2_000,
                expires: laterThisYear
            ),
        ]
    }

    static func promotion(code: String) -> Promotion? {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return all.first { $0.code == cleaned }
    }
}
