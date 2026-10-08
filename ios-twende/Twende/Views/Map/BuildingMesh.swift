import SceneKit
import simd

/// Material-batched triangles in local east/north/up metres. Curves share analytic normals.
struct BuildingMesh {
    private(set) var positions: [SCNVector3] = []
    private var normals: [SCNVector3] = []
    private var textureCoordinates: [CGPoint] = []

    mutating func triangle(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, normal: SIMD3<Double>? = nil, uv: [CGPoint]? = nil) {
        let cross = simd_cross(b - a, c - a)
        guard simd_length(cross) > 0.0000001 else { return }
        let n = normal ?? simd_normalize(cross)
        for (index, p) in [a, b, c].enumerated() {
            positions.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
            normals.append(SCNVector3(Float(n.x), Float(n.y), Float(n.z)))
            textureCoordinates.append(uv?[index] ?? CGPoint(x: p.x / 3, y: p.y / 3))
        }
    }

    mutating func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, normal: SIMD3<Double>? = nil, width: Double = 1, height: Double = 1) {
        triangle(a, b, c, normal: normal, uv: [.zero, CGPoint(x: width, y: 0), CGPoint(x: width, y: height)])
        triangle(a, c, d, normal: normal, uv: [.zero, CGPoint(x: width, y: height), CGPoint(x: 0, y: height)])
    }

    /// Per-vertex normals keep curved strips smooth while preserving planar adjoining surfaces.
    mutating func smoothQuad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, normals ns: [SIMD3<Double>]) {
        guard ns.count == 4 else { return }
        let points = [a, b, c, d]
        for indices in [[0, 1, 2], [0, 2, 3]] {
            guard simd_length(simd_cross(points[indices[1]] - points[indices[0]], points[indices[2]] - points[indices[0]])) > 0.0000001 else { continue }
            for i in indices {
                let p = points[i], n = ns[i]
                positions.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
                normals.append(SCNVector3(Float(n.x), Float(n.y), Float(n.z)))
                textureCoordinates.append(.zero)
            }
        }
    }

    mutating func smoothTriangle(_ points: [SIMD3<Double>], normals ns: [SIMD3<Double>]) {
        guard points.count == 3, ns.count == 3 else { return }
        for i in 0..<3 {
            let p = points[i], n = ns[i]
            positions.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
            normals.append(SCNVector3(Float(n.x), Float(n.y), Float(n.z)))
            textureCoordinates.append(.zero)
        }
    }

    /// A single smooth surface of revolution, not a stack of cylinders or stair-stepped extrusions.
    mutating func revolve(centre: SIMD2<Double>, profile: [SIMD2<Double>], segments: Int = 64) {
        guard profile.count >= 2 else { return }
        for row in 0..<(profile.count - 1) {
            func vertex(_ level: Int, _ segment: Int) -> (SIMD3<Double>, SIMD3<Double>) {
                let p = profile[level]
                let before = profile[max(0, level - 1)]
                let after = profile[min(profile.count - 1, level + 1)]
                let slope = after - before
                let angle = Double(segment) * 2 * .pi / Double(segments)
                let n = simd_normalize(SIMD3<Double>(slope.y * cos(angle), slope.y * sin(angle), -slope.x))
                return (SIMD3(centre.x + p.x * cos(angle), centre.y + p.x * sin(angle), p.y), n)
            }
            for segment in 0..<segments {
                let a = vertex(row, segment), b = vertex(row, segment + 1)
                let c = vertex(row + 1, segment + 1), d = vertex(row + 1, segment)
                for triplet in [[a, b, c], [a, c, d]] {
                    guard simd_length(simd_cross(triplet[1].0 - triplet[0].0, triplet[2].0 - triplet[0].0)) > 0.0000001 else { continue }
                    for (p, n) in triplet {
                        positions.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
                        normals.append(SCNVector3(Float(n.x), Float(n.y), Float(n.z)))
                        textureCoordinates.append(CGPoint(x: p.x / 3, y: p.z / 3))
                    }
                }
            }
        }
    }

    /// Rounded cross-section swept around a continuous contour; broad highlights replace knife edges.
    mutating func perimeter(rings: [[SIMD2<Double>]], bottom: Double, top: Double, projection: Double, profileSegments: Int = 8) {
        guard top > bottom, profileSegments >= 2, profileSegments <= 16 else { return }
        for ring in rings where ring.count >= 3 {
            let outer: [SIMD2<Double>] = ring.indices.map { i in
                let a = simd_normalize(ring[i] - ring[(i + ring.count - 1) % ring.count])
                let b = simd_normalize(ring[(i + 1) % ring.count] - ring[i])
                let n1 = SIMD2(a.y, -a.x), n2 = SIMD2(b.y, -b.x)
                guard simd_length(n1 + n2) > 0.001 else { return ring[i] + n1 * projection }
                let bisector = simd_normalize(n1 + n2)
                return ring[i] + bisector * (projection / max(0.5, simd_dot(bisector, n1)))
            }
            let ns = BuildingContour.outwardNormals(ring)
            let halfHeight = (top - bottom) / 2, centreZ = (top + bottom) / 2
            for step in 0..<profileSegments {
                let angle0 = -.pi / 2 + Double(step) * .pi / Double(profileSegments)
                let angle1 = -.pi / 2 + Double(step + 1) * .pi / Double(profileSegments)
                func p(_ i: Int, _ angle: Double) -> SIMD3<Double> {
                    let xy = ring[i] + (outer[i] - ring[i]) * cos(angle)
                    return SIMD3(xy.x, xy.y, centreZ + halfHeight * sin(angle))
                }
                func n(_ i: Int, _ angle: Double) -> SIMD3<Double> {
                    simd_normalize(SIMD3(ns[i].x * cos(angle) / max(0.01, projection), ns[i].y * cos(angle) / max(0.01, projection), sin(angle) / halfHeight))
                }
                for i in ring.indices {
                    let j = (i + 1) % ring.count
                    smoothQuad(p(i, angle0), p(j, angle0), p(j, angle1), p(i, angle1), normals: [n(i, angle0), n(j, angle0), n(j, angle1), n(i, angle1)])
                }
            }
        }
    }

    /// Reuses the Slipway kit's closed chamfered surfaces without changing landmark pigment.
    mutating func append(_ mesh: DioramaMesh) {
        for id in mesh.indices {
            let i = Int(id), p = mesh.positions[i], n = mesh.normals[i]
            positions.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
            normals.append(SCNVector3(Float(n.x), Float(n.y), Float(n.z)))
            textureCoordinates.append(CGPoint(x: p.x / 3, y: p.z / 3))
        }
    }

    func node(name: String, material: SCNMaterial) -> SCNNode {
        let sources = [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: textureCoordinates)]
        let indices = (0..<positions.count).map { UInt32($0) }
        let geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = name
        return node
    }
}
