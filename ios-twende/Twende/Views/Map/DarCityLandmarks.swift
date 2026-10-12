@_spi(Experimental) import MapboxMaps
import SceneKit
import Combine
import simd

/// Harbour layers share scenery admission; the airport has independent area-based activation.
@MainActor
final class DarCityLandmarks {
    var viewport: DioramaViewport?
    var viewportBounds: (() -> CGRect)?
    var onAirportGroundOwnershipChanged: ((Bool) -> Void)?
    /// Area policy, not a claim that airport geometry has initialized.
    private(set) var airportOwnsGround: Bool = false

    private func setAirportGroundOwnership(_ ownsGround: Bool) {
        guard airportOwnsGround != ownsGround else { return }
        airportOwnsGround = ownsGround
        print("[DarLandmarks] JNIA terrain policy=\(ownsGround ? "flat airport area" : "native outside airport area")")
        onAirportGroundOwnershipChanged?(ownsGround)
    }
    var budget = DioramaResidencyBudget() {
        didSet {
            budget.onLandmarkAvailable = { [weak self] in self?.scheduleAdmissionRefresh() }
        }
    }
    private var airportData: AirportMapData?
    private var airportSaved: AirportPackageStore.Saved?
    private var airportSavedSite: DarLandmarkSite?
    private var airportPreparedHost: DioramaLandmarkLayer?
    private var airportArrival: Task<Void, Never>?
    private var airportReveal: SIMD4<Float> = .zero
    private var airportRevealExtent: Float = 0
    private var airportNeedsSavedReload: Bool = false
    private var airportDetailRead: Task<Void, Never>?
    private var airportDetailKey: String?
    private var airportFailedDetailKey: String?
    private var airportDetailRequest: UUID?
    private var airportRead: Task<Void, Never>?
    private var airportReadFailed: Bool = false
    private var airportReadID: UUID?
    private var airportClip: Geometry?
    private var airportSpatialCatalog: AirportSpatialPackage.Catalog?
    private var airportSpatialKeys: Set<String> = []
    private var airportSpatialWanted: Set<String> = []
    private var airportSpatialChecked: Bool = false
    private var airportSpatialFailed: Set<String> = []
    private var airportActiveLayer: String = "twende-landmark-jnia-airport"
    private var isForeground: Bool = UIApplication.shared.applicationState == .active

    /// Airport terrain policy is geographic, independent of source and renderer readiness.
    func shouldFlattenAirport(on map: MapboxMap) -> Bool {
        isForeground && GeoPoint(map.cameraState.center).distanceKm(
            to: GeoPoint(latitude: -6.8717225202564105, longitude: 39.20505933538462)
        ) < 3.6
    }
    private var sites: [DarLandmarkSite] { DarLandmarkSite.all + ((airportData?.site ?? airportSavedSite).map { [$0] } ?? []) }
    private var hosts: [String: DioramaLandmarkLayer] = [:]
    private static var scenes: [String: SCNScene] = [:]
    private var pending: Task<Void, Never>?
    private var revision: UInt = 0
    private weak var currentMap: MapboxMap?
    private var subscriptions: Set<AnyCancellable> = []
    private var invalidHarbour: Set<String> = []
    private var suspendedUntil: Date = .distantPast
    private var recovery: Task<Void, Never>?

    private static let bakedStatus = "drawn by its saved tile (Slipway method)"
    static func layerID(_ id: String) -> String { "twende-landmark-\(id)" }
    static func clipID(_ id: String) -> String { "twende-landmark-clip-\(id)" }
    static func sourceID(_ id: String) -> String { "twende-landmark-site-\(id)" }

