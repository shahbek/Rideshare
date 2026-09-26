import SceneKit
import UIKit

/// Loads the supplied Forma fleet (`forma_fleet.glb`) into SceneKit. SceneKit cannot read glTF
/// directly, so this minimal reader converts meshes, node transforms and PBR materials.
/// Vehicles in the file point their nose along +X; they are returned with the nose on −Z, +Y up.
enum FormaFleetLoader {
    private struct Document {
        let json: [String: Any]
        let bin: Data
    }

    private static let document: Document? = loadDocument()
    private static var materialCache: [Int: SCNMaterial] = [:]
    private static var imageCache: [Int: UIImage] = [:]

    /// Returns the vehicle whose node name matches (e.g. "forma-sedan"), or nil if unavailable.
    static func vehicle(named name: String) -> SCNNode? {
        guard let document, let nodes = document.json["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { ($0["name"] as? String) == name }) else {
            print("[Fleet] missing vehicle \(name)")
            return nil
        }
        let model = buildNode(index, nodes: nodes, document: document)
        model.simdTransform = matrix_identity_float4x4
        let root = SCNNode()
        root.name = name
        // Nose +X → −Z. Transforms are baked onto geometry leaves directly under the root, because
        // flattening discards transforms on geometry-less groups (wheel wrappers, the turn itself).
        let turn = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        bake(model, parent: turn, into: root)
        return root
    }

    private static func bake(_ node: SCNNode, parent: simd_float4x4, into root: SCNNode) {
        let world = parent * node.simdTransform
        if let geometry = node.geometry {
            let leaf = SCNNode(geometry: geometry)
            leaf.name = node.name
            leaf.simdTransform = world
            root.addChildNode(leaf)
        }
        for child in node.childNodes { bake(child, parent: world, into: root) }
    }

