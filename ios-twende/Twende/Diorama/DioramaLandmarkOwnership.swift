import Foundation
import CoreLocation
import simd

/// Transient per-landmark ownership. Original downloaded indices remain the native fallback.
nonisolated enum DioramaLandmarkOwnership {
    private struct Feature: Decodable { let geometry: Geometry }
    private struct Geometry: Decodable { let coordinates: [[[Double]]] }
    private struct Catalog: Decodable { let sites: [Site] }
    private struct Site: Decodable { let id: String; let ring: [[Double]] }
    private static let outlines: [Site] = {
        var result: [Site] = []
        if let url = Bundle.main.url(forResource: "airtel_house", withExtension: "geojson"),
           let bytes = try? Data(contentsOf: url), let feature = try? JSONDecoder().decode(Feature.self, from: bytes),
           let ring = feature.geometry.coordinates.first { result.append(Site(id: "airtel", ring: ring)) }
        if let url = Bundle.main.url(forResource: "morocco_square", withExtension: "json"),
           let bytes = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: bytes) {
            result.append(contentsOf: catalog.sites)
        }
        return result.filter { $0.ring.count >= 4 && $0.ring.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } }
    }()

    private struct Mask {
        let id: String
        let ring: [DV2]
        let low: DV2
        let high: DV2
        func touches(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            Double(a.x) <= high.x && Double(b.x) >= low.x && Double(a.y) <= high.y && Double(b.y) >= low.y
        }
        func intersects(_ polygon: [DV2]) -> Bool {
            guard !polygon.isEmpty, (polygon.map(\.x).min() ?? 0) <= high.x,
                  (polygon.map(\.x).max() ?? 0) >= low.x, (polygon.map(\.y).min() ?? 0) <= high.y,
                  (polygon.map(\.y).max() ?? 0) >= low.y else { return false }
            if polygon.contains(where: { DioramaPolygon.contains(ring,$0) })
                || ring.contains(where: { DioramaPolygon.contains(polygon,$0) }) { return true }
            return polygon.indices.contains { i in ring.indices.contains { j in
                DioramaPolygon.segmentsIntersect(polygon[i],polygon[(i+1)%polygon.count],ring[j],ring[(j+1)%ring.count])
            } }
        }
    }

    private static func masks(origin: CLLocationCoordinate2D) -> [Mask] {
        let projection = DioramaProjection(origin: origin)
        return outlines.map { site in
            let source = site.ring.map { projection.local(longitude:$0[0],latitude:$0[1]) }
            let clean = DioramaPolygon.clean(source,flags:Array(repeating:false,count:source.count)).points
            let outline = DioramaPolygon.counterClockwise(clean)
            let ring = DioramaPolygon.offset(outline,by:1.0) ?? outline
            return Mask(id:site.id,ring:ring,low:DV2(ring.map(\.x).min() ?? 0,ring.map(\.y).min() ?? 0),
                high:DV2(ring.map(\.x).max() ?? 0,ring.map(\.y).max() ?? 0))
        }
    }

    static func partition(vertices: [BuildingRenderVertex], indices: [UInt32], ranges: [DioramaRenderLayer.Range],
                          groups: [DioramaInstanceGroup], origin: CLLocationCoordinate2D)
        -> (indices: [UInt32], ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup]) {
        guard let split = partition(indexCount:indices.count,index:{ indices[$0] },position:{ vertices[$0].position },
            ranges:ranges,groups:groups,origin:origin) else { return (indices,ranges,groups) }
        return (indices+split.appended,split.ranges,split.groups)
    }

    static func affects(ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup], origin: CLLocationCoordinate2D) -> Bool {
        let masks = masks(origin:origin)
        return ranges.contains { range in range.category == .buildings && masks.contains { $0.touches(range.minimum,range.maximum) } }
            || groups.contains { group in group.category == .buildings && masks.contains { $0.touches(group.minimum,group.maximum) } }
    }

    /// Splits only relevant finished-building triangles/placements, never terrain or road paint.
    static func partition(indexCount: Int, index: (Int) -> UInt32, position: (Int) -> SIMD4<Float>,
                          ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup], origin: CLLocationCoordinate2D)
        -> (appended: [UInt32], ranges: [DioramaRenderLayer.Range], groups: [DioramaInstanceGroup])? {
        let masks = masks(origin:origin)
        guard affects(ranges:ranges,groups:groups,origin:origin) else { return nil }
        var output: [UInt32] = [], result: [DioramaRenderLayer.Range] = []
        for range in ranges {
            let relevant = masks.filter { $0.touches(range.minimum,range.maximum) }
            guard (range.category == .buildings || range.category == .windowGlow), !relevant.isEmpty else { result.append(range); continue }
            var batches: [String:[UInt32]] = [:]
            for start in stride(from:range.start,to:range.start+range.count-2,by:3) {
                let ids = [index(start),index(start+1),index(start+2)]
                let triangle = ids.map { id -> DV2 in let p = position(Int(id)); return DV2(Double(p.x),Double(p.y)) }
                let owner = relevant.first(where: { $0.intersects(triangle) })?.id ?? ""
                batches[owner,default:[]].append(contentsOf:ids)
            }
            for owner in batches.keys.sorted() {
                guard let batch = batches[owner], !batch.isEmpty else { continue }
                result.append(.init(category:range.category,start:indexCount+output.count,count:batch.count,
                    minimum:range.minimum,maximum:range.maximum,doubleSided:range.doubleSided,
                    translucent:range.translucent,landmarkPlaceholder:!owner.isEmpty,landmarkID:owner.isEmpty ? nil : owner))
                output.append(contentsOf:batch)
            }
        }
        var split: [DioramaInstanceGroup] = []
        for group in groups {
            let relevant = masks.filter { $0.touches(group.minimum,group.maximum) }
            guard (group.category == .buildings || group.category == .windowGlow), !relevant.isEmpty else { split.append(group); continue }
            var low = SIMD2<Float>(repeating:.greatestFiniteMagnitude), high = -low
            for i in group.fullStart..<(group.fullStart+group.fullCount) {
                let p = position(Int(index(i))); low = simd_min(low,SIMD2(p.x,p.y)); high = simd_max(high,SIMD2(p.x,p.y))
            }
            let owners: [String?] = group.instances.map { instance in
                let c = Double(cos(instance.placement.w)), s = Double(sin(instance.placement.w))
                let polygon = [(low.x,low.y),(high.x,low.y),(high.x,high.y),(low.x,high.y)].map { x,y -> DV2 in
                    let px = Double(x*instance.scale.x), py = Double(y*instance.scale.y)
                    return DV2(px*c-py*s+Double(instance.placement.x),px*s+py*c+Double(instance.placement.y))
                }
                return relevant.first(where: { $0.intersects(polygon) })?.id
            }
            var first = 0
            while first < group.instances.count {
                let owner = owners[first]
                var end = first+1
                while end < group.instances.count && owners[end] == owner { end += 1 }
                split.append(.init(category:group.category,fullStart:group.fullStart,fullCount:group.fullCount,
                    lightStart:group.lightStart,lightCount:group.lightCount,doubleSided:group.doubleSided,
                    instances:Array(group.instances[first..<end]),firstInstance:group.firstInstance+first,
                    minimum:group.minimum,maximum:group.maximum,landmarkPlaceholder:owner != nil,landmarkID:owner,
                    lodSlot:group.lodSlot,lodScale:group.lodScale))
                first = end
            }
        }
        return (output,result,split)
    }
}

