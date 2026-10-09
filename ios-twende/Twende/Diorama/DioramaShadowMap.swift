import Metal
import simd

/// Tile-local directional shadows, cached until the lighting preset or visible geometry changes.
/// The static tile costs one depth pass per change, not another scene render on every water frame.
/// Baked geometry and instanced prototypes both cast.
nonisolated final class DioramaShadowMap {
    let texture: MTLTexture
    private let pipeline: MTLRenderPipelineState
    private let instancedPipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let corners: [SIMD3<Float>]
    private struct CacheKey: Equatable {
        let preset: DioramaTimeOfDay
        let landmarkPresent: Bool
        let categories: Set<DioramaCategory>
        let low: SIMD3<Float>?
        let high: SIMD3<Float>?
    }
    private var cachedKey: CacheKey?
    private var matrix: simd_float4x4 = matrix_identity_float4x4

    /// `bounds`: caster envelope (non-sprite vertices plus instance spheres).
    init?(device: MTLDevice, library: MTLLibrary, bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?) {
        guard let bounds else { return nil }
        guard let function = library.makeFunction(name: "dioramaShadowVertex"),
              let instanced = library.makeFunction(name: "dioramaInstancedShadowVertex") else { return nil }
        func make(_ vertex: MTLFunction, label: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = vertex
            descriptor.depthAttachmentPixelFormat = .depth32Float
            return try? DioramaPipelineCache.shared.state(device: device, descriptor: descriptor)
        }
        guard let pipeline = make(function, label: "Diorama directional shadow depth"),
              let instancedPipeline = make(instanced, label: "Diorama instanced shadow depth") else { return nil }
        self.pipeline = pipeline
        self.instancedPipeline = instancedPipeline
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depth = depth
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        target.usage = [.renderTarget, .shaderRead]
        target.storageMode = .private
        guard let texture = device.makeTexture(descriptor: target) else { return nil }
        self.texture = texture
        let low = bounds.minimum, high = bounds.maximum
        guard low.x.isFinite, high.x > low.x else { return nil }
        var corners: [SIMD3<Float>] = []
        for x in [low.x - 2, high.x + 2] {
            for y in [low.y - 2, high.y + 2] {
                for z in [low.z - 2, high.z + 2] { corners.append(SIMD3(x, y, z)) }
            }
        }
        self.corners = corners
    }

    /// Returns nil if encoding fails; callers disable sampling until a valid map exists.
    /// `focus` is the world bounds of what the camera sees; the light frustum is fitted to it
    /// (snapped to 8 m so the map is only re-rendered when the view moves meaningfully), while
    /// the depth range still spans the whole tile so off-screen casters keep casting into view.
    func update(command: MTLCommandBuffer, vertices: MTLBuffer, indices: MTLBuffer, instances: MTLBuffer?,
                ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup],
                focus: (SIMD3<Float>, SIMD3<Float>)?,
                sun: SIMD3<Float>, preset: DioramaTimeOfDay, landmarkPresent: Bool = false,
                lod: DioramaLODSelector? = nil, timing: DioramaPassTimer.Frame? = nil) -> simd_float4x4? {
        let casters = ranges.filter { !$0.category.isEmissive && $0.category != .water && !$0.translucent }
        let castingGroups = groups.filter { !$0.category.isEmissive }
        let snap: Float = 8
        let low = focus.map { floor($0.0 / snap) * snap }
        let high = focus.map { ceil($0.1 / snap) * snap }
        let key = CacheKey(preset: preset, landmarkPresent: landmarkPresent, categories: Set(casters.map(\.category)).union(castingGroups.map(\.category)), low: low, high: high)
        if cachedKey == key { return matrix }
        var focusCorners: [SIMD3<Float>] = []
        if let lo = low, let hi = high {
            for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z - 2, hi.z + 2] { focusCorners.append(SIMD3(x, y, z)) } } }
        }
        let forward = -simd_normalize(sun)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), sun))
        let up = simd_normalize(simd_cross(sun, right))
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in corners {
            let q = SIMD3(simd_dot(right, p), simd_dot(up, p), simd_dot(forward, p))
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        if !focusCorners.isEmpty {
            // Lateral extent from the view; depth range stays the tile's so distant casters still cast.
            var flo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), fhi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for p in focusCorners {
                let q = SIMD2(simd_dot(right, p), simd_dot(up, p))
                flo = simd_min(flo, q); fhi = simd_max(fhi, q)
            }
            lo.x = max(lo.x, flo.x - 6); lo.y = max(lo.y, flo.y - 6)
            hi.x = min(hi.x, fhi.x + 6); hi.y = min(hi.y, fhi.y + 6)
        }
        let span = simd_max(hi - lo, SIMD3<Float>(repeating: 1))
        let x = right * (2 / span.x), y = up * (2 / span.y), z = forward / span.z
        var candidate = simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-(hi.x + lo.x) / span.x, -(hi.y + lo.y) / span.y, -lo.z / span.z, 1)
        ))
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        timing?.attach(pass, "Shadow")
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Diorama cached sun shadows"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: 2048, height: 2048, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        // Closed meshes with geometric winding: cull back faces so only front faces write depth.
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setDepthBias(0.4, slopeScale: 1.0, clamp: 0.001)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&candidate, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        // Shadow texels are span/2048 m wide; detail below half a texel cannot change the map.
        let texelSelector = lod?.orthographic(0.5 * min(span.x, span.y) / 2048)
        let lodIndices = lod?.table.indexBuffer ?? indices
        let shadowRanges = DioramaDrawPlan.ranges(DioramaDrawPlan.levels(casters.filter { $0.intersects(candidate) }, selector: texelSelector))
        timing?.count("Shadow", triangles: shadowRanges.reduce(0) { $0 + $1.count / 3 })
        for range in shadowRanges {
            encoder.setCullMode(range.doubleSided ? .none : .back)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32,
                                          indexBuffer: range.usesLODBuffer ? lodIndices : indices, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        if let instances, !castingGroups.isEmpty {
            encoder.setRenderPipelineState(instancedPipeline)
            encoder.setVertexBuffer(instances, offset: 0, index: 3)
            // Light-space culling, not camera culling: offscreen objects still cast into view.
            let retained = castingGroups.filter {
                $0.fullCount > 0 && DioramaRenderLayer.Range(category: $0.category, start: 0, count: 0,
                    minimum: $0.minimum, maximum: $0.maximum).intersects(candidate)
            }
            let shadowGroups = DioramaDrawPlan.instances(retained, selector: texelSelector)
            timing?.count("Shadow", triangles: shadowGroups.reduce(0) { $0 + $1.count / 3 * $1.instanceCount })
            for group in shadowGroups {
                encoder.setCullMode(group.doubleSided ? .none : .back)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: group.count, indexType: .uint32,
                    indexBuffer: group.usesLODBuffer ? lodIndices : indices, indexBufferOffset: group.start * MemoryLayout<UInt32>.stride,
                    instanceCount: group.instanceCount, baseVertex: 0, baseInstance: group.firstInstance)
            }
        }
        encoder.endEncoding()
        matrix = candidate
        cachedKey = key
        return matrix
    }
}
