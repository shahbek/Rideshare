import MapboxMaps
import CoreGraphics
import Foundation
import simd

/// View-dependent chunk interest, using the current SDK transform and ground probes at bootstrap.
@MainActor enum AirportChunkInterest {
    static func keys(_ catalog: AirportSpatialPackage.Catalog, on map: MapboxMap, viewport: DioramaViewport?, bounds: CGRect) -> Set<String> {
        let projection = DioramaProjection(origin: catalog.coordinate)
        let centre = projection.local(longitude: map.cameraState.center.longitude, latitude: map.cameraState.center.latitude)
        var matrix: simd_float4x4?
        if let s = viewport?.snapshot(), abs(s.zoom - map.cameraState.zoom) < 0.02,
           abs(s.latitude - map.cameraState.center.latitude) < 0.0000001,
           abs(s.longitude - map.cameraState.center.longitude) < 0.0000001,
           abs(s.bearing - map.cameraState.bearing) < 0.05, abs(s.pitch - map.cameraState.pitch) < 0.05 {
            let offset = DioramaProjection(origin: s.origin).local(longitude: catalog.coordinate.longitude, latitude: catalog.coordinate.latitude)
            var translate = matrix_identity_double4x4; translate.columns.3 = SIMD4(offset.x, offset.y, 0, 1)
            let m = s.transform * translate
            matrix = simd_float4x4(columns: (SIMD4(m.columns.0), SIMD4(m.columns.1), SIMD4(m.columns.2), SIMD4(m.columns.3)))
        }
        var probes: [DV2] = [centre]
        for x in 0..<5 { for y in 0..<5 {
            let point = CGPoint(x: bounds.minX + bounds.width * (Double(x) + 0.5) / 5, y: bounds.minY + bounds.height * (Double(y) + 0.5) / 5)
            let coordinate = map.coordinate(for: point), roundtrip = map.point(for: coordinate)
            if roundtrip.x.isFinite, roundtrip.y.isFinite, hypot(roundtrip.x - point.x, roundtrip.y - point.y) < 4 {
                probes.append(projection.local(longitude: coordinate.longitude, latitude: coordinate.latitude))
            }
        } }
        let wanted = catalog.chunks.filter { item in
            let r = item.rect
            if probes.contains(where: { r.expanded(by: 40).contains($0) }) { return true }
            guard let matrix else { return false }
            return DioramaRenderLayer.Range(category: .buildings, start: 0, count: 0,
                minimum: SIMD3(Float(r.minX), Float(r.minY), 0), maximum: SIMD3(Float(r.maxX), Float(r.maxY), 61)).intersects(matrix)
        }.sorted { a, b in
            func distance(_ r: DioramaRect) -> Double {
                let p = DV2(min(r.maxX, max(r.minX, centre.x)), min(r.maxY, max(r.minY, centre.y)))
                return p.distance(to: centre)
            }
            return distance(a.rect) < distance(b.rect)
        }
        // A bounded detail bubble, not all-airport HD on a distant overview. Native scenery remains outside it.
        let seed = Set(wanted.prefix(12).map(\.key))
        var selected = seed
        // Complete any building touched by the initial view; otherwise its native shell stays authoritative.
        for owner in catalog.ownership where !seed.isDisjoint(with: owner.keys) { selected.formUnion(owner.keys) }
        return selected
    }
}
