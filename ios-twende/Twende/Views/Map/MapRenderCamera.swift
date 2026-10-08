import Foundation
@_spi(Experimental) import MapboxMaps
import simd

/// Resolves a finite shading/LOD eye without rejecting orthographic top-down projections.
nonisolated enum MapRenderCamera {
    static func eye(transform: simd_double4x4, parameters: CustomLayerRenderParameters,
                    origin: CLLocationCoordinate2D) -> (position: SIMD3<Float>, usedFallback: Bool) {
        let homogeneous = simd_inverse(transform) * SIMD4<Double>(0, 0, 1, 0)
        if homogeneous.w.isFinite, abs(homogeneous.w) > 1e-8 {
            let p = SIMD3<Float>(Float(homogeneous.x / homogeneous.w), Float(homogeneous.y / homogeneous.w), Float(homogeneous.z / homogeneous.w))
            if p.x.isFinite, p.y.isFinite, p.z.isFinite { return (p, false) }
        }
        let projection = DioramaProjection(origin: origin)
        let centre = projection.local(longitude: parameters.longitude, latitude: parameters.latitude)
        let metresPerPoint = Double(Projection.metersPerPoint(for: parameters.latitude, zoom: CGFloat(parameters.zoom)))
        let fov = max(1, min(120, parameters.fieldOfView)) * .pi / 180
        let distance = max(10, parameters.height * metresPerPoint / (2 * tan(fov / 2)))
        let pitch = parameters.pitch * .pi / 180, bearing = parameters.bearing * .pi / 180
        let horizontal = distance * sin(pitch)
        return (SIMD3(Float(centre.x - sin(bearing) * horizontal), Float(centre.y - cos(bearing) * horizontal), Float(max(10, distance * cos(pitch)))), true)
    }
}
