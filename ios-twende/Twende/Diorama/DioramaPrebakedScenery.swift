import CryptoKit
import Foundation

/// Pre-baked Masaki scenery on the project's backend. Preparation downloads it (never viewing), and
/// every file is checked against its SHA-256 before a directory is installed atomically. One
/// publisher device uploads its prepared + optimized packages with a publish key held in Keychain.
nonisolated enum DioramaPrebakedScenery {
    nonisolated struct File: Codable, Sendable {
        let d: String
        let f: String
        let b: Int
        let s: String
    }
    nonisolated struct Catalog: Codable, Sendable {
        let revision: Int
        let publishedAt: Double
        let files: [File]
    }
    nonisolated enum Failure: LocalizedError {
        case unavailable, checksum, rejected(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Pre-baked scenery is not published yet."
            case .checksum: "A downloaded scenery file failed verification and was discarded."
            case .rejected(let reason): "Server rejected the upload: \(reason)"
            }
        }
    }

    static let keychainKey = "zuri.scenery.publishKey"
    static var publishKey: String? {
        get { KeychainHelper.get(keychainKey) }
        set { if let newValue, !newValue.isEmpty { KeychainHelper.set(keychainKey, value: newValue) } else { KeychainHelper.delete(keychainKey) } }
    }

    private static var base: URL { PaymentGateway.baseURL }
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60; c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func catalog() async throws -> Catalog {
        let (data, response) = try await session.data(from: base.appendingPathComponent("scenery/catalog"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unavailable }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.revision > 0, !catalog.files.isEmpty else { throw Failure.unavailable }
        return catalog
    }

    /// Downloads and installs every catalogue directory not already present. Returns installed count.
    static func download(_ catalog: Catalog, progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> Int {
        let store = DioramaOfflineStore.shared
        let grouped = Dictionary(grouping: catalog.files, by: \.d)
        let total = catalog.files.reduce(Int64(0)) { $0 + Int64($1.b) }
        var done: Int64 = 0, installed = 0
        let stagingRoot = await store.stagingRoot
        try? FileManager.default.removeItem(at: stagingRoot)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        for name in grouped.keys.sorted() {
            try Task.checkCancellation()
            let files = grouped[name] ?? []
            if await store.hasDirectory(name) {
                done += files.reduce(0) { $0 + Int64($1.b) }; await progress(done, total); continue
            }
            let staged = stagingRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            for file in files {
                try Task.checkCancellation()
                var components = URLComponents(url: base.appendingPathComponent("scenery/file"), resolvingAgainstBaseURL: false)
                components?.queryItems = [.init(name: "d", value: file.d), .init(name: "f", value: file.f), .init(name: "s", value: file.s)]
                guard let url = components?.url else { throw Failure.unavailable }
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == file.b,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.s else { throw Failure.checksum }
                guard file.f == URL(fileURLWithPath: file.f).lastPathComponent else { throw Failure.checksum }
                try data.write(to: staged.appendingPathComponent(file.f), options: .atomic)
                done += Int64(file.b); await progress(done, total)
            }
            try await store.install(directory: name, staged: staged)
            installed += 1
        }
        return installed
    }

    /// Uploads every local package, r3 sidecar and LOD sidecar, then publishes the catalogue atomically.
    static func publish(progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Int {
        guard let key = publishKey else { throw Failure.rejected("publish key missing") }
        func request(_ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
            var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw Failure.unavailable }
            var r = URLRequest(url: url); r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 120
            r.setValue(key, forHTTPHeaderField: "X-Zuri-Scenery-Key")
            if method == "POST" { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: r)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure.rejected(String(data: data, encoding: .utf8)?.prefix(160).description ?? "HTTP error")
            }
            return data
        }
        let files = await DioramaOfflineStore.shared.publishableFiles()
        guard !files.isEmpty else { throw Failure.rejected("no prepared scenery on this device") }
        struct Begin: Decodable { let generation: Int }
        let generation = try JSONDecoder().decode(Begin.self, from: try await request("scenery/begin", method: "POST")).generation
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            _ = try await request("scenery/file", method: "PUT", query: [.init(name: "d", value: file.directory), .init(name: "f", value: file.file),
                .init(name: "s", value: sha), .init(name: "g", value: String(generation))], body: data)
            await progress(i + 1, files.count)
        }
        let body = try JSONSerialization.data(withJSONObject: ["g": generation, "count": files.count])
        _ = try await request("scenery/publish", method: "POST", body: body)
        return files.count
    }
}
