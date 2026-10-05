import Foundation

/// Purpose-built coast profiles. Never extrudes a generic land polygon or alters the inland DEM.
nonisolated struct DioramaShorelineGenerator {
    let config: DioramaConfig
    let data: DioramaTileData
    let terrain: DioramaTerrain
    let library: DioramaPropLibrary

    /// Profile coordinates: x is metres towards water, y is absolute scene height.
    func generate(ground: inout DioramaMesh, props: inout DioramaMesh, vegetation: inout DioramaMesh,
                  debug: inout DioramaMesh) {
        for segment in data.shorelines where segment.points.count >= 2 {
            switch segment.kind {
            case .beach:
                bank(segment, beach: true, ground: &ground)
                beachDetails(segment, props: &props, vegetation: &vegetation)
            case .seawall, .deck:
                seawall(segment, ground: &ground, props: &props)
                if segment.hasRevetment { rockBank(segment, standalone: false, ground: &ground, props: &props) }
            case .revetment:
                rockBank(segment, standalone: true, ground: &ground, props: &props)
            case .natural:
                rockBank(segment, standalone: true, ground: &ground, props: &props)
                naturalDetails(segment, vegetation: &vegetation)
            }
            let swatch: DioramaSwatch
            switch segment.kind {
            case .beach: swatch = .signYellow
            case .seawall: swatch = .signRed
            case .revetment: swatch = .signOrange
            case .deck: swatch = .signBlue
            case .natural: swatch = .signGreen
            }
            let rows = segment.points.indices.map { i in
                let h = max(terrain.height(segment.points[i]), terrain.waterLevel) + 0.4
                return [DV2(-0.9, h), DV2(0.9, h)]
            }
            sweep(segment, profiles: rows, swatches: [swatch], into: &debug)
        }
    }

    /// Plan footprint of every swept band, used to cut the land and seabed plates away underneath so
    /// the profiles never intersect them. Extents match the profile functions below.
    static func coverage(_ segments: [DioramaShorelineSegment], config: DioramaConfig, terrain: DioramaTerrain) -> [[DV2]] {
        var result: [[DV2]] = []
        for segment in segments where segment.points.count >= 2 {
            for i in 0..<(segment.points.count - 1) {
                let a = segment.points[i], b = segment.points[i + 1]
                let (inlandA, seaA) = extents(segment, at: i, config: config, terrain: terrain)
                let (inlandB, seaB) = extents(segment, at: i + 1, config: config, terrain: terrain)
                let quad = [a - segment.outward[i] * inlandA, b - segment.outward[i + 1] * inlandB,
                            b + segment.outward[i + 1] * seaB, a + segment.outward[i] * seaA]
                if DioramaPolygon.area(quad) > 0.001 { result.append(DioramaPolygon.counterClockwise(quad)) }
            }
        }
        return result
    }

    /// (inland, seaward) reach in metres of the band at station `i`.
    static func extents(_ segment: DioramaShorelineSegment, at i: Int, config: DioramaConfig, terrain: DioramaTerrain) -> (Double, Double) {
        switch segment.kind {
        case .beach:
            return (config.beachWidth * 0.65, config.beachWidth * 0.7)
        case .natural, .revetment:
            return (config.revetmentWidth * 0.5, config.revetmentWidth)
        case .seawall, .deck:
            let p = segment.points[i]
            let land = terrain.height(p)
            let toe = max(0, land - terrain.waterLevel + config.seawallSubmergedDepth) * config.seawallBatter
            return (config.copingWidth / 2, toe + 0.3 + (segment.hasRevetment ? config.revetmentWidth : 0))
        }
    }

    /// Connected indexed strip. Normals are shared across stations and cross-section rows, not per face.
    func sweep(_ segment: DioramaShorelineSegment, profiles: [[DV2]], swatches: [DioramaSwatch], into mesh: inout DioramaMesh) {
        guard profiles.count == segment.points.count, let row = profiles.first, row.count >= 2,
              profiles.allSatisfy({ $0.count == row.count }), segment.outward.count == profiles.count else { return }
        for band in 0..<(row.count - 1) {
            let uv = DioramaAtlas.uv(swatches[min(band, swatches.count - 1)], dark: false)
            let base = mesh.positions.count
            mesh.reserve(profiles.count * 2)
            for i in profiles.indices {
                for j in [band, band + 1] {
                    let p = profiles[i][j]
                    let closed = profiles[i].first == profiles[i].last
                    let previous = closed && j == 0 ? row.count - 2 : max(0, j - 1)
                    let next = closed && j == row.count - 1 ? 1 : min(row.count - 1, j + 1)
                    let lo = profiles[i][previous], hi = profiles[i][next]
                    let cross = hi - lo
                    let n = DV3(segment.outward[i].normalized * -cross.y, cross.x).normalized
                    mesh.vertex(DV3(segment.points[i] + segment.outward[i] * p.x, p.y), n, uv)
                }
            }
            for i in 0..<(profiles.count - 1) {
                let a = UInt32(base + i * 2), b = a + 2
                mesh.tri(a, b, b + 1); mesh.tri(a, b + 1, a + 1)
            }
        }
    }

    private func bank(_ segment: DioramaShorelineSegment, beach: Bool, ground: inout DioramaMesh) {
        let inland = beach ? config.beachWidth * 0.65 : config.revetmentWidth * 0.5
        let underwater = beach ? config.beachWidth * 0.7 : config.revetmentWidth
        let rows = segment.points.indices.map { i -> [DV2] in
            let p = segment.points[i], out = segment.outward[i]
            let top = terrain.height(p - out * inland) + 0.04
            let sea = terrain.waterLevel
            // The band meets the generated seabed exactly at its seaward edge.
            let bed = terrain.seabed(p + out * underwater)
            let mid = min(sea - underwater * 0.4 * config.beachSlope, sea - 0.02 + (bed - sea + 0.02) * 0.4)
            return [DV2(-inland, top), DV2(-inland * 0.65, sea + (top - sea) * 0.65),
                    DV2(-inland * 0.25, sea + (top - sea) * 0.25), DV2(0, sea - 0.015),
                    DV2(underwater * 0.4, mid), DV2(underwater, bed)]
        }
        sweep(segment, profiles: rows, swatches: beach ? [.earth, .earth, .wetSand, .wetSand, .wetSand] : [.earth, .rockWarm, .dampStone, .dampStone, .dampStone], into: &ground)
    }

    private func seawall(_ segment: DioramaShorelineSegment, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let sea = terrain.waterLevel
        let maxRise = segment.points.map { terrain.height($0) - sea }.max() ?? config.seawallHeight
        let courses = max(3, Int(ceil(max(maxRise, config.seawallHeight) / 0.45)))
        let rows = segment.points.indices.map { i -> [DV2] in
            let p = segment.points[i]
            let land = terrain.height(p)
            var row: [DV2] = []
            for k in 0...courses {
                let t = Double(k) / Double(courses)
                let z = land + (sea + 0.18 - land) * t
                row.append(DV2(max(0, land - z) * config.seawallBatter, z))
            }
            let toe = max(0, land - sea + config.seawallSubmergedDepth) * config.seawallBatter
            // The submerged toe lands on the generated seabed where the plate resumes.
            let bed = terrain.seabed(p + segment.outward[i] * (toe + 0.3))
            row += [DV2(max(0, land - sea) * config.seawallBatter, sea - 0.08),
                    DV2(toe, min(sea - config.seawallSubmergedDepth, bed + 0.05)),
                    DV2(toe + 0.3, bed)]
            return row
        }
        var colors = (0..<courses).map { $0 % 3 == 0 ? DioramaSwatch.rockPale : .coralStone }
        colors += [.algaeStone, .dampStone, .wetSand]
        sweep(segment, profiles: rows, swatches: colors, into: &ground)

        let half = config.copingWidth / 2, radius = min(config.copingRadius, config.copingHeight / 2)
        // Clockwise rounded rectangle in the cross-section: top, water side, bottom, land side.
        let corners = [DV2(-half, config.copingHeight), DV2(half, config.copingHeight), DV2(half, 0), DV2(-half, 0)]
        var rounded: [DV2] = []
        for i in corners.indices {
            let a = corners[(i + 3) % 4], b = corners[i], c = corners[(i + 1) % 4]
            let entry = b + (a - b).normalized * radius, exit = b + (c - b).normalized * radius
            for k in 0...6 {
                let t = Double(k) / 6, u = 1 - t
                rounded.append(entry * (u * u) + b * (2 * u * t) + exit * (t * t))
            }
        }
        rounded.append(rounded[0])
        let cap = segment.points.map { p in rounded.map { DV2($0.x, terrain.height(p) + $0.y) } }
        sweep(segment, profiles: cap, swatches: [.concrete], into: &ground)
        details(segment, props: &props)
    }

    private func rockBank(_ segment: DioramaShorelineSegment, standalone: Bool, ground: inout DioramaMesh, props: inout DioramaMesh) {
        let width = max(1, config.revetmentWidth), sea = terrain.waterLevel
        let start = standalone ? -width * 0.5 : 0.3
        let rows = segment.points.indices.map { i -> [DV2] in
            let p = segment.points[i], out = segment.outward[i]
            let top = standalone ? terrain.height(p + out * start) + 0.04 : sea + 0.22
            let toe = standalone ? 0 : max(0, terrain.height(p) - sea + config.seawallSubmergedDepth) * config.seawallBatter
            let bed = terrain.seabed(p + out * (toe + width))
            return [DV2(toe + start, top), DV2(toe + width * 0.45, min(sea - 0.25, bed + 0.1)), DV2(toe + width, bed)]
        }
        sweep(segment, profiles: rows, swatches: [.dampStone, .dampStone], into: &ground)
        var rng = DioramaRandom(seed: segment.id, salt: 207)
        let spacing = max(0.5, 1 / sqrt(max(0.2, config.rockDensity)))
        var along = 0.0
        for i in 0..<(segment.points.count - 1) {
            let a = segment.points[i], b = segment.points[i + 1], length = a.distance(to: b)
            var d = max(0, spacing - along)
            while d < length {
                let t = d / max(length, 0.001)
                let p = a + (b - a) * t
                let out = (segment.outward[i] * (1 - t) + segment.outward[i + 1] * t).normalized
                var offset = start + spacing * 0.4
                while offset < width {
                    let o = min(width - 0.15, offset + rng.range(-0.14...0.14))
                    let toe = standalone ? 0 : max(0, terrain.height(p) - sea + config.seawallSubmergedDepth) * config.seawallBatter
                    let q = p + out * (toe + o)
                    let top = standalone ? terrain.height(p + out * start) + 0.04 : sea + 0.22
                    let slope: Double
                    if o < width * 0.45 {
                        let t = (o - start) / max(0.01, width * 0.45 - start)
                        slope = top + (sea - 0.25 - top) * t
                    } else {
                        slope = sea - 0.25 - 0.65 * (o - width * 0.45) / (width * 0.55)
                    }
                    let size = rng.range(config.rockSizeRange)
                    if data.rect.contains(q), !data.buildings.contains(where: { DioramaPolygon.contains($0.ring, q) }) {
                        let variant = library.rocks[Int(rng.next() % UInt64(library.rocks.count))]
                        // Lower quarter is embedded in the slope: no floating boulders.
                        props.instance(variant, DioramaTransform(rotation: rng.range(0...(2 * .pi)),
                            scale: DV3(size, size * rng.range(0.85...1.1), size), translation: DV3(q, slope + size * 0.24)))
                    }
                    offset += spacing
                }
                d += spacing
            }
            along = (along + length).truncatingRemainder(dividingBy: spacing)
        }
    }

    private func details(_ segment: DioramaShorelineSegment, props: inout DioramaMesh) {
        var traveled = 0.0, next = 12.0, index = 0
        for i in 0..<(segment.points.count - 1) {
            let a = segment.points[i], b = segment.points[i + 1], length = a.distance(to: b)
            while next <= traveled + length {
                let t = (next - traveled) / max(length, 0.001)
                let p = a + (b - a) * t, out = segment.outward[i].normalized, tangent = out.right
                let top = terrain.height(p) + 0.11
                if index % 3 == 0 {
                    let q = p + out * 0.15
                    // Small dark recessed drain with stone surround; distinct from a painted perimeter.
                    props.box(centre: q, z0: top - 0.5, axis: tangent, halfLength: 0.13, halfWidth: 0.055, height: 0.18, .capCharcoal)
                } else if index % 3 == 1 {
                    let centre = DV3(p + out * 0.12, top - 0.3)
                    for k in 0..<20 {
                        let a = Double(k) * .pi / 10, b = Double(k + 1) * .pi / 10
                        props.tube(from: centre + DV3(tangent * (cos(a) * 0.12), sin(a) * 0.12),
                                   to: centre + DV3(tangent * (cos(b) * 0.12), sin(b) * 0.12), r0: 0.025, r1: 0.025, sides: 8, .metalCharcoal, cap: false)
                    }
                } else {
                    let q = p + out * (max(0, top - terrain.waterLevel) * config.seawallBatter + 0.28)
                    for side in [-1.0, 1.0] {
                        let foot = q + tangent * (side * 0.26)
                        props.cylinder(centre: foot, z0: terrain.waterLevel - 0.25, z1: top + 0.55, r0: 0.035, r1: 0.035, sides: 10, .metalCharcoal)
                    }
                    for z in stride(from: terrain.waterLevel - 0.05, to: top + 0.1, by: 0.3) {
                        props.tube(from: DV3(q - tangent * 0.26, z), to: DV3(q + tangent * 0.26, z), r0: 0.025, r1: 0.025, sides: 8, .metalCharcoal)
                    }
                }
                next += 26; index += 1
            }
            traveled += length
        }
    }

    private func beachDetails(_ segment: DioramaShorelineSegment, props: inout DioramaMesh, vegetation: inout DioramaMesh) {
        var rng = DioramaRandom(seed: segment.id, salt: 211)
        var traveled = 0.0, next = 8.0, index = 0
        for i in 0..<(segment.points.count - 1) {
            let a = segment.points[i], b = segment.points[i + 1], length = a.distance(to: b)
            if traveled + length >= next {
                let p = a + (b - a) * ((next - traveled) / max(length, 0.001)), out = segment.outward[i].normalized
                let q = p - out * (config.beachWidth * 0.58)
                let top = terrain.height(q) + 0.04
                if !data.buildings.contains(where: { DioramaPolygon.distanceToRing($0.ring, q) < 4 }), data.rect.contains(q) {
                    if index % 4 == 0 {
                        vegetation.instance(library.palm, DioramaTransform(rotation: rng.range(0...6.28), scale: DV3(0.7, 0.7, 0.7), translation: DV3(q, top)))
                    } else if index % 4 == 2 {
                        let mooring = p + out * 8
                        if data.water.contains(where: { DioramaPolygon.contains(polygon: $0.rings, mooring) }) {
                            props.instance(library.dhow, DioramaTransform(rotation: out.angle + 0.2, scale: DV3(0.4, 0.4, 0.4), translation: DV3(mooring, terrain.waterLevel)))
                        }
                    }
                }
                props.instance(library.rocks[index % 3], DioramaTransform(scale: DV3(0.5, 0.5, 0.5), translation: DV3(p - out * 0.5, terrain.waterLevel + 0.12)))
                for k in 0..<5 {
                    let weed = p - out * 1.5 + out.right * (Double(k) * 0.4)
                    let height = terrain.waterLevel + (top - terrain.waterLevel) * 1.5 / max(0.1, config.beachWidth * 0.65)
                    props.sphere(centre: DV3(weed, height + 0.025), radii: DV3(0.17, 0.06, 0.025), .seaweed, detail: 0)
                }
                next += 20; index += 1
            }
            traveled += length
        }
    }

    private func naturalDetails(_ segment: DioramaShorelineSegment, vegetation: inout DioramaMesh) {
        for i in stride(from: 0, to: segment.points.count, by: 10) {
            let p = segment.points[i] - segment.outward[i] * (config.revetmentWidth * 0.5)
            guard data.rect.contains(p), !data.buildings.contains(where: { DioramaPolygon.distanceToRing($0.ring, p) < 3 }) else { continue }
            vegetation.instance(library.bushes[i % library.bushes.count], DioramaTransform(scale: DV3(0.45, 0.45, 0.45), translation: DV3(p, terrain.height(p))))
        }
    }
}
