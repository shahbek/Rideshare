import Foundation
import CoreLocation

/// An offline OSM snapshot, not a survey. Original IDs, tags and coordinates remain authoritative.
nonisolated struct AirportMapData: Sendable {
    struct Feature: Sendable {
        let id: Int
        let tags: [String: String]
        let coordinates: [[Double]]
        var isClosed: Bool { coordinates.count > 3 && coordinates.first == coordinates.last }
        func local(origin: CLLocationCoordinate2D) -> [DV2] {
            let projection = DioramaProjection(origin: origin)
            let points = coordinates.map { projection.local(longitude: $0[0], latitude: $0[1]) }
            return isClosed ? Array(points.dropLast()) : points
        }
    }
    let boundary: Feature
    let features: [Feature]
    let points: [Feature]
    var site: DarLandmarkSite {
        DarLandmarkSite(id: "jnia-airport", name: "Julius Nyerere International Airport", kind: "airport",
            osmWay: boundary.id, bearing: 315, height: 60,
            heightEvidence: "OSM geography; architectural heights and flat site support are illustrative, not surveyed",
            reference: "https://www.jnia.taa.go.tz/", photo: "https://r2-pub.rork.com/attachments/kxgcia6kp34mq8erihlql.jpg",
            orientationEvidence: "OSM terminal outlines cross-checked against inspected Esri aerial and frontage/airside photographs",
            ring: boundary.coordinates)
    }

    /// Mapped landside parking is part of the scenery, even outside the aerodrome fence.
    func groundRings(origin: CLLocationCoordinate2D) -> [[DV2]] {
        [boundary.local(origin: origin)] + features.filter {
            $0.isClosed && ($0.tags["amenity"] == "parking" || [23359828, 597787841, 1188629104, 1237792404].contains($0.id))
        }.map { $0.local(origin: origin) }
    }

    func groundRect(origin: CLLocationCoordinate2D) -> DioramaRect {
        DioramaRect.bounding(groundRings(origin: origin).flatMap { $0 })
    }

    /// The aerodrome line follows part of the terminal facade, not the full landside buildings.
    /// Preserve both that line and the original terminal/connector outlines as a mapped union.
    func validationRings(origin: CLLocationCoordinate2D) -> [[DV2]] {
        groundRings(origin: origin)
    }

    static func load() -> AirportMapData? {
        var ways: [Int: Feature] = [:], points: [Int: Feature] = [:]
        for resource in ["jnia_central_osm", "jnia_east_osm", "jnia_south_osm", "jnia_west_osm"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "xml"),
                  let bytes = try? Data(contentsOf: url), bytes.count <= 8 * 1_048_576 else {
                #if DEBUG
                print("[DarLandmarks] JNIA source unavailable/oversized: \(resource)")
                #endif
                return nil
            }
            let reader = AirportOSMParser()
            let parser = XMLParser(data: bytes); parser.delegate = reader
            guard parser.parse() else {
                #if DEBUG
                print("[DarLandmarks] JNIA XML rejected: \(resource)")
                #endif
                return nil
            }
            for feature in reader.features { ways[feature.id] = feature }
            for feature in reader.points { points[feature.id] = feature }
        }
        guard let boundary = ways[135694174], boundary.isClosed, boundary.coordinates.count <= 512 else { return nil }
        let polygon = boundary.coordinates.map { DV2($0[0], $0[1]) }
        let landside = ways.values.filter { [23359832, 23359828, 597787841, 1188629104, 1237792404].contains($0.id) && $0.isClosed }
            .map { $0.coordinates.map { DV2($0[0], $0[1]) } }
        let masks = [polygon] + landside
        let features = ways.values.filter { feature in
            guard feature.id != boundary.id else { return false }
            let ring = feature.coordinates.map { DV2($0[0], $0[1]) }
            return masks.contains { mask in
                ring.contains { DioramaPolygon.contains(mask, $0) }
                    || (feature.isClosed && mask.contains { DioramaPolygon.contains(ring, $0) })
                    || zip(ring, ring.dropFirst()).contains { a, b in
                        DioramaRect.bounding([a, b]).intersects(DioramaRect.bounding(mask))
                            && mask.indices.contains { i in
                                let c = mask[i], d = mask[(i + 1) % mask.count]
                                let ab = b - a, cd = d - c, cross = ab.cross(cd)
                                guard abs(cross) > 1e-12 else { return false }
                                let t = (c - a).cross(cd) / cross, u = (c - a).cross(ab) / cross
                                return (0...1).contains(t) && (0...1).contains(u)
                            }
                    }
            }
        }.sorted { $0.id < $1.id }
        // Required mapped parts fail closed; a partial download must never hide the native airport.
        let ids = Set(features.map(\.id))
        let required: Set<Int> = [23359828, 597787841, 1188629104, 1237792404, 157259598, 157259599, 438449950, 23359832]
        guard required.isSubset(of: ids) else {
            #if DEBUG
            print("[DarLandmarks] JNIA incomplete mapped parts: \(required.subtracting(ids).sorted())")
            #endif
            return nil
        }
        return AirportMapData(boundary: boundary, features: features, points: points.values.filter {
            $0.coordinates.contains { DioramaPolygon.contains(polygon, DV2($0[0], $0[1])) }
        }.sorted { $0.id < $1.id })
    }
}
