import Foundation
import Observation
@preconcurrency import MapboxMaps

/// App-owned offline downloads. One active job, explicit network consent and durable SDK storage.
@Observable
@MainActor
final class OfflineMapService {
    private(set) var activeID: String?
    private(set) var progress: Double = 0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var storedBytes: [String: Int64] = [:]
    private(set) var completeIDs: Set<String> = []
    private(set) var styleReady: Bool = false
    private(set) var messages: [String: LKey] = [:]
    private(set) var removingIDs: Set<String> = []
    private(set) var inventoryError: Bool = false

    var wiFiOnly: Bool {
        didSet {
            UserDefaults.standard.set(wiFiOnly, forKey: "maps.downloadWiFiOnly")
            enforceNetworkPolicy()
        }
    }
    var downloadedOnly: Bool {
        didSet {
            UserDefaults.standard.set(downloadedOnly, forKey: "maps.downloadedOnly")
            if downloadedOnly { pause() }
            OfflineSwitch.shared.isMapboxStackConnected = !downloadedOnly
        }
    }

    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let manager: OfflineManager
    @ObservationIgnored private let store: TileStore
    @ObservationIgnored private var downloads: [Cancelable] = []
    @ObservationIgnored private var job: UUID = UUID()
    @ObservationIgnored private var inventory: UUID = UUID()
    @ObservationIgnored private var lastProgressUpdate: TimeInterval = 0
    @ObservationIgnored private var styleBytes: Int64 = 0

    init(network: NetworkMonitor) {
        self.network = network
        wiFiOnly = UserDefaults.standard.object(forKey: "maps.downloadWiFiOnly") as? Bool ?? true
        let usesSavedMaps = UserDefaults.standard.bool(forKey: "maps.downloadedOnly")
        downloadedOnly = usesSavedMaps
        OfflineSwitch.shared.isMapboxStackConnected = !usesSavedMaps
        store = TileStore.default
        manager = OfflineManager()
        network.didChange = { [weak self] in self?.enforceNetworkPolicy() }
        refresh()
    }

    var canDownload: Bool {
        network.isOnline && !downloadedOnly && (!wiFiOnly || (network.isWiFi && !network.isExpensive && !network.isConstrained))
    }

    var restriction: LKey? {
        if downloadedOnly { return .offlineDisableOnly }
        if !network.isOnline { return .offlineConnect }
        if wiFiOnly && (!network.isWiFi || network.isExpensive || network.isConstrained) { return .offlineNeedWiFi }
        return nil
    }

    func isReady(_ area: OfflineMapArea) -> Bool { styleReady && completeIDs.contains(area.id) }

