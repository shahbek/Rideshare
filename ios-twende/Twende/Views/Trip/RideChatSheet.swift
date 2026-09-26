import SwiftUI

/// Round chat button with an unread dot, used in the live-trip panels.
struct ChatButton: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ContactButton(systemImage: "bubble.left.and.bubble.right.fill", title: L(.chatWithDriver), compact: true) {
            Haptics.tap()
            env.flow.activeSheet = .chat
        }
        .overlay(alignment: .topTrailing) {
            if env.chat.unreadCount > 0 {
                Text("\(min(env.chat.unreadCount, 9))")
                    .font(TwendeFont.figtree(10, weight: .bold).monospacedDigit())
                    .foregroundStyle(TwendeColor.ink)
                    .frame(width: 18, height: 18)
                    .background(TwendeColor.primary, in: .circle)
                    .offset(x: 3, y: -3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("trip.chat")
    }
}

/// Simple in-app chat with the driver. Incoming lines in the other language show the translation first
/// with the original underneath. Quick replies cover the common pickup moments.
struct RideChatSheet: View {
    @Environment(AppEnvironment.self) private var env
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    private var quickReplies: [String] {
        [L(.chatQuickComing), L(.chatQuickHere), L(.chatQuickFiveMin), L(.chatQuickWhere)]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(L(.chatWithDriver))
                    .font(TwendeFont.display)
                    .foregroundStyle(TwendeColor.ink)
                    .frame(maxWidth: .infinity, alignment: .center)
                Label(L(.chatAutoTranslate), systemImage: "character.bubble")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if env.chat.messages.isEmpty {
                            Text(L(.chatEmpty))
                                .font(TwendeFont.caption)
                                .foregroundStyle(TwendeColor.inkSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 32)
                                .padding(.horizontal, 32)
                        }
                        ForEach(env.chat.messages) { message in
                            ChatBubble(message: message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: env.chat.messages.count) { _, _ in
                    guard let last = env.chat.messages.last else { return }
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            VStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickReplies, id: \.self) { reply in
                            Button {
                                Haptics.tap()
                                env.chat.send(reply)
                            } label: {
                                Text(reply)
                                    .font(TwendeFont.captionMedium)
                                    .foregroundStyle(TwendeColor.ink)
                                    .padding(.horizontal, 14)
                                    .frame(height: 36)
                                    .overlay(Capsule().strokeBorder(TwendeColor.border, lineWidth: 1))
                            }
                            .buttonStyle(.pressableCard)
                        }
                    }
                }
                .contentMargins(.horizontal, 16)

                HStack(spacing: 8) {
                    TextField(L(.chatPlaceholder), text: $draft, axis: .vertical)
                        .font(TwendeFont.body)
                        .lineLimit(1...4)
                        .focused($isFocused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(TwendeColor.surfaceAlt, in: .rect(cornerRadius: 8))
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(TwendeColor.ink)
                            .frame(width: 48, height: 48)
                            .background(draftIsEmpty ? TwendeColor.surfaceAlt : TwendeColor.primary, in: .circle)
                    }
                    .buttonStyle(.pressableCard)
                    .disabled(draftIsEmpty)
                    .accessibilityLabel(L(.chatSend))
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(TwendeColor.surface)
        }
        .onAppear { env.chat.isOpen = true }
        .onDisappear { env.chat.isOpen = false }
    }

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !draftIsEmpty else { return }
        Haptics.tap()
        env.chat.send(draft)
        draft = ""
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    private var isMine: Bool { message.sender == .passenger }

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.translated ?? message.original)
                    .font(TwendeFont.body)
                    .foregroundStyle(TwendeColor.ink)
                if let _ = message.translated {
                    Text(message.original)
                        .font(TwendeFont.caption)
                        .foregroundStyle(TwendeColor.inkSecondary)
                    Label(L(.chatTranslated), systemImage: "character.bubble")
                        .font(TwendeFont.figtree(11, weight: .medium))
                        .foregroundStyle(TwendeColor.accentText)
                }
                Text(message.sentAt, format: .dateTime.hour().minute())
                    .font(TwendeFont.figtree(11, weight: .medium).monospacedDigit())
                    .foregroundStyle(TwendeColor.inkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isMine ? TwendeColor.primaryTint : TwendeColor.surfaceAlt, in: .rect(cornerRadius: 8))
            if !isMine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
    }
}
