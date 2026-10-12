import SceneKit
import UIKit
import simd

/// Bakes the completed SceneKit geometry into an immutable native-map triangle buffer once per selection.
enum BuildingRenderGeometry {
    static func vertices(from scene: SCNScene, excludingAirportInstances: Bool = false) -> [BuildingRenderVertex] {
        var result: [BuildingRenderVertex] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            if excludingAirportInstances {
                var ancestor: SCNNode? = node
                while let current = ancestor {
                    if current.name?.hasPrefix(AirportInstanceGeometry.prefix) == true { return }
                    ancestor = current.parent
                }
            }
            guard let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first else { return }
            let positions = vectors(from: source)
            guard !positions.isEmpty else { return }
            let normals = geometry.sources(for: .normal).first.map { vectors(from: $0) } ?? []
            var uvs: [SIMD2<Float>]?
            let transform = node.simdWorldTransform
            let normalMatrix = simd_transpose(simd_inverse(simd_float3x3(columns: (
                SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            ))))
            for (elementIndex, element) in geometry.elements.enumerated() {
                guard element.primitiveType == .triangles || element.primitiveType == .triangleStrip,
                      [1, 2, 4].contains(element.bytesPerIndex) else { continue }
                let data = element.data
                let material = geometry.materials.isEmpty ? nil : geometry.materials[elementIndex % geometry.materials.count]
                let generated = material?.name?.hasPrefix("generated.landmark") == true
                let pigment = generated ? GeneratedLandmarkPigment.make(material: material, geometry: geometry) : nil
                let color = material?.diffuse.contents as? UIColor ?? (pigment == nil ? .lightGray : .white)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 1
                color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
                let tint = SIMD4<Float>(Float(r), Float(g), Float(b), Float(alpha) * Float(material?.transparency ?? 1))
                let materialName = material?.name ?? ""
                let isGem = materialName == "landmark.tanzaniteLight"
                let isSign = materialName == "airtel.signLight" || materialName == "airport.roofSignBlue"
                let isSignHalo = materialName == "airtel.signHalo"
                let isHalo = materialName == "landmark.tanzaniteHalo" || isSignHalo
                let isConcrete = materialName == "surface.bridgeConcrete"
                // Landmark shader-facade walls: "landmark.facade|style|storey|ground|base" (see
                // HarbourArchitectureParts.facadeSkin); u = along-wall fraction, v = corner flags.
                let facade = Self.facade(materialName)
                if facade != nil, uvs == nil {
                    uvs = geometry.sources(for: .texcoord).first.map { vectors2(from: $0) } ?? []
                }
                let appearance = SIMD4<Float>(
                    (material?.roughness.contents as? NSNumber)?.floatValue ?? 0.85,
                    (material?.metalness.contents as? NSNumber)?.floatValue ?? 0,
                    isSignHalo ? 0.055 : isSign ? 1 : isGem ? 1.2 : node.name == "architecturalLighting" ? 0.85 : 0, materialName == "landmark.airportGround" ? -15 : materialName == "landmark.poolWater" ? -14 : materialName == "landmark.ledScreen" ? -13 : materialName == "landmark.panoramicGlass" ? -12 : materialName == "landmark.windowLight" ? -11 : materialName == "bridgeRoad" ? -7 : ["landmark.clay", "landmark.slate"].contains(materialName) ? -8 : ["landmark.silver", "landmark.pspfAnodised", "airtel.silverSpandrel", "airtel.charcoalAluminium"].contains(materialName) ? -9 : materialName == "landmark.foliage" ? -5 : materialName == "landmark.trunk" ? -2 : materialName == "landmark.sitePaving" ? -6 : isSign || node.name == "architecturalLighting" ? 4 : isHalo ? 3 : isGem ? 2 : isConcrete ? -4 : ["reflectiveWindows", "dormerGlass", "clerestoryGlass", "curtainGlass", "bayWindowGlass"].contains(node.name ?? "") ? 1 : material?.name == "surface.brick" ? -1 : material?.name == "surface.timber" ? -2 : material?.name == "surface.stone" ? -3 : 0
                )
                let indices: [Int] = data.withUnsafeBytes { bytes in
                    (0..<(data.count / element.bytesPerIndex)).map { index in
                        let offset = index * element.bytesPerIndex
                        switch element.bytesPerIndex {
                        case 1: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                        case 2: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        default: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        }
                    }
                }
                let triangleCount = element.primitiveType == .triangles ? min(element.primitiveCount, indices.count / 3) : min(element.primitiveCount, max(0, indices.count - 2))
                for triangle in 0..<triangleCount {
                    let start = element.primitiveType == .triangles ? triangle * 3 : triangle
                    var ids = [indices[start], indices[start + 1], indices[start + 2]]
                    if element.primitiveType == .triangleStrip && triangle % 2 == 1 { ids.swapAt(0, 1) }
                    guard ids.allSatisfy({ positions.indices.contains($0) }) else { continue }
                    let face = simd_cross(positions[ids[1]] - positions[ids[0]], positions[ids[2]] - positions[ids[0]])
                    guard simd_length_squared(face) > 0.00000001 else { continue }
                    for id in ids {
                        let p = transform * SIMD4(positions[id], 1)
                        let inputNormal = normals.indices.contains(id) ? normals[id] : simd_normalize(face)
                        let normal = simd_normalize(normalMatrix * inputNormal)
                        let sampledTint = pigment?.color(at: id).map { $0 * tint } ?? tint
                        var shaded = appearance
                        if let (spec, base) = facade {
                            let uv = uvs.flatMap { $0.indices.contains(id) ? $0[id] : nil } ?? .zero
                            shaded = SIMD4(uv.y, spec.materialCode(along: uv.x), spec.heightAttribute(Double(p.z) - base), -20)
                        }
                        result.append(BuildingRenderVertex(position: p, normal: SIMD4(normal, 0), color: sampledTint, appearance: shaded))
                    }
                }
            }
        }
        return result
    }

    private static func facade(_ name: String) -> (DioramaFacade, Double)? {
        guard name.hasPrefix("landmark.facade|") else { return nil }
        let parts = name.split(separator: "|")
        guard parts.count == 5, let style = Int(parts[1]).flatMap(DioramaFacade.Style.init(rawValue:)),
              let storey = Double(parts[2]), let ground = Double(parts[3]), let base = Double(parts[4]) else { return nil }
        return (DioramaFacade(style: style, storey: storey, groundFloor: ground), base)
    }

    private static func vectors2(from source: SCNGeometrySource) -> [SIMD2<Float>] {
        guard source.usesFloatComponents, source.componentsPerVector >= 2,
              [4, 8].contains(source.bytesPerComponent), source.vectorCount > 0 else { return [] }
        return source.data.withUnsafeBytes { bytes in
            var result: [SIMD2<Float>] = []
            result.reserveCapacity(source.vectorCount)
            for index in 0..<source.vectorCount {
                let start = source.dataOffset + index * source.dataStride
                guard start >= 0, start + 2 * source.bytesPerComponent <= bytes.count else { return [] }
                func scalar(_ component: Int) -> Float {
                    let offset = start + component * source.bytesPerComponent
                    return source.bytesPerComponent == 4
                        ? bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                        : Float(bytes.loadUnaligned(fromByteOffset: offset, as: Double.self))
                }
                result.append(SIMD2(scalar(0), scalar(1)))
            }
            return result
        }
    }

    private static func vectors(from source: SCNGeometrySource) -> [SIMD3<Float>] {
        guard source.usesFloatComponents, source.componentsPerVector >= 3,
              [4, 8].contains(source.bytesPerComponent), source.vectorCount > 0 else { return [] }
        return source.data.withUnsafeBytes { bytes in
            var result: [SIMD3<Float>] = []
            for index in 0..<source.vectorCount {
                let start = source.dataOffset + index * source.dataStride
                guard start >= 0, start + 3 * source.bytesPerComponent <= bytes.count else { return [] }
                func scalar(_ component: Int) -> Float {
                    let offset = start + component * source.bytesPerComponent
                    return source.bytesPerComponent == 4
                        ? bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                        : Float(bytes.loadUnaligned(fromByteOffset: offset, as: Double.self))
                }
                result.append(SIMD3(scalar(0), scalar(1), scalar(2)))
            }
            return result
        }
    }
}
