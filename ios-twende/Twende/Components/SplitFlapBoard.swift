import SwiftUI

/// Satin split-flap code: inset-lit green halves, printed white digits and a sequential hinge reveal.
struct SplitFlapBoard: View {
    let text: String
    var tileSize: CGSize = CGSize(width: 58, height: 80)
    var spacing: CGFloat = 10

    private var characters: [Character] { Array(text) }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                SplitFlapTile(target: character, size: tileSize, startDelay: Double(index) * 0.14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L(.ridePINAccessibility, text.map(String.init).joined(separator: " "))))
    }
}

/// The task is keyed to the digit and motion preference so a changed code or disappearing panel
/// cancels the previous reveal. Inset and angle-dependent lighting never cast outside a tile.
struct SplitFlapTile: View {
    let target: Character
    let size: CGSize
    var startDelay: Double = 0
    /// Face shown before the first reveal; a space starts on a blank silver leaf.
    var initial: Character = "0"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Character? = nil
    @State private var incoming: Character? = nil
    @State private var flipAngle: CGFloat = 0

    private static let flapDuration: Double = 0.16

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                SplitFlapFace(character: incoming ?? current, size: size, top: true)
                SplitFlapFace(character: current, size: size, top: false)
            }
            if let incoming {
                SplitFlapLeaf(outgoing: current, incoming: incoming, size: size, angle: flipAngle)
                    .transition(.identity)
            }
            VStack(spacing: 0) {
                Rectangle().fill(TwendeColor.ink).frame(height: 1.25)
                Rectangle().fill(.white.opacity(0.38)).frame(height: 0.75)
            }
            .allowsHitTesting(false)
            HStack {
                hingeRecess
                Spacer()
                hingeRecess
            }
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .task(id: "\(target)-\(reduceMotion)") {
            await reveal()
        }
    }

    private var current: Character { shown ?? initial }

    private var hingeRecess: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(TwendeColor.ink.shadow(.inner(color: .black.opacity(0.7), radius: 1, y: 1)))
            .frame(width: 3, height: 7)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.32)).frame(height: 0.5) }
    }

    private func reveal() async {
        resetFlap()
        guard target != current else { return }
        guard !reduceMotion else {
            shown = target
            return
        }
        // Blank leaves drop straight onto the typed digit (and back) in one decisive flap.
        guard let digit = target.wholeNumberValue, let current = self.current.wholeNumberValue else {
            await flap(to: target)
            return
        }
        var steps = (digit - current + 10) % 10
        if steps == 0 { steps = 10 }
        do {
            try await Task.sleep(for: .seconds(startDelay))
            for step in 1...steps {
                try Task.checkCancellation()
                let character = Character(String((current + step) % 10))
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    incoming = character
                    flipAngle = 0
                }
                // Commit the front face before rotating; otherwise SwiftUI can coalesce both states.
                try await Task.sleep(for: .milliseconds(16))
                withAnimation(.timingCurve(0.45, 0, 0.8, 0.6, duration: Self.flapDuration)) {
                    flipAngle = 180
                }
                try await Task.sleep(for: .seconds(Self.flapDuration))
                Haptics.selection()
                if step == steps {
                    withAnimation(.easeOut(duration: 0.07)) { flipAngle = 183 }
                    try await Task.sleep(for: .milliseconds(70))
                    withAnimation(.easeInOut(duration: 0.12)) { flipAngle = 180 }
                    try await Task.sleep(for: .milliseconds(120))
                }
                withTransaction(transaction) {
                    shown = character
                    incoming = nil
                    flipAngle = 0
                }
                if step < steps { try await Task.sleep(for: .milliseconds(25)) }
            }
        } catch {
            // Cancellation is expected when leaving the trip panel or switching accessibility settings.
        }
    }

    private func flap(to character: Character) async {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        do {
            try await Task.sleep(for: .seconds(startDelay))
            withTransaction(transaction) {
                incoming = character
                flipAngle = 0
            }
            try await Task.sleep(for: .milliseconds(16))
            withAnimation(.timingCurve(0.45, 0, 0.8, 0.6, duration: 0.2)) { flipAngle = 180 }
            try await Task.sleep(for: .seconds(0.2))
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.07)) { flipAngle = 184 }
            try await Task.sleep(for: .milliseconds(70))
            withAnimation(.easeInOut(duration: 0.12)) { flipAngle = 180 }
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            // A newer keystroke supersedes this flap; it settles on the target below.
        }
        withTransaction(transaction) {
            shown = character
            incoming = nil
            flipAngle = 0
        }
    }

    private func resetFlap() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            incoming = nil
            flipAngle = 0
        }
    }
}
