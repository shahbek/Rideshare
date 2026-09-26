import Observation
import SceneKit
import Metal
import UIKit

/// Static illustrations use the same sculpted fleet as the live map. Rendered once per tier, with
/// separate overhead and catalogue cameras; no imported vehicle model is used in the visible fleet.
@Observable
final class VehicleSpriteStore {
    static let shared: VehicleSpriteStore = VehicleSpriteStore()
    private(set) var sprites: [RideTier: UIImage] = [:]
    private(set) var previews: [RideTier: UIImage] = [:]
    /// Low-angle turntable of the 3D vehicle, one frame per compass heading step (frame 0 = driving away,
    /// 4 = side profile facing right, 8 = front). The Live Activity picks the frame for the car's heading.
    private(set) var turntables: [RideTier: [UIImage]] = [:]
    static let turntableFrameCount: Int = 16
    /// Straight-down render of the same 3D vehicle, nose pointing right, for the Live Activity route line.
    private(set) var topViews: [RideTier: UIImage] = [:]
    private var hasStarted: Bool = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { @MainActor in
            for tier in RideTier.allCases {
                // GPU work submitted while backgrounded gets the process terminated; wait for the foreground.
                while UIApplication.shared.applicationState == .background {
                    try? await Task.sleep(for: .seconds(1))
                }
                let miniature = VehicleMiniatureScene(tier: tier)
                let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                renderer.scene = miniature.scene
                renderer.pointOfView = miniature.camera
                let ready = await withCheckedContinuation { continuation in
                    renderer.prepare([miniature.scene.rootNode]) { success in continuation.resume(returning: success) }
                }
                guard ready else {
                    print("[VehicleSpriteStore] procedural geometry preparation failed: \(tier.rawValue)")
                    continue
                }
                miniature.update(heading: 0, bearing: 0, pitch: 18)
                sprites[tier] = VehicleSpriteRenderer.snapshot(renderer)
                // Comfort's catalogue angle follows the supplied low three-quarter sedan reference.
                miniature.update(heading: tier == .comfort ? 135 : 145, bearing: 0, pitch: tier == .comfort ? 72 : 55)
                if tier == .comfort { miniature.setGroundShadowVisible(false) }
                previews[tier] = VehicleSpriteRenderer.snapshot(renderer)
                miniature.setGroundShadowVisible(false)
                var frames: [CGImage] = []
                for index in 0..<Self.turntableFrameCount {
                    miniature.update(heading: Double(index) * 360 / Double(Self.turntableFrameCount), bearing: 0, pitch: 72)
                    if let frame = renderer.snapshot(atTime: 0, with: CGSize(width: 256, height: 256), antialiasingMode: .multisampling4X).cgImage {
                        frames.append(frame)
                    }
                }
                turntables[tier] = VehicleSpriteRenderer.uniformCrop(frames, maxSide: 168)
                // Heading 90 with a straight-down camera puts the nose on the right of the frame.
                miniature.update(heading: 90, bearing: 0, pitch: 0)
                if let top = renderer.snapshot(atTime: 0, with: CGSize(width: 256, height: 256), antialiasingMode: .multisampling4X).cgImage {
                    topViews[tier] = VehicleSpriteRenderer.uniformCrop([top], maxSide: 120).first
                }
                miniature.setGroundShadowVisible(true)
            }
        }
    }

    func sprite(for tier: RideTier) -> UIImage? { sprites[tier] }
    func preview(for tier: RideTier) -> UIImage? { previews[tier] }
    func turntable(for tier: RideTier) -> [UIImage] { turntables[tier] ?? [] }
    func topView(for tier: RideTier) -> UIImage? { topViews[tier] }
}

/// Retained metadata for the archived imported assets and the debug-only GLB probe.
nonisolated enum ModelFrontAxis: Sendable {
    case negativeX, positiveX, negativeZ, positiveZ

    var yawTowardsNegativeZ: Float {
        switch self {
        case .negativeZ: 0
        case .positiveZ: .pi
        case .negativeX: -.pi / 2
        case .positiveX: .pi / 2
        }
    }
}

/// Transparent snapshot cropping for product illustrations only. Live map canvases must never be
/// cropped because their centre is the ground-coordinate anchor, not the model's visual centroid.
enum VehicleSpriteRenderer {
    static func snapshot(_ renderer: SCNRenderer) -> UIImage? {
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 384, height: 384), antialiasingMode: .multisampling4X)
        guard let source = image.cgImage else { return nil }
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let normalized: CGImage? = bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        guard let normalized else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let left = max(0, minX - 8), top = max(0, minY - 8)
        let rect = CGRect(x: left, y: top, width: min(width, maxX + 9) - left, height: min(height, maxY + 9) - top)
        guard let cropped = normalized.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Crops every frame to the union of their opaque bounds so a turning vehicle keeps one scale and
    /// ground line (a front view is not blown up to the width of a side view), then downsizes.
    static func uniformCrop(_ frames: [CGImage], maxSide: CGFloat) -> [UIImage] {
        guard let first = frames.first else { return [] }
        let width = first.width, height = first.height
        var minX = width, minY = height, maxX = -1, maxY = -1
        var normalized: [CGImage] = []
        for frame in frames where frame.width == width && frame.height == height {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let image: CGImage? = bytes.withUnsafeMutableBytes { storage in
                guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
                return context.makeImage()
            }
            guard let image else { continue }
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 8 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            normalized.append(image)
        }
        guard maxX >= minX, maxY >= minY else { return [] }
        let left = max(0, minX - 4), top = max(0, minY - 4)
        let rect = CGRect(x: left, y: top, width: min(width, maxX + 5) - left, height: min(height, maxY + 5) - top)
        let scale = min(1, maxSide / max(rect.width, rect.height))
        let target = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let drawer = UIGraphicsImageRenderer(size: target, format: format)
        return normalized.compactMap { image in
            guard let cropped = image.cropping(to: rect) else { return nil }
            return drawer.image { _ in UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: target)) }
        }
    }
}
