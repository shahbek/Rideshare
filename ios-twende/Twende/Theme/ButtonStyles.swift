import SwiftUI

/// Full-width 56pt brushed-gold action. Exactly one per screen. Disabled state is grey, not faded.
/// Built as a physical key: a darker gold base lip sits under a domed face that casts a soft shadow.
/// Pressing sinks the face onto its base, flattens the shadow and turns the lighting into an inner
/// occlusion, so it reads as recessed rather than dimmed. No moving light streaks.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    private static let lipDepth: CGFloat = 1.5

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(TwendeFont.bodySemibold)
            .foregroundStyle(labelStyle)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background { surface(pressed: pressed) }
            .clipShape(.rect(cornerRadius: 8))
            .overlay { if isEnabled && !pressed { GoldStreak().clipShape(.rect(cornerRadius: 8)).allowsHitTesting(false) } }
            .offset(y: pressed ? Self.lipDepth : 0)
            .background { base(pressed: pressed) }
            .animation(.spring(response: 0.16, dampingFraction: 0.82), value: pressed)
    }

    /// The darker side of the key, visible as a lip under the face; also carries the cast shadow.
    @ViewBuilder
    private func base(pressed: Bool) -> some View {
        if isEnabled {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [TwendeColor.goldDeep.darkened(0.22), TwendeColor.goldDeep.darkened(0.38)],
                                     startPoint: .top, endPoint: .bottom))
                .offset(y: Self.lipDepth)
                .opacity(pressed ? 0 : 1)
                .shadow(color: TwendeColor.goldDeep.darkened(0.55).opacity(pressed ? 0 : 0.22),
                        radius: 4, y: 2.5)
                .shadow(color: TwendeColor.ink.opacity(pressed ? 0.05 : 0.12), radius: pressed ? 0.3 : 1, y: pressed ? 0 : 1)
                .allowsHitTesting(false)
        }
    }

    private var labelStyle: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(TwendeColor.inkTertiary) }
        return AnyShapeStyle(Color.white.shadow(.drop(color: TwendeColor.goldDeep.opacity(0.55), radius: 0.6, y: 0.6)))
    }

    /// Gentle brushed metal, left to right: no hard highlight bands, just a soft broad lift through the middle.
    private func sheenStops(pressed: Bool) -> [Gradient.Stop] {
        let dim = pressed ? 0.07 : 0
        return [
            .init(color: TwendeColor.goldMid.darkened(dim + 0.04), location: 0),
            .init(color: TwendeColor.goldMid.darkened(dim), location: 0.22),
            .init(color: TwendeColor.goldLight.darkened(dim), location: 0.5),
            .init(color: TwendeColor.goldMid.darkened(dim), location: 0.78),
            .init(color: TwendeColor.goldMid.darkened(dim + 0.04), location: 1)
        ]
    }

    @ViewBuilder
    private func surface(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        if isEnabled {
            ZStack {
                shape.fill(LinearGradient(stops: sheenStops(pressed: pressed), startPoint: .leading, endPoint: .trailing))
                // Dome: light from above on the raised face; inverted (dark top) once sunk into its well.
                shape.fill(LinearGradient(
                    stops: pressed
                        ? [.init(color: TwendeColor.ink.opacity(0.28), location: 0), .init(color: TwendeColor.ink.opacity(0.08), location: 0.4),
                           .init(color: .clear, location: 0.75), .init(color: .white.opacity(0.08), location: 1)]
                        : [.init(color: .white.opacity(0.34), location: 0), .init(color: .white.opacity(0.06), location: 0.45),
                           .init(color: .clear, location: 0.6), .init(color: TwendeColor.ink.opacity(0.10), location: 1)],
                    startPoint: .top, endPoint: .bottom
                ))
                if pressed {
                    // Sunk into a well: deep occlusion from the top rim, softer from the sides,
                    // and a faint bounce-light line along the bottom lip.
                    shape.fill(
                        Color.clear
                            .shadow(.inner(color: TwendeColor.ink.opacity(0.55), radius: 6, y: 4))
                            .shadow(.inner(color: TwendeColor.goldDeep.darkened(0.45).opacity(0.7), radius: 3, x: 0, y: 1.5))
                            .shadow(.inner(color: TwendeColor.ink.opacity(0.25), radius: 5, x: 2.5))
                            .shadow(.inner(color: TwendeColor.ink.opacity(0.25), radius: 5, x: -2.5))
                            .shadow(.inner(color: .white.opacity(0.28), radius: 1, y: -1))
                    )
                } else {
                    shape.fill(
                        Color.clear
                            .shadow(.inner(color: .white.opacity(0.6), radius: 0.8, y: 1.2))
                            .shadow(.inner(color: TwendeColor.goldDeep.darkened(0.3).opacity(0.55), radius: 1.5, y: -1.5))
                    )
                }
                ObjectSurfaceGrain()
                shape.inset(by: 0.5).strokeBorder(
                    LinearGradient(colors: pressed
                                   ? [TwendeColor.ink.opacity(0.4), TwendeColor.ink.opacity(0.12), .white.opacity(0.2)]
                                   : [.white.opacity(0.55), .white.opacity(0.05), TwendeColor.goldDeep.darkened(0.3).opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .allowsHitTesting(false)
        } else {
            shape.fill(TwendeColor.surfaceAlt)
        }
    }
}

/// A soft, narrow diagonal glint that drifts across the gold every few seconds. Static when Reduce Motion is on.
private struct GoldStreak: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    private static let period: Double = 4.5
    private static let travel: Double = 1.2

    var body: some View {
        GeometryReader { geo in
            if reduceMotion {
                band(width: geo.size.width, height: geo.size.height, progress: 0.72)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
                    band(width: geo.size.width, height: geo.size.height, progress: min(t / Self.travel, 1.0))
                }
            }
        }
    }

    private func band(width: CGFloat, height: CGFloat, progress: Double) -> some View {
        let streakWidth: CGFloat = 46
        let x = -streakWidth + (width + streakWidth * 2) * progress
        return LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: streakWidth, height: height * 2)
            .rotationEffect(.degrees(18))
            .position(x: x, y: height / 2)
            .blendMode(.plusLighter)
    }
}

/// Full-width outlined secondary action (Airbnb's white button with an ink edge).
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TwendeFont.bodySemibold)
            .foregroundStyle(isEnabled ? TwendeColor.ink : TwendeColor.inkTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                configuration.isPressed ? TwendeColor.surfaceAlt : TwendeColor.surface,
                in: .rect(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isEnabled ? TwendeColor.ink : TwendeColor.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Underlined ink text button reserved for cancel / skip.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TwendeFont.bodySemibold)
            .underline()
            .foregroundStyle(configuration.isPressed ? TwendeColor.inkSecondary : TwendeColor.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
    }
}

/// Red action used only for the SOS flow.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TwendeFont.bodySemibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                TwendeColor.danger.opacity(configuration.isPressed ? 0.85 : 1),
                in: .rect(cornerRadius: 8)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small pressable scale feedback for cards and rows.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var twendePrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var twendeSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var twendeGhost: GhostButtonStyle { GhostButtonStyle() }
}

extension ButtonStyle where Self == DangerButtonStyle {
    static var twendeDanger: DangerButtonStyle { DangerButtonStyle() }
}

extension ButtonStyle where Self == PressableCardStyle {
    static var pressableCard: PressableCardStyle { PressableCardStyle() }
}