    init() {
        for name in [UIApplication.willResignActiveNotification,UIApplication.didReceiveMemoryWarningNotification] {
            NotificationCenter.default.publisher(for:name).sink { [weak self] _ in
                guard let self else { return }
                let isBackground = name == UIApplication.willResignActiveNotification
                if isBackground {
                    self.isForeground = false
                    self.airportRead?.cancel(); self.airportRead = nil; self.airportReadID = nil
                    self.airportSaved = nil; self.airportPreparedHost = nil; self.airportNeedsSavedReload = true
                    self.setAirportGroundOwnership(false)
                }
                guard let map = self.currentMap else { return }
                self.revision &+= 1; self.pending?.cancel(); self.pending = nil
                if name == UIApplication.didReceiveMemoryWarningNotification {
                    self.budget.constrain(); self.suspendedUntil = Date().addingTimeInterval(30)
                    self.recovery?.cancel()
                    self.recovery = Task { [weak self] in
                        do { try await Task.sleep(for:.seconds(30)) } catch { return }
                        guard let self, let map = self.currentMap else { return }
                        self.update(on:map)
                    }
                }
                // Harbour towers are bounded independent hosts: a memory warning raised by other scenery
                // must not tear them down. Background still releases their GPU resources.
                for site in self.sites where isBackground && (site.isBudgetedArchitecture || site.kind == "airport") {
                    self.remove(id: site.id, from: map)
                }
                if !isBackground { self.scheduleAdmissionRefresh() }
            }.store(in:&subscriptions)
        }
        NotificationCenter.default.publisher(for: AirportPackageStore.changed).sink { [weak self] _ in
            guard let self else { return }
            self.airportRead?.cancel(); self.airportRead = nil; self.airportReadID = nil
            self.airportReadFailed = false; self.airportData = nil; self.airportSaved = nil; self.airportPreparedHost = nil; self.airportSavedSite = nil
            self.airportSpatialCatalog = nil; self.airportSpatialChecked = false; self.airportSpatialKeys = []; self.airportSpatialWanted = []; self.airportSpatialFailed = []
            self.invalidHarbour.remove("jnia-airport")
            if let map = self.currentMap { self.remove(id: "jnia-airport", from: map) }
            self.scheduleAdmissionRefresh()
        }.store(in: &subscriptions)
        // Build any missing tile-drawn landmark meshes before the first saved tile read needs them.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(4))
            await DioramaBakedLandmarks.shared.prewarm()
        }
        NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.isForeground = true
            self?.scheduleAdmissionRefresh()
        }.store(in:&subscriptions)
    }

    private func scheduleAdmissionRefresh() {
        Task { @MainActor [weak self] in
            guard let self, let map = self.currentMap else { return }
            self.update(on:map)
        }
    }

    func update(on map: MapboxMap) {
        currentMap = map
        setAirportGroundOwnership(shouldFlattenAirport(on: map))
        updateLighting()
        if !shouldFlattenAirport(on: map) {
            airportRead?.cancel(); airportRead = nil; airportReadID = nil
            airportSaved = nil; airportPreparedHost = nil; airportNeedsSavedReload = true
        }
        if !prepareAirportSpatialIfNeeded(on: map) { prepareAirportIfNeeded(on: map) }
        prepareAirportDetailIfNeeded(on: map)
        if airportSaved != nil, let site = airportData?.site ?? airportSavedSite, hosts[site.id] == nil, shouldFlattenAirport(on: map) {
            do { try install(site, on: map) }
            catch { remove(id: site.id, from: map) }
        }
        // Admission uses the viewport test; an installed tower is retained by distance/zoom only, so a
        // momentary frustum disagreement can never tear it down before its first GPU frame.
        let desired = sites.filter { wanted($0,on:map) || (hosts[$0.id] != nil && retained($0, on: map)) }
        for id in Array(hosts.keys) where !desired.contains(where:{ $0.id == id }) {
            if let site = sites.first(where: { $0.id == id }) { setStatus(site, "released: out of range") }
            remove(id:id,from:map)
        }
        // Designed harbour sites own their footprint as soon as they are in view: Mapbox's own
        // extrusions/models are clipped there independently of model construction or GPU readiness.
        for site in sites where site.isBudgetedArchitecture {
            if DioramaLandmarkBakery.isDrawnBySavedTile(site.id), budget.landmarkStatus[site.name] != Self.bakedStatus {
                setStatus(site, Self.bakedStatus)
            }
            let isWanted = desired.contains(where: { $0.id == site.id })
            if isWanted { try? installClip(site, on: map) }
            else if hosts[site.id] == nil, map.layerExists(withId: Self.clipID(site.id)) { remove(id: site.id, from: map) }
        }
        guard pending == nil, desired.contains(where:{ self.hosts[$0.id] == nil && !map.layerExists(withId:Self.layerID($0.id)) }) else { return }
        let version = revision
        pending = Task { [weak self,weak map] in
            do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
            guard let self, let map, self.revision == version else { return }
            self.pending = nil
            // Re-evaluate the live camera, not the stale desired list captured before the debounce.
            for site in self.sites.filter({ self.wanted($0,on:map) }) {
                guard self.hosts[site.id] == nil, !map.layerExists(withId:Self.layerID(site.id)) else { continue }
                do { try self.install(site,on:map) }
                catch { self.remove(id:site.id,from:map); print("[DarLandmarks] Installation failed; native building retained") }
            }
        }
    }

    /// Saved 240 m chunks replace whole-campus residency; still only one effect renderer is mounted.
    private func prepareAirportSpatialIfNeeded(on map: MapboxMap) -> Bool {
        guard shouldFlattenAirport(on: map) else { airportSpatialKeys = []; airportSpatialWanted = []; return false }
        if !airportSpatialChecked {
            airportSpatialCatalog = try? AirportSpatialPackage.catalog(); airportSpatialChecked = true
        }
        guard let catalog = airportSpatialCatalog else { return false }
        let bounds = viewportBounds?() ?? CGRect(origin: .zero, size: viewport?.snapshot()?.size ?? CGSize(width: 390, height: 844))
        let keys = AirportChunkInterest.keys(catalog, on: map, viewport: viewport, bounds: bounds)
        airportSpatialWanted = keys
        guard !keys.isEmpty else {
            airportRead?.cancel(); airportRead = nil; airportReadID = nil
            if hosts["jnia-airport"] != nil { remove(id: "jnia-airport", from: map) }
            return true
        }
        if keys == airportSpatialKeys || keys == airportSpatialFailed || airportRead != nil { return true }
        let request = UUID(), version = revision
        airportReadID = request
        airportRead = Task { [weak self, weak map] in
            guard let self, let map else { return }
            defer {
                if self.airportReadID == request {
                    self.airportRead = nil; self.airportReadID = nil
                    if self.airportSpatialWanted != keys { self.scheduleAdmissionRefresh() }
                }
            }
            guard let device = DioramaGPUPreparation.shared.device else { return }
            let retained = self.hosts["jnia-airport"]?.storedMeshBytes ?? 0
            let worker = Task.detached(priority: .utility) { try AirportSpatialPackage.read(catalog, keys: keys, device: device, retainingBytes: retained) }
            do {
                let selection = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard self.revision == version, self.currentMap === map, self.shouldFlattenAirport(on: map), self.airportSpatialWanted == keys else { return }
                let host = DioramaLandmarkLayer(airportOrigin: catalog.coordinate, artifacts: nil, resident: selection.resident, groundRect: selection.rect)
                host.setAirportGroundPaint(selection.resident)
                host.viewport = self.viewport
                let upload = Task.detached(priority: .utility) { await DioramaGPUUploadQueue.shared.prepare(host.transitionRenderer) }
                await withTaskCancellationHandler { await upload.value } onCancel: { upload.cancel() }
                try Task.checkCancellation()
                guard self.revision == version, self.currentMap === map, self.shouldFlattenAirport(on: map), self.airportSpatialWanted == keys, host.transitionRenderer.isRendererReady else { return }
                let previous = self.hosts["jnia-airport"], previousLayer = self.airportActiveLayer
                let previousClip = self.airportClip, previousReveal = self.airportReveal, previousKeys = self.airportSpatialKeys
                let layer = Self.layerID("jnia-airport") + "-" + request.uuidString
                let empty = SIMD4<Float>(0, 0, -DioramaRevealStyle.support - 2, 1)
                host.transitionRenderer.setLifecycleReveal(empty)
                var committed = false
                defer { if !committed, map.layerExists(withId: layer) { try? map.removeLayer(withId: layer) } }
                try map.addCustomLayer(withId: layer, layerHost: host, layerPosition: nil)
                try await map.setLayerProperty(for: layer, property: "slot", value: "middle")
                map.triggerRepaint()
                let deadline = Date().addingTimeInterval(8)
                while !host.transitionRenderer.hasCompletedLifecycle(empty), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(33))
                    try Task.checkCancellation()
                }
                guard host.transitionRenderer.hasCompletedLifecycle(empty), self.revision == version,
                      self.currentMap === map, self.shouldFlattenAirport(on: map), self.airportSpatialWanted == keys else { return }
                let preserved = previous == nil ? nil : self.airportReveal
                self.airportArrival?.cancel(); self.airportArrival = nil
                self.airportClip = self.spatialAirportClip(catalog, keys: keys)
                do {
                    try self.registerAirport(host, site: catalog.site, on: map, reveal: previous == nil, layerID: layer, alreadyRegistered: true, preservedReveal: preserved)
                } catch {
                    self.hosts["jnia-airport"] = previous; self.airportActiveLayer = previousLayer
                    self.airportClip = previousClip; self.airportReveal = previousReveal; self.airportSpatialKeys = previousKeys
                    if let previous {
                        try? self.installClip(catalog.site, on: map)
                        self.startAirportArrival(previous, site: catalog.site, on: map)
                    }
                    throw error
                }
                committed = true
                if previous != nil, map.layerExists(withId: previousLayer) { try map.removeLayer(withId: previousLayer) }
                self.airportSaved = nil; self.airportPreparedHost = nil; self.airportData = nil; self.airportSavedSite = catalog.site
                self.airportNeedsSavedReload = false
                self.airportSpatialKeys = keys; self.airportSpatialFailed = []
                print("[AirportHD] \(keys.count)/\(catalog.chunks.count) 240m chunks; packed working set \(selection.resident.gpuBytes / 1_048_576)MiB; one shared effect renderer")
            } catch is CancellationError { }
            catch let error as CocoaError where error.code == .fileReadTooLarge {
                self.airportSpatialFailed = keys
                print("[AirportHD] Viewed detail set exceeds conservative upload allowance; existing/native coverage retained")
            }
            catch {
                self.airportSpatialFailed = keys
                self.airportSpatialCatalog = nil; self.airportSpatialChecked = true
                self.airportNeedsSavedReload = self.hosts["jnia-airport"] == nil
                self.airportReadFailed = false
                self.scheduleAdmissionRefresh()
                print("[AirportHD] Spatial read/upload failed; existing coverage retained, legacy local fallback enabled")
            }
        }
        return true
    }

    private func spatialAirportClip(_ catalog: AirportSpatialPackage.Catalog, keys: Set<String>) -> Geometry {
        let rings = catalog.ownership.filter { Set($0.keys).isSubset(of: keys) }.map(\.ring)
        return .multiPolygon(MultiPolygon(rings.map { Polygon([$0.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }]) }))
    }

    private func prepareAirportIfNeeded(on map: MapboxMap) {
        guard ((airportData == nil && airportSavedSite == nil) || airportNeedsSavedReload), airportRead == nil, !airportReadFailed,
              shouldFlattenAirport(on: map) else { return }
        let request = UUID(); airportReadID = request
        let expectedRevision = revision
        airportRead = Task { [weak self] in
            defer {
                if let self, self.airportReadID == nil, self.airportData != nil || self.airportSavedSite != nil {
                    self.scheduleAdmissionRefresh()
                }
            }
            let worker = Task.detached(priority: .utility) {
                let start = Date()
                let saved = DioramaGPUPreparation.shared.device.flatMap { try? AirportPackageStore.read(device: $0) }
                if Task.isCancelled { return (Optional<AirportMapData>.none, Optional<AirportPackageStore.Saved>.none) }
                if let saved, saved.ground != nil {
                    #if DEBUG
                    print("[AirportHD] saved buffers ready \(Int(Date().timeIntervalSince(start) * 1000))ms; no XML parse, SceneKit build or HD raster upload")
                    #endif
                    return (Optional<AirportMapData>.none, Optional(saved))
                }
                return (AirportMapData.load(), saved)
            }
            let loaded = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            let data = loaded.0
            guard let self, self.airportReadID == request else { return }
            guard !Task.isCancelled, let map = self.currentMap, self.shouldFlattenAirport(on: map) else {
                self.airportRead = nil; self.airportReadID = nil
                self.airportSaved = nil; self.airportPreparedHost = nil; self.airportNeedsSavedReload = true
                return
            }
            if let saved = loaded.1 {
                let host = DioramaLandmarkLayer(airportOrigin: saved.metadata.coordinate, artifacts: nil, resident: saved.resident, groundRect: saved.metadata.rect)
                host.setAirportGroundPaint(saved.ground?.resident)
                let upload = Task.detached(priority: .utility) { await DioramaGPUUploadQueue.shared.prepare(host.transitionRenderer) }
                await withTaskCancellationHandler { await upload.value } onCancel: { upload.cancel() }
                guard self.airportReadID == request else { return }
                guard !Task.isCancelled, self.revision == expectedRevision, self.currentMap === map, self.shouldFlattenAirport(on: map) else {
                    self.airportRead = nil; self.airportReadID = nil; self.airportNeedsSavedReload = true
                    return
                }
                self.airportPreparedHost = host
            }
            self.airportRead = nil; self.airportReadID = nil
            self.airportData = data; self.airportReadFailed = data == nil && loaded.1 == nil
            self.airportSaved = loaded.1; self.airportSavedSite = loaded.1?.ground?.metadata.site
            self.airportNeedsSavedReload = false
            if let data {
                DarLandmarkSite.airportTerminalOutlines = data.features.filter { [23359828, 597787841, 1188629104, 1237792404].contains($0.id) }.map { f in
                    DarLandmarkSite(id: "jnia-protected-\(f.id)", name: f.tags["name"] ?? "Airport walking connection", kind: "airport-outline", osmWay: f.id, bearing: 315, height: 25,
                        heightEvidence: "Photo-estimated", reference: data.site.reference, photo: data.site.photo,
                        orientationEvidence: data.site.orientationEvidence, ring: f.coordinates)
                }
                print("[DarLandmarks] JNIA bundled map: \(data.features.count) ways, \(data.points.count) tagged points; estimates are not a survey")
            }
            else if loaded.1 == nil { print("[DarLandmarks] JNIA bundled map incomplete; native retained") }
        }
    }

    private func prepareAirportDetailIfNeeded(on map: MapboxMap) {
        guard shouldFlattenAirport(on: map), let data = airportData, let host = hosts[data.site.id], !host.hasAnalyticAirportGround, airportDetailRead == nil,
              let device = DioramaGPUPreparation.shared.device else { return }
        let p = DioramaProjection(origin: data.site.anchor.coordinate).local(longitude: map.cameraState.center.longitude, latitude: map.cameraState.center.latitude)
        let key = AirportPackageStore.pageKey(at: p)
        guard airportDetailKey != key, airportFailedDetailKey != key else { return }
        let request = UUID(); airportDetailRequest = request
        airportDetailRead = Task { [weak self, weak host, weak map] in
            let worker = Task.detached(priority: .utility) { try? AirportPackageStore.readPage(at: p, device: device) }
            let page = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, self.airportDetailRequest == request else { return }
            self.airportDetailRead = nil; self.airportDetailRequest = nil
            guard !Task.isCancelled, let map, let host, self.hosts[data.site.id] === host, self.shouldFlattenAirport(on: map) else { return }
            let current = DioramaProjection(origin: data.site.anchor.coordinate).local(longitude: map.cameraState.center.longitude, latitude: map.cameraState.center.latitude)
            guard AirportPackageStore.pageKey(at: current) == key else { self.prepareAirportDetailIfNeeded(on: map); return }
            if let page {
                host.setAirportGroundDetail(page, rect: AirportPackageStore.pageRect(at: p))
                self.airportDetailKey = key; self.airportFailedDetailKey = nil
                print("[DarLandmarks] JNIA checked HD paint \(key), 4096px / 600m; same ground surface")
            } else {
                self.airportFailedDetailKey = key
                host.setAirportGroundDetail(nil, rect: nil); self.airportDetailKey = nil
            }
            map.triggerRepaint()
        }
    }

    private func wanted(_ site: DarLandmarkSite, on map: MapboxMap) -> Bool {
        if site.kind == "airport" {
            return shouldFlattenAirport(on: map) && (airportSpatialCatalog == nil || !airportSpatialWanted.isEmpty)
        }
        guard map.cameraState.zoom >= 14.5, GeoPoint(map.cameraState.center).distanceKm(to:site.anchor) < 1.6 else { return false }
        // Drawn by its saved tile (Slipway/Sea Cliff method); a standalone host is only the fallback.
        if DioramaLandmarkBakery.isDrawnBySavedTile(site.id) { return false }
        guard site.isBudgetedArchitecture else { return true }
        guard UIApplication.shared.applicationState == .active else { return false }
        let rect = viewportBounds?() ?? CGRect(origin:.zero,size:viewport?.snapshot()?.size ?? CGSize(width:390,height:844))
        guard rect.width>0, rect.height>0 else { return false }
        if let snapshot = viewport?.snapshot(), abs(snapshot.zoom-map.cameraState.zoom)<0.02,
           abs(snapshot.latitude-map.cameraState.center.latitude)<0.0000001,
           abs(snapshot.longitude-map.cameraState.center.longitude)<0.0000001,
           abs(snapshot.bearing-map.cameraState.bearing)<0.05, abs(snapshot.pitch-map.cameraState.pitch)<0.05,
           let footprint = site.footprint {
            let offset = DioramaProjection(origin:snapshot.origin).local(longitude:site.anchor.longitude,latitude:site.anchor.latitude)
            var translation = matrix_identity_double4x4
            translation.columns.3 = SIMD4(offset.x,offset.y,0,1)
            let matrix = snapshot.transform*translation, b = HarbourArchitectureParts.bounds(footprint.rings.first ?? [])
            let range = DioramaRenderLayer.Range(category:.buildings,start:0,count:0,
                minimum:SIMD3(Float(b.x)-1,Float(b.y)-1,-10),maximum:SIMD3(Float(b.z)+1,Float(b.w)+1,Float(site.height)+10))
            let floatMatrix = simd_float4x4(columns:(SIMD4(matrix.columns.0),SIMD4(matrix.columns.1),SIMD4(matrix.columns.2),SIMD4(matrix.columns.3)))
            return range.intersects(floatMatrix)
        }
        // Bootstrap before a renderer publishes its transform; conservatively include the tower's vertical reach.
        let points = site.ring.map { map.point(for:CLLocationCoordinate2D(latitude:$0[1],longitude:$0[0])) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let lowX = points.map(\.x).min() ?? 0, highX = points.map(\.x).max() ?? 0
        let lowY = points.map(\.y).min() ?? 0, highY = points.map(\.y).max() ?? 0
        let metres = Double(Projection.metersPerPoint(for:site.anchor.latitude,zoom:CGFloat(map.cameraState.zoom)))
        let reach = min(600,site.height/max(0.01,metres))
        return rect.intersects(CGRect(x:lowX-24,y:lowY-reach-24,width:highX-lowX+48,height:highY-lowY+reach+48))
    }

    private func retained(_ site: DarLandmarkSite, on map: MapboxMap) -> Bool {
        guard site.isBudgetedArchitecture, !DioramaLandmarkBakery.isDrawnBySavedTile(site.id) else { return false }
        return isForeground && map.cameraState.zoom >= 14.0
            && GeoPoint(map.cameraState.center).distanceKm(to: site.anchor) < 2.2
    }

    private func startInitializationWatch(_ site: DarLandmarkSite, host: DioramaLandmarkLayer, on map: MapboxMap) {
        Task { @MainActor [weak self, weak host, weak map] in
            for attempt in 1...6 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let host, let map, self.hosts[site.id] === host else { return }
                guard !host.transitionRenderer.isRendererReady else { return }
                let present = map.layerExists(withId: Self.layerID(site.id))
                self.setStatus(site, present
                    ? "registered, Mapbox has not started its renderer (\(attempt * 2)s)"
                    : "layer missing after registration")
                map.triggerRepaint()
            }
        }
    }

    private var outputSize: CGSize {
        let size = viewportBounds?().size ?? CGSize(width:390,height:844)
        let scale = UIScreen.main.scale
        return CGSize(width:max(1,size.width*scale),height:max(1,size.height*scale))
    }

    private func setStatus(_ site: DarLandmarkSite, _ status: String) {
        guard site.isBudgetedArchitecture else { return }
        budget.landmarkStatus[site.name] = status
        print("[DarLandmarks] \(site.id) \(status)")
    }

    func install(_ site: DarLandmarkSite, on map: MapboxMap) throws {
        currentMap = map
        let isAirport = site.kind == "airport"
        let needsValidation = site.isBudgetedArchitecture || isAirport
        if isAirport { setAirportGroundOwnership(shouldFlattenAirport(on: map)) }
        if hosts[site.id] != nil || map.layerExists(withId: Self.layerID(site.id)) { remove(id:site.id,from:map) }
        if needsValidation, invalidHarbour.contains(site.id) { return }
        // Harbour towers no longer compete with saved tiles for the shared scenery allowance: a full
        // allowance or a memory-constrained session previously deferred them indefinitely.
        setStatus(site, "building model")
        let scene: SCNScene
        if isAirport, let saved = airportSaved {
            let clips = saved.ground?.metadata.clips ?? airportData?.features.filter { saved.metadata.builtIDs.contains($0.id) }.map(\.coordinates) ?? []
            airportClip = .multiPolygon(MultiPolygon(clips.map { ring in
                Polygon([ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }])
            }))
            let host = airportPreparedHost ?? DioramaLandmarkLayer(airportOrigin: saved.metadata.coordinate, artifacts: nil, resident: saved.resident, groundRect: saved.metadata.rect)
            airportPreparedHost = nil
            host.setAirportGroundPaint(saved.ground?.resident)
            airportSaved = nil
            try registerAirport(host, site: site, on: map)
            return
        }
        if isAirport {
            guard let airportData else { return }
            scene = AirportGeometry.make(airportData, site: site)
        }
        else { scene = site.isBudgetedArchitecture ? DarLandmarkGeometry.make(site) : Self.scenes[site.id] ?? DarLandmarkGeometry.make(site) }
        var triangleCount = 0
        scene.rootNode.enumerateChildNodes { node, _ in triangleCount += node.geometry?.elements.reduce(0) { $0+$1.primitiveCount } ?? 0 }
        guard triangleCount>0 else {
            if needsValidation {
                invalidHarbour.insert(site.id)
                setStatus(site, "recipe empty")
            }
            return
        }
        if needsValidation {
            guard let checked = HarbourArchitectureParts.validate(scene, site: site, airportData: isAirport ? airportData : nil) else {
                invalidHarbour.insert(site.id)
                setStatus(site, "validation rejected: \(HarbourArchitectureParts.lastRejection)")
                return
            }
            triangleCount = checked
        } else if site.kind != "generated" { Self.scenes[site.id] = scene }
        let airportImage: DioramaGroundImage?
        let airportRect: DioramaRect?
        if site.kind == "airport", let airportData {
            guard let image = AirportGroundGeometry.image(airportData, origin: site.anchor.coordinate) else {
                print("[DarLandmarks] JNIA ground image allocation failed; native retained")
                return
            }
            airportImage = image
            airportRect = airportData.groundRect(origin: site.anchor.coordinate)
            var builtIDs: Set<Int> = [23359828, 597787841, 1188629104, 1237792404]
            scene.rootNode.enumerateChildNodes { node, _ in
                if let name = node.name, name.hasPrefix("mappedAirportBuilding-"),
                   let id = Int(name.dropFirst("mappedAirportBuilding-".count)) { builtIDs.insert(id) }
            }
            airportClip = .multiPolygon(MultiPolygon(airportData.features.filter { builtIDs.contains($0.id) }.map { f in
                Polygon([f.coordinates.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }])
            }))
        } else { airportImage = nil; airportRect = nil }
        let finalTriangles = triangleCount
        do {
            let host: DioramaLandmarkLayer
            if isAirport, let airportRect {
                let artifacts = DioramaLandmarkMesh.airport(scene, origin: site.anchor.coordinate, image: airportImage, rect: airportRect)
                host = DioramaLandmarkLayer(airportOrigin: site.anchor.coordinate, artifacts: artifacts, groundRect: airportRect)
                try registerAirport(host, site: site, on: map)
                return
            } else {
                host = DioramaLandmarkLayer(origin:site.anchor.coordinate,scene:scene,ring:site.footprint?.rings.first ?? [],
                    landmarkID:site.id)
            }
            host.viewport = viewport
            host.onInitializationFailed = { [weak self,weak map,weak host] in
                Task { @MainActor [weak self,weak map,weak host] in
                    guard let self, let map, let host, self.hosts[site.id] === host else { return }
                    self.setStatus(site, "GPU initialization failed: \(host.diagnostic)")
                    self.invalidHarbour.insert(site.id)
                    self.remove(id:site.id,from:map)
                }
            }
            if needsValidation {
                host.onInitialized = { [weak self,weak map,weak host] in
                    Task { @MainActor [weak self,weak map,weak host] in
                        guard let self, let map, let host, self.hosts[site.id] === host else { return }
                        do {
                            try self.installClip(site,on:map)
                            self.setStatus(site, "visible · \(finalTriangles) triangles")
                            map.triggerRepaint()
                        }
                        catch { self.remove(id:site.id,from:map) }
                    }
                }
            }
            configureLighting(host)
            hosts[site.id] = host
            setStatus(site, "waiting for first GPU frame · \(triangleCount) triangles")
            do {
                try map.addCustomLayer(withId:Self.layerID(site.id),layerHost:host,layerPosition:nil)
                try map.setLayerProperty(for:Self.layerID(site.id),property:"slot",value:"middle")
            } catch {
                if needsValidation {
                    invalidHarbour.insert(site.id)
                    setStatus(site, "map registration failed: \(error.localizedDescription)")
                }
                throw error
            }
            if !needsValidation { try installClip(site,on:map) }
            else { startInitializationWatch(site, host: host, on: map) }
            if needsValidation {
                print("[DarLandmarks] \(site.id) procedural triangles=\(triangleCount), geographic host registered\(isAirport ? "; airport performance admission bypassed" : "")")
            }
            map.triggerRepaint()
        } catch { remove(id:site.id,from:map); throw error }
    }

    private func registerAirport(_ host: DioramaLandmarkLayer, site: DarLandmarkSite, on map: MapboxMap, reveal: Bool = true,
                                 layerID: String? = nil, alreadyRegistered: Bool = false, preservedReveal: SIMD4<Float>? = nil) throws {
        host.viewport = viewport
        let bounds = host.transitionRenderer.revealBounds
        let p = DioramaProjection(origin: site.anchor.coordinate).local(longitude: map.cameraState.center.longitude, latitude: map.cameraState.center.latitude)
        let x = min(bounds.maximum.x, max(bounds.minimum.x, Float(p.x)))
        let y = min(bounds.maximum.y, max(bounds.minimum.y, Float(p.y)))
        airportReveal = preservedReveal ?? (reveal ? SIMD4(x, y, -DioramaRevealStyle.support - 2, 1) : .zero)
        let extent = max(abs(bounds.minimum.x - x), abs(bounds.maximum.x - x), abs(bounds.minimum.y - y), abs(bounds.maximum.y - y)) + DioramaRevealStyle.support + 50
        airportRevealExtent = preservedReveal == nil ? extent : max(airportRevealExtent, extent)
        host.transitionRenderer.setLifecycleReveal(airportReveal)
        host.transitionRenderer.onLifecycleCompleted = { [weak self, weak host] in
            Task { @MainActor in
                guard let self, let host, let map = self.currentMap, self.hosts[site.id] === host else { return }
                self.startAirportArrival(host, site: site, on: map)
            }
        }
        host.onInitializationFailed = { [weak self, weak map, weak host] in
            Task { @MainActor in
                guard let self, let map, let host, self.hosts[site.id] === host else { return }
                self.invalidHarbour.insert(site.id); self.remove(id: site.id, from: map)
                print("[DarLandmarks] JNIA saved GPU initialization failed; native retained")
            }
        }
        host.onInitialized = { [weak self, weak map, weak host] in
            Task { @MainActor in
                guard let self, let map, let host, self.hosts[site.id] === host else { return }
                do {
                    try self.installClip(site, on: map)
                    self.startAirportArrival(host, site: site, on: map)
                    self.prepareAirportDetailIfNeeded(on: map); map.triggerRepaint()
                }
                catch { self.remove(id: site.id, from: map) }
            }
        }
        configureLighting(host); hosts[site.id] = host
        let id = layerID ?? Self.layerID(site.id)
        airportActiveLayer = id
        do {
            if !alreadyRegistered {
                try map.addCustomLayer(withId: id, layerHost: host, layerPosition: nil)
                try map.setLayerProperty(for: id, property: "slot", value: "middle")
            } else {
                try installClip(site, on: map)
                map.updateGeoJSONSource(withId: Self.sourceID(site.id), geoJSON: .geometry(airportRevealClip(site)))
                startAirportArrival(host, site: site, on: map)
            }
            print("[DarLandmarks] JNIA shared Metal campus registered; finite reveal armed")
            map.triggerRepaint()
        } catch { remove(id: site.id, from: map); throw error }
    }

    private func startAirportArrival(_ host: DioramaLandmarkLayer, site: DarLandmarkSite, on map: MapboxMap) {
        guard airportArrival == nil, airportReveal.w > 0.5, shouldFlattenAirport(on: map) else { return }
        let field = airportReveal, extent = airportRevealExtent
        airportArrival = Task { [weak self, weak host, weak map] in
            guard let self, let host, let map else { return }
            let finished = await DioramaTileTransition.run(host: host.transitionRenderer, from: field.z, to: extent, field: field) { [weak self, weak host, weak map] value, _ in
                guard let self, let host, let map, self.hosts[site.id] === host else { return }
                self.airportReveal = value
                if map.sourceExists(withId: Self.sourceID(site.id)) {
                    map.updateGeoJSONSource(withId: Self.sourceID(site.id), geoJSON: .geometry(self.airportRevealClip(site)))
                }
                map.triggerRepaint()
            }
            guard !Task.isCancelled, self.hosts[site.id] === host else { return }
            self.airportArrival = nil
            if finished {
                self.airportReveal = .zero; host.transitionRenderer.setLifecycleReveal(.zero)
                map.updateGeoJSONSource(withId: Self.sourceID(site.id), geoJSON: .geometry(self.airportRevealClip(site)))
                map.triggerRepaint()
            } else {
                print("[DarLandmarks] JNIA reveal waiting for a completed GPU frame; current coverage retained")
                if host.transitionRenderer.hasCompletedLifecycle(self.airportReveal) {
                    self.startAirportArrival(host, site: site, on: map)
                }
            }
        }
    }

    private func airportRevealClip(_ site: DarLandmarkSite) -> Geometry {
        guard airportReveal.w > 0.5, case let .multiPolygon(polygons) = airportClip else {
            return airportClip ?? .multiPolygon(MultiPolygon([Polygon]()))
        }
        let radius = Double(airportReveal.z - DioramaRevealStyle.support)
        guard radius > 0 else { return .multiPolygon(MultiPolygon([Polygon]())) }
        let rect = DioramaRect(minX: Double(airportReveal.x) - radius, minY: Double(airportReveal.y) - radius,
            maxX: Double(airportReveal.x) + radius, maxY: Double(airportReveal.y) + radius)
        let projection = DioramaProjection(origin: site.anchor.coordinate)
        let rings = polygons.coordinates.compactMap { polygon -> Polygon? in
            guard let ring = polygon.first else { return nil }
            let local = ring.map { projection.local(longitude: $0.longitude, latitude: $0.latitude) }
            let clipped = DioramaPolygon.clipPolygon(local, to: rect)
            guard clipped.count >= 3 else { return nil }
            var coordinates = clipped.map { p in
                let c = projection.coordinate(p)
                return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            }
            if let first = coordinates.first { coordinates.append(first) }
            return Polygon([coordinates])
        }
        return .multiPolygon(MultiPolygon(rings))
    }

    private func installClip(_ site: DarLandmarkSite, on map: MapboxMap) throws {
        guard !map.layerExists(withId:Self.clipID(site.id)) else { return }
        var source = GeoJSONSource(id:Self.sourceID(site.id))
        if site.kind == "airport", let airportClip {
            source.data = .geometry(airportRevealClip(site))
        } else { source.data = .geometry(BuildingIllumination.expanded(site.geometry,by:0.35)) }
        try map.addSource(source)
        var clip = ClipLayer(id:Self.clipID(site.id),source:Self.sourceID(site.id))
        clip.slot = .top; clip.clipLayerScope = .constant(["basemap"]); clip.clipLayerTypes = .constant([.model])
        try map.addLayer(clip)
    }

    func updateLighting() { for host in hosts.values { configureLighting(host) } }
    private func configureLighting(_ host: DioramaLandmarkLayer) {
        let state = DioramaState.shared
        host.setLighting(time:state.isEnabled && !state.isBasemapOnly ? state.timeOfDay
            : DioramaTimeOfDay.from(preset:AppSettings.shared.mapStyle.lightPreset),
            reduced:ProcessInfo.processInfo.isLowPowerModeEnabled
                || ProcessInfo.processInfo.thermalState.rawValue>=ProcessInfo.ThermalState.serious.rawValue)
    }

    func styleDidReload() {
        revision &+= 1; pending?.cancel(); pending = nil
        hosts.removeAll(); airportActiveLayer = Self.layerID("jnia-airport")
        airportArrival?.cancel(); airportArrival = nil; airportReveal = .zero
        airportClip = nil
        airportSpatialKeys = []; airportSpatialWanted = []; airportSpatialFailed = []
        airportSaved = nil; airportPreparedHost = nil; airportNeedsSavedReload = true
        airportRead?.cancel(); airportRead = nil; airportReadID = nil
        airportDetailRead?.cancel(); airportDetailRead = nil; airportDetailRequest = nil
        airportDetailKey = nil; airportFailedDetailKey = nil
        if let map = currentMap { setAirportGroundOwnership(shouldFlattenAirport(on: map)) }
        else { setAirportGroundOwnership(false) }
        invalidHarbour.removeAll()
    }

    func remove(from map: MapboxMap) {
        revision &+= 1; pending?.cancel(); pending = nil
        recovery?.cancel(); recovery = nil
        airportRead?.cancel(); airportRead = nil; airportReadID = nil
        airportSaved = nil; airportPreparedHost = nil; airportNeedsSavedReload = true
        for site in sites { remove(id:site.id,from:map) }
        currentMap = nil
        setAirportGroundOwnership(false)
    }

    private func remove(id: String, from map: MapboxMap) {
        let hadHost = hosts[id] != nil
        for layer in [Self.clipID(id), id == "jnia-airport" ? airportActiveLayer : Self.layerID(id)] where map.layerExists(withId:layer) { try? map.removeLayer(withId:layer) }
        if map.sourceExists(withId:Self.sourceID(id)) { try? map.removeSource(withId:Self.sourceID(id)) }
        hosts[id] = nil
        if id == "jnia-airport" {
            airportActiveLayer = Self.layerID(id)
            airportSpatialKeys = []; airportSpatialWanted = []; airportSpatialFailed = []
            airportArrival?.cancel(); airportArrival = nil; airportReveal = .zero
            if hadHost { airportNeedsSavedReload = true; airportSaved = nil; airportPreparedHost = nil }
            airportClip = nil
            airportDetailRead?.cancel(); airportDetailRead = nil; airportDetailRequest = nil
            airportDetailKey = nil; airportFailedDetailKey = nil
        }
    }
}
