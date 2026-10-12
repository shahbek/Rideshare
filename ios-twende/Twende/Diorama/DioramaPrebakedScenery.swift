import CryptoKit
import Foundation

/// Pre-baked scenery on the project's backend, one catalogue per region. Masaki preparation downloads
/// it in bulk; harbour tiles stream one at a time while viewing (`DioramaSceneryStreamer`). Every file
/// is checked against its SHA-256 before a directory is installed atomically. One publisher device
/// uploads its prepared + optimized packages with a publish key held in Keychain.
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

    private static func url(_ path: String, region: DioramaRegion, query: [URLQueryItem] = []) -> URL? {
        url(path, catalog: region.rawValue, query: query)
    }
    private static func url(_ path: String, catalog name: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query + [.init(name: "region", value: name)]
        return components?.url
    }

    static func catalog(region: DioramaRegion = .masaki) async throws -> Catalog {
        try await catalog(named: region.rawValue)
    }

    /// A named server catalogue (a region, or a region's compact stream catalogue such as "harbour-z1").
    static func catalog(named name: String) async throws -> Catalog {
        guard let url = url("scenery/catalog", catalog: name) else { throw Failure.unavailable }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unavailable }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.revision > 0, !catalog.files.isEmpty else { throw Failure.unavailable }
        return catalog
    }

    /// Downloads and installs every catalogue directory not already present. Returns installed count.
    static func download(_ catalog: Catalog, region: DioramaRegion = .masaki,
                         progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> Int {
        let store = DioramaOfflineStore.store(for: region)
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
                try await fetch(file, region: region, into: staged)
                done += Int64(file.b); await progress(done, total)
            }
            try await store.install(directory: name, staged: staged)
            installed += 1
        }
        return installed
    }

    /// Downloads one catalogue file into `directory` after checking its size and SHA-256.
    static func fetch(_ file: File, region: DioramaRegion, into directory: URL, session override: URLSession? = nil) async throws {
        guard file.f == URL(fileURLWithPath: file.f).lastPathComponent, !file.f.hasPrefix(".") else { throw Failure.checksum }
        let data = try await fetchData(file, catalog: region.rawValue, session: override)
        try data.write(to: directory.appendingPathComponent(file.f), options: .atomic)
    }

    /// Downloads one catalogue file into memory after checking its size and SHA-256.
    static func fetchData(_ file: File, catalog name: String, session override: URLSession? = nil,
                          progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> Data {
        guard let url = url("scenery/file", catalog: name, query: [.init(name: "d", value: file.d), .init(name: "f", value: file.f), .init(name: "s", value: file.s)])
        else { throw Failure.checksum }
        guard let progress else {
            let (data, response) = try await (override ?? session).data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == file.b,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.s else { throw Failure.checksum }
            return data
        }
        // Streamed body: the digest is folded in as bytes arrive and progress is reported every 64 KiB.
        let (bytes, response) = try await (override ?? session).bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.checksum }
        var data = Data(capacity: file.b)
        var hasher = SHA256()
        var chunk = [UInt8](); chunk.reserveCapacity(65536)
        var reported: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 65536 {
                hasher.update(data: chunk); data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                guard data.count <= file.b else { throw Failure.checksum }
                let received = Int64(data.count)
                if received - reported >= 65536 { reported = received; progress(received, Int64(file.b)) }
            }
        }
        if !chunk.isEmpty { hasher.update(data: chunk); data.append(contentsOf: chunk) }
        guard data.count == file.b,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == file.s else { throw Failure.checksum }
        progress(Int64(data.count), Int64(file.b))
        return data
    }

    /// Uploads every local package, r3 sidecar and LOD sidecar, then publishes the catalogue atomically.
    /// Streamed regions publish only compact (format 2) packages and the sidecars that belong to them.
    static func publish(region: DioramaRegion = .masaki, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Int {
        let store = DioramaOfflineStore.store(for: region)
        var files = await store.publishableFiles(compactOnly: region != .masaki)
        if files.isEmpty && region != .masaki { files = await store.publishableFiles(compactOnly: false) }
        guard !files.isEmpty else { throw Failure.rejected("no prepared scenery on this device") }
        return try await publish(catalog: region.rawValue, keyless: region != .masaki,
                                 files: files.map { Upload(directory: $0.directory, file: $0.file, url: $0.url) }, progress: progress)
    }

    nonisolated struct Upload: Sendable {
        let directory: String
        let file: String
        let url: URL
    }

    /// Uploads `files` into the named catalogue and publishes it atomically. `keyless` catalogues
    /// (streamed regions) are seeded by the service itself: without the owner key, a phone may fill
    /// an empty catalogue once using a short-lived upload token issued by the server.
    static func publish(catalog name: String, keyless: Bool, files: [Upload],
                        progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Int {
        let key = publishKey
        guard key != nil || keyless else { throw Failure.rejected("publish key missing") }
        guard !files.isEmpty else { throw Failure.rejected("nothing to upload") }
        var token: String?
        func request(_ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
            guard let url = url(path, catalog: name, query: query) else { throw Failure.unavailable }
            var r = URLRequest(url: url); r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 120
            if let key { r.setValue(key, forHTTPHeaderField: "X-Zuri-Scenery-Key") }
            if let token { r.setValue(token, forHTTPHeaderField: "X-Zuri-Upload-Token") }
            if method == "POST" { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: r)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure.rejected(String(data: data, encoding: .utf8)?.prefix(160).description ?? "HTTP error")
            }
            return data
        }
        struct Begin: Decodable { let generation: Int; let token: String? }
        // A keyless upload session is resumed across taps: the server allows one contributor at a
        // time, so opening a fresh session on every retry would lock this phone out of its own upload.
        var resumed = keyless ? UploadSession.load(catalog: name) : nil
        if resumed == nil {
            // With the owner key, a previous set or stale seed lock is cleared first so the new bake replaces it.
            if key != nil, keyless { _ = try? await request("scenery/reset", method: "POST") }
            let begin = try JSONDecoder().decode(Begin.self, from: try await request("scenery/begin", method: "POST"))
            resumed = UploadSession(generation: begin.generation, token: begin.token, sent: [])
            if keyless { resumed?.save(catalog: name) }
        }
        guard var live = resumed else { throw Failure.unavailable }
        let generation = live.generation
        token = live.token
        func sessionLost(_ error: Error) -> Bool {
            guard case Failure.rejected(let reason) = error else { return false }
            return reason.contains("seed_expired") || reason.contains("stale_or_invalid") || reason.contains("forbidden")
        }
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            if live.sent.contains(file.directory) { await progress(i + 1, files.count); continue }
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            do {
                _ = try await request("scenery/file", method: "PUT", query: [.init(name: "d", value: file.directory), .init(name: "f", value: file.file),
                    .init(name: "s", value: sha), .init(name: "g", value: String(generation))], body: data)
            } catch {
                if sessionLost(error) { UploadSession.clear(catalog: name) }
                throw error
            }
            live.sent.insert(file.directory)
            if keyless { live.save(catalog: name) }
            await progress(i + 1, files.count)
        }
        let body = try JSONSerialization.data(withJSONObject: ["g": generation, "count": files.count])
        do {
            _ = try await request("scenery/publish", method: "POST", body: body)
        } catch {
            if sessionLost(error) { UploadSession.clear(catalog: name) }
            throw error
        }
        UploadSession.clear(catalog: name)
        return files.count
    }

    /// Resumable keyless upload: the server-issued token and generation plus the directories already stored.
    nonisolated private struct UploadSession: Codable {
        let generation: Int
        let token: String?
        var sent: Set<String>
        private static func key(_ catalog: String) -> String { "zuri.scenery.upload.\(catalog)" }
        static func load(catalog: String) -> UploadSession? {
            guard let data = UserDefaults.standard.data(forKey: key(catalog)) else { return nil }
            return try? JSONDecoder().decode(UploadSession.self, from: data)
        }
        func save(catalog: String) {
            if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(catalog)) }
        }
        static func clear(catalog: String) { UserDefaults.standard.removeObject(forKey: key(catalog)) }
    }
}
