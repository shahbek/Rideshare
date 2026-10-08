import Foundation

/// Shared vertex packing for scene generation and additive local visual patches.
nonisolated enum DioramaMeshPacking {
    static func vertices(_ mesh: DioramaMesh, category: DioramaCategory, config: DioramaConfig, legacyMaterials: Bool = false) -> [BuildingRenderVertex] {
        let code: Float = category == .shorelineDebug ? 6 : (category.isEmissive ? 4 : (category == .water ? 1 : 0))
        return mesh.positions.indices.map { i in
            let p = mesh.positions[i], n = mesh.normals[i]
            let cell = DioramaAtlas.lookup(mesh.uvs[i])
            let halo = category == .propGlow && cell?.swatch == .lampGlow && p.z > 0 && abs(n.z) > 1.5
            let texture: Float
            switch cell?.swatch {
            case .painted: texture = 9
            case .grass, .lawn, .pitchGreen: texture = 1
            case .earth, .wetSand, .seabed: texture = 2
            case .asphalt: texture = 3
            case .paving, .pavement, .concrete: texture = 4
            case .poolBlue: texture = 5
            case .glass, .glassPale: texture = 6
            case .tileClay: texture = 7
            case .muralBlue: texture = 8
            case .leafDark, .leafMid, .leafLight, .leafOlive, .leafBright, .hedge, .cypress: texture = 10
            case .roofTeal, .roofRust, .roofSlate, .roofGreen, .roofTerracotta, .roofConcrete, .seaCliffRoof: texture = 11
            case .whitewash, .cream, .paleYellow, .sage, .brick, .terracottaWall: texture = 12
            case .trunk, .palmTrunk, .pierWood, .deckWood, .doorWood: texture = 13
            default: texture = 0
            }
            let attribute = i < mesh.attributes.count ? mesh.attributes[i] : 0
            let appearance = SIMD4<Float>(0.85, legacyMaterials && texture > 9.5 ? 0 : texture, attribute.isFinite ? attribute : 0, halo ? 5 : code)
            var color = cell.map { DioramaAtlas.color($0.swatch, dark: $0.dark, config: config) } ?? SIMD4<Float>(1, 0, 1, 1)
            if i < mesh.tints.count {
                let t = mesh.tints[i]
                color = SIMD4(min(color.x * t.x, 1), min(color.y * t.y, 1), min(color.z * t.z, 1), color.w)
            }
            let valid = p.x.isFinite && p.y.isFinite && p.z.isFinite
            let normalValid = n.x.isFinite && n.y.isFinite && n.z.isFinite
            return BuildingRenderVertex(position: valid ? SIMD4(Float(p.x), Float(p.y), Float(p.z), 1) : SIMD4(0, 0, 0, 1),
                normal: normalValid ? SIMD4(Float(n.x), Float(n.y), Float(n.z), 0) : SIMD4(0, 0, 1, 0),
                color: valid ? color : SIMD4(1, 0, 1, 1), appearance: appearance)
        }
    }
}
