import Foundation

/// Shared joins for road boundaries, compound masonry and clipped foliage.
nonisolated enum DioramaLinearGeometry {
    static func key(_ p: DV2) -> String {
        "\(Int64((p.x * 10000).rounded())):\(Int64((p.y * 10000).rounded()))"
    }

    /// Connects directed spans without bridging intentional openings. Closed loops repeat their start.
    static func chains(_ edges: [(DV2, DV2)]) -> [[DV2]] {
        let edges = edges.filter { $0.0.distance(to: $0.1) > 0.0001 }
        var outgoing: [String: [Int]] = [:]
        var incoming: [String: Int] = [:]
        for i in edges.indices {
            outgoing[key(edges[i].0), default: []].append(i)
            incoming[key(edges[i].1), default: 0] += 1
        }
        var used: Set<Int> = []
        var result: [[DV2]] = []
        let starts = edges.indices.filter { incoming[key(edges[$0].0), default: 0] != 1 }
        for start in starts + Array(edges.indices) where !used.contains(start) {
            var line = [edges[start].0]
            var next: Int? = start
            while let i = next, used.insert(i).inserted {
                line.append(edges[i].1)
                next = outgoing[key(edges[i].1)]?.first { !used.contains($0) }
            }
            if line.count > 1 { result.append(line) }
        }
        return result
    }

    /// Keep bend vertices and openings, but remove redundant clipping stations before tessellation.
    static func simplified(_ line: [DV2]) -> [DV2] {
        var result: [DV2] = []
        for p in line {
            if let last = result.last, last.distance(to: p) < 0.00001 { continue }
            while result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                let before = b - a, after = p - b
                guard before.dot(after) > 0, abs(before.normalized.cross(after.normalized)) < 0.000001 else { break }
                result.removeLast()
            }
            result.append(p)
        }
        return result
    }

    static func rounded(_ line: [DV2], radius: Double) -> [DV2] {
        guard line.count > 2 else { return line }
        let closed = line[0].distance(to: line[line.count - 1]) < 0.0002
        let source = closed ? Array(line.dropLast()) : line
        var result: [DV2] = []
        for i in source.indices {
            if !closed && (i == 0 || i == source.count - 1) { result.append(source[i]); continue }
            let a = source[(i + source.count - 1) % source.count], b = source[i], c = source[(i + 1) % source.count]
            let before = (b - a).normalized, after = (c - b).normalized
            if before.dot(after) > 0.995 { result.append(b); continue }
            let reach = min(radius, a.distance(to: b) * 0.35, b.distance(to: c) * 0.35)
            let entry = b - before * reach, exit = b + after * reach
            for k in 0...5 {
                let t = Double(k) / 5, u = 1 - t
                result.append(entry * (u * u) + b * (2 * u * t) + exit * (t * t))
            }
        }
        if closed, let first = result.first { result.append(first) }
        return result
    }
}

