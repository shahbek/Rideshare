import SceneKit
import UIKit
import simd

/// Smooth lofts and small machined details for the miniature fleet. All geometry is local: +Y is up,
/// −Z is the nose, and wheel contact is Y=0. Normals are averaged across rings, never faceted.
enum VehicleGeometry {
    /// Ring components are longitudinal position, half-width, vertical centre, and half-height.
    typealias Ring = SIMD4<Float>

    static func material(_ color: UIColor, metal: CGFloat = 0, roughness: CGFloat = 0.4) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = metal
        material.roughness.contents = roughness
        return material
    }

    /// Catmull–Rom interpolation of rounded-rectangle sections produces continuous shoulders, bonnets
    /// and roof crowns rather than stacked boxes. End caps share the same surface material.
    static func loft(_ rings: [Ring], material: SCNMaterial, roundness: Float = 0.5, wheelbase: Float? = nil) -> SCNNode {
        guard rings.count >= 2 else { return SCNNode() }
        let sides = 40
        let subdivisions = wheelbase == nil ? 8 : 16
        var sections: [Ring] = []
        for i in 0..<(rings.count - 1) {
            let p0 = rings[max(0, i - 1)], p1 = rings[i]
            let p2 = rings[i + 1], p3 = rings[min(rings.count - 1, i + 2)]
            for step in 0..<subdivisions {
                let t = Float(step) / Float(subdivisions)
                var section = Ring.zero
                for axis in 0..<4 {
                    let a: Float = p0[axis]
                    let b: Float = p1[axis]
                    let c: Float = p2[axis]
                    let d: Float = p3[axis]
                    let linear: Float = (c - a) * t
                    let quadratic: Float = ((2 * a - 5 * b) + (4 * c - d)) * t * t
                    let cubic: Float = ((3 * b - a) + (d - 3 * c)) * t * t * t
                    let interpolated = (2 * b + linear + quadratic + cubic) * 0.5
                    // Prevent thin roof sections and short ends from overshooting into ripples or spikes.
                    section[axis] = min(max(interpolated, min(b, c)), max(b, c))
                }
                sections.append(section)
            }
        }
        sections.append(rings[rings.count - 1])
        var vertices: [SIMD3<Float>] = []
        var indices: [Int32] = []
        for section in sections {
            for i in 0..<sides {
                let angle = Float(i) * 2 * .pi / Float(sides)
                let c = cos(angle), s = sin(angle)
                let x = (c < 0 ? -1 : Float(1)) * pow(abs(c), roundness) * max(section.y, 0.001)
                let y = (s < 0 ? -1 : Float(1)) * pow(abs(s), roundness) * max(section.w, 0.001)
                var surfaceY = section.z + y
                if let wheelbase {
                    let distance = min(abs(section.x - wheelbase), abs(section.x + wheelbase))
                    let archRadius: Float = 0.395
                    if distance < archRadius {
                        let archTop: Float = 0.34 + sqrt(archRadius * archRadius - distance * distance)
                        let edgeWeight = min(1, max(0, (abs(x) / max(section.y, 0.001) - 0.70) / 0.16))
                        surfaceY += max(0, archTop - surfaceY) * edgeWeight
                    }
                }
                vertices.append(SIMD3(x, surfaceY, section.x))
            }
        }
        for row in 0..<(sections.count - 1) {
            for side in 0..<sides {
                let a = Int32(row * sides + side)
                let b = Int32(row * sides + (side + 1) % sides)
                let c = a + Int32(sides), d = b + Int32(sides)
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        for end in [0, sections.count - 1] {
            let ring = sections[end]
            let centre = Int32(vertices.count)
            vertices.append(SIMD3(0, ring.z, ring.x))
            // Caps need their own vertices; sharing normals with the shell dents the nose and tail.
            let capStart = Int32(vertices.count)
            for side in 0..<sides { vertices.append(vertices[end * sides + side]) }
            for side in 0..<sides {
                let a = capStart + Int32(side)
                let b = capStart + Int32((side + 1) % sides)
                indices.append(contentsOf: end == 0 ? [centre, b, a] : [centre, a, b])
            }
        }
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let normal = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            normals[a] += normal
            normals[b] += normal
            normals[c] += normal
        }
        let source = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let normalSource = SCNGeometrySource(normals: normals.map {
            let n = simd_length_squared($0) > 0.00000001 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0)
            return SCNVector3(n.x, n.y, n.z)
        })
        let mesh = SCNGeometry(sources: [source, normalSource], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        mesh.materials = [material]
        return SCNNode(geometry: mesh)
    }

    /// Shared interpolation keeps panel details on exactly the same surface as their body shell.
    static func sample(_ values: [SIMD4<Float>], at z: Float) -> SIMD4<Float> {
        guard let first = values.first, let last = values.last else { return .zero }
        if z <= first.x { return first }
        if z >= last.x { return last }
        let i = max(0, (values.firstIndex { $0.x > z } ?? values.count - 1) - 1)
        let a = values[max(0, i - 1)], b = values[i]
        let c = values[i + 1], d = values[min(values.count - 1, i + 2)]
        let t = (z - b.x) / max(0.0001, c.x - b.x)
        let tangent: SIMD4<Float> = (c - a) * t
        let quadraticStart: SIMD4<Float> = a * 2 - b * 5
        let quadraticEnd: SIMD4<Float> = c * 4 - d
        let quadratic: SIMD4<Float> = (quadraticStart + quadraticEnd) * (t * t)
        let cubicStart: SIMD4<Float> = b * 3 - a
        let cubicEnd: SIMD4<Float> = d - c * 3
        let cubic: SIMD4<Float> = (cubicStart + cubicEnd) * (t * t * t)
        let linearPart: SIMD4<Float> = b * 2 + tangent
        let interpolated: SIMD4<Float> = (linearPart + quadratic + cubic) * 0.5
        return simd_clamp(interpolated, simd_min(b, c), simd_max(b, c))
    }

    static func cubic(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>, t: Float) -> SIMD2<Float> {
        let linear: SIMD2<Float> = (c - a) * t
        let quadraticStart: SIMD2<Float> = a * 2 - b * 5
        let quadraticEnd: SIMD2<Float> = c * 4 - d
        let quadratic: SIMD2<Float> = (quadraticStart + quadraticEnd) * (t * t)
        let cubicStart: SIMD2<Float> = b * 3 - a
        let cubicEnd: SIMD2<Float> = d - c * 3
        let cubic: SIMD2<Float> = (cubicStart + cubicEnd) * (t * t * t)
        let linearPart: SIMD2<Float> = b * 2 + linear
        let interpolated: SIMD2<Float> = (linearPart + quadratic + cubic) * 0.5
        return simd_clamp(interpolated, simd_min(b, c), simd_max(b, c))
    }

    /// Area-weighted smooth normals remain continuous across material boundaries such as flush glass.
    static func mesh(_ vertices: [SIMD3<Float>], groups: [[Int32]], materials: [SCNMaterial]) -> SCNNode {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for indices in groups {
            for i in stride(from: 0, to: indices.count, by: 3) {
                let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
                let normal = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
                normals[a] += normal
                normals[b] += normal
                normals[c] += normal
            }
        }
        let positions = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let surfaceNormals = SCNGeometrySource(normals: normals.map {
            let n = simd_length_squared($0) > 0.00000001 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0)
            return SCNVector3(n.x, n.y, n.z)
        })
        let elements = groups.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
        let geometry = SCNGeometry(sources: [positions, surfaceNormals], elements: elements)
        geometry.materials = materials
        return SCNNode(geometry: geometry)
    }

    /// A thin curved panel, sampled as a grid rather than a bent box. Used for glazing and mudguards.
    @discardableResult
    static func panel(_ parent: SCNNode, columns: Int = 24, rows: Int = 16, material: SCNMaterial,
                      surface: (Float, Float) -> SIMD3<Float>) -> SCNNode {
        var positions: [SIMD3<Float>] = []
        var indices: [Int32] = []
        for row in 0...rows {
            for column in 0...columns {
                positions.append(surface(Float(column) / Float(columns), Float(row) / Float(rows)))
            }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let a = Int32(row * (columns + 1) + column), b = a + 1
                let c = a + Int32(columns + 1), d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        // Thin open panels have an inside face too; never change a shared material globally.
        let finish = material.copy() as? SCNMaterial ?? material
        finish.isDoubleSided = true
        let node = mesh(positions, groups: [indices], materials: [finish])
        parent.addChildNode(node)
        return node
    }

    /// Revolve an axial/radial cross-section around the wheel axle. Shoulder and bead are one surface.
    @discardableResult
    static func revolve(_ parent: SCNNode, profile: [SIMD2<Float>], at centre: SIMD3<Float>, material: SCNMaterial) -> SCNNode {
        let segments = 40
        var positions: [SIMD3<Float>] = []
        var indices: [Int32] = []
        for p in profile {
            for step in 0..<segments {
                let angle = Float(step) * 2 * .pi / Float(segments)
                positions.append(centre + SIMD3(p.x, cos(angle) * p.y, sin(angle) * p.y))
            }
        }
        for row in 0..<max(0, profile.count - 1) {
            for step in 0..<segments {
                let a = Int32(row * segments + step), b = Int32(row * segments + (step + 1) % segments)
                let c = a + Int32(segments), d = b + Int32(segments)
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        let node = mesh(positions, groups: [indices], materials: [material])
        parent.addChildNode(node)
        return node
    }

    @discardableResult
    static func box(_ parent: SCNNode, _ dimensions: SIMD3<Float>, at position: SIMD3<Float>, material: SCNMaterial, radius: CGFloat = 0.03) -> SCNNode {
        let geometry = SCNBox(width: CGFloat(dimensions.x), height: CGFloat(dimensions.y), length: CGFloat(dimensions.z), chamferRadius: radius)
        geometry.chamferSegmentCount = 3
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = position
        parent.addChildNode(node)
        return node
    }

    @discardableResult
    static func ellipsoid(_ parent: SCNNode, size: SIMD3<Float>, at position: SIMD3<Float>, material: SCNMaterial) -> SCNNode {
        let geometry = SCNSphere(radius: 1)
        geometry.segmentCount = 32
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = position
        node.simdScale = size
        parent.addChildNode(node)
        return node
    }

    @discardableResult
    static func rod(_ parent: SCNNode, from: SIMD3<Float>, to: SIMD3<Float>, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let delta = to - from
        let length = simd_length(delta)
        guard length > 0.0001 else { return SCNNode() }
        let geometry = SCNCylinder(radius: radius, height: CGFloat(length))
        geometry.radialSegmentCount = 12
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = (from + to) / 2
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
        parent.addChildNode(node)
        return node
    }

    static func seam(_ parent: SCNNode, points: [SIMD3<Float>], radius: CGFloat = 0.008, material: SCNMaterial) {
        guard points.count > 1 else { return }
        let sides = 8
        var vertices: [SIMD3<Float>] = []
        var indices: [Int32] = []
        for i in points.indices {
            let delta = points[min(i + 1, points.count - 1)] - points[max(0, i - 1)]
            let tangent = simd_length_squared(delta) > 0.000001 ? simd_normalize(delta) : SIMD3<Float>(0, 0, 1)
            let reference = abs(tangent.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let u = simd_normalize(simd_cross(tangent, reference))
            let v = simd_cross(tangent, u)
            for side in 0..<sides {
                let angle = Float(side) * 2 * .pi / Float(sides)
                vertices.append(points[i] + Float(radius) * (u * cos(angle) + v * sin(angle)))
            }
        }
        for row in 0..<(points.count - 1) {
            for side in 0..<sides {
                let a = Int32(row * sides + side), b = Int32(row * sides + (side + 1) % sides)
                let c = a + Int32(sides), d = b + Int32(sides)
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        parent.addChildNode(mesh(vertices, groups: [indices], materials: [material]))
    }

    /// Tyre shoulders, recessed brake disc, alloy rim, radial spokes and centre cap on both sides.
    static func wheel(_ parent: SCNNode, at centre: SIMD3<Float>, radius: Float, width: Float, tyre: SCNMaterial, alloy: SCNMaterial, dark: SCNMaterial, spokes: Int = 8) {
        let rubber = SCNCylinder(radius: CGFloat(radius * 0.94), height: CGFloat(width))
        rubber.radialSegmentCount = 40
        rubber.materials = [tyre]
        let core = SCNNode(geometry: rubber)
        core.simdPosition = centre
        core.eulerAngles.z = .pi / 2
        parent.addChildNode(core)
        for side in [Float(-1), 1] {
            let ring = SCNTorus(ringRadius: CGFloat(radius * 0.78), pipeRadius: CGFloat(radius * 0.22))
            ring.ringSegmentCount = 40
            ring.pipeSegmentCount = 12
            ring.materials = [tyre]
            let shoulder = SCNNode(geometry: ring)
            shoulder.eulerAngles.z = .pi / 2
            shoulder.simdPosition = centre + SIMD3(side * width * 0.35, 0, 0)
            parent.addChildNode(shoulder)
            let faceX = centre.x + side * width * 0.52
            let disc = SCNCylinder(radius: CGFloat(radius * 0.61), height: 0.014)
            disc.radialSegmentCount = 32
            disc.materials = [dark]
            let brake = SCNNode(geometry: disc)
            brake.eulerAngles.z = .pi / 2
            brake.simdPosition = SIMD3(faceX, centre.y, centre.z)
            parent.addChildNode(brake)
            let rim = SCNTorus(ringRadius: CGFloat(radius * 0.64), pipeRadius: CGFloat(radius * 0.065))
            rim.ringSegmentCount = 32
            rim.pipeSegmentCount = 8
            rim.materials = [alloy]
            let rimNode = SCNNode(geometry: rim)
            rimNode.eulerAngles.z = .pi / 2
            rimNode.simdPosition = SIMD3(faceX, centre.y, centre.z)
            parent.addChildNode(rimNode)
            for i in 0..<spokes {
                let angle = Float(i) * 2 * .pi / Float(spokes)
                rod(parent, from: SIMD3(faceX + side * 0.01, centre.y, centre.z),
                    to: SIMD3(faceX + side * 0.015, centre.y + cos(angle) * radius * 0.60, centre.z + sin(angle) * radius * 0.60),
                    radius: CGFloat(radius * 0.055), material: alloy)
            }
            ellipsoid(parent, size: SIMD3(0.025, radius * 0.20, radius * 0.20), at: SIMD3(faceX + side * 0.025, centre.y, centre.z), material: alloy)
        }
    }

    static func arch(_ parent: SCNNode, at centre: SIMD3<Float>, radius: Float, material: SCNMaterial, thickness: CGFloat = 0.035) {
        let points: [SIMD3<Float>] = (0...28).map { i in
            let angle = Float(i) / 28 * .pi
            return centre + SIMD3(0, sin(angle) * radius, cos(angle) * radius)
        }
        seam(parent, points: points, radius: thickness, material: material)
    }
}
