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
    private var cachedKey: String?
    private var matrix: simd_float4x4 = matrix_identity_float4x4

    init?(device: MTLDevice, library: MTLLibrary, vertices: [BuildingRenderVertex], instances: [DioramaInstanceData]) {
        guard let function = library.makeFunction(name: "dioramaShadowVertex"),
              let instanced = library.makeFunction(name: "dioramaInstancedShadowVertex") else { return nil }
        func make(_ vertex: MTLFunction, label: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = vertex
            descriptor.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: descriptor)
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
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices where v.appearance.w < 3.5 {
            let p = SIMD3<Float>(v.position.x, v.position.y, v.position.z)
            low = simd_min(low, p); high = simd_max(high, p)
        }
        for i in instances {
            low = simd_min(low, i.centre - SIMD3(repeating: i.radius))
            high = simd_max(high, i.centre + SIMD3(repeating: i.radius))
        }
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
                sun: SIMD3<Float>, preset: DioramaTimeOfDay) -> simd_float4x4? {
        let casters = ranges.filter { !$0.category.isEmissive && $0.category != .water }
        let castingGroups = groups.filter { !$0.category.isEmissive }
        let snap: Float = 8
        var focusCorners: [SIMD3<Float>] = []
        var focusKey = ""
        if let focus {
            let lo = floor(focus.0 / snap) * snap, hi = ceil(focus.1 / snap) * snap
            for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z - 2, hi.z + 2] { focusCorners.append(SIMD3(x, y, z)) } } }
            focusKey = "\(lo.x),\(lo.y),\(lo.z),\(hi.x),\(hi.y),\(hi.z)"
        }
        let key = preset.rawValue + casters.map { $0.category.rawValue }.sorted().joined(separator: "/")
            + "|" + Set(castingGroups.map { $0.category.rawValue }).sorted().joined(separator: "/") + "|" + focusKey
        if cachedKey == key { return matrix }
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
        for range in casters {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: range.start * MemoryLayout<UInt32>.stride)
        }
        if let instances, !castingGroups.isEmpty {
            encoder.setRenderPipelineState(instancedPipeline)
            encoder.setVertexBuffer(instances, offset: 0, index: 3)
            for group in castingGroups where group.fullCount > 0 && !group.instances.isEmpty {
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: group.lightCount > 0 ? group.lightCount : group.fullCount, indexType: .uint32,
                                              indexBuffer: indices, indexBufferOffset: (group.lightCount > 0 ? group.lightStart : group.fullStart) * MemoryLayout<UInt32>.stride,
                                              instanceCount: group.instances.count, baseVertex: 0, baseInstance: group.firstInstance)
            }
        }
        encoder.endEncoding()
        matrix = candidate
        cachedKey = key
        return matrix
    }
}