extension DioramaMesh {
    /// Closed, smoothly shaded rounded-rectangle sweep. Adjacent spans share the exact same
    /// cross-section. Noise deforms a single box-like foliage skin, never stacks separate blobs.
    nonisolated mutating func mouldedStrip(
        _ path: [DV2], halfWidth: Double, height: Double, radius: Double,
        lateralOffset: Double = 0, foliage: Bool = false,
        swatch: DioramaSwatch, base: (DV2) -> Double
    ) {
        guard path.count >= 2, halfWidth > 0, height > 0 else { return }
        let clean = DioramaLinearGeometry.simplified(path)
        guard clean.count >= 2 else { return }
        let line = DioramaPolygon.densify(clean, maxStep: foliage ? 0.65 : 1.5)
        let closed = line[0].distance(to: line[line.count - 1]) < 0.0002
        let count = line.count
        let r = min(radius, halfWidth * 0.95, height * 0.45)
        var profile: [DV2] = []
        // Counter-clockwise in lateral/height coordinates.
        for corner in 0..<4 {
            let centres = [DV2(halfWidth - r, r), DV2(halfWidth - r, height - r),
                           DV2(-halfWidth + r, height - r), DV2(-halfWidth + r, r)]
            for k in 0...3 {
                let angle = -Double.pi / 2 + Double(corner) * .pi / 2 + Double(k) * .pi / 6
                profile.append(centres[corner] + DV2(cos(angle), sin(angle)) * r)
            }
        }
        let width = profile.count
        var points: [DV3] = []
        var sections: [[DV2]] = []
        var sides: [DV2] = []
        for i in line.indices {
            let previous = i == 0 ? (closed ? line[count - 2] : line[0]) : line[i - 1]
            let next = i == count - 1 ? (closed ? line[1] : line[i]) : line[i + 1]
            let before = (line[i] - previous).normalized.right
            let after = (next - line[i]).normalized.right
            let side: DV2
            if !closed && i == 0 { side = after }
            else if !closed && i == count - 1 { side = before }
            else {
                let bisector = (before + after).normalized
                side = bisector * (1 / max(0.35, bisector.dot(after)))
            }
            sides.append(side)
            let p = line[i]
            let ground = base(p)
            let wave = sin(p.x * 1.73 + p.y * 0.83) * 0.055 + sin(p.y * 2.31 - p.x * 0.61) * 0.025
            var section: [DV2] = []
            for q in profile {
                let fullness = foliage ? 1 + wave + 0.045 * sin(p.x * 2.1 + p.y + q.y * 4) : 1
                let x = q.x * fullness + lateralOffset
                let z = q.y * (foliage ? 1 + wave * 1.4 : 1)
                section.append(DV2(x, z))
                points.append(DV3(p + side * x, ground + z))
            }
            sections.append(section)
        }
        var faces: [(Int, Int, Int)] = []
        var normals = [DV3](repeating: DV3(0, 0, 0), count: points.count)
        for i in 0..<(count - 1) {
            for j in 0..<width {
                let k = (j + 1) % width
                let delta = profile[k] - profile[j]
                let out = DV3((sides[i] + sides[i + 1]).normalized * delta.y, -delta.x)
                let a = i * width + j, b = (i + 1) * width + j
                let c = (i + 1) * width + k, d = i * width + k
                for triangle in [(a, b, c), (a, c, d)] {
                    var (v0, v1, v2) = triangle
                    if (points[v1] - points[v0]).cross(points[v2] - points[v0]).dot(out) < 0 { swap(&v1, &v2) }
                    let n = (points[v1] - points[v0]).cross(points[v2] - points[v0])
                    for v in [v0, v1, v2] { normals[v] = normals[v] + n }
                    faces.append((v0, v1, v2))
                }
            }
        }
        if closed {
            for j in 0..<width {
                let last = (count - 1) * width + j
                let n = normals[j] + normals[last]
                normals[j] = n; normals[last] = n
            }
        }
        reserve(points.count + width * 2)
        let start = UInt32(positions.count)
        for i in points.indices {
            let q = profile[i % width]
            let color: DioramaSwatch = foliage ? (q.y > height * 0.75 ? .leafLight : (q.y < height * 0.2 ? .leafDark : .hedge)) : swatch
            vertex(points[i], normals[i].normalized, DioramaAtlas.uv(color, dark: false))
        }
        for (a, b, c) in faces { face(start + UInt32(a), start + UInt32(b), start + UInt32(c)) }
        if !closed {
            for end in [0, count - 1] {
                let out = end == 0 ? (line[0] - line[1]).normalized : (line[count - 1] - line[count - 2]).normalized
                for (a, b, c) in DioramaPolygon.triangulate(sections[end]) {
                    triangle(points[end * width + a], points[end * width + b], points[end * width + c], swatch, normal: DV3(out, 0))
                }
            }
        }
    }
}
