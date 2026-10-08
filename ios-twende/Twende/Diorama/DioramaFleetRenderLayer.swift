@_spi(Experimental) import MapboxMaps
import Metal
import Foundation
import simd

/// Live vehicles share Mapbox's projection/depth and resident diorama lighting, not UIKit canvases.
nonisolated final class DioramaFleetRenderLayer: NSObject, CustomLayerHost {
    struct Pose: Equatable, Sendable {
        let id: String
        let tier: RideTier
        let point: GeoPoint
        let heading: Double
    }
    private struct Geometry {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let count: Int
    }
    private struct Support {
        let pose: Pose
        let host: ObjectIdentifier?
        let matrix: simd_float4x4
    }
    private let lock = NSLock()
    private var poses: [Pose] = []
    private var meshes: [RideTier: DioramaFleetMesh] = [:]
    private var time: DioramaTimeOfDay = .day
    private var geometry: [RideTier: Geometry] = [:]
    private var support: [String: Support] = [:]
    private var device: MTLDevice?
    private var pipeline: MTLRenderPipelineState?
    private var depth: MTLDepthStencilState?
    private var contactPipeline: MTLRenderPipelineState?
    private var contactDepth: MTLDepthStencilState?
    private var blank: MTLTexture?
    private var blankLight: MTLBuffer?
    private var blankTable: MTLBuffer?
    private var blankIndex: MTLBuffer?
    private var blankPaint: MTLBuffer?

    @MainActor func update(_ next: [Pose], time: DioramaTimeOfDay) -> Bool {
        lock.lock()
        let changed = poses != next || self.time != time
        let missing = Set(next.map(\.tier)).subtracting(meshes.keys)
        lock.unlock()
        guard changed else { return false }
        let built = missing.map { ($0, DioramaFleetMesh.make(for: $0)) }
        lock.lock()
        for (tier, mesh) in built { meshes[tier] = mesh }
        poses = next; self.time = time
        lock.unlock()
        return true
    }

    func renderingWillStart(_ device: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        self.device = device
        DioramaGPUPreparation.shared.capture(device: device, color: colorPixelFormat, depth: depthStencilPixelFormat)
        guard let library = DioramaShaderSource.library(for: device) else { return }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "dioramaFleetVertex")
        d.fragmentFunction = library.makeFunction(name: "dioramaFragment")
        d.colorAttachments[0].pixelFormat = MTLPixelFormat(rawValue: colorPixelFormat) ?? .bgra8Unorm
        d.depthAttachmentPixelFormat = MTLPixelFormat(rawValue: depthStencilPixelFormat) ?? .depth32Float_stencil8
        d.stencilAttachmentPixelFormat = d.depthAttachmentPixelFormat
        do {
            pipeline = try DioramaPipelineCache.shared.state(device: device, descriptor: d)
            d.vertexFunction = library.makeFunction(name: "dioramaFleetContactVertex")
            d.fragmentFunction = library.makeFunction(name: "dioramaFleetContactFragment")
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            contactPipeline = try DioramaPipelineCache.shared.state(device: device, descriptor: d)
        }
        catch { print("[Fleet map] pipeline unavailable"); return }
        let state = MTLDepthStencilDescriptor(); state.depthCompareFunction = .lessEqual; state.isDepthWriteEnabled = true
        depth = device.makeDepthStencilState(descriptor: state)
        state.isDepthWriteEnabled = false
        contactDepth = device.makeDepthStencilState(descriptor: state)
        func buffer<T>(_ value: T) -> MTLBuffer? {
            var value = value
            return withUnsafeBytes(of: &value) { bytes in
                guard let base = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
            }
        }
        blankLight = buffer(DioramaShaderLight(position: .zero, color: .zero))
        blankTable = buffer(SIMD2<UInt32>.zero); blankIndex = buffer(UInt32(0)); blankPaint = buffer(DioramaPaintTriangle.empty)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        td.usage = .shaderRead; td.storageMode = .shared
        blank = device.makeTexture(descriptor: td)
        var zero: UInt32 = 0
        withUnsafeBytes(of: &zero) { bytes in
            if let base = bytes.baseAddress { blank?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: base, bytesPerRow: 4) }
        }
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        lock.lock(); let poses = self.poses; let meshes = self.meshes; let time = self.time; lock.unlock()
        guard !poses.isEmpty, let device, let pipeline, let depth, let blankLight, let blankTable, let blankIndex, let blankPaint,
              let target = mtlRenderPassDescriptor.colorAttachments[0].texture, parameters.projectionMatrix.count == 16 else { return }
        DioramaGPUPreparation.shared.captureSize(width: target.width, height: target.height)
        for tier in Set(poses.map(\.tier)) where geometry[tier] == nil {
            guard let mesh = meshes[tier], !mesh.vertices.isEmpty, !mesh.indices.isEmpty else { continue }
            let vb = mesh.vertices.withUnsafeBytes { bytes -> MTLBuffer? in
                guard let base = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
            }
            let ib = mesh.indices.withUnsafeBytes { bytes -> MTLBuffer? in
                guard let base = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
            }
            if let vb, let ib { geometry[tier] = Geometry(vertices: vb, indices: ib, count: mesh.indices.count) }
        }
        guard let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        encoder.label = "Terrain-supported live fleet"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height),
            znear: Double(parameters.depthRange.min), zfar: Double(parameters.depthRange.max)))
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth)
        encoder.setFrontFacing(.counterClockwise); encoder.setCullMode(.none)
        var projection = matrix_identity_double4x4
        for c in 0..<4 { for r in 0..<4 { projection[c, r] = parameters.projectionMatrix[c * 4 + r].doubleValue } }
        support = support.filter { cached in poses.contains { $0.id == cached.key } }
        for pose in poses {
            guard let geometry = geometry[pose.tier] else { continue }
            let environment = DioramaFleetLighting.shared.environment(at: pose.point)
            let host = environment?.0
            let origin = environment?.1.origin ?? pose.point.coordinate
            let point = Projection.project(origin, zoomScale: CGFloat(pow(2, parameters.zoom)))
            let scale = 1 / Double(Projection.metersPerPoint(for: origin.latitude, zoom: CGFloat(parameters.zoom)))
            var anchor = matrix_identity_double4x4
            anchor[0, 0] = scale; anchor[1, 1] = -scale; anchor[3, 0] = point.x; anchor[3, 1] = point.y
            let transform = projection * anchor
            var matrix = simd_float4x4(columns: (SIMD4(transform.columns.0), SIMD4(transform.columns.1), SIMD4(transform.columns.2), SIMD4(transform.columns.3)))
            let eye = MapRenderCamera.eye(transform: transform, parameters: parameters, origin: origin).position
            var uniforms = environment?.1.uniforms ?? DioramaLighting.uniforms(for: time, eye: eye)
            uniforms.eye = SIMD4(eye, 1); uniforms.post.x = 0
            uniforms.reveal = .zero; uniforms.lifecycleReveal = .zero; uniforms.tileEdges = .zero; uniforms.tileState = SIMD4(1, 1, 0, 0)
            uniforms.shoreline.w = 0
            if environment == nil { uniforms.lightGrid = SIMD4(0, 0, 1, 1); uniforms.groundColor.w = 0 }
            uniforms.water.z = Float(target.width); uniforms.water.w = Float(target.height)
            let hostID = host.map(ObjectIdentifier.init)
            var model: simd_float4x4
            if let cached = support[pose.id], cached.pose == pose, cached.host == hostID, host != nil {
                model = cached.matrix
            } else {
                let angle = pose.heading * .pi / 180
                let s = sin(angle), c = cos(angle)
                let h = host?.groundHeight(at: pose.point)
                    ?? parameters.elevationData?.getElevationFor(pose.point.coordinate)?.doubleValue ?? 0
                let front = host?.groundHeight(at: pose.point.offset(eastMetres: s * 1.5, northMetres: c * 1.5)) ?? h
                let back = host?.groundHeight(at: pose.point.offset(eastMetres: -s * 1.5, northMetres: -c * 1.5)) ?? h
                let rightH = host?.groundHeight(at: pose.point.offset(eastMetres: c * 0.8, northMetres: -s * 0.8)) ?? h
                let leftH = host?.groundHeight(at: pose.point.offset(eastMetres: -c * 0.8, northMetres: s * 0.8)) ?? h
                let forward = simd_normalize(SIMD3<Float>(Float(s), Float(c), Float(max(-0.3, min(0.3, (front - back) / 3)))))
                var right = simd_normalize(SIMD3<Float>(Float(c), Float(-s), Float(max(-0.3, min(0.3, (rightH - leftH) / 1.6)))))
                let up = simd_normalize(simd_cross(right, forward)); right = simd_normalize(simd_cross(forward, up))
                let local = DioramaProjection(origin: origin).local(longitude: pose.point.longitude, latitude: pose.point.latitude)
                model = simd_float4x4(columns: (SIMD4(right, 0), SIMD4(forward, 0), SIMD4(up, 0), SIMD4(Float(local.x), Float(local.y), Float(h + 0.015), 1)))
                support[pose.id] = Support(pose: pose, host: hostID, matrix: model)
            }
            let vehicleMatrix = matrix * model
            let bounds = DioramaRenderLayer.Range(category: .props, start: 0, count: 0,
                minimum: SIMD3(-4, -4, -1), maximum: SIMD3(4, 4, 4))
            guard bounds.intersects(vehicleMatrix) else { continue }
            let buffers = environment?.1.buffers ?? [blankLight, blankTable, blankIndex, blankPaint, blankTable, blankIndex]
            let textures = environment?.1.textures ?? [blank, nil, blank, blank, blank]
            encoder.setVertexBuffer(geometry.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 2)
            encoder.setVertexBytes(&model, length: MemoryLayout<simd_float4x4>.stride, index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DioramaShaderUniforms>.stride, index: 0)
            for (i, buffer) in buffers.enumerated() { encoder.setFragmentBuffer(buffer, offset: 0, index: i + 1) }
            for (i, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: i) }
            if let contactPipeline, let contactDepth {
                var dimensions = SIMD4<Float>(Float(pose.tier.modelLengthMetres * 0.29), Float(pose.tier.modelLengthMetres * 0.53), 0, 0)
                encoder.setVertexBytes(&dimensions, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
                encoder.setRenderPipelineState(contactPipeline); encoder.setDepthStencilState(contactDepth)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: geometry.count, indexType: .uint32, indexBuffer: geometry.indices, indexBufferOffset: 0)
        }
        encoder.endEncoding()
    }

    func renderingWillEnd() {
        geometry.removeAll(); support.removeAll(); device = nil; pipeline = nil; depth = nil
        contactPipeline = nil; contactDepth = nil
        blank = nil; blankLight = nil; blankTable = nil; blankIndex = nil; blankPaint = nil
    }
}
