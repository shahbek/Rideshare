import Foundation

/// The stylised harbour's prop set: every model is a few dozen triangles at most, built once at the
/// origin (facing +x, standing on z = 0) and placed as GPU instances. Lighting is baked into the
/// vertex colours (hemisphere sky plus the sun from above, so a rotated placement still reads right).
nonisolated struct DioramaStylisedProps: Sendable {
    let prototypes: [DioramaPrototype]
    let trees: [DioramaPrototype]
    let palms: [DioramaPrototype]
    let bushes: [DioramaPrototype]
    let lamp: DioramaPrototype
    let lampGlow: DioramaPrototype
    /// Camera-facing halo sprite, appended as baked geometry (the vertex shader rebuilds it).
    let lampHalo: DioramaMesh
    let cars: [DioramaPrototype]
    let bajaji: DioramaPrototype
    let dhow: DioramaPrototype
    let kiosk: DioramaPrototype

    init() {
        var registry: [DioramaPrototype] = []
        func make(_ mesh: DioramaMesh) -> DioramaPrototype {
            let prototype = DioramaPrototype(id: registry.count, full: mesh)
            registry.append(prototype)
            return prototype
        }
        trees = [
            make(Self.roundTree(height: 5.2, radius: 2.6, crown: .leafMid, top: .leafLight)),
            make(Self.roundTree(height: 6.4, radius: 3.1, crown: .leafDark, top: .leafMid)),
            make(Self.roundTree(height: 4.4, radius: 2.2, crown: .leafBright, top: .leafLight)),
            make(Self.umbrellaTree(height: 7.0, radius: 4.2)),
        ]
        palms = [make(Self.palm(height: 7.5, lean: 0.35)), make(Self.palm(height: 9.5, lean: 0.9)), make(Self.palm(height: 6.0, lean: 0.2))]
        bushes = [make(Self.bush(.hedge)), make(Self.bush(.leafOlive)), make(Self.bush(.flowerPink)), make(Self.bush(.flowerYellow))]
        let lampParts = Self.lamp()
        lamp = make(lampParts.post)
        lampGlow = make(lampParts.glow)
        lampHalo = DioramaPropLibrary.makeHalo(radius: 2.2, .lampGlow)
        cars = [make(Self.car(.carSilver)), make(Self.car(.carWhite)), make(Self.car(.carRed)), make(Self.car(.sunflower))]
        bajaji = make(Self.bajajiModel())
        dhow = make(Self.dhowModel())
        kiosk = make(Self.kioskModel())
        prototypes = registry
    }

    /// Trunk plus a 20-face crown: 32 triangles.
    private static func roundTree(height: Double, radius: Double, crown: DioramaSwatch, top: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        let trunkTop = height - radius * 0.9
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, trunkTop + 0.3), r0: 0.22, r1: 0.16, sides: 6, .trunk, cap: false)
        m.sphere(centre: DV3(0, 0, trunkTop + radius * 0.55), radii: DV3(radius, radius * 0.92, radius * 0.8), crown, detail: -1)
        return m
    }

    /// Flat spreading acacia-like crown: 12 + 20 triangles.
    private static func umbrellaTree(height: Double, radius: Double) -> DioramaMesh {
        var m = DioramaMesh()
        m.tube(from: DV3(0, 0, 0), to: DV3(0, 0, height - 1.2), r0: 0.28, r1: 0.18, sides: 6, .trunk, cap: false)
        m.sphere(centre: DV3(0, 0, height - 0.9), radii: DV3(radius, radius * 0.85, 1.1), .leafOlive, detail: -1)
        return m
    }

    /// Leaning trunk and six frond blades: 10 + 12 triangles.
    private static func palm(height: Double, lean: Double) -> DioramaMesh {
        var m = DioramaMesh()
        let top = DV3(lean, lean * 0.3, height)
        m.tube(from: DV3(0, 0, 0), to: top, r0: 0.2, r1: 0.14, sides: 5, .palmTrunk, cap: false)
        m.doubleSided = true
        for k in 0..<6 {
            let angle = Double(k) / 6 * 2 * .pi + 0.3
            let dir = DV3(cos(angle), sin(angle), 0)
            let side = DV3(-sin(angle), cos(angle), 0) * 0.55
            let tip = top + dir * 3.2 + DV3(0, 0, -1.1)
            let mid = top + dir * 1.4 + DV3(0, 0, 0.5)
            m.quad(top + side * 0.3, mid + side, tip, mid - side, k % 2 == 0 ? .leafMid : .leafBright, normal: DV3(0, 0, 1))
        }
        m.doubleSided = false
        return m
    }

    /// 20 triangles.
    private static func bush(_ swatch: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        m.sphere(centre: DV3(0, 0, 0.55), radii: DV3(0.85, 0.75, 0.6), swatch, detail: -1)
        return m
    }

    private static func lamp() -> (post: DioramaMesh, glow: DioramaMesh) {
        var post = DioramaMesh(), glow = DioramaMesh()
        let h = DioramaPropLibrary.lampHeadHeight
        post.tube(from: DV3(0, 0, 0), to: DV3(0, 0, h - 0.4), r0: 0.08, r1: 0.06, sides: 4, .lampPole, cap: false)
        post.tube(from: DV3(0, 0, h - 0.45), to: DV3(0.7, 0, h - 0.2), r0: 0.05, r1: 0.05, sides: 4, .lampPole, cap: false)
        glow.box(centre: DV2(0.7, 0), z0: h - 0.5, halfLength: 0.22, halfWidth: 0.16, height: 0.32, .lampGlow, bottom: true)
        return (post, glow)
    }

    /// Body and cabin boxes: 24 triangles.
    private static func car(_ swatch: DioramaSwatch) -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: .zero, z0: 0.25, halfLength: 2.1, halfWidth: 0.9, height: 0.6, swatch)
        m.box(centre: DV2(-0.2, 0), z0: 0.85, halfLength: 1.1, halfWidth: 0.8, height: 0.55, .glass, top: swatch)
        return m
    }

    private static func bajajiModel() -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: .zero, z0: 0.2, halfLength: 1.25, halfWidth: 0.65, height: 0.55, .bajajiBlue)
        m.box(centre: DV2(-0.15, 0), z0: 0.75, halfLength: 0.95, halfWidth: 0.6, height: 0.85, .bajajiBlue, top: .tankBlack)
        return m
    }

    /// Hull box and one lateen sail: 12 + 2 triangles.
    private static func dhowModel() -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: .zero, z0: -0.2, halfLength: 4.5, halfWidth: 1.2, height: 1.0, .hullWood, top: .deckWood)
        m.tube(from: DV3(0.5, 0, 0.8), to: DV3(0.5, 0, 7.5), r0: 0.08, r1: 0.06, sides: 3, .mastGrey, cap: false)
        m.doubleSided = true
        m.triangle(DV3(0.6, 0, 1.2), DV3(0.6, 0, 7.2), DV3(-3.8, 0, 2.2), .sailCream, normal: DV3(0, 1, 0))
        m.doubleSided = false
        return m
    }

    private static func kioskModel() -> DioramaMesh {
        var m = DioramaMesh()
        m.box(centre: .zero, z0: 0, halfLength: 1.3, halfWidth: 1.0, height: 2.2, .ochre, top: .canopyRed)
        return m
    }
}
