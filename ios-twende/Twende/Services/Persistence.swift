import Foundation

/// JSON persistence over UserDefaults. Small payloads only (profile, history, active trip snapshot).
nonisolated enum Persistence {
    enum Key {
        static let passenger = "twende.passenger.v1"
        static let activeTrip = "twende.activeTrip.v1"
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            print("[Persistence] Failed to decode \(key): \(error.localizedDescription)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        do {
            let data = try encoder.encode(value)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("[Persistence] Failed to encode \(key): \(error.localizedDescription)")
        }
    }

    static func remove(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
