import Foundation
import simd

/// Minimal binary glTF 2.0 writer: positions, normals, UVs, 16-bit indices, one material with the palette
/// atlas as base colour (and as emissive texture for glowing categories). ModelIO cannot export glTF.
///
/// Axis convention: glTF is right-handed Y-up. Mapbox maps glTF (x, y, z) to (east, up, south), so local
/// (east, north, up) becomes glTF (east, up, -north).
nonisolated enum DioramaGLBWriter {
    nonisolated struct Stats: Sendable {
        var triangles: Int
        var bytes: Int
    }

    static func write(_ mesh: DioramaMesh, emissive: Bool, atlas: Data, to url: URL) throws -> Stats {
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var primitives: [[String: Any]] = []

        func align() {
            while bin.count % 4 != 0 { bin.append(0) }
        }

        @discardableResult
        func addView(_ data: Data, target: Int?) -> Int {
            align()
            var view: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": data.count]
            if let target { view["target"] = target }
            bin.append(data)
            bufferViews.append(view)
            return bufferViews.count - 1
        }

        let positions = mesh.positions
        let normals = mesh.normals
        let uvs = mesh.uvs
        let indices = mesh.indices

        for (c, chunk) in mesh.chunks.enumerated() {
            let vertexEnd = c + 1 < mesh.chunks.count ? mesh.chunks[c + 1].vertex : positions.count
            let indexEnd = c + 1 < mesh.chunks.count ? mesh.chunks[c + 1].index : indices.count
            let vertexCount = vertexEnd - chunk.vertex
            let indexCount = indexEnd - chunk.index
            guard vertexCount > 0, indexCount > 0 else { continue }

            var posData = Data(capacity: vertexCount * 12)
            var nrmData = Data(capacity: vertexCount * 12)
            var uvData = Data(capacity: vertexCount * 8)
            var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in chunk.vertex..<vertexEnd {
                let p = positions[i]
                let g = SIMD3<Float>(Float(p.x), Float(p.z), Float(-p.y))
                minP = simd_min(minP, g)
                maxP = simd_max(maxP, g)
                append(&posData, g)
                let n = normals[i]
                append(&nrmData, SIMD3<Float>(Float(n.x), Float(n.z), Float(-n.y)))
                append(&uvData, uvs[i])
            }
            var idxData = Data(capacity: indexCount * 2)
            for i in chunk.index..<indexEnd {
                var v = UInt16(truncatingIfNeeded: indices[i] - UInt32(chunk.vertex))
                withUnsafeBytes(of: &v) { idxData.append(contentsOf: $0) }
            }

            let posView = addView(posData, target: 34962)
            let nrmView = addView(nrmData, target: 34962)
            let uvView = addView(uvData, target: 34962)
            let idxView = addView(idxData, target: 34963)

            accessors.append([
                "bufferView": posView, "componentType": 5126, "count": vertexCount, "type": "VEC3",
                "min": [minP.x, minP.y, minP.z], "max": [maxP.x, maxP.y, maxP.z],
            ])
            let posAccessor = accessors.count - 1
            accessors.append(["bufferView": nrmView, "componentType": 5126, "count": vertexCount, "type": "VEC3"])
            accessors.append(["bufferView": uvView, "componentType": 5126, "count": vertexCount, "type": "VEC2"])
            accessors.append(["bufferView": idxView, "componentType": 5123, "count": indexCount, "type": "SCALAR"])
            primitives.append([
                "attributes": ["POSITION": posAccessor, "NORMAL": posAccessor + 1, "TEXCOORD_0": posAccessor + 2],
                "indices": posAccessor + 3,
                "material": 0,
                "mode": 4,
            ])
        }

        let imageView = addView(atlas, target: nil)
        align()

        var material: [String: Any] = [
            "name": emissive ? "diorama-glow" : "diorama-matte",
            "doubleSided": false,
            "pbrMetallicRoughness": [
                "baseColorTexture": ["index": 0],
                "metallicFactor": 0,
                "roughnessFactor": 0.95,
            ],
        ]
        if emissive {
            material["emissiveTexture"] = ["index": 0]
            material["emissiveFactor"] = [1, 1, 1]
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Zuri Diorama"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": emissive ? "glow" : "diorama"]],
            "meshes": [["primitives": primitives]],
            "materials": [material],
            "textures": [["sampler": 0, "source": 0]],
            "samplers": [["magFilter": 9728, "minFilter": 9728, "wrapS": 33071, "wrapT": 33071]],
            "images": [["bufferView": imageView, "mimeType": "image/png"]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": accessors,
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var glb = Data()
        appendUInt32(&glb, 0x4654_6C67)
        appendUInt32(&glb, 2)
        appendUInt32(&glb, UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        appendUInt32(&glb, UInt32(jsonData.count))
        appendUInt32(&glb, 0x4E4F_534A)
        glb.append(jsonData)
        appendUInt32(&glb, UInt32(bin.count))
        appendUInt32(&glb, 0x004E_4942)
        glb.append(bin)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try glb.write(to: url, options: .atomic)
        return Stats(triangles: mesh.triangleCount, bytes: glb.count)
    }

    private static func append(_ data: inout Data, _ v: SIMD3<Float>) {
        var x = v.x, y = v.y, z = v.z
        withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }
    }

    private static func append(_ data: inout Data, _ v: SIMD2<Float>) {
        var x = v.x, y = v.y
        withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