    private static func loadDocument() -> Document? {
        guard let url = Bundle.main.url(forResource: "forma_fleet", withExtension: "glb"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 20 else {
            print("[Fleet] forma_fleet.glb not found")
            return nil
        }
        var offset = 12
        var json: [String: Any]?
        var bin = Data()
        while offset + 8 <= data.count {
            let length = Int(readUInt32(data, offset))
            let type = readUInt32(data, offset + 4)
            let start = offset + 8
            guard start + length <= data.count else { break }
            let chunk = data.subdata(in: start..<(start + length))
            if type == 0x4E4F534A {
                json = (try? JSONSerialization.jsonObject(with: chunk)) as? [String: Any]
            } else if type == 0x004E4942 {
                bin = chunk
            }
            offset = start + length
        }
        guard let json else { return nil }
        return Document(json: json, bin: bin)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func buildNode(_ index: Int, nodes: [[String: Any]], document: Document) -> SCNNode {
        let info = nodes[index]
        let node = SCNNode()
        node.name = info["name"] as? String
        if let m = (info["matrix"] as? [NSNumber])?.map({ Float(truncating: $0) }), m.count == 16 {
            node.simdTransform = simd_float4x4(columns: (
                SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        } else {
            if let t = (info["translation"] as? [NSNumber])?.map({ Float(truncating: $0) }), t.count == 3 {
                node.simdPosition = SIMD3(t[0], t[1], t[2])
            }
            if let r = (info["rotation"] as? [NSNumber])?.map({ Float(truncating: $0) }), r.count == 4 {
                node.simdOrientation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            }
            if let s = (info["scale"] as? [NSNumber])?.map({ Float(truncating: $0) }), s.count == 3 {
                node.simdScale = SIMD3(s[0], s[1], s[2])
            }
        }
        if let meshIndex = info["mesh"] as? Int {
            let geometries = buildMesh(meshIndex, document: document)
            if geometries.count == 1 {
                node.geometry = geometries[0]
            } else {
                for geometry in geometries { node.addChildNode(SCNNode(geometry: geometry)) }
            }
        }
        for child in (info["children"] as? [Int]) ?? [] {
            node.addChildNode(buildNode(child, nodes: nodes, document: document))
        }
        return node
    }

    private static func buildMesh(_ index: Int, document: Document) -> [SCNGeometry] {
        guard let meshes = document.json["meshes"] as? [[String: Any]], index < meshes.count,
              let primitives = meshes[index]["primitives"] as? [[String: Any]] else { return [] }
        return primitives.compactMap { primitive in
            guard (primitive["mode"] as? Int ?? 4) == 4,
                  let attributes = primitive["attributes"] as? [String: Int],
                  let positionIndex = attributes["POSITION"],
                  let positions = floatSource(positionIndex, semantic: .vertex, document: document) else { return nil }
            var sources = [positions]
            if let n = attributes["NORMAL"], let normals = floatSource(n, semantic: .normal, document: document) { sources.append(normals) }
            if let t = attributes["TEXCOORD_0"], let uv = floatSource(t, semantic: .texcoord, document: document) { sources.append(uv) }
            let element: SCNGeometryElement
            if let indicesIndex = primitive["indices"] as? Int, let built = indexElement(indicesIndex, document: document) {
                element = built
            } else {
                let count = positions.vectorCount
                let indices = (0..<UInt32(count)).map { $0 }
                element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            }
            let geometry = SCNGeometry(sources: sources, elements: [element])
            if let materialIndex = primitive["material"] as? Int {
                geometry.materials = [material(materialIndex, document: document)]
            }
            return geometry
        }
    }

    private static func accessorBytes(_ index: Int, document: Document) -> (data: Data, count: Int, componentType: Int, components: Int)? {
        guard let accessors = document.json["accessors"] as? [[String: Any]], index < accessors.count,
              let views = document.json["bufferViews"] as? [[String: Any]] else { return nil }
        let accessor = accessors[index]
        guard let viewIndex = accessor["bufferView"] as? Int, viewIndex < views.count,
              let count = accessor["count"] as? Int,
              let componentType = accessor["componentType"] as? Int,
              let type = accessor["type"] as? String else { return nil }
        let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][type] ?? 1
        let componentSize = componentType == 5126 || componentType == 5125 ? 4 : (componentType == 5123 || componentType == 5122 ? 2 : 1)
        let view = views[viewIndex]
        let start = (view["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let elementSize = components * componentSize
        let stride = view["byteStride"] as? Int ?? elementSize
        guard count > 0, start + stride * (count - 1) + elementSize <= document.bin.count else { return nil }
        if stride == elementSize {
            return (document.bin.subdata(in: start..<(start + elementSize * count)), count, componentType, components)
        }
        var packed = Data(capacity: elementSize * count)
        for i in 0..<count {
            let s = start + i * stride
            packed.append(document.bin.subdata(in: s..<(s + elementSize)))
        }
        return (packed, count, componentType, components)
    }

    private static func floatSource(_ index: Int, semantic: SCNGeometrySource.Semantic, document: Document) -> SCNGeometrySource? {
        guard let bytes = accessorBytes(index, document: document), bytes.componentType == 5126 else { return nil }
        return SCNGeometrySource(data: bytes.data, semantic: semantic, vectorCount: bytes.count,
                                 usesFloatComponents: true, componentsPerVector: bytes.components,
                                 bytesPerComponent: 4, dataOffset: 0, dataStride: bytes.components * 4)
    }

    private static func indexElement(_ index: Int, document: Document) -> SCNGeometryElement? {
        guard let bytes = accessorBytes(index, document: document) else { return nil }
        switch bytes.componentType {
        case 5123:
            return SCNGeometryElement(data: bytes.data, primitiveType: .triangles, primitiveCount: bytes.count / 3, bytesPerIndex: 2)
        case 5125:
            return SCNGeometryElement(data: bytes.data, primitiveType: .triangles, primitiveCount: bytes.count / 3, bytesPerIndex: 4)
        case 5121:
            let wide = bytes.data.map { UInt16($0) }
            return SCNGeometryElement(indices: wide, primitiveType: .triangles)
        default:
            return nil
        }
    }

    private static func material(_ index: Int, document: Document) -> SCNMaterial {
        if let cached = materialCache[index] { return cached }
        let result = SCNMaterial()
        result.lightingModel = .physicallyBased
        guard let materials = document.json["materials"] as? [[String: Any]], index < materials.count else { return result }
        let info = materials[index]
        result.name = info["name"] as? String
        let pbr = info["pbrMetallicRoughness"] as? [String: Any] ?? [:]
        let factor = (pbr["baseColorFactor"] as? [NSNumber])?.map { CGFloat(truncating: $0) } ?? [1, 1, 1, 1]
        let baseColor = UIColor(red: srgb(factor[0]), green: srgb(factor[1]), blue: srgb(factor[2]), alpha: factor.count > 3 ? factor[3] : 1)
        if let texture = pbr["baseColorTexture"] as? [String: Any], let textureIndex = texture["index"] as? Int,
           let image = textureImage(textureIndex, document: document) {
            result.diffuse.contents = image
            result.diffuse.wrapS = .clamp
            result.diffuse.wrapT = .clamp
            result.diffuse.mipFilter = .linear
        } else {
            result.diffuse.contents = baseColor
        }
        let hasPackedTexture = pbr["metallicRoughnessTexture"] != nil
        let metal = CGFloat(truncating: (pbr["metallicFactor"] as? NSNumber) ?? 1)
        let rough = CGFloat(truncating: (pbr["roughnessFactor"] as? NSNumber) ?? 1)
        // Packed metal/rough maps use separate channels SceneKit cannot pick; use painted-body values.
        // Dark metallic paint reads muddy in the small studio rig; keep it satin and reflective.
        // Glossy lacquer: low roughness so the paint reads clearly at miniature size.
        let isRubber = rough > 0.8 && metal < 0.05
        result.metalness.contents = hasPackedTexture ? 0.15 : min(metal, 0.2)
        result.roughness.contents = isRubber ? rough : (hasPackedTexture ? 0.14 : min(rough, 0.16))
        if !isRubber {
            result.clearCoat.contents = 1.0
            result.clearCoatRoughness.contents = 0.04
        }
        if let emissive = (info["emissiveFactor"] as? [NSNumber])?.map({ CGFloat(truncating: $0) }), emissive.count == 3,
           emissive.contains(where: { $0 > 0 }) {
            let extensions = info["extensions"] as? [String: Any]
            let strength = ((extensions?["KHR_materials_emissive_strength"] as? [String: Any])?["emissiveStrength"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 1
            result.emission.contents = UIColor(red: srgb(emissive[0]), green: srgb(emissive[1]), blue: srgb(emissive[2]), alpha: 1)
            // Lamps read as switched on: strong emission plus a bright base colour.
            result.emission.intensity = max(strength, 1) * 6
            result.diffuse.contents = result.emission.contents
            result.lightingModel = .constant
        }
        if let extensions = info["extensions"] as? [String: Any],
           let clearcoat = extensions["KHR_materials_clearcoat"] as? [String: Any],
           let amount = clearcoat["clearcoatFactor"] as? NSNumber {
            if (result.clearCoat.contents as? Double) == nil {
                result.clearCoat.contents = max(CGFloat(truncating: amount), 0.5)
            }
            result.clearCoatRoughness.contents = CGFloat(truncating: (clearcoat["clearcoatRoughnessFactor"] as? NSNumber) ?? 0)
        }
        result.isDoubleSided = (info["doubleSided"] as? Bool) ?? false
        materialCache[index] = result
        return result
    }

    private static func textureImage(_ index: Int, document: Document) -> UIImage? {
        guard let textures = document.json["textures"] as? [[String: Any]], index < textures.count,
              let source = textures[index]["source"] as? Int else { return nil }
        if let cached = imageCache[source] { return cached }
        guard let images = document.json["images"] as? [[String: Any]], source < images.count,
              let viewIndex = images[source]["bufferView"] as? Int,
              let views = document.json["bufferViews"] as? [[String: Any]], viewIndex < views.count else { return nil }
        let view = views[viewIndex]
        let start = view["byteOffset"] as? Int ?? 0
        let length = view["byteLength"] as? Int ?? 0
        guard start + length <= document.bin.count,
              let image = UIImage(data: document.bin.subdata(in: start..<(start + length))) else { return nil }
        imageCache[source] = image
        return image
    }

    private static func srgb(_ linear: CGFloat) -> CGFloat {
        let c = max(0, min(1, linear))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
