import SwiftUI
import UIKit

/// Renders an A5 PDF receipt for a trip and returns its temporary file URL.
enum ReceiptRenderer {
    static func render(trip: Trip, driver: Driver?, language: AppLanguage) -> URL? {
        let renderer = ImageRenderer(content: ReceiptDocument(trip: trip, driver: driver, language: language))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Zuri-\(trip.id).pdf")
        var didWrite = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            didWrite = true
        }
        return didWrite ? url : nil
    }
}

/// Print layout of the receipt. Pure, no environment access so it renders off-screen.
struct ReceiptDocument: View {
    let trip: Trip
    let driver: Driver?
    let language: AppLanguage

    private func text(_ key: LKey) -> String {
        Strings.text(for: key, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Zuri")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(TwendeColor.primary)
                Spacer()
                Text(trip.id)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            .padding(.bottom, 24)

            Text(text(.receipt))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TwendeColor.inkSecondary)
            Text(Format.tzs(trip.totalDue))
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .padding(.top, 2)
            Text(Format.dateTime(trip.createdAt))
                .font(.system(size: 12))
                .foregroundStyle(TwendeColor.inkSecondary)
                .padding(.top, 4)

            hairline.padding(.vertical, 16)

            stop(title: text(.pickupLabel), place: trip.pickup, time: trip.startedAt, isPickup: true)
                .padding(.bottom, 10)
            stop(title: text(.dropoffLabel), place: trip.destination, time: trip.completedAt, isPickup: false)
            Text("\(Format.distance(trip.quote.distanceKm)) · \(String(format: text(.minutesShort), trip.quote.durationMinutes))")
                .font(.system(size: 11))
                .foregroundStyle(TwendeColor.inkSecondary)
                .padding(.top, 8)
                .padding(.leading, 18)

            if let driver {
                hairline.padding(.vertical, 16)
                HStack(spacing: 8) {
                    Text(driver.firstName)
                        .font(.system(size: 12, weight: .medium))
                    Text("·").foregroundStyle(TwendeColor.inkTertiary)
                    Text(driver.vehicle.description)
                        .font(.system(size: 12))
                        .foregroundStyle(TwendeColor.inkSecondary)
                    Spacer()
                    Text(Format.plate(driver.vehicle.plate))
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .kerning(0.4)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(TwendeColor.border, lineWidth: 0.8))
                }
            }

            hairline.padding(.vertical, 16)

            VStack(spacing: 8) {
                line(text(.baseFare), Format.tzs(trip.quote.breakdown.base))
                line(String(format: text(.distanceFare), Format.distance(trip.quote.distanceKm)), Format.tzs(trip.quote.breakdown.distance))
                line(String(format: text(.timeFare), trip.quote.durationMinutes), Format.tzs(trip.quote.breakdown.time))
                if trip.quote.breakdown.discount > 0 {
                    line(text(.promoDiscount), Format.signedTZS(-trip.quote.breakdown.discount), tint: TwendeColor.badgeForeground)
                }
                if trip.tip > 0 {
                    line(text(.tip), Format.tzs(trip.tip))
                }
            }
            hairline.padding(.vertical, 12)
            HStack {
                Text(text(.total)).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(Format.tzs(trip.totalDue))
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TwendeColor.primary)
                Text(String(format: text(.badgeDriverReceived), Format.tzs(trip.totalDue)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TwendeColor.badgeForeground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(TwendeColor.primaryTint, in: .rect(cornerRadius: 8))
            .padding(.top, 12)
            Text("\(text(.payment)): \(trip.paymentMethod.displayName)")
                .font(.system(size: 12))
                .foregroundStyle(TwendeColor.inkSecondary)
                .padding(.top, 10)

            Spacer(minLength: 12)
            Text(text(.latraNotice))
                .font(.system(size: 9))
                .foregroundStyle(TwendeColor.inkSecondary)
            Text("Zuri Mobility Ltd · TIN 123-456-789 · Dar es Salaam")
                .font(.system(size: 9))
                .foregroundStyle(TwendeColor.inkTertiary)
                .padding(.top, 2)
        }
        .padding(32)
        .frame(width: 420, height: 595, alignment: .top)
        .background(Color.white)
        .foregroundStyle(TwendeColor.ink)
    }

    private var hairline: some View {
        Rectangle()
            .fill(TwendeColor.border)
            .frame(height: 1)
    }

    private func stop(title: String, place: Place, time: Date?, isPickup: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if isPickup {
                    Circle().fill(TwendeColor.primary)
                } else {
                    RoundedRectangle(cornerRadius: 1.5).fill(TwendeColor.ink)
                }
            }
            .frame(width: 8, height: 8)
            .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TwendeColor.inkSecondary)
                    Spacer()
                    if let time {
                        Text(Format.time(time))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(TwendeColor.inkSecondary)
                    }
                }
                Text(place.name)
                    .font(.system(size: 12, weight: .medium))
                Text(place.address)
                    .font(.system(size: 11))
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
        }
    }

    private func line(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(TwendeColor.inkSecondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint ?? TwendeColor.ink)
        }
        .font(.system(size: 12))
    }
}
