import Foundation
import Observation

/// One chat line. `original` is what the sender typed in `language`; `translated` is filled in when it
/// differs from the reader's app language.
nonisolated struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    enum Sender: String, Codable, Sendable { case passenger, driver }

    var id: String
    var sender: Sender
    var original: String
    /// ISO code of the sender's language ("sw" / "en").
    var language: String
    var sentAt: Date
    var translated: String? = nil
}

/// Minimal rider ⇄ driver chat for the live trip. Messages are relayed through the Zuri server keyed by
/// trip id so the driver app can read and reply; the passenger's phone translates incoming lines
/// between Swahili and English with a small, cheap model. Works without WhatsApp or SMS credit.
@Observable
final class RideChatService {
    private(set) var messages: [ChatMessage] = []
    private(set) var tripID: String?
    private(set) var unreadCount: Int = 0
    private(set) var isSending: Bool = false
    var isOpen: Bool = false {
        didSet { if isOpen { unreadCount = 0 } }
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var demoDriverName: String = ""
    @ObservationIgnored private var didAutoReply: Set<String> = []

    /// Starts relaying for a live trip. Safe to call repeatedly with the same id.
    func attach(tripID: String, driverName: String) {
        guard self.tripID != tripID else { return }
        detach()
        self.tripID = tripID
        demoDriverName = driverName
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(self?.isOpen == true ? 3 : 10))
            }
        }
    }

    func detach() {
        pollTask?.cancel()
        pollTask = nil
        tripID = nil
        messages = []
        unreadCount = 0
        didAutoReply = []
    }

    /// Sends a line in the passenger's current language.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tripID, !trimmed.isEmpty else { return }
        let message = ChatMessage(
            id: UUID().uuidString,
            sender: .passenger,
            original: String(trimmed.prefix(300)),
            language: AppSettings.shared.language.rawValue,
            sentAt: Date()
        )
        messages.append(message)
        isSending = true
        Task { [weak self] in
            await RideChatAPI.post(message, tripID: tripID)
            guard let self else { return }
            self.isSending = false
            self.simulateDriverReply(to: message)
        }
    }

    private func refresh() async {
        guard let tripID, let remote = await RideChatAPI.fetch(tripID: tripID) else { return }
        guard self.tripID == tripID else { return }
        let known = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var merged = remote.map { incoming -> ChatMessage in
            var message = incoming
            message.translated = known[incoming.id]?.translated
            return message
        }
        // Keep lines still in flight so they don't blink out before the server has them.
        let remoteIDs = Set(remote.map(\.id))
        merged += messages.filter { !remoteIDs.contains($0.id) }
        merged.sort { $0.sentAt < $1.sentAt }
        let newDriverLines = merged.filter { $0.sender == .driver && known[$0.id] == nil }.count
        if merged != messages { messages = merged }
        if newDriverLines > 0 {
            if !isOpen { unreadCount += newDriverLines }
            Haptics.selection()
        }
        await translatePending()
    }

    /// Translates driver lines written in the other language. Cached per message.
    private func translatePending() async {
        let reader = AppSettings.shared.language.rawValue
        for message in messages where message.language != reader && message.translated == nil {
            guard let text = await ChatTranslator.translate(message.original, from: message.language, to: reader) else { continue }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].translated = text
            }
        }
    }

    /// Until the driver app is live, the simulated driver answers the first message in Swahili so the
    /// translation path is exercised end to end.
    private func simulateDriverReply(to message: ChatMessage) {
        guard let tripID, !didAutoReply.contains(tripID) else { return }
        didAutoReply.insert(tripID)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.tripID == tripID else { return }
            let reply = ChatMessage(
                id: UUID().uuidString,
                sender: .driver,
                original: "Sawa, nimepokea. Nakusubiri hapa.",
                language: "sw",
                sentAt: Date()
            )
            await RideChatAPI.post(reply, tripID: tripID)
            await self.refresh()
        }
    }
}

/// Thin HTTP client for `/chat/<tripId>` on the Zuri server.
nonisolated enum RideChatAPI {
    private struct Envelope: Codable { let messages: [ChatMessage] }

    private static func url(_ tripID: String) -> URL {
        PaymentGateway.baseURL.appendingPathComponent("chat").appendingPathComponent(tripID)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func fetch(tripID: String) async -> [ChatMessage]? {
        var request = URLRequest(url: url(tripID))
        request.setValue(PaymentGateway.deviceID, forHTTPHeaderField: "X-Zuri-Device")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? decoder.decode(Envelope.self, from: data).messages
    }

    static func post(_ message: ChatMessage, tripID: String) async {
        var request = URLRequest(url: url(tripID))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(PaymentGateway.deviceID, forHTTPHeaderField: "X-Zuri-Device")
        request.timeoutInterval = 10
        request.httpBody = try? encoder.encode(message)
        _ = try? await URLSession.shared.data(for: request)
    }
}

/// Swahili ⇄ English translation for short chat lines through Rork Toolkit (Gemini Flash Lite).
nonisolated enum ChatTranslator {
    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private static func name(_ code: String) -> String {
        code == "sw" ? "Swahili" : "English"
    }

    static func translate(_ text: String, from source: String, to target: String) async -> String? {
        let base = Config.EXPO_PUBLIC_TOOLKIT_URL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY
        guard !base.isEmpty, !key.isEmpty, let url = URL(string: "\(base)/v2/vercel/v1/chat/completions") else { return nil }
        let body: [String: Any] = [
            "model": "google/gemini-3.1-flash-lite",
            "temperature": 0,
            "max_tokens": 200,
            "providerOptions": ["gateway": ["models": ["openai/gpt-5.4-nano"]]],
            "messages": [
                ["role": "system", "content": "You translate short ride-hailing chat messages between a passenger and a driver in Dar es Salaam from \(name(source)) to \(name(target)). Keep it casual and short. Keep place names, numbers and plates unchanged. Reply with the translation only."],
                ["role": "user", "content": text],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                print("[Chat] translation unavailable (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
                return nil
            }
            let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content
            let cleaned = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }
}