    /// Inventory reads local SDK metadata only. Never refreshes network resources implicitly.
    func refresh() {
        let token = UUID()
        inventory = token
        inventoryError = false
        manager.allStylePacks { [weak self] result in
            var ready = false
            var failed = false
            switch result {
            case .success(let packs):
                for pack in packs {
                    let matches = pack.styleURI == StyleURI.standard.rawValue
                    let complete = pack.requiredResourceCount > 0 && pack.completedResourceCount >= pack.requiredResourceCount
                    if matches && complete { ready = true }
                }
            case .failure: failed = true
            }
            let styleComplete = ready
            let readFailed = failed
            Task { @MainActor in
                guard let self, self.inventory == token else { return }
                self.styleReady = styleComplete
                if readFailed { self.inventoryError = true }
            }
        }
        store.allTileRegions { [weak self] result in
            let records: [RegionSnapshot]
            let failed: Bool
            switch result {
            case .success(let regions):
                failed = false
                records = regions.filter { $0.id.hasPrefix("zuri-") }.map {
                    RegionSnapshot(id: $0.id, bytes: Int64($0.completedResourceSize),
                        complete: $0.requiredResourceCount > 0 && $0.completedResourceCount >= $0.requiredResourceCount)
                }
            case .failure:
                failed = true; records = []
            }
            Task { @MainActor in
                guard let self, self.inventory == token else { return }
                if failed { self.inventoryError = true; return }
                self.storedBytes = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.bytes) })
                self.completeIDs = Set(records.filter(\.complete).map(\.id))
            }
        }
    }

    /// A cancelled/partial region resumes from existing tile packs under the same identifier.
    /// Refresh is opt-in; ordinary resumes may reuse expired tiles to avoid repeat mobile transfers.
    func download(_ area: OfflineMapArea, update: Bool = false) {
        guard activeID == nil, removingIDs.isEmpty, canDownload else { return }
        inventory = UUID()
        let token = UUID()
        job = token; activeID = area.id
        progress = 0; downloadedBytes = 0; styleBytes = 0; lastProgressUpdate = 0
        messages[area.id] = .offlinePreparing
        guard let options = StylePackLoadOptions(glyphsRasterizationMode: .ideographsRasterizedLocally,
            metadata: ["app": "zuri", "schema": 1], acceptExpired: !update) else {
            fail(area.id, token: token); return
        }
        let handle = manager.loadStylePack(for: .standard, loadOptions: options) { [weak self] value in
            let fraction = Double(value.completedResourceCount) / Double(max(value.requiredResourceCount, 1))
            let bytes = Int64(value.completedResourceSize)
            Task { @MainActor in self?.report(token: token, fraction: fraction * 0.15, bytes: bytes) }
        } completion: { [weak self] result in
            let success: Bool
            switch result {
            case .success: success = true
            case .failure: success = false
            }
            Task { @MainActor in
                guard let self, self.job == token, self.activeID == area.id else { return }
                guard success, self.canDownload else { self.fail(area.id, token: token); return }
                self.styleReady = true
                self.styleBytes = self.downloadedBytes
                self.loadTiles(area, token: token, update: update)
            }
        }
        downloads.append(handle)
    }

    private func loadTiles(_ area: OfflineMapArea, token: UUID, update: Bool) {
        let descriptor = manager.createTilesetDescriptor(for: TilesetDescriptorOptions(
            styleURI: .standard, zoomRange: 0...16, tilesets: nil))
        guard let options = TileRegionLoadOptions(geometry: area.geometry, descriptors: [descriptor],
            metadata: ["app": "zuri", "area": area.id, "schema": 1], acceptExpired: !update,
            networkRestriction: wiFiOnly ? .disallowExpensive : .none) else {
            fail(area.id, token: token); return
        }
        messages[area.id] = .offlineDownloading
        let handle = store.loadTileRegion(forId: area.id, loadOptions: options) { [weak self] value in
            let fraction = Double(value.completedResourceCount) / Double(max(value.requiredResourceCount, 1))
            let bytes = Int64(value.completedResourceSize)
            Task { @MainActor in
                guard let self else { return }
                self.report(token: token, fraction: 0.15 + fraction * 0.85, bytes: self.styleBytes + bytes)
            }
        } completion: { [weak self] result in
            let success: Bool
            switch result {
            case .success(let region):
                success = region.requiredResourceCount > 0 && region.completedResourceCount >= region.requiredResourceCount
            case .failure: success = false
            }
            Task { @MainActor in
                guard let self, self.job == token, self.activeID == area.id else { return }
                guard success else { self.fail(area.id, token: token); return }
                self.progress = 1
                self.activeID = nil
                self.downloads.removeAll()
                self.messages[area.id] = nil
                self.refresh()
            }
        }
        downloads.append(handle)
    }

    private func report(token: UUID, fraction: Double, bytes: Int64) {
        guard job == token, activeID != nil else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastProgressUpdate >= 0.25 || fraction >= 1 else { return }
        lastProgressUpdate = now
        progress = min(max(fraction, 0), 1)
        downloadedBytes = bytes
    }

    func pause() {
        guard let id = activeID else { return }
        job = UUID()
        activeID = nil
        downloads.forEach { $0.cancel() }
        downloads.removeAll()
        messages[id] = .offlinePaused
        refresh()
    }

    private func enforceNetworkPolicy() {
        if !canDownload { pause() }
    }

    private func fail(_ id: String, token: UUID) {
        guard job == token else { return }
        job = UUID(); activeID = nil
        downloads.forEach { $0.cancel() }
        downloads.removeAll()
        messages[id] = .offlineFailed
        refresh()
        print("[OfflineMaps] Download incomplete; retained resources may be resumed")
    }

    func remove(_ area: OfflineMapArea) {
        guard activeID == nil, !removingIDs.contains(area.id) else { return }
        inventory = UUID()
        removingIDs.insert(area.id)
        store.removeRegion(forId: area.id) { [weak self] result in
            let succeeded: Bool
            switch result { case .success: succeeded = true; case .failure: succeeded = false }
            Task { @MainActor in
                guard let self else { return }
                self.removingIDs.remove(area.id)
                if succeeded {
                    self.messages[area.id] = nil
                    self.completeIDs.remove(area.id)
                    self.storedBytes[area.id] = nil
                } else { self.messages[area.id] = .offlineRemoveFailed }
                // Keep the shared Standard style pack for other regions and ordinary map browsing.
                self.refresh()
            }
        }
    }

    nonisolated private struct RegionSnapshot: Sendable {
        let id: String
        let bytes: Int64
        let complete: Bool
    }
}
