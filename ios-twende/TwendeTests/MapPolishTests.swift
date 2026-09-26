import XCTest
import CoreLocation
import SwiftUI
import SceneKit
import Metal
@_spi(Experimental) import MapboxMaps
@testable import Twende

/// Focused regressions for the shipping annotation / miniature pipeline (not the old GLB experiments).
@MainActor
final class MapPolishTests: XCTestCase {
    func testRouteOrderIncludesPickupDestinationAndDuplicateVisits() {
        let env = AppEnvironment()
        let flow = env.flow
        let pickup = flow.pickup
        let first = DemoPlaces.mlimaniCity
        let last = DemoPlaces.airport
        flow.stops = [first, first]
        flow.destination = last
        flow.pickupNote = "Meet by the gate"
        let reordered = [last, first, pickup, first]
        XCTAssertTrue(flow.reorderRoute(reordered))
        XCTAssertEqual(flow.pickup, last)
        XCTAssertEqual(flow.stops, [first, pickup])
        XCTAssertEqual(flow.destination, first)
        XCTAssertEqual(flow.waypoints, reordered.map(\.point))
        XCTAssertEqual(flow.pickupNote, "")
        XCTAssertFalse(flow.quotes.isEmpty)
        flow.resetToHome()
    }

    func testRouteOrderRejectsMissingOrInventedPlaces() {
        let env = AppEnvironment()
        let flow = env.flow
        flow.stops = [DemoPlaces.mlimaniCity]
        flow.destination = DemoPlaces.airport
        let original = flow.orderedPlaces
        XCTAssertFalse(flow.reorderRoute(Array(original.dropLast())))
        XCTAssertFalse(flow.reorderRoute([original[0], original[0], original[2]]))
        XCTAssertEqual(flow.orderedPlaces, original)
        flow.resetToHome()
    }

    func testReorderingBeforeDestinationDoesNotPromoteAStop() {
        let env = AppEnvironment()
        let flow = env.flow
        let pickup = flow.pickup
        let stop = DemoPlaces.mlimaniCity
        flow.stops = [stop]
        XCTAssertTrue(flow.reorderRoute([stop, pickup]))
        XCTAssertEqual(flow.pickup, stop)
        XCTAssertEqual(flow.stops, [pickup])
        XCTAssertNil(flow.destination)
        flow.resetToHome()
    }

