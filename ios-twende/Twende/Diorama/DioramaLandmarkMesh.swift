import CoreLocation
import SceneKit
import UIKit
import simd

/// Converts airport construction markers into immutable static batches and 60m-binned prototype placements.
/// Other landmarks keep their established conversion path.
enum DioramaLandmarkMesh {
    /// The established bespoke-landmark conversion, shared by standalone hosts and saved-tile baking
    /// so both draw exactly the same triangles, materials and batches.
    static func standard(_ scene: SCNScene) -> DioramaLandmarkBake.Geometry {
        var packed: [BuildingRenderVertex] = [], cells: [String: (DioramaCategory, [UInt32], Bool)] = [:]
        let baked = BuildingRenderGeometry.vertices(from: scene)
        func append(_ v: [BuildingRenderVertex], category: DioramaCategory, doubleSided: Bool, translucent: Bool = false) {
            let base = UInt32(packed.count)
            packed.append(contentsOf: v)
            let p = (v[0].position + v[1].position + v[2].position) / 3
            // Glass triangles retain separate ranges for back-to-front composition.
            let key = "\(category.rawValue)/\(Int(floor(p.x / 60)))/\(Int(floor(p.y / 60)))/\(doubleSided)/\(translucent ? "glass-\(base)" : "solid")"
            if cells[key] == nil { cells[key] = (category, [], doubleSided) }
            cells[key]?.1.append(contentsOf: [base, base + 1, base + 2])
        }
        for start in stride(from: 0, to: baked.count - 2, by: 3) {
            let raw = Array(baked[start..<(start + 3)])
            let code = raw[0].appearance.w
            // Old billboard halos carried a different normal grammar; real bloom replaces them.
            if code == 3 { continue }
            if code == -20 {
                // Shader-facade wall: openings, mullions, floor lines and night windows come from the
                // fragment shader, exactly as on the city's buildings (DioramaFacade encoding).
                var wall = raw.map { v in BuildingRenderVertex(position: v.position, normal: v.normal, color: v.color,
                    appearance: SIMD4(0.85, v.appearance.y, v.appearance.z, v.appearance.x * 0.0625)) }
                let p = wall.map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
                let n = wall.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.normal.x, $1.normal.y, $1.normal.z) }
                if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) < 0 { wall.swapAt(1, 2) }
                append(wall, category: .buildings, doubleSided: false)
                continue
            }
            let material: Float = code == -15 ? 9 : code == -14 ? 5 : code == -12 ? 15 : code == 1 || code == 2 || code == -11 ? 6 : code == -5 ? 10 : code == -2 ? 13 : code == -6 ? 4 : code == -7 ? 3 : code == -8 ? 11 : code == -9 || code == 4 ? 0 : 12
            var solid = raw.map { v in
                BuildingRenderVertex(position: v.position, normal: v.normal,
                    color: code == -11 ? SIMD4(0.255, 0.494, 0.525, 1) : v.color,
                    appearance: SIMD4(0.85, material, material == 12 ? 100 + v.position.z : 0, code == -13 ? 7 : 0))
            }
            let p = solid.map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
            let n = solid.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.normal.x, $1.normal.y, $1.normal.z) }
            if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) < 0 { solid.swapAt(1, 2) }
            let category: DioramaCategory = code == -5 || code == -2 ? .vegetation : code == -6 || code == -15 ? .ground : .buildings
            append(solid, category: category, doubleSided: code == -5 || material == 6, translucent: code == -12)
            if code == 4 || code == 2 || code == -11 || code == -13 {
                let glow = solid.map { v in BuildingRenderVertex(position: v.position, normal: v.normal,
                    color: code == -11 ? SIMD4(1, 0.64, 0.20, 1) : v.color, appearance: SIMD4(0.85, 1, 0, 4)) }
                append(glow, category: .windowGlow, doubleSided: true)
            }
        }
        var indices: [UInt32] = [], ranges: [DioramaRenderLayer.Range] = []
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for key in cells.keys.sorted() {
            guard let (category, batch, doubleSided) = cells[key] else { continue }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for id in batch { let p = packed[Int(id)].position; lo = simd_min(lo, SIMD3(p.x,p.y,p.z)); hi = simd_max(hi, SIMD3(p.x,p.y,p.z)) }
            ranges.append(.init(category: category, start: indices.count, count: batch.count, minimum: lo, maximum: hi, doubleSided: doubleSided, translucent: key.contains("/glass-")))
            indices.append(contentsOf: batch)
            if !category.isEmissive { low = simd_min(low, lo); high = simd_max(high, hi) }
        }
        var lights: [DioramaLight] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            guard node.name == "landmarkPointLight", let light = node.light else { return }
            let p = node.simdWorldPosition
            lights.append(.init(position: DV3(Double(p.x), Double(p.y), Double(p.z)),
                color: SIMD3(1, 0.64, 0.20), radius: Double(light.attenuationEndDistance), intensity: Float(light.intensity) / 1000))
        }
        return .init(vertices: packed, indices: indices, ranges: ranges, lights: lights, minimum: low, maximum: high)
    }

    static func airport(_ scene: SCNScene, origin: CLLocationCoordinate2D, image: DioramaGroundImage?, rect: DioramaRect) -> DioramaTileArtifacts {
        var vertices: [BuildingRenderVertex] = [], indices: [UInt32] = [], ranges: [DioramaRenderLayer.Range] = []
        var groups: [DioramaInstanceGroup] = [], allInstances: [DioramaInstanceData] = []
        struct Batch {
            let category: DioramaCategory
            let doubleSided: Bool
            let translucent: Bool
            var ids: [UInt32] = []
        }
        func converted(_ raw: [BuildingRenderVertex]) -> [(vertices: [BuildingRenderVertex], category: DioramaCategory, doubleSided: Bool, translucent: Bool)] {
            guard raw.count == 3 else { return [] }
            let code = raw[0].appearance.w
            if code == 3 { return [] }
            if code == -20 {
                var wall = raw.map { v in BuildingRenderVertex(position: v.position, normal: v.normal, color: v.color,
                    appearance: SIMD4(0.85, v.appearance.y, v.appearance.z, v.appearance.x * 0.0625)) }
                let p = wall.map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
                let n = wall.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.normal.x, $1.normal.y, $1.normal.z) }
                if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) < 0 { wall.swapAt(1, 2) }
                return [(wall, .buildings, false, false)]
            }
            let material: Float = code == -15 ? 9 : code == -14 ? 5 : code == -12 ? 15 : code == 1 || code == 2 || code == -11 ? 6 : code == -5 ? 10 : code == -2 ? 13 : code == -6 ? 4 : code == -7 ? 3 : code == -8 ? 11 : code == -9 || code == 4 ? 0 : 12
            var solid = raw.map { v in
                BuildingRenderVertex(position: v.position, normal: v.normal, color: code == -11 ? SIMD4(0.255, 0.494, 0.525, 1) : v.color,
                    appearance: SIMD4(0.85, material, material == 12 ? 100 + v.position.z : 0, code == -13 ? 7 : 0))
            }
            let p = solid.map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
            let n = solid.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.normal.x, $1.normal.y, $1.normal.z) }
            if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) < 0 { solid.swapAt(1, 2) }
            let category: DioramaCategory = code == -5 || code == -2 ? .vegetation : code == -6 || code == -15 ? .ground : .buildings
            var result = [(solid, category, code == -5 || material == 6, code == -12)]
            if code == 4 || code == 2 || code == -11 || code == -13 {
                let glow = solid.map { BuildingRenderVertex(position: $0.position, normal: $0.normal, color: code == -11 ? SIMD4(1, 0.78, 0.46, 1) : $0.color, appearance: SIMD4(0.85, 1, 0, 4)) }
                result.append((glow, .windowGlow, true, false))
            }
            return result
        }
        func bounds(_ ids: [UInt32]) -> (SIMD3<Float>, SIMD3<Float>) {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for id in ids { let p = vertices[Int(id)].position; lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z)) }
            return (lo, hi)
        }
        func bake(_ raw: [BuildingRenderVertex], spatial: Bool) -> [String: Batch] {
            var batches: [String: Batch] = [:]
            for start in stride(from: 0, to: max(0, raw.count - 2), by: 3) {
                for part in converted(Array(raw[start..<(start + 3)])) {
                    let base = UInt32(vertices.count), p = part.vertices.reduce(SIMD4<Float>.zero) { $0 + $1.position } / 3
                    let cell = spatial ? "\(Int(floor(p.x / 60)))/\(Int(floor(p.y / 60)))" : "prototype"
                    let key = "\(part.category.rawValue)/\(cell)/\(part.doubleSided)/\(part.translucent ? "glass-\(base)" : "solid")"
                    vertices.append(contentsOf: part.vertices)
                    if batches[key] == nil { batches[key] = Batch(category: part.category, doubleSided: part.doubleSided, translucent: part.translucent) }
                    batches[key]?.ids.append(contentsOf: [base, base + 1, base + 2])
                }
            }
            return batches
        }
        let staticBatches = bake(BuildingRenderGeometry.vertices(from: scene, excludingAirportInstances: true), spatial: true)
        for key in staticBatches.keys.sorted() {
            guard let batch = staticBatches[key] else { continue }
            let b = bounds(batch.ids)
            ranges.append(.init(category: batch.category, start: indices.count, count: batch.ids.count, minimum: b.0, maximum: b.1, doubleSided: batch.doubleSided, translucent: batch.translucent))
            indices.append(contentsOf: batch.ids)
        }
        var placed: [String: [SCNNode]] = [:]
        scene.rootNode.enumerateChildNodes { node, _ in
            if let name = node.name, name.hasPrefix(AirportInstanceGeometry.prefix) { placed[name, default: []].append(node) }
        }
        for name in placed.keys.sorted() {
            guard let nodes = placed[name], let first = nodes.first else { continue }
            let prototype = first.clone(); prototype.simdTransform = matrix_identity_float4x4; prototype.name = nil
            let model = SCNScene(); model.rootNode.addChildNode(prototype)
            let batches = bake(BuildingRenderGeometry.vertices(from: model), spatial: false)
            for key in batches.keys.sorted() {
                guard let batch = batches[key], !batch.ids.isEmpty else { continue }
                let b = bounds(batch.ids), start = indices.count
                indices.append(contentsOf: batch.ids)
                let radius = max(simd_length(b.0), simd_length(b.1))
                var cells: [String: [DioramaInstanceData]] = [:]
                for node in nodes {
                    let transform = node.simdWorldTransform, p = transform.columns.3
                    let sx = simd_length(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
                    let sy = simd_length(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
                    let sz = simd_length(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
                    let angle = atan2(transform.columns.0.y, transform.columns.0.x)
                    let value = DioramaInstanceData(placement: SIMD4(p.x, p.y, p.z, angle), scale: SIMD4(sx, sy, sz, radius * max(sx, max(sy, sz))))
                    cells["\(Int(floor(p.x / 60)))/\(Int(floor(p.y / 60)))", default: []].append(value)
                }
                for cell in cells.keys.sorted() {
                    guard let instances = cells[cell] else { continue }
                    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                    for i in instances { lo = simd_min(lo, i.centre - SIMD3(repeating: i.radius)); hi = simd_max(hi, i.centre + SIMD3(repeating: i.radius)) }
                    groups.append(.init(category: batch.category, fullStart: start, fullCount: batch.ids.count, lightStart: start, lightCount: batch.ids.count,
                        doubleSided: batch.doubleSided, instances: instances, firstInstance: allInstances.count, minimum: lo, maximum: hi))
                    allInstances.append(contentsOf: instances)
                }
            }
        }
        var lights: [DioramaLight] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            guard node.name == "landmarkPointLight", let light = node.light else { return }
            let p = node.simdWorldPosition
            lights.append(.init(position: DV3(Double(p.x), Double(p.y), Double(p.z)), color: SIMD3(1, 0.78, 0.46), radius: Double(light.attenuationEndDistance), intensity: Float(light.intensity) / 1000))
        }
        print("[DarLandmarks] JNIA packed: \(vertices.count / 3) unique triangles, \(placed.values.reduce(0) { $0 + $1.count }) prototype placements, \(groups.count) 60m instance bins")
        return DioramaTileArtifacts(tile: DioramaTileID(latitude: origin.latitude, longitude: origin.longitude, zoom: 16), vertices: vertices, indices: indices,
            ranges: ranges, groups: groups, allInstances: allInstances, parts: [], lights: lights,
            lightGrid: DioramaLightGrid.build(lights, rect: rect, cells: 96, perCell: 16), waterHeight: 0, shorelineReport: [], generationSeconds: 0,
            groundImage: image, renderMaterialsPrepared: true)
    }
}
