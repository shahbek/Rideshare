import SwiftUI

/// Transient confirmation shown at the top of the map root.
nonisolated struct ToastMessage: Equatable, Identifiable, Sendable {
    enum Tint: Sendable {
        case success
        case warning
        case neutral
    }

    var id: UUID = UUID()
    var text: String
    var symbol: String
    var tint: Tint
}

/// Dark snackbar with a tinted leading icon.
struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tintColor)
            Text(message.text)
                .font(TwendeFont.captionMedium)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(TwendeColor.ink, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 16)
    }

    private var tintColor: Color {
        switch message.tint {
        case .success: TwendeColor.primary
        case .warning: Color(hex: 0xFFB35C)
        case .neutral: Color.white.opacity(0.75)
        }
    }
}

/// Presents `ToastView` for a few seconds whenever the bound message changes.
struct ToastPresenter: ViewModifier {
    @Binding var message: ToastMessage?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                ToastView(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message.id) {
                        try? await Task.sleep(for: .seconds(3.2))
                        if self.message?.id == message.id {
                            withAnimation(.easeInOut(duration: 0.25)) { self.message = nil }
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.4), value: message?.id)
    }
}

extension View {
    func toast(_ message: Binding<ToastMessage?>) -> some View {
        modifier(ToastPresenter(message: message))
    }
}
