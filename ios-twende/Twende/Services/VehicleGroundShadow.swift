import CoreImage
import SceneKit
import UIKit
import simd

/// Mapbox view annotations do not participate in the map's light/shadow pass. Project the actual
/// miniature triangles onto Y=0 and soften the resulting alpha mask; never render a visible floor.
/// The 24-direction cache is shared by the fleet, so moving a marker doesn't rerasterize its shadow.
enum VehicleGroundShadow {
    static let extent: CGFloat = 6.2
    /// High softbox keeps the cast close to the tyres instead of stretching a second vehicle beside it.
    static let lightHeight: Float = 32
    private static let resolution: Int = 256
    private static let context: CIContext = CIContext(options: [.cacheIntermediates: false])
    private static var triangles: [RideTier: [SIMD3<Float>]] = [:]
    private static var images: [RideTier: [Int: UIImage]] = [:]
    private static var contactImages: [RideTier: UIImage] = [:]

    static func direction(for heading: Double) -> Int {
        let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int((normalized / 15).rounded()) % 24
    }

    static func image(for tier: RideTier, direction: Int) -> UIImage {
        if let cached = images[tier]?[direction] { return cached }
        let vertices = triangles[tier] ?? extractTriangles(from: ProceduralVehicleFactory.shadowGeometry(for: tier))
        triangles[tier] = vertices
        // Sun and vehicle rotate with map bearing together, leaving only vehicle heading in local space.
        let azimuth = Float(Double(direction * 15 - 35) * .pi / 180)
        let lightSlope = SIMD2<Float>(sin(azimuth), cos(azimuth)) * (6.0 / lightHeight)
        let cast = mask(vertices, slope: lightSlope)
        // Contact comes only from low surfaces. Projecting the roof again created a broad double blob.
        let contact = contactImages[tier] ?? blurred(mask(vertices, slope: .zero, contactOnly: true), radius: 0.9)
        contactImages[tier] = contact
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: resolution, height: resolution)
        let rect = CGRect(origin: .zero, size: size)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            blurred(cast, radius: 1.5).draw(in: rect, blendMode: .normal, alpha: 0.22)
            contact.draw(in: rect, blendMode: .normal, alpha: 0.12)
        }
        images[tier, default: [:]][direction] = image
        return image
    }

    private static func mask(_ vertices: [SIMD3<Float>], slope: SIMD2<Float>, contactOnly: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: resolution, height: resolution)
        let pixelsPerUnit = CGFloat(resolution) / extent
        func project(_ point: SIMD3<Float>) -> CGPoint {
            CGPoint(x: (CGFloat(point.x - point.y * slope.x) + extent / 2) * pixelsPerUnit,
                    y: (CGFloat(point.z - point.y * slope.y) + extent / 2) * pixelsPerUnit)
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.black.cgColor)
            // The mask is blurred afterwards. Opaque, non-antialiased batches form the same union
            // without asking Core Graphics to resolve tens of thousands of overlapping subpaths.
            // The unbounded winding path previously spent seconds here on the main thread at launch.
            context.setShouldAntialias(false)
            let verticesPerBatch = 96 * 3
            for start in stride(from: 0, to: vertices.count, by: verticesPerBatch) {
                let path = CGMutablePath()
                let end = min(start + verticesPerBatch, vertices.count)
                for index in stride(from: start, to: end - 2, by: 3) {
                    if contactOnly && max(vertices[index].y, max(vertices[index + 1].y, vertices[index + 2].y)) > 0.28 { continue }
                    let a = project(vertices[index])
                    let b = project(vertices[index + 1])
                    let c = project(vertices[index + 2])
                    let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                    guard area.isFinite, abs(area) > 0.0001 else { continue }
                    path.move(to: a)
                    path.addLine(to: area > 0 ? b : c)
                    path.addLine(to: area > 0 ? c : b)
                    path.closeSubpath()
                }
                context.addPath(path)
                context.fillPath(using: .winding)
            }
        }
    }

    private static func blurred(_ image: UIImage, radius: Double) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let input = CIImage(cgImage: cgImage)
        let output = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        guard let result = context.createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: result)
    }

    static func extractTriangles(from root: SCNNode) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        func append(_ node: SCNNode, transform: simd_float4x4) {
            guard let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first,
                  source.usesFloatComponents, source.componentsPerVector >= 3,
                  source.bytesPerComponent == MemoryLayout<Float>.size else { return }
            let localPositions: [SIMD3<Float>] = source.data.withUnsafeBytes { bytes in
                (0..<source.vectorCount).map { index in
                    let offset = source.dataOffset + source.dataStride * index
                    let x = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                    let y = bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                    let z = bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                    return SIMD3(x, y, z)
                }
            }
            // SceneKit primitives can expose a canonical mesh in their CPU source while applying
            // their dimensions privately during rendering. Reading that mesh as-is projects tiny
            // trim pieces as full-sized boxes, even below the road, producing the ragged blob.
            var sourceScale = SIMD3<Float>(repeating: 1)
            var sourceOffset = SIMD3<Float>.zero
            if geometry is SCNBox || geometry is SCNCylinder || geometry is SCNSphere || geometry is SCNTorus,
               let first = localPositions.first {
                var low = first, high = first
                for position in localPositions {
                    low = simd_min(low, position)
                    high = simd_max(high, position)
                }
                let bounds = geometry.boundingBox
                let targetLow = SIMD3(bounds.min.x, bounds.min.y, bounds.min.z)
                let targetHigh = SIMD3(bounds.max.x, bounds.max.y, bounds.max.z)
                for axis in 0..<3 where high[axis] - low[axis] > 0.000001 {
                    sourceScale[axis] = (targetHigh[axis] - targetLow[axis]) / (high[axis] - low[axis])
                    sourceOffset[axis] = targetLow[axis] - low[axis] * sourceScale[axis]
                }
            }
            let positions: [SIMD3<Float>] = localPositions.map { local in
                let corrected = local * sourceScale + sourceOffset
                let world = transform * SIMD4<Float>(corrected.x, corrected.y, corrected.z, 1)
                return SIMD3(world.x, world.y, world.z)
            }
            for element in geometry.elements {
                guard element.primitiveType == .triangles || element.primitiveType == .triangleStrip else { continue }
                let data = element.data
                let count = data.count / max(element.bytesPerIndex, 1)
                let indices: [Int] = data.withUnsafeBytes { bytes in
                    (0..<count).map { index in
                        let offset = index * element.bytesPerIndex
                        switch element.bytesPerIndex {
                        case 1: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                        case 2: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        case 4: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        default: return -1
                        }
                    }
                }
                let step = element.primitiveType == .triangles ? 3 : 1
                for index in stride(from: 0, to: max(0, indices.count - 2), by: step) {
                    let a = indices[index], b = indices[index + 1], c = indices[index + 2]
                    guard positions.indices.contains(a), positions.indices.contains(b), positions.indices.contains(c) else { continue }
                    result.append(contentsOf: [positions[a], positions[b], positions[c]])
                }
            }
        }
        func visit(_ node: SCNNode, transform: simd_float4x4) {
            append(node, transform: transform)
            for child in node.childNodes {
                visit(child, transform: transform * child.simdTransform)
            }
        }
        visit(root, transform: matrix_identity_float4x4)
        return result
    }
}
