@_spi(Experimental) import MapboxMaps
import Metal
import CoreGraphics
import Foundation
import simd

/// Blanks every rendered basemap pixel outside the existing 45 km operational service zone.
/// A screen-space final layer is required: Standard clip layers do not clip land/water/roads.
nonisolated final class DarServiceMask: NSObject, CustomLayerHost {
    static let layerID = "zuri-dar-service-mask"
    private var pipeline: MTLRenderPipelineState?
    private var depth: MTLDepthStencilState?
    private let origin = DarEsSalaam.centre.coordinate

    @MainActor static func install(on map: MapboxMap) {
        guard !map.layerExists(withId: layerID) else { return }
        do {
            try map.addCustomLayer(withId: layerID, layerHost: DarServiceMask(), layerPosition: nil)
            // No slot: after all imported Standard labels, terrain, models and custom content.
            try map.setCameraBounds(with: CameraBoundsOptions(bounds: bounds, minZoom: 9, maxPitch: 75))
        } catch { print("[Map service area] mask/bounds unavailable") }
    }

    @MainActor static var bounds: CoordinateBounds {
        let r = DarEsSalaam.serviceRadiusKm * 1000
        return CoordinateBounds(southwest: DarEsSalaam.centre.offset(eastMetres: -r, northMetres: -r).coordinate,
                                northeast: DarEsSalaam.centre.offset(eastMetres: r, northMetres: r).coordinate)
    }

    func renderingWillStart(_ device: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 ndc; };
        vertex V maskVertex(uint id [[vertex_id]]) {
            float2 p = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
            return { float4(p, 0, 1), p };
        }
        fragment float4 maskFragment(V in [[stage_in]], constant float4x4 &inverse [[buffer(0)]],
                                     constant float4 &settings [[buffer(1)]]) {
            float4 a = inverse * float4(in.ndc, 0, 1);
            float4 b = inverse * float4(in.ndc, 0.5, 1);
            if (abs(a.w) < 1e-10 || abs(b.w) < 1e-10) return float4(settings.yzw, 1);
            float3 nearPoint = a.xyz / a.w, farPoint = b.xyz / b.w;
            float3 ray = farPoint - nearPoint;
            if (abs(ray.z) < 1e-8) return float4(settings.yzw, 1);
            float t = -nearPoint.z / ray.z;
            float2 ground = (nearPoint + ray * t).xy;
            if (t >= 0 && dot(ground, ground) <= settings.x * settings.x) discard_fragment();
            return float4(settings.yzw, 1);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "maskVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "maskFragment")
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormat(rawValue: colorPixelFormat) ?? .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = MTLPixelFormat(rawValue: depthStencilPixelFormat) ?? .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = descriptor.depthAttachmentPixelFormat
            pipeline = try DioramaPipelineCache.shared.state(device: device, descriptor: descriptor)
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .always; d.isDepthWriteEnabled = false
            depth = device.makeDepthStencilState(descriptor: d)
        } catch { print("[Map service area] Metal mask unavailable") }
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let pipeline, let depth, parameters.projectionMatrix.count == 16,
              let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { return }
        var projection = matrix_identity_double4x4
        for c in 0..<4 { for r in 0..<4 { projection[c, r] = parameters.projectionMatrix[c * 4 + r].doubleValue } }
        let p = Projection.project(origin, zoomScale: CGFloat(pow(2, parameters.zoom)))
        let scale = 1 / Double(Projection.metersPerPoint(for: origin.latitude, zoom: CGFloat(parameters.zoom)))
        var model = matrix_identity_double4x4
        model[0, 0] = scale; model[1, 1] = -scale; model[3, 0] = p.x; model[3, 1] = p.y
        let transform = projection * model
        DioramaViewport.shared.publish(.init(transform: transform, origin: origin, latitude: parameters.latitude,
            longitude: parameters.longitude, zoom: parameters.zoom, bearing: parameters.bearing, pitch: parameters.pitch))
        DioramaGPUPreparation.shared.captureSize(width: mtlRenderPassDescriptor.colorAttachments[0].texture?.width ?? 0,
                                                 height: mtlRenderPassDescriptor.colorAttachments[0].texture?.height ?? 0)
        let inverse = simd_inverse(transform)
        var matrix = simd_float4x4(columns: (SIMD4(inverse.columns.0), SIMD4(inverse.columns.1), SIMD4(inverse.columns.2), SIMD4(inverse.columns.3)))
        // The existing map canvas, not an ocean/land surface outside the zone.
        var settings = SIMD4<Float>(Float(DarEsSalaam.serviceRadiusKm * 1000), 247.0 / 255, 247.0 / 255, 247.0 / 255)
        encoder.label = "Dar service-area blank canvas"
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth); encoder.setCullMode(.none)
        encoder.setFragmentBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 0)
        encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func renderingWillEnd() { pipeline = nil; depth = nil }
}
