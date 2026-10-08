import Foundation
import CoreLocation
import simd

/// Transient geometry ownership. Original saved indices remain usable when the bespoke host is absent.
nonisolated enum DioramaLandmarkOwnership {
    private struct Feature: Decodable { let geometry: Geometry }
    private struct Geometry: Decodable { let coordinates: [[[Double]]] }
    private static let geographicRing: [[Double]] = {
        guard let url = Bundle.main.url(forResource: "airtel_house", withExtension: "geojson"),
              let bytes = try? Data(contentsOf: url), let feature = try? JSONDecoder().decode(Feature.self, from: bytes) else { return [] }
        return feature.geometry.coordinates.first ?? []
    }()

    static func partition(vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [DioramaRenderLayer.Range],
                          groups: [DioramaInstanceGroup], origin: CLLocationCoordinate2D)
        -> (indices: [UInt32], ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup]) {
        guard let split = partition(indexCount: indices.count, index: { indices[$0] }, position: { vertices[$0].position },
                                    ranges: ranges, groups: groups, origin: origin) else { return (indices, ranges, groups) }
        return (indices + split.appended, split.ranges, split.groups)
    }

    /// Whether `partition` could add a copied index list (for memory preflight).
    static func affects(ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup], origin: CLLocationCoordinate2D) -> Bool {
        let projection = DioramaProjection(origin: origin)
        let ring = geographicRing.map { projection.local(longitude: $0[0], latitude: $0[1]) }
        guard ring.count >= 3 else { return false }
        let lo = DV2(ring.map(\.x).min() ?? 0, ring.map(\.y).min() ?? 0) - DV2(3, 3)
        let hi = DV2(ring.map(\.x).max() ?? 0, ring.map(\.y).max() ?? 0) + DV2(3, 3)
        func touches(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            Double(a.x) <= hi.x && Double(b.x) >= lo.x && Double(a.y) <= hi.y && Double(b.y) >= lo.y
        }
        return ranges.contains { $0.category == .buildings && touches($0.minimum, $0.maximum) }
            || groups.contains { $0.category == .buildings && touches($0.minimum, $0.maximum) }
    }

    /// Buffer-agnostic form: returns indices to append after the existing `indexCount`, or nil when untouched.
    static func partition(indexCount: Int, index: (Int) -> UInt32, position: (Int) -> SIMD4<Float>,
                          ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup], origin: CLLocationCoordinate2D)
        -> (appended: [UInt32], ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup])? {
        let projection = DioramaProjection(origin: origin)
        let ring = geographicRing.map { projection.local(longitude: $0[0], latitude: $0[1]) }
        guard ring.count >= 3 else { return nil }
        let outline = DioramaPolygon.counterClockwise(ring)
        let mask = DioramaPolygon.offset(outline, by: 2.0) ?? outline
        let lo = DV2(mask.map(\.x).min() ?? 0, mask.map(\.y).min() ?? 0)
        let hi = DV2(mask.map(\.x).max() ?? 0, mask.map(\.y).max() ?? 0)
        func touches(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            Double(a.x) <= hi.x && Double(b.x) >= lo.x && Double(a.y) <= hi.y && Double(b.y) >= lo.y
        }
        func intersectsMask(_ polygon: [DV2]) -> Bool {
            guard !polygon.isEmpty,
                  (polygon.map(\.x).min() ?? 0) <= hi.x, (polygon.map(\.x).max() ?? 0) >= lo.x,
                  (polygon.map(\.y).min() ?? 0) <= hi.y, (polygon.map(\.y).max() ?? 0) >= lo.y else { return false }
            if polygon.contains(where: { DioramaPolygon.contains(mask, $0) })
                || mask.contains(where: { DioramaPolygon.contains(polygon, $0) }) { return true }
            return polygon.indices.contains { i in mask.indices.contains { j in
                DioramaPolygon.segmentsIntersect(polygon[i], polygon[(i + 1) % polygon.count], mask[j], mask[(j + 1) % mask.count])
            } }
        }
        guard ranges.contains(where: { $0.category == .buildings && touches($0.minimum, $0.maximum) })
            || groups.contains(where: { $0.category == .buildings && touches($0.minimum, $0.maximum) }) else { return nil }
        var output: [UInt32] = [], result: [DioramaRenderLayer.Range] = []
        for range in ranges {
            guard (range.category == .buildings || range.category == .windowGlow), touches(range.minimum, range.maximum) else { result.append(range); continue }
            var owned: [UInt32] = [], ordinary: [UInt32] = []
            for start in stride(from: range.start, to: range.start + range.count - 2, by: 3) {
                let ids = [index(start), index(start + 1), index(start + 2)]
                let pts = ids.map { id -> DV2 in let p = position(Int(id)); return DV2(Double(p.x), Double(p.y)) }
                if intersectsMask(pts) { owned.append(contentsOf: ids) }
                else { ordinary.append(contentsOf: ids) }
            }
            for (batch, placeholder) in [(ordinary, false), (owned, true)] where !batch.isEmpty {
                let copy = DioramaRenderLayer.Range(category: range.category, start: indexCount + output.count, count: batch.count,
                    minimum: range.minimum, maximum: range.maximum, doubleSided: range.doubleSided, landmarkPlaceholder: placeholder)
                result.append(copy); output.append(contentsOf: batch)
            }
        }
        var split: [DioramaInstanceGroup] = []
        for group in groups {
            guard (group.category == .buildings || group.category == .windowGlow), touches(group.minimum, group.maximum) else { split.append(group); continue }
            var prototypeLow = SIMD2<Float>(repeating: .greatestFiniteMagnitude), prototypeHigh = -prototypeLow
            for i in group.fullStart..<(group.fullStart + group.fullCount) {
                let p = position(Int(index(i)))
                prototypeLow = simd_min(prototypeLow, SIMD2(p.x,p.y)); prototypeHigh = simd_max(prototypeHigh, SIMD2(p.x,p.y))
            }
            let ownedFlags = group.instances.map { instance -> Bool in
                let c = Double(cos(instance.placement.w)), s = Double(sin(instance.placement.w))
                let polygon = [(prototypeLow.x,prototypeLow.y), (prototypeHigh.x,prototypeLow.y),
                    (prototypeHigh.x,prototypeHigh.y), (prototypeLow.x,prototypeHigh.y)].map { x, y -> DV2 in
                    let px = Double(x * instance.scale.x), py = Double(y * instance.scale.y)
                    return DV2(px * c - py * s + Double(instance.placement.x), px * s + py * c + Double(instance.placement.y))
                }
                return intersectsMask(polygon)
            }
            var first = 0
            while first < group.instances.count {
                func owned(_ i: Int) -> Bool { ownedFlags[i] }
                let flag = owned(first)
                var end = first + 1
                while end < group.instances.count && owned(end) == flag { end += 1 }
                split.append(.init(category: group.category, fullStart: group.fullStart, fullCount: group.fullCount,
                    lightStart: group.lightStart, lightCount: group.lightCount, doubleSided: group.doubleSided,
                    instances: Array(group.instances[first..<end]), firstInstance: group.firstInstance + first,
                    minimum: group.minimum, maximum: group.maximum, landmarkPlaceholder: flag))
                first = end
            }
        }
        return (output, result, split)
    }
}

/// Scoped to the same map as saved scenery; weak entries cannot leave a hole after teardown/failure.
nonisolated final class DioramaLandmarkPresence: @unchecked Sendable {
    static let shared = DioramaLandmarkPresence()
    private final class Entry {
        weak var host: DioramaLandmarkLayer?
        let viewport: ObjectIdentifier
        init(host: DioramaLandmarkLayer, viewport: DioramaViewport) { self.host = host; self.viewport = ObjectIdentifier(viewport) }
    }
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    func publish(host: DioramaLandmarkLayer, viewport: DioramaViewport) {
        lock.lock(); entries[ObjectIdentifier(host)] = Entry(host: host, viewport: viewport); lock.unlock()
    }
    func remove(host: DioramaLandmarkLayer) {
        lock.lock(); entries[ObjectIdentifier(host)] = nil; lock.unlock()
    }
    func hasAirtel(viewport: DioramaViewport?) -> Bool {
        guard let viewport else { return false }
        lock.lock(); defer { lock.unlock() }
        return entries.values.contains { $0.host != nil && $0.viewport == ObjectIdentifier(viewport) }
    }
}