/// Weak, initialized entries on the owning map: removing one landmark restores only its saved shell.
nonisolated final class DioramaLandmarkPresence: @unchecked Sendable {
    static let shared = DioramaLandmarkPresence()
    private final class Entry {
        weak var host: DioramaLandmarkLayer?
        let viewport: ObjectIdentifier
        let id: String
        init(host: DioramaLandmarkLayer, viewport: DioramaViewport, id: String) {
            self.host = host; self.viewport = ObjectIdentifier(viewport); self.id = id
        }
    }
    private let lock = NSLock()
    private var entries: [ObjectIdentifier:Entry] = [:]
    func publish(host: DioramaLandmarkLayer, viewport: DioramaViewport) {
        guard let id = host.landmarkID else { return }
        lock.lock(); entries[ObjectIdentifier(host)] = Entry(host:host,viewport:viewport,id:id); lock.unlock()
    }
    func remove(host: DioramaLandmarkLayer) {
        lock.lock(); entries[ObjectIdentifier(host)] = nil; lock.unlock()
    }
    func activeIDs(viewport: DioramaViewport?) -> Set<String> {
        guard let viewport else { return [] }
        lock.lock(); defer { lock.unlock() }
        return Set(entries.values.filter { $0.host != nil && $0.viewport == ObjectIdentifier(viewport) }.map(\.id))
    }
    func hasAirtel(viewport: DioramaViewport?) -> Bool { activeIDs(viewport:viewport).contains("airtel") }
}