    func testAllFiveProceduralVehiclesRenderWithTransparentEdgesAndShadows() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for tier in RideTier.allCases {
            let miniature = VehicleMiniatureScene(tier: tier)
            miniature.update(heading: 35, bearing: 0, pitch: 45)
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = miniature.scene
            renderer.pointOfView = miniature.camera
            let prepared = await withCheckedContinuation { continuation in
                renderer.prepare([miniature.scene.rootNode]) { ready in continuation.resume(returning: ready) }
            }
            XCTAssertTrue(prepared)
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 256, height: 256), antialiasingMode: .multisampling4X)
            let pixels = try rgba(image)
            var opaque = 0
            var transparent = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[i + 3] > 240 { opaque += 1 }
                if pixels[i + 3] < 3 { transparent += 1 }
            }
            XCTAssertGreaterThan(opaque, 400, "\(tier) must render a solid vehicle, not an empty view")
            XCTAssertGreaterThan(transparent, 35_000, "\(tier) must not render a floor plate")
            // Compare shadows on/off outside the opaque body rather than count antialiasing as a shadow.
            miniature.setGroundShadowVisible(false)
            let noShadow = renderer.snapshot(atTime: 1, with: CGSize(width: 256, height: 256), antialiasingMode: .multisampling4X)
            let baseline = try rgba(noShadow)
            var shadowPixels = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                if baseline[i + 3] < 3 && pixels[i + 3] > 8 && pixels[i + 3] < 200 { shadowPixels += 1 }
            }
            XCTAssertGreaterThan(shadowPixels, 30, "\(tier) must cast a visible translucent ground shadow")
            let attachment = XCTAttachment(image: image)
            attachment.name = "procedural-\(tier.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            miniature.setGroundShadowVisible(true)
            miniature.update(heading: 145, bearing: 0, pitch: 55)
            let catalogueImage = renderer.snapshot(atTime: 2, with: CGSize(width: 512, height: 512), antialiasingMode: .multisampling4X)
            let catalogue = XCTAttachment(image: catalogueImage)
            catalogue.name = "catalogue-\(tier.rawValue)"
            catalogue.lifetime = .keepAlways
            add(catalogue)
        }
    }

    func testShadowSourceVerticesRespectTheModelBounds() {
        let root = ProceduralVehicleFactory.shadowGeometry(for: .economy)
        let vertices = VehicleGroundShadow.extractTriangles(from: root)
        let bounds = root.boundingBox
        var lower = SIMD3<Float>(repeating: .infinity)
        var upper = SIMD3<Float>(repeating: -.infinity)
        for vertex in vertices {
            lower = SIMD3(min(lower.x, vertex.x), min(lower.y, vertex.y), min(lower.z, vertex.z))
            upper = SIMD3(max(upper.x, vertex.x), max(upper.y, vertex.y), max(upper.z, vertex.z))
        }
        XCTAssertEqual(lower.x, bounds.min.x, accuracy: 0.02, "Actual vertices \(lower)...\(upper)")
        XCTAssertEqual(upper.z, bounds.max.z, accuracy: 0.02, "Actual vertices \(lower)...\(upper)")
        XCTAssertEqual(upper.y, bounds.max.y, accuracy: 0.02, "Actual vertices \(lower)...\(upper)")
    }

    func testVehicleShadowsStayLightAndCloseToTheBody() throws {
        for tier in RideTier.allCases {
            let vehicle = ProceduralVehicleFactory.makeVehicle(for: tier)
            let (low, high) = vehicle.boundingBox
            let pixels = try rgba(VehicleGroundShadow.image(for: tier, direction: 6))
            var peak: UInt8 = 0
            var spill = 0
            var minPixel = SIMD2<Int>(256, 256)
            var maxPixel = SIMD2<Int>(0, 0)
            let shadowBounds = ProceduralVehicleFactory.shadowGeometry(for: tier).boundingBox
            for y in 0..<256 {
                for x in 0..<256 {
                    let alpha = pixels[(y * 256 + x) * 4 + 3]
                    peak = max(peak, alpha)
                    if alpha > 8 {
                        minPixel = SIMD2(min(minPixel.x, x), min(minPixel.y, y))
                        maxPixel = SIMD2(max(maxPixel.x, x), max(maxPixel.y, y))
                    }
                    let worldX = Float(x) / 256 * Float(VehicleGroundShadow.extent) - Float(VehicleGroundShadow.extent) / 2
                    let worldZ = Float(y) / 256 * Float(VehicleGroundShadow.extent) - Float(VehicleGroundShadow.extent) / 2
                    if alpha > 8 && (worldX < low.x - 0.48 || worldX > high.x + 0.48 || worldZ < low.z - 0.48 || worldZ > high.z + 0.48) {
                        spill += 1
                    }
                }
            }
            XCTAssertLessThanOrEqual(peak, 90, "\(tier) must not become a dense double-shadow blob")
            XCTAssertEqual(spill, 0, "\(tier) shadow must stay close to its footprint; visible=\(low)...\(high), shadowMesh=\(shadowBounds), pixels=\(minPixel)...\(maxPixel)")
        }
    }

    func testShadowPlaneStaysHorizontalAtEveryHeading() throws {
        let miniature = VehicleMiniatureScene(tier: .economy)
        let shadow = try XCTUnwrap(miniature.scene.rootNode.childNode(withName: "geometry-ground-shadow", recursively: true))
        for heading in [0.0, 45, 90, 145, 270] {
            miniature.update(heading: heading, bearing: 35, pitch: 45)
            let normal = shadow.simdConvertVector(SIMD3<Float>(0, 0, 1), to: miniature.scene.rootNode)
            XCTAssertEqual(abs(normal.y), 1, accuracy: 0.001)
            XCTAssertEqual(normal.x, 0, accuracy: 0.001)
            XCTAssertEqual(normal.z, 0, accuracy: 0.001)
        }
    }

    func testUncachedVehicleShadowDoesNotBlockLaunch() {
        // These headings are not used by startup thumbnails. Warm the mesh, not the shadow cache.
        for tier in RideTier.allCases {
            _ = ProceduralVehicleFactory.makeVehicle(for: tier)
            for direction in [11, 12] {
                let started = ContinuousClock.now
                let image = VehicleGroundShadow.image(for: tier, direction: direction)
                let elapsed = started.duration(to: .now)
                XCTAssertNotNil(image.cgImage)
                XCTAssertLessThan(elapsed, .seconds(0.5), "\(tier) uncached shadow must not stall the UI thread: \(elapsed)")
            }
        }
    }

    func testProjectedShadowsHaveTransparentEdgesAndChangeWithHeading() throws {
        for tier in RideTier.allCases {
            let first = try rgba(VehicleGroundShadow.image(for: tier, direction: 0))
            let turned = try rgba(VehicleGroundShadow.image(for: tier, direction: 6))
            var visible = 0
            var changed = 0
            for y in 0..<256 {
                for x in 0..<256 {
                    let offset = (y * 256 + x) * 4
                    let alpha = first[offset + 3]
                    if alpha > 15 { visible += 1 }
                    if abs(Int(alpha) - Int(turned[offset + 3])) > 10 { changed += 1 }
                    if x < 3 || x > 252 || y < 3 || y > 252 {
                        XCTAssertLessThan(alpha, 3, "No rectangular floor edge for \(tier)")
                    }
                    XCTAssertLessThan(alpha, 180, "The map must remain visible through the shadow")
                }
            }
            XCTAssertGreaterThan(visible, 500, "\(tier) needs a real ground footprint")
            XCTAssertGreaterThan(changed, 100, "\(tier) shadow must follow light direction")
        }
        XCTAssertEqual(VehicleGroundShadow.direction(for: -15), 23)
        XCTAssertEqual(VehicleGroundShadow.direction(for: 360), 0)
    }

    func testPinsStayAtGroundCoordinateAcrossZoomBearingAndLabelChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let controller = UIViewController()
        window.rootViewController = controller
        let origin = DarEsSalaam.upanga
        // Local, network-independent style: exercises Mapbox's actual projection and annotation layout.
        let json = ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#F2F1EE"}}]}"##
        let options = MapInitOptions(cameraOptions: CameraOptions(center: origin.coordinate, zoom: 15, pitch: 45), styleURI: nil, styleJSON: json)
        let map = MapView(frame: window.bounds, mapInitOptions: options)
        map.presentationTransactionMode = .sync
        controller.view.addSubview(map)
        let loaded = expectation(description: "local style loaded")
        let token = map.mapboxMap.onStyleLoaded.observeNext { _ in loaded.fulfill() }
        window.makeKeyAndVisible()
        defer {
            token.cancel()
            map.viewAnnotations.removeAll()
            window.isHidden = true
            oldWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [loaded], timeout: 10)
        let coordinator = TripMapView.Coordinator(parent: TripMapView(camera: .constant(.automatic)))
        coordinator.mapView = map
        coordinator.updatePin(.pickup, at: origin, label: "4 min")
        let annotation = try XCTUnwrap(map.viewAnnotations.allAnnotations.first(where: {
            $0.variableAnchors.first?.anchor == .bottomLeft
        }))
        for zoom in [13.0, 15.0, 17.0] {
            for bearing in [0.0, 75.0] {
                map.mapboxMap.setCamera(to: CameraOptions(center: origin.offset(eastMetres: 40, northMetres: 30).coordinate, zoom: zoom, bearing: bearing, pitch: 45))
                coordinator.updatePin(.pickup, at: origin, label: zoom == 15 ? "A much longer pickup label" : "2 min")
                var error: CGFloat = .infinity
                for _ in 0..<80 {
                    annotation.view.layoutIfNeeded()
                    let actual = annotation.view.convert(CGPoint(x: 8 + MapPin.headSize / 2, y: annotation.view.bounds.height - MapPin.baseSize / 2), to: map)
                    let expected = map.mapboxMap.point(for: origin.coordinate)
                    error = hypot(actual.x - expected.x, actual.y - expected.y)
                    if !annotation.view.isHidden && error < 1.5 { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                XCTAssertLessThan(error, 1.5, "ground-dot error at zoom \(zoom), bearing \(bearing)")
                XCTAssertFalse(annotation.view.isHidden)
            }
        }
    }

    func testPremiumMinivanHasAnUprightCabinDistinctFromTheBasicHatchback() {
        let minivan = VehicleCoachwork(style: .minivan)
        let hatchback = VehicleCoachwork(style: .hatchback)
        let sedan = VehicleCoachwork(style: .sedan)
        XCTAssertEqual(sedan.point(z: 0.15, contour: 0).y, 1.615, accuracy: 0.001)
        XCTAssertEqual(sedan.point(z: 1.42, contour: 0).y, 1.235, accuracy: 0.001)
        XCTAssertLessThan(sedan.point(z: 1.42, contour: 0).y, hatchback.point(z: 1.42, contour: 0).y, "The reference sedan retains a sloping rear window, unlike the hatchback")
        XCTAssertEqual(sedan.wheelbase, 1.30)
        XCTAssertEqual(sedan.wheelRadius, 0.44)
        XCTAssertGreaterThan(minivan.point(z: 1.42, contour: 0).y, sedan.point(z: 1.42, contour: 0).y + 0.7)
        XCTAssertGreaterThan(minivan.wheelbase, hatchback.wheelbase)
        XCTAssertGreaterThan(minivan.rearZ - minivan.frontZ, hatchback.rearZ - hatchback.frontZ)
        XCTAssertGreaterThan(minivan.point(z: 1.85, contour: 0).y, 1.9, "The passenger cabin must extend to the rear, not taper like a sedan")
        XCTAssertGreaterThan(hatchback.point(z: 1.26, contour: 0).y, 1.4, "The hatchback needs a full-height rear cabin")
        XCTAssertLessThan(hatchback.point(z: hatchback.rearZ, contour: 0).y, 1.0, "The liftgate must fall steeply behind the roof")
        for tier in [RideTier.economy, .comfort, .premium] {
            let vehicle = ProceduralVehicleFactory.makeVehicle(for: tier)
            let (minimum, maximum) = vehicle.boundingBox
            XCTAssertEqual(maximum.z - minimum.z, 3.4, accuracy: 0.01, "Equal map prominence must survive the new silhouettes")
            XCTAssertEqual(minimum.y, 0, accuracy: 0.01)
        }
    }

    func testReferenceSedanHasWhiteCoachworkDiscWheelsAndSeparatedHeadlights() throws {
        let root = ProceduralVehicleFactory.shadowGeometry(for: .comfort)
        let body = try XCTUnwrap(root.childNode(withName: "continuous-sedan-coachwork", recursively: true)?.geometry)
        let paint = try XCTUnwrap(body.materials.first)
        XCTAssertEqual(paint.name, "sedan-white-paint")
        let color = try XCTUnwrap(paint.diffuse.contents as? UIColor)
        var white: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getWhite(&white, alpha: &alpha))
        XCTAssertEqual(white, 0.94, accuracy: 0.001)
        var wheels = 0, headlights = 0, handles = 0, mirrors = 0
        root.enumerateChildNodes { node, _ in
            switch node.name {
            case "sedan-aero-disc": wheels += 1
            case "sedan-headlight":
                headlights += 1
                let bounds = node.boundingBox
                XCTAssertLessThan(bounds.max.x - bounds.min.x, 0.40, "Each end lamp must stay short, not become a continuous white strip")
                XCTAssertTrue(bounds.min.x > 0.25 || bounds.max.x < -0.25, "The centre of the black band stays unlit")
            case "sedan-black-handle": handles += 1
            case "sedan-black-mirror": mirrors += 1
            default: break
            }
        }
        XCTAssertEqual(wheels, 8, "Four wheels, each closed by an aero disc on both axle faces")
        XCTAssertEqual(headlights, 2)
        XCTAssertEqual(handles, 4)
        XCTAssertEqual(mirrors, 2)
        XCTAssertNotNil(root.childNode(withName: "sedan-black-front-band", recursively: true))
        XCTAssertNotNil(root.childNode(withName: "sedan-lower-intake", recursively: true))
        XCTAssertNotNil(root.childNode(withName: "sedan-panoramic-roof", recursively: true))
    }

    func testReferenceSedanRendersAtCatalogueAndMapAngles() async throws {
        let miniature = VehicleMiniatureScene(tier: .comfort)
        let renderer = SCNRenderer(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: nil)
        renderer.scene = miniature.scene
        renderer.pointOfView = miniature.camera
        let ready = await withCheckedContinuation { continuation in
            renderer.prepare([miniature.scene.rootNode]) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(ready)
        miniature.setGroundShadowVisible(false)
        for (name, heading, pitch) in [("reference-three-quarter", 135.0, 72.0), ("front", 180.0, 72.0), ("side", 90.0, 72.0), ("map", 135.0, 45.0)] {
            miniature.update(heading: heading, bearing: 0, pitch: pitch)
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 768, height: 768), antialiasingMode: .multisampling4X)
            let pixels = try rgba(image)
            var whiteBody = 0, darkDetails = 0, transparent = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[index + 3] < 3 { transparent += 1 }
                guard pixels[index + 3] > 240 else { continue }
                if pixels[index] > 150 && pixels[index + 1] > 150 && pixels[index + 2] > 150 { whiteBody += 1 }
                if pixels[index] < 110 && pixels[index + 1] < 110 && pixels[index + 2] < 110 { darkDetails += 1 }
            }
            XCTAssertGreaterThan(whiteBody, 300, "White paint/discs must be visible from \(name)")
            XCTAssertGreaterThan(darkDetails, 100, "Tyres/glass/trim must remain distinct from \(name)")
            XCTAssertGreaterThan(transparent, 35_000, "No floor or background image")
            let attachment = XCTAttachment(image: image)
            attachment.name = "sedan-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testFleetUsesOnlyNeutralAndWarmMetallicBodyMaterials() {
        for tier in RideTier.allCases {
            let root = ProceduralVehicleFactory.makeVehicle(for: tier)
            var materialCount = 0
            func inspect(_ node: SCNNode) {
                for material in node.geometry?.materials ?? [] {
                    guard let color = material.diffuse.contents as? UIColor else { continue }
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { continue }
                    materialCount += 1
                    // Neutral paints, warm champagne and red safety lights; never green/cyan paint.
                    XCTAssertGreaterThanOrEqual(r + 0.02, g, "Green bodywork returned for \(tier)")
                    XCTAssertGreaterThanOrEqual(g + 0.02, b, "Blue/turquoise bodywork returned for \(tier)")
                }
                for child in node.childNodes { inspect(child) }
            }
            inspect(root)
            XCTAssertGreaterThan(materialCount, 3)
        }
    }

    func testLightMonochromeKeepsStandardBuildingsAndPlaces() {
        let config = TripMapView.Coordinator.standardConfig(for: .monochromeDay)
        XCTAssertEqual(config["showPointOfInterestLabels"] as? Bool, true)
        XCTAssertEqual(config["showLandmarkIcons"] as? Bool, true)
        XCTAssertEqual(config["showLandmarkIconLabels"] as? Bool, true)
        XCTAssertEqual(config["showPlaceLabels"] as? Bool, true)
        XCTAssertEqual(config["densityPointOfInterestLabels"] as? Int, 5)
        XCTAssertEqual(config["colorModePointOfInterestLabels"] as? String, "default")
        XCTAssertEqual(config["theme"] as? String, "monochrome")
        XCTAssertEqual(config["lightPreset"] as? String, "day")
        XCTAssertFalse(MapStyleOption.monochromeDay.isDark, "Pins and banners must use dark ink on the light map")
        XCTAssertEqual(AppSettings(defaults: UserDefaults(suiteName: "twende.tests.defaultStyle") ?? .standard).mapStyle, .monochromeDay, "Light monochrome/day stays the shipped default")
        XCTAssertEqual(config["show3dObjects"] as? Bool, true)
    }

    func testVehicleZoomCurveIsContinuousAndClamped() {
        XCTAssertEqual(ProceduralTukTukMarker.canvasSide(at: 10), 28)
        XCTAssertEqual(ProceduralTukTukMarker.canvasSide(at: 15), 46)
        XCTAssertEqual(ProceduralTukTukMarker.canvasSide(at: 16), 46 * sqrt(2), accuracy: 0.01)
        XCTAssertEqual(ProceduralTukTukMarker.canvasSide(at: 21), 88)
        XCTAssertEqual(ProceduralTukTukMarker.canvasSide(at: .nan), 46)
        XCTAssertLessThan(ProceduralTukTukMarker.canvasSide(at: 15.01) - ProceduralTukTukMarker.canvasSide(at: 15), 0.2)
    }

    func testBannersSwitchSidesAndStayInsideEdges() {
        let viewport = CGRect(x: 12, y: 60, width: 366, height: 680)
        let size = CGSize(width: 110, height: 26)
        let right = MapBannerLayout.frame(anchor: CGPoint(x: 100, y: 300), size: size, viewport: viewport)
        XCTAssertEqual(right.minX, 117)
        let left = MapBannerLayout.frame(anchor: CGPoint(x: 350, y: 300), size: size, viewport: viewport)
        XCTAssertEqual(left.maxX, 333)
        let wide = MapBannerLayout.frame(anchor: CGPoint(x: 195, y: 300), size: CGSize(width: 180, height: 26), viewport: viewport)
        XCTAssertLessThan(wide.maxY, 261)
        let long = MapBannerLayout.frame(anchor: CGPoint(x: 195, y: 300), size: CGSize(width: 260, height: 44), viewport: viewport)
        XCTAssertTrue(viewport.contains(long))
        XCTAssertLessThan(long.maxY, 261, "A long place label must not cover the marker head")
        for anchor in [CGPoint(x: 0, y: 10), CGPoint(x: 390, y: 10), CGPoint(x: 390, y: 750), CGPoint(x: 0, y: 750)] {
            XCTAssertTrue(viewport.contains(MapBannerLayout.frame(anchor: anchor, size: size, viewport: viewport)))
        }
    }

    func testTabStacksRemainIndependentAndBookingReturnsHome() {
        let activity = MenuNavigation()
        let account = MenuNavigation()
        activity.path = [.tripDetail("trip"), .support]
        account.path = [.payments]
        activity.pop()
        XCTAssertEqual(account.path, [.payments])
        XCTAssertEqual(activity.path, [.tripDetail("trip")])
        let env = AppEnvironment()
        env.flow.selectedTab = .account
        env.flow.beginSearch()
        XCTAssertEqual(env.flow.selectedTab, .home)
        XCTAssertEqual(env.flow.path, [.search])
        env.flow.resetToHome()
    }

    private func rgba(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 256, height: 256))
            return true
        }
        XCTAssertTrue(rendered)
        return pixels
    }
}
