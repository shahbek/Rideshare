import Foundation
import CoreLocation
import CoreGraphics
import simd

/// The exact SDK-to-Metal camera transform, shared without querying hundreds of SDK points on main.
nonisolated final class DioramaViewport: @unchecked Sendable {
    static let shared = DioramaViewport()
    struct Snapshot: Sendable {
        let transform: simd_double4x4
        let origin: CLLocationCoordinate2D
        let latitude: Double
        let longitude: Double
        let zoom: Double
        let bearing: Double
        let pitch: Double
    }
    private let lock = NSLock()
    private var value: Snapshot?

    func publish(_ snapshot: Snapshot) {
        lock.lock(); value = snapshot; lock.unlock()
    }
    func snapshot() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }; return value
    }

    /// Homogeneous clipping handles rotated views, horizon crossings and tiles containing the viewport.
    /// Ground area is the priority metric; a raised envelope conservatively retains tall tile contents.
    static func area(tile: DioramaTileID, snapshot: Snapshot, viewport: CGRect, height: Double = 0) -> Double {
        let rect = DioramaProjection(origin: snapshot.origin).rect(of: tile)
        var polygon = [DV2(rect.minX, rect.minY), DV2(rect.maxX, rect.minY),
                       DV2(rect.maxX, rect.maxY), DV2(rect.minX, rect.maxY)]
            .map { snapshot.transform * SIMD4($0.x, $0.y, height, 1) }
        let planes: [SIMD4<Double>] = [SIMD4(0, 0, 0, 1), SIMD4(1, 0, 0, 1),
            SIMD4(-1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, -1, 0, 1)]
        for plane in planes {
            guard !polygon.isEmpty else { return 0 }
            var output: [SIMD4<Double>] = []
            var previous = polygon[polygon.count - 1]
            var previousDistance = simd_dot(previous, plane) - 1e-8
            for current in polygon {
                let distance = simd_dot(current, plane) - 1e-8
                if (distance >= 0) != (previousDistance >= 0) {
                    let t = previousDistance / (previousDistance - distance)
                    output.append(previous + (current - previous) * t)
                }
                if distance >= 0 { output.append(current) }
                previous = current; previousDistance = distance
            }
            polygon = output
        }
        let points = polygon.map { CGPoint(x: viewport.midX + $0.x / $0.w * viewport.width / 2,
                                           y: viewport.midY - $0.y / $0.w * viewport.height / 2) }
        return screenArea(points, viewport: viewport)
    }

    static func screenArea(_ input: [CGPoint], viewport: CGRect) -> Double {
        var polygon = input
        guard input.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return 0 }
        for edge in 0..<4 {
            guard !polygon.isEmpty else { return 0 }
            func distance(_ p: CGPoint) -> Double {
                switch edge {
                case 0: return p.x - viewport.minX
                case 1: return viewport.maxX - p.x
                case 2: return p.y - viewport.minY
                default: return viewport.maxY - p.y
                }
            }
            var output: [CGPoint] = []
            var previous = polygon[polygon.count - 1]
            var pd = distance(previous)
            for current in polygon {
                let d = distance(current)
                if (d >= 0) != (pd >= 0) {
                    let t = pd / (pd - d)
                    output.append(CGPoint(x: previous.x + (current.x - previous.x) * t,
                                          y: previous.y + (current.y - previous.y) * t))
                }
                if d >= 0 { output.append(current) }
                previous = current; pd = d
            }
            polygon = output
        }
        guard polygon.count >= 3 else { return 0 }
        var area: Double = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) * 0.5
    }
}
