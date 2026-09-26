import SwiftUI

/// Neutral driver mark by default; pickup UI can opt into the assigned driver's own portrait.
/// Missing photos retain the neutral figure rather than displaying another person's face.
struct DriverAvatar: View {
    let driver: Driver
    var size: CGFloat = 56
    var showsStatus: Bool = true
    var ringColor: Color? = nil
    var showsPortrait: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(TwendeColor.surfaceAlt)
                .frame(width: size, height: size)
                .overlay {
                    if showsPortrait, let name = driver.portraitName, let portrait = UIImage(named: name) {
                        Image(uiImage: portrait)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    } else {
                        Image(Icon3D.driver.heroAsset ?? Icon3D.driver.rawValue)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size * 0.78, height: size * 0.78)
                            .offset(y: size * 0.06)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(.circle)
                .overlay {
                    if let ringColor {
                        Circle().stroke(ringColor, lineWidth: 2)
                    }
                }
                .saturation(driver.status == .offline ? 0.2 : 1)
                .opacity(driver.status == .offline ? 0.7 : 1)

            if showsStatus {
                Circle()
                    .fill(statusColor)
                    .frame(width: max(size * 0.24, 12), height: max(size * 0.24, 12))
                    .overlay(Circle().stroke(TwendeColor.surface, lineWidth: 2.5))
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: size + 2, height: size + 2)
        .accessibilityLabel(Text("\(driver.firstName), \(statusLabel)"))
    }

    private var statusColor: Color {
        switch driver.status {
        case .online: TwendeColor.statusOnline
        case .busy: TwendeColor.statusBusy
        case .offline: TwendeColor.statusOffline
        }
    }

    private var statusLabel: String {
        switch driver.status {
        case .online: L(.statusOnline)
        case .busy: L(.statusBusy)
        case .offline: L(.statusOffline)
        }
    }
}

/// Icon + label status chip. Never colour alone.
struct DriverStatusChip: View {
    let status: DriverStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(label)
                .font(TwendeFont.label)
        }
        .foregroundStyle(TwendeColor.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(TwendeColor.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(TwendeColor.border, lineWidth: 1))
    }

    private var dot: Color {
        switch status {
        case .online: TwendeColor.statusOnline
        case .busy: TwendeColor.statusBusy
        case .offline: TwendeColor.statusOffline
        }
    }

    private var label: String {
        switch status {
        case .online: L(.statusOnline)
        case .busy: L(.statusBusy)
        case .offline: L(.statusOffline)
        }
    }
}
