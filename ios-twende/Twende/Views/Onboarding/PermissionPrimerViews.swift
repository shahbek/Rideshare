import CoreLocation
import SwiftUI
import UserNotifications

/// A6 — explains why location is needed before the system prompt.
struct LocationPrimerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var didRequest: Bool = false

    var body: some View {
        OnboardingScaffold(
            step: 5,
            title: L(.locationTitle),
            subtitle: L(.locationSubtitle)
        ) {
            PrimerMapIllustration()
            VStack(spacing: 0) {
                PrimerBullet(icon: .signpost, text: L(.locationBullet1))
                RowDivider(leading: 56)
                PrimerBullet(icon: .clock, text: L(.locationBullet2))
                RowDivider(leading: 56)
                PrimerBullet(icon: .lock, text: L(.locationBullet3))
            }
            if env.location.isDenied && didRequest {
                Text(L(.locationDeniedHint))
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.amberText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button(L(.allowLocation)) {
                Haptics.medium()
                didRequest = true
                if env.location.authorization == .notDetermined {
                    env.location.requestPermission()
                } else {
                    advance()
                }
            }
            .buttonStyle(.twendePrimary)

            Button(L(.notNow)) { advance() }
                .buttonStyle(.twendeGhost)
        }
        .onChange(of: env.location.authorization) { _, newValue in
            guard didRequest, newValue != .notDetermined else { return }
            advance()
        }
    }

    private func advance() {
        env.settings.onboardingStage = .notifications
    }
}

/// A7 — trip notifications primer.
struct NotificationPrimerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isRequesting: Bool = false

    var body: some View {
        OnboardingScaffold(
            step: 6,
            title: L(.notificationsTitle),
            subtitle: L(.notificationsSubtitle)
        ) {
            PrimerNotificationIllustration()
            VStack(spacing: 0) {
                PrimerBullet(icon: .cityCar, text: L(.notificationsBullet1))
                RowDivider(leading: 56)
                PrimerBullet(icon: .star, text: L(.notificationsBullet2))
                RowDivider(leading: 56)
                PrimerBullet(icon: .receipt, text: L(.notificationsBullet3))
            }
        } footer: {
            Button {
                requestNotifications()
            } label: {
                if isRequesting {
                    ProgressView().tint(.white)
                } else {
                    Text(L(.allowNotifications))
                }
            }
            .buttonStyle(.twendePrimary)
            .disabled(isRequesting)

            Button(L(.skip)) {
                env.settings.tripNotificationsEnabled = false
                finish()
            }
            .buttonStyle(.twendeGhost)
        }
    }

    private func requestNotifications() {
        Haptics.medium()
        isRequesting = true
        Task {
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            env.settings.tripNotificationsEnabled = granted ?? false
            isRequesting = false
            finish()
        }
    }

    private func finish() {
        env.settings.onboardingStage = .done
        env.startServices()
    }
}

/// Product illustration: a slice of the muted map with a route, the pickup dot and a car — what the
/// permission actually unlocks, rather than an icon in a circle.
private struct PrimerMapIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(TwendeColor.mapCanvas)
            MapStreets()
                .stroke(TwendeColor.inkSecondary, lineWidth: 6)
            RoutePath()
                .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            RoutePath()
                .stroke(TwendeColor.route, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            PickupMarker()
                .offset(x: -96, y: 44 - MapPin.totalHeight / 2)
            DestinationMarker(label: L(.minutesShort, 12))
                .offset(x: 104, y: -74 - MapPin.totalHeight / 2)
            TopDownVehicle(tier: .economy, height: 44, heading: 38)
                .offset(x: -20, y: -6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .clipShape(.rect(cornerRadius: 16))
        .accessibilityHidden(true)
    }
}

/// Product illustration: a stacked pair of trip notifications as iOS renders them.
private struct PrimerNotificationIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(TwendeColor.surfaceAlt)
            VStack(spacing: 10) {
                notification(title: L(.driverArrivedTitle, "Juma"), body: L(.meetAtPickup), time: "09:41")
                notification(title: L(.paymentConfirmed), body: "TZS 8,500 · M-Pesa", time: "10:12")
                    .opacity(0.7)
                    .scaleEffect(0.96)
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .accessibilityHidden(true)
    }

    private func notification(title: String, body: String, time: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Z")
                .font(TwendeFont.figtree(15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(TwendeColor.primary, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Zuri")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TwendeColor.ink)
                    Spacer()
                    Text(time)
                        .font(.system(size: 11))
                        .foregroundStyle(TwendeColor.inkTertiary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TwendeColor.ink)
                    .lineLimit(1)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(TwendeColor.inkSecondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(TwendeColor.surface, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

private struct MapStreets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.3))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.22))
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.64))
        path.move(to: CGPoint(x: rect.width * 0.28, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.maxY))
        path.move(to: CGPoint(x: rect.width * 0.68, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.width * 0.74, y: rect.maxY))
        return path
    }
}

private struct RoutePath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - 96, y: rect.midY + 44))
        path.addLine(to: CGPoint(x: rect.midX - 60, y: rect.midY + 40))
        path.addLine(to: CGPoint(x: rect.midX - 48, y: rect.midY - 14))
        path.addLine(to: CGPoint(x: rect.midX + 40, y: rect.midY - 22))
        path.addLine(to: CGPoint(x: rect.midX + 50, y: rect.midY - 58))
        path.addLine(to: CGPoint(x: rect.midX + 104, y: rect.midY - 62))
        return path
    }
}

private struct PrimerBullet: View {
    let icon: Icon3D
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Icon3DView(icon: icon, size: 40)
            Text(text)
                .font(TwendeFont.body)
                .foregroundStyle(TwendeColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 60)
    }
}
