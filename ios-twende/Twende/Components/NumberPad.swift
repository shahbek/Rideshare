import SwiftUI

/// A self-contained numeric keypad for digit entry that never depends on the system keyboard.
/// Used by phone entry and OTP so the flow works even when no hardware or software keyboard appears.
struct NumberPad: View {
    @Binding var digits: String
    let limit: Int
    /// Flat keys: no fill at rest, a grey press state only. Used for amounts.
    var isFlat: Bool = false
    /// Amounts never start with zero.
    var allowsLeadingZero: Bool = true
    /// Flat keys shrink (down to 44pt) to fit the space they're given instead of a fixed height.
    var isCompressible: Bool = false
    /// Called once the entry reaches `limit`, so callers can auto-submit.
    var onComplete: (() -> Void)? = nil

    private let keys: [[NumberPadKey]] = [
        [.digit("1"), .digit("2"), .digit("3")],
        [.digit("4"), .digit("5"), .digit("6")],
        [.digit("7"), .digit("8"), .digit("9")],
        [.blank, .digit("0"), .backspace],
    ]

    var body: some View {
        VStack(spacing: isCompressible ? 4 : 10) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { key in
                        NumberPadButton(key: key, isFlat: isFlat, isCompressible: isCompressible) { press(key) }
                    }
                }
            }
        }
    }

    private func press(_ key: NumberPadKey) {
        switch key {
        case .blank:
            return
        case .backspace:
            guard !digits.isEmpty else { return }
            Haptics.tap()
            digits.removeLast()
        case let .digit(value):
            guard digits.count < limit else { return }
            if !allowsLeadingZero, digits.isEmpty, value == "0" { return }
            Haptics.tap()
            digits.append(value)
            if digits.count == limit { onComplete?() }
        }
    }
}

enum NumberPadKey: Identifiable, Hashable {
    case digit(String)
    case backspace
    case blank

    var id: String {
        switch self {
        case let .digit(value): value
        case .backspace: "delete"
        case .blank: "blank"
        }
    }
}

private struct NumberPadButton: View {
    let key: NumberPadKey
    var isFlat: Bool = false
    var isCompressible: Bool = false
    let action: () -> Void

    var body: some View {
        if isFlat {
            Button(action: action) { label }
                .buttonStyle(FlatKeyStyle())
                .disabled(key == .blank)
                .accessibilityIdentifier("keypad.\(key.id)")
                .accessibilityHidden(key == .blank)
        } else {
            standard
        }
    }

    private var label: some View {
        Group {
            switch key {
            case let .digit(value):
                Text(value)
                    .font(TwendeFont.figtree(28, weight: .medium).monospacedDigit())
                    .foregroundStyle(TwendeColor.ink)
            case .backspace:
                Image(systemName: "delete.left")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(TwendeColor.ink)
            case .blank:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: isCompressible ? 44 : 58, maxHeight: 58)
        .contentShape(Rectangle())
    }

    private var standard: some View {
        Button(action: action) {
            Group {
                switch key {
                case let .digit(value):
                    Text(value)
                        .font(.system(size: 26, weight: .medium).monospacedDigit())
                        .foregroundStyle(TwendeColor.ink)
                case .backspace:
                    Image(systemName: "delete.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(TwendeColor.ink)
                case .blank:
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(background, in: .rect(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .disabled(key == .blank)
        .accessibilityIdentifier("keypad.\(key.id)")
        .accessibilityHidden(key == .blank)
    }

    private var background: Color {
        key == .blank ? .clear : TwendeColor.surfaceAlt
    }
}

/// No resting fill; the key briefly greys while pressed, like a calculator keypad.
private struct FlatKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? TwendeColor.surfacePressed : .clear, in: .rect(cornerRadius: 8))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
