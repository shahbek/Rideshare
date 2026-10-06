@_spi(Experimental) import MapboxMaps
import UIKit
import XCTest
@testable import Twende

/// Native Mapbox custom-layer captures with the unchanged production Metal/effect pipeline.
/// A local, empty style isolates the diorama from network/style/font changes in Standard.
/// This does not certify basemap integration or animated reveal frames.
final class DioramaVisualBaselineTests: XCTestCase {
    @MainActor
    func testCachedCutoutCandidateMatchesV31AtFixedCameras() async throws {
        let baseline = try await captureFixture(candidate: false)
        let candidate = try await captureFixture(candidate: true)
        XCTAssertEqual(baseline.count, 4)
        XCTAssertEqual(candidate.count, baseline.count)
        for (before, after) in zip(baseline, candidate) {
            XCTAssertEqual(before.name, after.name)
            XCTAssertEqual(before.width, after.width)
            XCTAssertEqual(before.height, after.height)
            guard before.bytes.count == after.bytes.count else {
                XCTFail("Capture dimensions changed: \(before.name)"); continue
            }
            var changedPixels = 0
            for i in stride(from: 0, to: before.bytes.count, by: 4) {
                if before.bytes[i..<(i + 4)] != after.bytes[i..<(i + 4)] { changedPixels += 1 }
            }
            XCTAssertEqual(changedPixels, 0, "\(before.name): exact native-resolution RGBA comparison; no tolerance, resizing, or ignored pixels")
        }
    }

    @MainActor
    private func captureFixture(candidate: Bool) async throws -> [Capture] {
        var settings = DioramaConfig.slipway
        settings.instancesArchitecture = candidate
        let config = settings
        let data = DioramaMapboxData.resolveOwnership(try XCTUnwrap(DioramaBundledTile.load(config: config)))
        let artifacts = try await Task.detached(priority: .userInitiated) {
            try DioramaGenerationAudit.$current.withValue(DioramaGenerationAudit(usesCachedCutoutBounds: candidate)) {
                try DioramaTileGenerator.generate(data, config: config, library: DioramaPropLibrary(config: config), reduced: false)
            }
        }.value
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 80, width: 320, height: 320)
        window.windowLevel = .alert + 1
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        let json = ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#F7F7F7"}}]}"##
        let mapView = MapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), mapInitOptions: MapInitOptions(
            cameraOptions: CameraOptions(center: data.tile.centre, zoom: 17, bearing: 0, pitch: 45), styleURI: nil, styleJSON: json))
        controller.view.addSubview(mapView)
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden
        defer {
            try? mapView.mapboxMap.removeLayer(withId: "diorama-regression")
            mapView.removeFromSuperview()
            window.isHidden = true
        }
        let loaded = await waitFor(mapView.mapboxMap.onStyleLoaded, timeout: 10)
        guard loaded else { throw CaptureError.styleTimeout }
        let gallery = try XCTUnwrap(data.buildings.first { $0.id == 688_368_950 })
        let pavilion = try XCTUnwrap(data.buildings.first { $0.id == 180_607_949 })
        let mosque = try XCTUnwrap(data.pois.first { $0.kind == "mosque" && $0.name == "Masjid 36" })
        let cameras: [(String, DV2, Double, Double, DioramaTimeOfDay)] = [
            ("hotel-day-z19-b0-p55", gallery.centroid, 19, 0, .day),
            ("pavilion-day-z19-b90-p55", pavilion.centroid, 19, 90, .day),
            ("masjid-day-z19-b180-p55", mosque.point, 19, 180, .day),
            ("waterfront-dusk-z17-b0-p55", .zero, 17, 0, .dusk)
        ]
        let visible = Set(DioramaCategory.allCases.filter { $0 != .shorelineDebug })
        let host = DioramaRenderLayer(origin: data.tile.centre, vertices: artifacts.vertices, indices: artifacts.indices,
            ranges: artifacts.ranges, groups: artifacts.groups, instances: artifacts.allInstances,
            lightGrid: artifacts.lightGrid, waterHeight: artifacts.waterHeight, groundImage: artifacts.groundImage,
            groundRect: data.rect, visible: visible, timeOfDay: .day, animates: false, config: config,
            labels: artifacts.buildingLabels, displayScale: Float(mapView.contentScaleFactor))
        host.setReducedEffects(false)
        host.setReveal(.zero)
        try mapView.mapboxMap.addCustomLayer(withId: "diorama-regression", layerHost: host, layerPosition: nil)
        var captures: [Capture] = []
        for (name, centre, zoom, bearing, time) in cameras {
            let coordinate = data.projection.coordinate(centre)
            mapView.mapboxMap.setCamera(to: CameraOptions(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                                         zoom: zoom, bearing: bearing, pitch: 55))
            host.setVisible(visible, timeOfDay: time)
            let image = try await stableCapture(mapView)
            XCTAssertTrue(host.diagnostic.hasPrefix("ready"), host.diagnostic)
            let capture = try rgba(image, name: name)
            // Fail on a blank/stale custom layer, not merely two identical empty snapshots.
            var colors: Set<UInt32> = []
            for i in stride(from: 0, to: capture.bytes.count, by: 4) {
                colors.insert(UInt32(capture.bytes[i]) << 16 | UInt32(capture.bytes[i + 1]) << 8 | UInt32(capture.bytes[i + 2]))
            }
            XCTAssertGreaterThan(colors.count, 256, "Missing rendered scene: \(name)")
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(candidate ? "candidate" : "v31")-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            captures.append(capture)
        }
        return captures
    }

    @MainActor
    private func stableCapture(_ view: MapView) async throws -> UIImage {
        var previous: [UInt8]?
        var consecutive = 0
        for _ in 0..<16 {
            // Register before requesting a frame; no unbounded continuation or blind fixed sleep.
            let rendered = await waitFor(view.mapboxMap.onRenderFrameFinished, timeout: 3) { view.mapboxMap.triggerRepaint() }
            guard rendered else { throw CaptureError.frameTimeout }
            let image = try view.snapshot()
            let pixels = try rgba(image, name: "stability").bytes
            consecutive = pixels == previous ? consecutive + 1 : 0
            if consecutive >= 3 { return image }
            previous = pixels
        }
        throw CaptureError.unstablePixels
    }

    @MainActor
    private func waitFor<T>(_ signal: Signal<T>, timeout: TimeInterval, trigger: () -> Void = {}) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = FrameGate(continuation)
            gate.token = signal.observeNext { _ in gate.finish(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { gate.finish(false) }
            trigger()
        }
    }

    @MainActor
    private final class FrameGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        var token: AnyCancelable?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            token?.cancel(); token = nil
            continuation.resume(returning: value)
        }
    }

    private struct Capture {
        let name: String
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private enum CaptureError: Error { case styleTimeout, frameTimeout, unstablePixels, imageUnavailable }

    private func rgba(_ image: UIImage, name: String) throws -> Capture {
        guard let image = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CaptureError.imageUnavailable }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let succeeded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard succeeded else { throw CaptureError.imageUnavailable }
        return Capture(name: name, width: image.width, height: image.height, bytes: pixels)
    }
}
