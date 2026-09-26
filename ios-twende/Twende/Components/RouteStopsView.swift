import SwiftUI

/// Pickup above destination joined by a connector, with any intermediate stops as numbered circles in
/// between — the standard route summary block.
struct RouteStopsView: View {
    let pickup: String
    let destination: String
    /// Intermediate stop names in visiting order.
    var stops: [String] = []
    var pickupDetail: String? = nil
    var destinationDetail: String? = nil
    var pickupAccessory: String? = nil
    var destinationAccessory: String? = nil
    var onPickupTap: (() -> Void)? = nil
    /// Shows a remove control on each stop.
    var onRemoveStop: ((Int) -> Void)? = nil

    private var rowHeight: CGFloat {
        pickupDetail == nil && destinationDetail == nil ? 40 : 54
    }

    private var rowCount: Int { stops.count + 2 }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            connector
            VStack(spacing: 0) {
                row(title: pickup, detail: pickupDetail, accessory: pickupAccessory, action: onPickupTap)
                ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                    RowDivider(leading: 0)
                    stopRow(title: stop, index: index)
                }
                RowDivider(leading: 0)
                row(title: destination, detail: destinationDetail, accessory: destinationAccessory, action: nil)
            }
        }
    }

    private var connector: some View {
        let totalHeight = rowHeight * CGFloat(rowCount)
        return ZStack {
            Rectangle()
                .fill(TwendeColor.border)
                .frame(width: 2, height: totalHeight - rowHeight - 18)
            VStack(spacing: 0) {
                RouteMarker(kind: .start, size: 13)
                    .frame(height: rowHeight)
                ForEach(Array(stops.indices), id: \.self) { index in
                    RouteMarker(kind: .stop(index + 1), size: 14)
                        .frame(height: rowHeight)
                }
                RouteMarker(kind: .end, size: 13)
                    .frame(height: rowHeight)
            }
        }
        .frame(width: 14, height: totalHeight)
        .accessibilityHidden(true)
    }

    private func stopRow(title: String, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TwendeFont.bodyMedium)
                .foregroundStyle(TwendeColor.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let onRemoveStop {
                Button {
                    Haptics.tap()
                    onRemoveStop(index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.pressableCard)
                .accessibilityLabel(L(.removeStop))
            }
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(L(.stopLabel, index + 1)), \(title)"))
    }

    @ViewBuilder
    private func row(title: String, detail: String?, accessory: String?, action: (() -> Void)?) -> some View {
        let content = HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TwendeFont.bodyMedium)
                    .foregroundStyle(TwendeColor.ink)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let accessory {
                // Tappable accessories read as links; static ones (times) stay quiet grey.
                Text(accessory)
                    .font(TwendeFont.captionMedium)
                    .monospacedDigit()
                    .foregroundStyle(action == nil ? TwendeColor.inkSecondary : TwendeColor.badgeForeground)
            }
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())

        if let action {
            Button {
                Haptics.tap()
                action()
            } label: {
                content
            }
            .buttonStyle(.pressableCard)
        } else {
            content
        }
    }
}
