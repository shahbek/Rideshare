@_spi(Experimental) import MapboxMaps
import AVFoundation
import SceneKit
import UIKit

/// Installs a billboard (steel structure + live video screen) only when the camera is close, and tears
/// everything down — layers, player and repaint clock — when it leaves, so it costs nothing elsewhere.
@MainActor
final class BillboardLandmark {
    let ad: BillboardAd
    private var structureID: String { "zuri-billboard-structure-\(ad.id)" }
    private var screenID: String { "zuri-billboard-screen-\(ad.id)" }
    private static var scenes: [String: SCNScene] = [:]

    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var loopObserver: NSObjectProtocol?
    private var repaintTimer: Timer?
    private weak var installedMap: MapboxMap?
    private var pending: Task<Void, Never>?

    init(ad: BillboardAd) {
        self.ad = ad
    }

    var isInstalled: Bool { installedMap != nil }

    func update(on map: MapboxMap) {
        let camera = map.cameraState
        guard camera.zoom >= 14.5, GeoPoint(camera.center).distanceKm(to: ad.site) < 1.8 else {
            remove(from: map)
            return
        }
        guard !map.layerExists(withId: screenID), pending == nil else { return }
        pending = Task { [weak self, weak map] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, let map else { return }
            self.pending = nil
            do { try self.install(on: map) }
            catch {
                self.remove(from: map)
                print("[Billboard] Could not install \(self.ad.id)")
            }
        }
    }

    private func install(on map: MapboxMap) throws {
        guard !map.layerExists(withId: screenID),
              let url = Bundle.main.url(forResource: ad.videoResource, withExtension: "mp4") else { return }
        let scene = Self.scenes[ad.id] ?? BillboardGeometry.make(facingDegrees: ad.facingDegrees)
        Self.scenes[ad.id] = scene

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        loopObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        // Silent ambient video must never pause the passenger's music or podcast.
        if AVAudioSession.sharedInstance().category == .soloAmbient {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        }

        let structure = BuildingRenderLayer(origin: ad.site.coordinate, scene: scene)
        let screen = BillboardRenderLayer(origin: ad.site.coordinate, facingDegrees: ad.facingDegrees, output: output)
        try map.addCustomLayer(withId: structureID, layerHost: structure, layerPosition: nil)
        try map.setLayerProperty(for: structureID, property: "slot", value: "middle")
        try map.addCustomLayer(withId: screenID, layerHost: screen, layerPosition: nil)
        try map.setLayerProperty(for: screenID, property: "slot", value: "middle")

        self.player = player
        self.output = output
        installedMap = map
        player.play()
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installedMap?.triggerRepaint() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repaintTimer = timer
    }

    /// True when a tap at `point` lands on the lifted screen. The panel floats ~12 m up, so on a pitched
    /// camera it appears beyond its ground anchor along the view direction.
    func hitTest(_ point: CGPoint, on map: MapboxMap) -> Bool {
        guard isInstalled else { return false }
        let camera = map.cameraState
        let bearing = camera.bearing * .pi / 180
        let lift = (BillboardDimensions.screenBottom + BillboardDimensions.screenHeight / 2) * tan(camera.pitch * .pi / 180)
        let metresPerDegreeLat = 111_320.0
        let metresPerDegreeLon = metresPerDegreeLat * cos(ad.site.latitude * .pi / 180)
        let target = CLLocationCoordinate2D(
            latitude: ad.site.latitude + cos(bearing) * lift / metresPerDegreeLat,
            longitude: ad.site.longitude + sin(bearing) * lift / metresPerDegreeLon
        )
        let screen = map.point(for: target)
        let metresPerPoint = Projection.metersPerPoint(for: ad.site.latitude, zoom: camera.zoom)
        let radius = max(44, BillboardDimensions.screenWidth / metresPerPoint * 0.6)
        return hypot(screen.x - point.x, screen.y - point.y) <= radius
    }

    func styleDidReload() {
        pending?.cancel()
        pending = nil
        stopPlayback()
    }

    func remove(from map: MapboxMap) {
        pending?.cancel()
        pending = nil
        for id in [screenID, structureID] where map.layerExists(withId: id) { try? map.removeLayer(withId: id) }
        stopPlayback()
    }

    private func stopPlayback() {
        repaintTimer?.invalidate()
        repaintTimer = nil
        player?.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player = nil
        output = nil
        installedMap = nil
    }
}
