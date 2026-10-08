import Foundation

/// Reference-led branching and crown lobes, bounded to shared 80-face ellipsoids (20 at distance).
nonisolated enum DioramaTreeModels {
    static func make(variant: Int, light: Bool = false) -> DioramaMesh {
        var mesh = DioramaMesh()
        var rng = DioramaRandom(seed: UInt64(variant + 1), salt: 108)
        let small = variant == 8
        let umbrella = variant == 6
        let column = variant == 7 || variant == 9
        let scale = small ? 0.58 : (variant == 1 ? 1.15 : (variant == 2 ? 0.86 : 1.0))
        let fork = (umbrella ? 3.7 : (column ? 3.2 : 2.5)) * scale
        let radius = (small ? 0.20 : 0.30) * scale
        let sides = light ? (small ? 3 : 5) : 8
        mesh.tube(from: DV3(0, 0, 0), to: DV3(0.08 * scale, 0, fork), r0: radius,
                  r1: radius * 0.66, sides: sides, .trunk)
        if !light || column {
            mesh.cylinder(centre: .zero, z0: 0, z1: 0.18 * scale, r0: radius * 1.35,
                          r1: radius, sides: sides, .trunk)
        }
        if column {
            // Slender layered forms stay distinct from the wide spreading roadside crowns.
            for tier in 0..<4 {
                let t = Double(tier)
                let r = (variant == 9 ? 1.25 : 1.5) - t * 0.23
                let centre = DV3(0.12 * sin(t * 2), 0.1 * cos(t * 2), fork + 0.5 + t * 0.9)
                mesh.sphere(centre: centre, radii: DV3(r, r * 0.9, 1.05),
                            tier == 3 ? .leafLight : (variant == 9 ? .cypress : .leafMid), detail: light ? -1 : 0)
            }
            return mesh
        }
        let layered = variant == 4 || variant == 5
        let count = small ? 4 : (umbrella ? (light ? 3 : 6) : 5)
        let spread = (umbrella ? 2.0 : 1.3) * scale
        let lobe = (umbrella ? 1.8 : 1.55) * scale
        let phase = rng.range(0...Double.pi * 2)
        for k in 0..<count {
            let angle = phase + Double(k) * Double.pi * 2 / Double(count)
            let offset = DV2(cos(angle), sin(angle)) * spread * rng.range(0.82...1.05)
            let lift = layered ? Double(k % 3) * 0.55 : rng.range(-0.15...0.3)
            let centre = DV3(offset, fork + (umbrella ? 1.0 : 1.45) * scale + lift)
            let joint = DV3(offset * 0.62, centre.z - lobe * 0.45)
            // Each major branch actually reaches a canopy cluster, including the light silhouette.
            if !light || (small ? k == 0 : k % 2 == 0) {
                mesh.tube(from: DV3(0.08 * scale, 0, fork * 0.72), to: joint,
                          r0: radius * 0.64, r1: radius * 0.20, sides: light ? 3 : (umbrella ? 6 : sides), .trunk)
            }
            let foliage: DioramaSwatch = small ? .flowerPink : (variant == 3 ? .leafBright : (k % 3 == 0 ? .leafOlive : .leafMid))
            mesh.sphere(centre: centre, radii: DV3(lobe, lobe * rng.range(0.86...1.02), lobe * (umbrella ? 0.58 : 0.90)),
                        foliage, detail: light ? -1 : 0)
        }
        // An upper and lower central cluster join the lobes without hiding the forked silhouette.
        mesh.sphere(centre: DV3(0, 0, fork + 2.1 * scale),
                    radii: DV3(lobe * 0.90, lobe * 0.88, lobe * (umbrella ? 0.5 : 0.92)),
                    small ? .flowerPink : .leafLight, detail: light ? -1 : 0)
        if !light && !umbrella {
            mesh.sphere(centre: DV3(0, 0, fork + 0.8 * scale),
                        radii: DV3(lobe * 0.78, lobe * 0.75, lobe * 0.58),
                        .leafDark, detail: 0)
        }
        return mesh
    }
}
