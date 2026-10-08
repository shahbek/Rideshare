import SceneKit
import UIKit
import simd

/// Existing fleet geometry converted once to the map's packed Metal vertex layout; no new vehicle art.
nonisolated struct DioramaFleetMesh: Sendable {
    let vertices: [BuildingRenderVertex]
    let indices: [UInt32]

    @MainActor private static var cache: [RideTier: DioramaFleetMesh] = [:]

    @MainActor static func make(for tier: RideTier) -> DioramaFleetMesh {
        if let cached = cache[tier] { return cached }
        let root = ProceduralVehicleFactory.shadowGeometry(for: tier)
        var vertices: [BuildingRenderVertex] = []
        var indices: [UInt32] = []
        let metricScale = Float(tier.modelLengthMetres / 3.4)
        func values(_ source: SCNGeometrySource?) -> [SIMD3<Float>] {
            guard let source, source.usesFloatComponents, source.bytesPerComponent == 4,
                  source.componentsPerVector >= 3 else { return [] }
            return source.data.withUnsafeBytes { bytes in
                (0..<source.vectorCount).map { i in
                    let offset = source.dataOffset + i * source.dataStride
                    guard offset + 12 <= bytes.count else { return .zero }
                    return SIMD3(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                                 bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                                 bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
                }
            }
        }
        func visit(_ node: SCNNode, parent: simd_float4x4) {
            let transform = parent * node.simdTransform
            if let geometry = node.geometry {
                let positions = values(geometry.sources(for: .vertex).first)
                let normals = values(geometry.sources(for: .normal).first)
                let colors = values(geometry.sources(for: .color).first)
                let uvSource = geometry.sources(for: .texcoord).first
                let uv: [SIMD2<Float>] = uvSource.map { source in
                    guard source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 2 else { return [] }
                    return source.data.withUnsafeBytes { bytes in
                        (0..<source.vectorCount).map { i in
                            let offset = source.dataOffset + i * source.dataStride
                            guard offset + 8 <= bytes.count else { return .zero }
                            return SIMD2(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                                         bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self))
                        }
                    }
                } ?? []
                var sourceScale = SIMD3<Float>(repeating: 1), sourceOffset = SIMD3<Float>.zero
                if geometry is SCNBox || geometry is SCNCylinder || geometry is SCNSphere || geometry is SCNTorus,
                   let first = positions.first {
                    var lo = first, hi = first
                    for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
                    let bounds = geometry.boundingBox
                    let targetLo = SIMD3(bounds.min.x, bounds.min.y, bounds.min.z)
                    let targetHi = SIMD3(bounds.max.x, bounds.max.y, bounds.max.z)
                    for axis in 0..<3 where hi[axis] - lo[axis] > 1e-6 {
                        sourceScale[axis] = (targetHi[axis] - targetLo[axis]) / (hi[axis] - lo[axis])
                        sourceOffset[axis] = targetLo[axis] - lo[axis] * sourceScale[axis]
                    }
                }
                let normalTransform = simd_transpose(simd_inverse(simd_float3x3(
                    SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                    SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                    SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))))
                for (elementIndex, element) in geometry.elements.enumerated() {
                    guard element.primitiveType == .triangles || element.primitiveType == .triangleStrip else { continue }
                    let material = geometry.materials.isEmpty ? nil : geometry.materials[elementIndex % geometry.materials.count]
                    let color = material?.diffuse.contents as? UIColor ?? UIColor.white
                    var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
                    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    let base = SIMD4(Float(red), Float(green), Float(blue), 1)
                    var pixels: [UInt8] = []
                    var imageWidth: Int = 0, imageHeight: Int = 0
                    if let image = (material?.diffuse.contents as? UIImage)?.cgImage {
                        imageWidth = min(image.width, 1024); imageHeight = min(image.height, 1024)
                        pixels = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
                        pixels.withUnsafeMutableBytes { bytes in
                            if let context = CGContext(data: bytes.baseAddress, width: imageWidth, height: imageHeight,
                                bitsPerComponent: 8, bytesPerRow: imageWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                                context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
                            }
                        }
                    }
                    let roughness = (material?.roughness.contents as? NSNumber)?.floatValue ?? 0.4
                    let glass: Float = roughness < 0.25 && red + green + blue < 0.6 ? 6 : 0
                    let emission: Float = (material?.emission.contents as? UIColor) != nil && material?.lightingModel == .constant ? 4 : 0
                    let firstVertex = UInt32(vertices.count)
                    for i in positions.indices {
                        let p = positions[i] * sourceScale + sourceOffset
                        let world = transform * SIMD4(p, 1)
                        var n = normals.indices.contains(i) ? normals[i] : SIMD3<Float>(0, 1, 0)
                        n = normalTransform * (n / simd_max(sourceScale, SIMD3(repeating: 1e-6)))
                        n = simd_length_squared(n) > 1e-8 ? simd_normalize(n) : SIMD3(0, 1, 0)
                        var tint = colors.indices.contains(i) ? SIMD4(colors[i], 1) * base : base
                        if !pixels.isEmpty, uv.indices.contains(i), uv[i].x.isFinite, uv[i].y.isFinite {
                            let x = min(imageWidth - 1, max(0, Int(uv[i].x * Float(imageWidth - 1))))
                            let y = min(imageHeight - 1, max(0, Int((1 - uv[i].y) * Float(imageHeight - 1))))
                            let offset = (y * imageWidth + x) * 4
                            tint *= SIMD4(Float(pixels[offset]) / 255, Float(pixels[offset + 1]) / 255,
                                          Float(pixels[offset + 2]) / 255, 1)
                        }
                        vertices.append(BuildingRenderVertex(position: SIMD4(world.x * metricScale, -world.z * metricScale, world.y * metricScale, 1),
                            normal: SIMD4(n.x, -n.z, n.y, 0), color: tint,
                            appearance: SIMD4(1, glass > 0 ? glass : 14, roughness, emission)))
                    }
                    let local: [UInt32] = element.data.withUnsafeBytes { bytes in
                        (0..<(bytes.count / max(1, element.bytesPerIndex))).map { i in
                            let offset = i * element.bytesPerIndex
                            switch element.bytesPerIndex {
                            case 1: return UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                            case 2: return UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                            case 4: return bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                            default: return UInt32.max
                            }
                        }
                    }
                    let step = element.primitiveType == .triangles ? 3 : 1
                    for i in stride(from: 0, to: max(0, local.count - 2), by: step) {
                        var a = local[i], b = local[i + 1]
                        let c = local[i + 2]
                        if element.primitiveType == .triangleStrip, i % 2 == 1 { swap(&a, &b) }
                        guard Int(a) < positions.count, Int(b) < positions.count, Int(c) < positions.count else { continue }
                        indices.append(contentsOf: [a + firstVertex, b + firstVertex, c + firstVertex])
                    }
                }
            }
            for child in node.childNodes { visit(child, parent: transform) }
        }
        visit(root, parent: matrix_identity_float4x4)
        let mesh = DioramaFleetMesh(vertices: vertices, indices: indices)
        cache[tier] = mesh
        return mesh
    }
}
