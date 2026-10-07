import CryptoKit
import Foundation
import ImageIO

/// Addressed source bytes, retained independently of URLCache and shared across elevation children.
actor DioramaSourceStore {
    static let shared = DioramaSourceStore()
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MasakiOffline/sources", isDirectory: true)
    }
    /// Verified local read for road routing; never constructs a request or downloads data.
    func savedData(key: String) -> Data? {
        let file = root.appendingPathComponent(key)
        guard let bytes = try? Data(contentsOf: file),
              let digest = try? Data(contentsOf: file.appendingPathExtension("sha")),
              Data(SHA256.hash(data: bytes)) == digest else { return nil }
        return bytes
    }

    func data(url: URL, key: String, offline: Bool) async throws -> Data {
        let file = root.appendingPathComponent(key)
        if let bytes = try? Data(contentsOf: file), let digest = try? Data(contentsOf: file.appendingPathExtension("sha")),
           Data(SHA256.hash(data: bytes)) == digest, valid(bytes, key: key) { return bytes }
        guard !offline, !UserDefaults.standard.bool(forKey: "maps.downloadedOnly") else { throw DioramaOfflineStore.Failure.source }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        let wifiOnly = UserDefaults.standard.object(forKey: "maps.downloadWiFiOnly") as? Bool ?? true
        request.allowsCellularAccess = !wifiOnly
        request.allowsExpensiveNetworkAccess = !wifiOnly
        request.allowsConstrainedNetworkAccess = false
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        let ocean = key.hasPrefix("terrain-") && status == 404
            && (try? JSONDecoder().decode([String: String].self, from: bytes)["message"]) == "Tile does not exist"
        guard (status == 200 || ocean), !bytes.isEmpty, bytes.count <= 32 * 1_048_576 else { throw DioramaOfflineStore.Failure.source }
        try Task.checkCancellation()
        guard valid(bytes, key: key) else { throw DioramaOfflineStore.Failure.source }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
        try Data(SHA256.hash(data: bytes)).write(to: file.appendingPathExtension("sha"), options: .atomic)
        return bytes
    }
    private func valid(_ bytes: Data, key: String) -> Bool {
        if key.hasPrefix("streets-") {
            return (try? DioramaVectorTile.decode(bytes, includesEnvironment: true).isEmpty) == false
        }
        if (try? JSONDecoder().decode([String: String].self, from: bytes)["message"]) == "Tile does not exist" { return true }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return image.bitsPerComponent == 8 && [24, 32].contains(image.bitsPerPixel)
            && image.width > 0 && image.height > 0 && image.width <= 1024 && image.height <= 1024
    }
}
